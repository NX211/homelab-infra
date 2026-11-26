"""Unit tests for the pure parts of uploader.py: parsing, reconcile, counts."""
import datetime as dt
import json
import unittest

import uploader as u

NOW = dt.datetime(2026, 12, 6, 3, 0, tzinfo=dt.timezone.utc)
T = {"app": "reggiesbbq", "service": "reggiesbbq", "url": "https://staging.reggiesbbqonline.com"}

ZAP = {"site": [{"@name": T["url"], "alerts": [
    {"alertRef": "10038-1", "alert": "CSP Header Not Set", "riskcode": "2", "confidence": "2",
     "count": "3", "cweid": "693", "solution": "<p>Set a CSP.</p>", "desc": "<p>No CSP</p>",
     "instances": [{"uri": "https://staging.reggiesbbqonline.com/"}]},
    {"alertRef": "10096", "alert": "Timestamp Disclosure", "riskcode": "0", "confidence": "1", "instances": []},
    {"alertRef": "40012", "alert": "XSS", "riskcode": "3", "confidence": "0", "instances": []},
    {"alertRef": "10202", "alert": "Absence of Anti-CSRF Tokens", "riskcode": "3", "confidence": "2",
     "instances": [{"uri": "a"}, {"uri": "b"}]},
]}]}

NUCLEI = [
    json.dumps({"template-id": "git-config", "info": {"name": "Git Config", "severity": "medium",
               "classification": {"cwe-id": ["cwe-200"]}}, "matched-at": "https://x/.git/config"}),
    json.dumps({"template-id": "git-config", "info": {"name": "Git Config", "severity": "medium"},
                "matched-at": "https://y/.git/config"}),
    json.dumps({"template-id": "tech-detect", "matcher-name": "nextjs", "info": {"name": "Tech", "severity": "info"}}),
    "",
]


class Parse(unittest.TestCase):
    def test_zap(self):
        f = {x["rule_id"]: x for x in u.parse_zap(ZAP)}
        self.assertNotIn("40012", f, "confidence 0 is a false positive")
        self.assertEqual(f["10038-1"]["severity"], "medium")
        self.assertEqual(f["10038-1"]["instances"], 3)
        self.assertEqual(f["10038-1"]["solution"], "Set a CSP.")
        self.assertEqual(f["10202"]["severity"], "high")
        self.assertEqual(f["10202"]["instances"], 2)
        self.assertEqual(f["10096"]["severity"], "info")

    def test_nuclei(self):
        f = {x["rule_id"]: x for x in u.parse_nuclei(NUCLEI)}
        self.assertEqual(f["git-config"]["instances"], 2)
        self.assertEqual(f["git-config"]["cwe"], "cwe-200")
        self.assertIn("tech-detect:nextjs", f)

    def test_counts(self):
        self.assertEqual(u.counts(u.parse_zap(ZAP)), {"info": 1, "low": 0, "medium": 1, "high": 1, "critical": 0})


class Reconcile(unittest.TestCase):
    def run_(self, found, state):
        return u.reconcile("zap", T, found, state, NOW, "gs://b/p/", ["SDP-5.3"])

    def test_new_findings_open_with_policy_targets(self):
        items, nxt = self.run_(u.parse_zap(ZAP), {})
        by = {i["id"]: i for i in items}
        self.assertEqual(set(by), {"zap-reggiesbbq-10038-1", "zap-reggiesbbq-10202"}, "info is not synced")
        self.assertEqual(by["zap-reggiesbbq-10202"]["target_date"], "2027-01-05T03:00:00Z")  # high: 30 days
        self.assertEqual(by["zap-reggiesbbq-10038-1"]["target_date"], "2027-03-06T03:00:00Z")  # medium: 90 days
        self.assertEqual(set(nxt), set(by))

    def test_first_seen_survives_and_drives_target(self):
        state = {"zap-reggiesbbq-10202": {"first_seen": "2026-11-01T00:00:00Z"}}
        items, nxt = self.run_(u.parse_zap(ZAP), state)
        i = next(x for x in items if x["id"] == "zap-reggiesbbq-10202")
        self.assertEqual(i["first_seen"], "2026-11-01T00:00:00Z")
        self.assertEqual(i["target_date"], "2026-12-01T00:00:00Z")
        self.assertEqual(nxt["zap-reggiesbbq-10202"]["first_seen"], "2026-11-01T00:00:00Z")

    def test_absent_finding_resolves_with_full_record_and_leaves_state(self):
        _, first = u.reconcile("zap", T, u.parse_zap(ZAP), {}, NOW - dt.timedelta(days=7), "gs://b/old/", ["SDP-5.3"])
        items, nxt = self.run_([], first)
        self.assertEqual(nxt, {})
        r = next(i for i in items if i["id"] == "zap-reggiesbbq-10202")
        self.assertEqual((r["state"], r["resolved_at"], r["evidence_uri"]), ("resolved", "2026-12-06T03:00:00Z", "gs://b/p/"))
        self.assertEqual((r["title"], r["severity"], r["first_seen"]),
                         ("Absence of Anti-CSRF Tokens (reggiesbbq)", "high", "2026-11-29T03:00:00Z"))

    def test_state_texts_are_shortened(self):
        long = [{"rule_id": "r", "name": "n", "severity": "low", "instances": 1, "cwe": "",
                 "solution": "s" * 2000, "description": "d" * 2000, "example": ""}]
        items, nxt = self.run_(long, {})
        self.assertEqual(len(items[0]["solution"]), 2000)
        self.assertEqual(len(nxt["zap-reggiesbbq-r"]["solution"]), 300)

    def test_low_has_no_target(self):
        items, _ = self.run_([{"rule_id": "r", "name": "n", "severity": "low", "instances": 1,
                               "cwe": "", "solution": "", "description": "", "example": ""}], {})
        self.assertIsNone(items[0]["target_date"])

    def test_ids_are_port_safe(self):
        items, _ = self.run_([{"rule_id": "Tech Detect:Next.JS", "name": "n", "severity": "low", "instances": 1,
                               "cwe": "", "solution": "", "description": "", "example": ""}], {})
        self.assertRegex(items[0]["id"], r"^[a-z0-9-]+$")


class Success(unittest.TestCase):
    def test_exit_codes(self):
        self.assertTrue(u.succeeded("zap", {"exit_code": 2}))
        self.assertFalse(u.succeeded("zap", {"exit_code": 3}))
        self.assertFalse(u.succeeded("nuclei", {"exit_code": 1}))
        self.assertFalse(u.succeeded("nuclei", {}))


if __name__ == "__main__":
    unittest.main()

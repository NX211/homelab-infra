#!/usr/bin/env python3
"""Store one scan run as compliance evidence and sync its findings to Port.

Runs after a scanner (security-scans/*-cronjob.yaml) has written, per target,
REPORTS_DIR/<app>/status.json plus the tool's raw output. For each target it:

1. uploads every file and then manifest.json (sha256, versions, target, deployed
   images, UTC times, severity counts, requirements) to
   gs://EVIDENCE_BUCKET/scans/<tool>/<app>/<yyyy-mm-dd>/<run>/ -- create-only
   (ifGenerationMatch=0), with a federated token from the pod's projected k3s
   token: no key material.
2. on a successful scan only, sends the low-and-above findings to the Port
   webhook: current ones open (first_seen kept from earlier runs), ones that were
   open before and are now absent resolved. A failed scan resolves nothing --
   absence is evidence only when the scan completed.

First-seen dates and the open set live in the ConfigMap scan-state-<tool>.
Standard library only. Exits non-zero if any target failed to store or sync.
"""
import datetime as dt
import hashlib
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

SEVERITIES = ["info", "low", "medium", "high", "critical"]
# docs/vulnerability-management-policy.md VUL-3.2..3.5 (low: next routine update)
TARGET_DAYS = {"critical": 7, "high": 30, "medium": 90}
ZAP_RISK = {"0": "info", "1": "low", "2": "medium", "3": "high"}
K8S = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
CHUNK = 50


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(s).lower()).strip("-")[:80]


def clip(s, n=2000) -> str:
    return re.sub(r"<[^>]+>", "", str(s or "")).strip()[:n]


def parse_zap(doc: dict) -> list:
    """ZAP traditional JSON (-J) -> findings. Confidence 0 means false positive."""
    out = {}
    for site in doc.get("site") or []:
        for a in site.get("alerts") or []:
            if str(a.get("confidence")) == "0":
                continue
            rule = a.get("alertRef") or a.get("pluginid")
            f = out.setdefault(rule, {
                "rule_id": str(rule),
                "name": a.get("alert") or a.get("name") or str(rule),
                "severity": ZAP_RISK.get(str(a.get("riskcode")), "info"),
                "instances": 0,
                "cwe": str(a.get("cweid") or ""),
                "solution": clip(a.get("solution")),
                "description": clip(a.get("desc")),
                "example": "",
            })
            inst = a.get("instances") or []
            f["instances"] += int(a.get("count") or len(inst) or 1)
            if not f["example"] and inst:
                f["example"] = str(inst[0].get("uri", ""))[:500]
    return list(out.values())


def parse_nuclei(lines) -> list:
    """Nuclei JSONL -> one finding per template (and matcher)."""
    out = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        info = r.get("info") or {}
        rule = r.get("template-id", "unknown") + (":" + r["matcher-name"] if r.get("matcher-name") else "")
        sev = str(info.get("severity", "info")).lower()
        f = out.setdefault(rule, {
            "rule_id": rule,
            "name": info.get("name") or rule,
            "severity": sev if sev in SEVERITIES else "info",
            "instances": 0,
            "cwe": ",".join((info.get("classification") or {}).get("cwe-id") or []),
            "solution": clip(info.get("remediation")),
            "description": clip(info.get("description")),
            "example": str(r.get("matched-at", ""))[:500],
        })
        f["instances"] += 1
    return list(out.values())


def reconcile(tool, target, found, state, now, evidence_uri, requirements):
    """Port payload items and the next state for one successfully scanned target.

    The state keeps each open finding's last payload (texts shortened), because
    a resolution must re-send every property: the webhook has one mapping, and
    a property it maps to a missing key would be blanked."""
    app, service = target["app"], target["service"]
    items, nxt = [], {}
    for f in found:
        if SEVERITIES.index(f["severity"]) < SEVERITIES.index("low"):
            continue
        fid = f"{tool}-{slug(app)}-{slug(f['rule_id'])}"
        first = (state.get(fid) or {}).get("first_seen") or iso(now)
        days = TARGET_DAYS.get(f["severity"])
        target_date = iso(dt.datetime.fromisoformat(first.replace("Z", "+00:00")) + dt.timedelta(days=days)) if days else None
        item = {
            "id": fid, "title": f"{f['name']} ({app})"[:200], "tool": tool, "app": app, "service": service,
            "rule_id": f["rule_id"], "severity": f["severity"], "state": "open",
            "first_seen": first, "last_seen": iso(now), "resolved_at": None, "target_date": target_date,
            "target_url": target["url"], "example": f["example"], "instances": f["instances"], "cwe": f["cwe"],
            "description": f["description"], "solution": f["solution"],
            "evidence_uri": evidence_uri, "requirements": requirements,
        }
        items.append(item)
        nxt[fid] = dict(item, description=item["description"][:300], solution=item["solution"][:300])
    for fid, prev in state.items():
        if fid not in nxt:
            items.append(dict(prev, state="resolved", resolved_at=iso(now), evidence_uri=evidence_uri))
    return items, nxt


def counts(found) -> dict:
    c = {s: 0 for s in SEVERITIES}
    for f in found:
        c[f["severity"]] += 1
    return c


# --- I/O -----------------------------------------------------------------------

def http(method, url, body=None, headers=None, ctx=None, timeout=60):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        raw = r.read()
        return json.loads(raw) if raw and "json" in r.headers.get("content-type", "") else raw


def gcp_token() -> str:
    form = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "audience": os.environ["WIF_AUDIENCE"],
        "scope": "https://www.googleapis.com/auth/devstorage.read_write",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
        "subject_token": open(os.environ.get("WIF_TOKEN_FILE", "/var/run/gcp/token")).read().strip(),
    }).encode()
    return http("POST", "https://sts.googleapis.com/v1/token", form,
                {"Content-Type": "application/x-www-form-urlencoded"})["access_token"]


def gcs_put(token, bucket, name, data: bytes, ctype):
    q = urllib.parse.urlencode({"uploadType": "media", "name": name, "ifGenerationMatch": "0"})
    http("POST", f"https://storage.googleapis.com/upload/storage/v1/b/{bucket}/o?{q}", data,
         {"Authorization": f"Bearer {token}", "Content-Type": ctype})


class Kube:
    def __init__(self):
        self.ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
        self.ns = open(f"{SA_DIR}/namespace").read().strip()

    def call(self, method, path, body=None, ctype="application/json"):
        tok = open(f"{SA_DIR}/token").read().strip()
        data = json.dumps(body).encode() if body is not None else None
        return http(method, K8S + path, data, {"Authorization": f"Bearer {tok}", "Content-Type": ctype}, self.ctx)

    def state(self, name) -> dict:
        try:
            cm = self.call("GET", f"/api/v1/namespaces/{self.ns}/configmaps/{name}")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            self.call("POST", f"/api/v1/namespaces/{self.ns}/configmaps",
                      {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name}, "data": {}})
            return {}
        return {k: json.loads(v) for k, v in (cm.get("data") or {}).items()}

    def save(self, name, app, value: dict):
        self.call("PATCH", f"/api/v1/namespaces/{self.ns}/configmaps/{name}",
                  {"data": {app: json.dumps(value, sort_keys=True)}}, "application/merge-patch+json")

    def images(self, app) -> list:
        try:
            a = self.call("GET", f"/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/staging-{app}")
            return sorted((a.get("status") or {}).get("summary", {}).get("images") or [])
        except urllib.error.HTTPError as e:
            return [f"unavailable: HTTP {e.code}"]


def raw_findings(tool, d):
    if tool == "zap":
        return parse_zap(json.load(open(os.path.join(d, "report.json"))))
    return parse_nuclei(open(os.path.join(d, "results.jsonl")))


def succeeded(tool, status) -> bool:
    # zap-baseline.py: 0 pass, 1 FAIL-level alerts, 2 WARN-level alerts, 3 error.
    return status.get("exit_code") in ((0, 1, 2) if tool == "zap" else (0,))


def main() -> int:
    tool = os.environ["TOOL"]
    reports = os.environ.get("REPORTS_DIR", "/reports")
    bucket = os.environ["EVIDENCE_BUCKET"]
    requirements = [r for r in os.environ.get("REQUIREMENTS", "").split(",") if r]
    run = os.environ.get("RUN_ID", "manual")
    webhook = open(os.environ.get("PORT_WEBHOOK_URL_FILE", "/secrets/port/url")).read().strip()
    targets = json.load(open(os.environ.get("TARGETS_FILE", "/config/targets.json")))
    kube, state_cm = Kube(), f"scan-state-{tool}"
    state, token, failures = kube.state(state_cm), gcp_token(), 0

    for t in targets:
        app, d = t["app"], os.path.join(reports, t["app"])
        try:
            status = json.load(open(os.path.join(d, "status.json")))
        except (OSError, ValueError):
            print(f"[{app}] no status.json: scanner did not run", flush=True)
            failures += 1
            continue
        now = dt.datetime.now(dt.timezone.utc)
        prefix = f"scans/{tool}/{app}/{now:%Y-%m-%d}/{run}"
        ok = succeeded(tool, status)
        try:
            found = raw_findings(tool, d) if ok else []
        except (OSError, ValueError) as e:
            print(f"[{app}] report unreadable ({e}); treating the scan as failed", flush=True)
            ok, found = False, []
        files = []
        try:
            for name in sorted(os.listdir(d)):
                data = open(os.path.join(d, name), "rb").read()
                ctype = "application/json" if name.endswith((".json", ".jsonl")) else (
                    "text/html" if name.endswith(".html") else "text/plain")
                gcs_put(token, bucket, f"{prefix}/{name}", data, ctype)
                files.append({"name": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
            manifest = {
                "schema": 1, "tool": tool, "tool_version": status.get("tool_version"),
                "templates_version": status.get("templates_version"),
                "app": app, "service": t["service"], "target": t["url"], "app_images": kube.images(app),
                "run_id": run, "started_at": status.get("started_at"), "finished_at": status.get("finished_at"),
                "scan_status": "succeeded" if ok else "failed", "exit_code": status.get("exit_code"),
                "requirements": requirements, "counts": counts(found), "files": files,
            }
            gcs_put(token, bucket, f"{prefix}/manifest.json",
                    json.dumps(manifest, indent=2, sort_keys=True).encode(), "application/json")
        except urllib.error.HTTPError as e:
            print(f"[{app}] evidence upload failed: HTTP {e.code} {e.read()[:300]!r}", flush=True)
            failures += 1
            continue
        if not ok:
            print(f"[{app}] scan failed (exit {status.get('exit_code')}); evidence stored, findings untouched", flush=True)
            failures += 1
            continue
        items, nxt = reconcile(tool, t, found, state.get(app) or {}, now, f"gs://{bucket}/{prefix}/", requirements)
        try:
            for i in range(0, len(items), CHUNK):
                http("POST", webhook, json.dumps({"tool": tool, "app": app, "run_id": run,
                                                  "findings": items[i:i + CHUNK]}).encode(),
                     {"Content-Type": "application/json"})
            kube.save(state_cm, app, nxt)
        except urllib.error.HTTPError as e:
            print(f"[{app}] Port sync failed: HTTP {e.code}; state kept for the next run", flush=True)
            failures += 1
            continue
        c = counts(found)
        print(f"[{app}] stored {len(files) + 1} files; open={len(nxt)} "
              f"resolved={sum(1 for x in items if x['state'] == 'resolved')} "
              f"high+={c['high'] + c['critical']}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

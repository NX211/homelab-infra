#!/usr/bin/env python3
"""Fail when a Tekton Pipeline references a $(params.x) that does not resolve.

Tekton's admission webhook rejects such a Pipeline outright, but these
Pipelines are git-resolved at run time, so the rejection only surfaces when a
lane is dispatched. #1345 shipped `$(params.image)` into heal-rule and
implement-spec and both lanes were dead until it was noticed.

Scope rules mirrored from Tekton:
  - a pipeline task's own `params:` values see the Pipeline's params;
  - an inline taskSpec sees the Pipeline's params (propagation) plus the
    params it DECLARES. A pipeline task's own `params:` entry (the only way a
    $(tasks.x.results.y) reaches an inline taskSpec) is visible only once the
    taskSpec declares it; the admission webhook rejects it otherwise.

  scripts/check-pipeline-params.py build-catalog/pipelines/*.yaml
"""
import re
import sys

import yaml

REF = re.compile(r"\$\(params(?:\.([A-Za-z0-9_-]+)|\[['\"]([A-Za-z0-9_.-]+)['\"]\])")


def refs(node) -> set:
    found = set()
    if isinstance(node, dict):
        for v in node.values():
            found |= refs(v)
    elif isinstance(node, list):
        for v in node:
            found |= refs(v)
    elif isinstance(node, str):
        found |= {a or b for a, b in REF.findall(node)}
    return found


def check(doc: dict) -> list:
    spec = doc.get("spec") or {}
    declared = {p["name"] for p in spec.get("params") or []}
    errors = []
    for section in ("tasks", "finally"):
        for task in spec.get(section) or []:
            name = task.get("name", "?")
            for ref in sorted(refs(task.get("params") or []) - declared):
                errors.append(f"{section}/{name} params: $(params.{ref}) is not a Pipeline param")
            ts = task.get("taskSpec")
            if not ts:
                continue
            scope = declared | {p["name"] for p in ts.get("params") or []}
            body = {k: v for k, v in ts.items() if k != "params"}
            for ref in sorted(refs(body) - scope):
                errors.append(f"{section}/{name}: $(params.{ref}) is neither a Pipeline param nor declared in its taskSpec")
    return errors


def main(paths) -> int:
    bad = 0
    for path in paths:
        for doc in yaml.safe_load_all(open(path)):
            if not isinstance(doc, dict) or doc.get("kind") != "Pipeline":
                continue
            for e in check(doc):
                print(f"{path}: {e}")
                bad += 1
    print(f"checked {len(paths)} file(s): {bad} unresolved param reference(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

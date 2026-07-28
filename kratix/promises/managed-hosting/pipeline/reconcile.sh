#!/usr/bin/env sh
# Kratix resource pipeline: delegate the Tenant to the Restate durable reconcile.
# Kratix mounts the requested Tenant at /kratix/input/object.yaml and re-runs this
# on each reconciliation (drift). We POST the spec to the provisionTenant Virtual
# Object; Restate serializes per key and the islands are idempotent, so re-runs
# are safe. This is the WRAP — no island logic here, just delegation.
set -eu

OBJ=/kratix/input/object.yaml
RESTATE="${RESTATE_INGRESS:-http://restate.restate.svc.cluster.local:8080}"

KEY=$(yq -r '.metadata.name' "$OBJ")
SPEC=$(yq -o=json '.spec' "$OBJ")

[ -n "$KEY" ] && [ "$KEY" != "null" ] || { echo "tenant has no metadata.name" >&2; exit 1; }

# Fire-and-forget: the reconcile saga is durable in Restate.
code=$(curl -s -o /dev/stderr -w '%{http_code}' \
  -X POST "$RESTATE/provisionTenant/$KEY/reconcile/send" \
  -H 'content-type: application/json' -d "$SPEC")

case "$code" in
  2*) echo "reconcile dispatched for tenant/$KEY (HTTP $code)" ;;
  *)  echo "reconcile dispatch failed for tenant/$KEY (HTTP $code)" >&2; exit 1 ;;
esac

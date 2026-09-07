# tekton/chains — keyless signing credentials

Tekton Chains signs build artifacts and records them in Rekor. This directory
holds the credential machinery; the Chains **configuration** lives in
`tekton/config/tektonconfig.yaml` under `spec.chain`, because the Tekton
operator owns that surface and reverts anything written directly to the
`TektonChain` CR or the `chains-config` ConfigMap.

## ⚠️ `chains.tekton.dev/signed: "true"` is not evidence

Chains sets that annotation when it has finished **reconciling** a TaskRun — not
when it has produced a signature. From Phase 0 until this directory existed,
every TaskRun in the cluster carried `signed: "true"` while Chains logged, 138
times:

```
error configuring x509 signer: no valid private key found, looked for: [x509.pem, cosign.key]
No signer x509 configured for tekton
```

`signing-secrets` — created empty by the operator — was never populated, so
`NewSigner` fell through every branch and returned an error that Chains logs at
**warn** and then swallows. Nothing failed, nothing was signed, and the objects
said otherwise.

**Never gate on the annotation.** Verify against the registry or Rekor
(["Verifying"](#verifying) below). If you add an admission policy, it must check
a real attestation, not this field.

## Why not the token the operator already mounts

The operator mounts a projected ServiceAccount token with `audience: sigstore`
at `/var/run/sigstore/cosign/oidc-token` — cosign's default filesystem-provider
path — which looks like it should just work. It cannot: public Fulcio validates
the issuer, and this cluster's is

```
"iss": "https://kubernetes.default.svc.cluster.local"
```

which Google cannot resolve or fetch a JWKS from.

So `chains-token-refresher` federates that same token to GCP — the
`homelab-staging` workload identity pool carries the k3s JWKS **inline**, which
is what makes an unreachable issuer usable — and mints a *Google* ID token as
`homelab-chains-signer@platform-infra-prod`. `accounts.google.com` is an issuer
Fulcio trusts, and the SA's email becomes the certificate SAN.

```
projected k3s SA token  ──STS token-exchange──▶  federated Google token
                                                          │
                        ┌─────────────────────────────────┴──────────────────┐
                        ▼                                                    ▼
        generateIdToken (aud=sigstore)                       generateAccessToken
        → oidc-token   → Fulcio → Rekor                      → config.json → AR push
                        └──────────────── chains-keyless-creds ──────────────┘
```

Both land in the `chains-keyless-creds` Secret, mounted into the Chains
controller at `/var/run/chains-creds`. The Artifact Registry half is needed
because `artifacts.*.storage` is `oci`: Chains pushes the attestation next to
the image, using its own credentials rather than the build pod's.

## Rotation

Google ID tokens live one hour; the CronJob runs every 20 minutes. Chains
rebuilds its signer — and re-reads the token file — on **every** signing
operation (`allSigners()` is called inside `Sign()`), so a refreshed file is
picked up without restarting the controller. Allow ~1 minute for the kubelet to
project an updated Secret into the running pod.

The Secret is deliberately **not** in git and not managed by ArgoCD.

## Verifying

The credential path and the signing path fail independently — check both.

**1. The refresher produced a token.** It prints the identity and expiry, never
the token:

```
kubectl -n tekton-pipelines create job --from=cronjob/chains-token-refresher bootstrap
kubectl -n tekton-pipelines logs job/bootstrap
# refreshed tekton-pipelines/chains-keyless-creds as homelab-chains-signer@...
#   id-token exp: 2026-09-07T22:14:03Z
```

The likeliest failure is the **WIF subject allowlist** — the provider's
`attribute_condition` in `platform-infra` must contain
`system:serviceaccount:tekton-pipelines:chains-token-refresher`, or STS rejects
the exchange before impersonation is attempted.

**2. Chains actually signed.** Run a build, then look for the signer coming up
rather than warning:

```
kubectl -n tekton-pipelines logs deploy/tekton-chains-controller | grep -i "fulcio\|rekor\|signer"
# want: "Signing with fulcio ..." and a Rekor entry URL
# not:  "No signer x509 configured for ..."
```

**3. The attestation exists** — the only check that proves anything:

```
IMG=$(kubectl -n provisioning-engine-builds-trusted get taskrun <run>-build \
        -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
cosign verify-attestation --type slsaprovenance \
  --certificate-identity "homelab-chains-signer@platform-infra-prod.iam.gserviceaccount.com" \
  --certificate-oidc-issuer "https://accounts.google.com" \
  "$IMG"
```

Until step 3 passes for a real build, treat build provenance as **absent**,
whatever the TaskRun annotations say.

## Related

- GCP side: `platform-infra/terraform/environments/prod/homelab-wif.tf`
- The same federation pattern, for image *pull*: `ar-token-refresher/`
- Design: `docs/design/tekton-build-platform.md` §5, ADR-0005

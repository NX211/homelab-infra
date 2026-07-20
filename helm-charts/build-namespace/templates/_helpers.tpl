{{/* Namespace: one per (project, tier); override to preserve a legacy name. */}}
{{- define "bn.namespace" -}}
{{- .Values.namespace | default (printf "%s-builds-%s" .Values.project .Values.tier) -}}
{{- end -}}

{{/* Pipeline (per-build identity) SA: per (project, channel, tier). */}}
{{- define "bn.pipelineSA" -}}
{{- .Values.pipelineServiceAccount | default (printf "%s-%s-%s" .Values.project .Values.channel .Values.tier) -}}
{{- end -}}

{{/* EventListener trigger SA: per project. */}}
{{- define "bn.triggerSA" -}}
{{- printf "%s-trigger" .Values.project -}}
{{- end -}}

{{/* Per-tier Verdaccio proxy URL — a tier physically can't reach the other's cache (H3). */}}
{{- define "bn.verdaccioRegistry" -}}
{{- printf "http://verdaccio-%s.build-registry-proxy.svc.cluster.local:4873/" .Values.tier -}}
{{- end -}}

{{/* Guard: fail fast on a malformed inventory entry. */}}
{{- define "bn.validate" -}}
{{- if not (has .Values.tier (list "trusted" "untrusted")) -}}
{{- fail (printf "tier must be trusted|untrusted, got %q" .Values.tier) -}}
{{- end -}}
{{- if or (not .Values.project) (not .Values.channel) -}}
{{- fail "project and channel are required" -}}
{{- end -}}
{{- end -}}

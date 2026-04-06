{{/*
Common labels
*/}}
{{- define "argocd-wrapper.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

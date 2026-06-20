{{/* Common labels for the Matrix stack */}}
{{- define "matrix.labels" -}}
app.kubernetes.io/part-of: matrix
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

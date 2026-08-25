{{/*
Expand the name of the chart.
*/}}
{{- define "staging-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "staging-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "staging-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "staging-app.labels" -}}
helm.sh/chart: {{ include "staging-app.chart" . }}
{{ include "staging-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: staging
{{- end }}

{{/*
Selector labels
*/}}
{{- define "staging-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "staging-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
App-specific database secret name
*/}}
{{- define "staging-app.databaseSecretName" -}}
{{- .Values.database.secretName | default (printf "%s-database" .Values.appName) }}
{{- end }}

{{/*
GCR pull secret name
*/}}
{{- define "staging-app.gcrSecretName" -}}
{{- .Values.gcrPullSecret.secretName | default (printf "gcr-pull-secret-%s" .Values.appName) }}
{{- end }}

{{/*
Bitwarden ClusterSecretStore name
*/}}
{{- define "staging-app.secretStoreName" -}}
{{- printf "bitwarden-staging-%s" .Values.appName }}
{{- end }}

{{/*
Container name
*/}}
{{- define "staging-app.containerName" -}}
{{- .Values.containerName | default (printf "%s-web" .Values.appName) }}
{{- end }}

{{/*
App label for log messages
*/}}
{{- define "staging-app.appLabel" -}}
{{- .Values.appLabel | default .Values.appName }}
{{- end }}

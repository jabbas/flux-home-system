{{/*
Expand the name of the chart.
*/}}
{{- define "authentik-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "authentik-stack.fullname" -}}
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
{{- define "authentik-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "authentik-stack.labels" -}}
helm.sh/chart: {{ include "authentik-stack.chart" . }}
{{ include "authentik-stack.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "authentik-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "authentik-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels - extends common labels with a component name
Usage: {{ include "authentik-stack.componentLabels" (dict "context" . "component" "blueprints") }}
*/}}
{{- define "authentik-stack.componentLabels" -}}
{{ include "authentik-stack.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Generate or retrieve a secret value.
Priority: 1) User-provided value, 2) Existing secret in cluster, 3) Generate new

Usage:
  {{ include "authentik-stack.secretValue" (dict "Release" .Release "value" .Values.oidc.clientSecret "secretName" "oidc-secret-talos" "key" "AUTHENTIK_TALOS_SECRET" "length" 32) }}
*/}}
{{- define "authentik-stack.secretValue" -}}
{{- if .value -}}
  {{- .value -}}
{{- else -}}
  {{- $existingSecret := lookup "v1" "Secret" .Release.Namespace .secretName -}}
  {{- if and $existingSecret (index $existingSecret.data .key) -}}
    {{- index $existingSecret.data .key | b64dec -}}
  {{- else -}}
    {{- randAlphaNum (.length | int) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Database fullname helper
*/}}
{{- define "authentik-stack.database.fullname" -}}
{{- printf "%s-db" (include "authentik-stack.fullname" .) }}
{{- end }}

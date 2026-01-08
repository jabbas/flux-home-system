{{/*
Expand the name of the chart.
*/}}
{{- define "authentik-blueprints.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "authentik-blueprints.fullname" -}}
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
{{- define "authentik-blueprints.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "authentik-blueprints.labels" -}}
helm.sh/chart: {{ include "authentik-blueprints.chart" . }}
{{ include "authentik-blueprints.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "authentik-blueprints.selectorLabels" -}}
app.kubernetes.io/name: {{ include "authentik-blueprints.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels - extends common labels with a component name
Usage: {{ include "authentik-blueprints.componentLabels" (dict "context" . "component" "oidc") }}
*/}}
{{- define "authentik-blueprints.componentLabels" -}}
{{ include "authentik-blueprints.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

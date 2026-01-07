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

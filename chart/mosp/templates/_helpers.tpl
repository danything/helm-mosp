{{- define "mosp.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "mosp.labels" -}}
app.kubernetes.io/name: mosp
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "mosp.dbSecretName" -}}
{{- if .Values.postgresql.existingSecret -}}
{{ .Values.postgresql.existingSecret }}
{{- else -}}
{{ include "mosp.fullname" . }}-db
{{- end -}}
{{- end -}}

{{/* One Grafana-managed alert rule (file provisioning format). */}}
{{- define "obs.alertRule" -}}
- uid: {{ .uid }}
  title: {{ .title | quote }}
  condition: C
  data:
    - refId: A
      relativeTimeRange: { from: 900, to: 0 }
      datasourceUid: {{ .ds }}
      model:
        refId: A
        expr: {{ .expr | quote }}
        instant: true
        range: false
    - refId: C
      datasourceUid: __expr__
      relativeTimeRange: { from: 0, to: 0 }
      model:
        refId: C
        type: threshold
        expression: A
        conditions:
          - evaluator: { type: {{ .op }}, params: [{{ .value }}] }
  noDataState: OK
  execErrState: Error
  for: {{ .pending | default .for | default "10m" }}
  labels:
    severity: {{ .severity | default "warning" }}
    team: platform
  annotations:
    summary: {{ .summary | quote }}
    description: {{ .description | quote }}
{{- end }}

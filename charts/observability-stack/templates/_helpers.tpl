{{/* ===================================================================
     Naming / labels
     =================================================================== */}}

{{- define "obs.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: observability-stack
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
observability.aauti.com/cluster: {{ .Values.cluster.name | quote }}
{{- end }}

{{- define "obs.isHub" -}}
{{- if eq .Values.mode "hub" }}true{{ end }}
{{- end }}

{{/* Title for a tenant id: tenants.<id>.title or the id title-cased. */}}
{{- define "obs.tenantTitle" -}}
{{- $t := index .root.Values.tenants .tenant -}}
{{- default (title .tenant) $t.title -}}
{{- end }}

{{/* In-cluster gateway service name / URL (hub mode). */}}
{{- define "obs.gatewayName" -}}observability-gateway{{- end }}

{{- define "obs.gatewayTLSSecretName" -}}
{{- default "observability-gateway-tls" .Values.gateway.tls.existingSecret -}}
{{- end }}

{{/* DNS server for NGINX's runtime upstream resolution. An IP (not a host
     name) so the gateway can start even while cluster DNS is still coming up. */}}
{{- define "obs.gatewayResolver" -}}
{{- if .Values.gateway.resolver -}}
{{- .Values.gateway.resolver -}}
{{- else -}}
{{- $svc := (lookup "v1" "Service" "kube-system" "kube-dns") | default dict -}}
{{- $ip := dig "spec" "clusterIP" "" $svc -}}
{{- if and $ip (ne $ip "None") -}}{{ $ip }}{{- else -}}kube-dns.kube-system.svc.cluster.local.{{- end -}}
{{- end -}}
{{- end }}

{{- define "obs.gatewayInternalUrl" -}}
https://{{ include "obs.gatewayName" . }}.{{ .Release.Namespace }}.svc:{{ .Values.gateway.service.port }}
{{- end }}

{{/* URL the local agent / k6 / Grafana use to reach the gateway. */}}
{{- define "obs.hubUrl" -}}
{{- if .Values.agent.hubUrl -}}
{{- trimSuffix "/" .Values.agent.hubUrl -}}
{{- else if eq .Values.mode "hub" -}}
{{- include "obs.gatewayInternalUrl" . -}}
{{- else -}}
{{- fail "agent.hubUrl is required in spoke mode" -}}
{{- end -}}
{{- end }}

{{/* ===================================================================
     Stable generated secrets.
     Values are resolved once per render and cached in .Values._cache so
     every template sees the same random value; existing in-cluster Secrets
     win so upgrades never rotate credentials by accident.
     =================================================================== */}}

{{- define "obs.cache" -}}
{{- if not (hasKey .Values "_cache") -}}
{{- $_ := set .Values "_cache" dict -}}
{{- end -}}
{{- end }}

{{/* Returns a dict tenant-id -> password (as JSON). With gateway.reader
     enabled it also holds the read-only federated user (gateway.reader.username). */}}
{{- define "obs.tenantPasswords" -}}
{{- include "obs.cache" . -}}
{{- if not (hasKey .Values._cache "tenantPasswords") -}}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace "observability-tenant-credentials") | default dict -}}
{{- $existingData := $existing.data | default dict -}}
{{- $out := dict -}}
{{- range $id, $t := .Values.tenants -}}
{{- $pw := "" -}}
{{- if $t.password -}}
{{- $pw = $t.password -}}
{{- else if hasKey $existingData $id -}}
{{- $pw = index $existingData $id | b64dec -}}
{{- else -}}
{{- $pw = randAlphaNum 32 -}}
{{- end -}}
{{- $_ := set $out $id $pw -}}
{{- end -}}
{{- if .Values.gateway.reader.enabled -}}
{{- $rid := .Values.gateway.reader.username -}}
{{- $rpw := ternary (index $existingData $rid | default "" | b64dec) (randAlphaNum 32) (hasKey $existingData $rid) -}}
{{- $_ := set $out $rid $rpw -}}
{{- end -}}
{{- $_ := set .Values._cache "tenantPasswords" $out -}}
{{- end -}}
{{- .Values._cache.tenantPasswords | toJson -}}
{{- end }}

{{/* Generic "keep existing secret key or generate" helper.
     Args: root, secret, key, value (optional explicit value), length */}}
{{- define "obs.stableSecretValue" -}}
{{- if .value -}}
{{- .value -}}
{{- else -}}
{{- $existing := (lookup "v1" "Secret" .root.Release.Namespace .secret) | default dict -}}
{{- $data := $existing.data | default dict -}}
{{- if hasKey $data .key -}}
{{- index $data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (.length | default 32) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Gateway TLS material (generated CA + server cert), cached per render,
     reused from the existing Secret on upgrade. Returns JSON {ca, crt, key}. */}}
{{- define "obs.gatewayTLS" -}}
{{- include "obs.cache" . -}}
{{- if not (hasKey .Values._cache "gatewayTLS") -}}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace "observability-gateway-tls") | default dict -}}
{{- $data := $existing.data | default dict -}}
{{- $out := dict -}}
{{- if and (hasKey $data "tls.crt") (hasKey $data "ca.crt") -}}
{{- $out = dict "ca" (index $data "ca.crt" | b64dec) "crt" (index $data "tls.crt" | b64dec) "key" (index $data "tls.key" | b64dec) -}}
{{- else -}}
{{- $svc := include "obs.gatewayName" . -}}
{{- $ns := .Release.Namespace -}}
{{- $dns := list $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.cluster.local" $svc $ns) "localhost" -}}
{{- $dns = concat $dns .Values.gateway.tls.extraDnsNames -}}
{{- if .Values.gateway.ingress.enabled -}}{{- $dns = append $dns .Values.gateway.ingress.host -}}{{- end -}}
{{- $ips := concat (list "127.0.0.1") .Values.gateway.tls.extraIpAddresses -}}
{{- $days := int .Values.gateway.tls.validityDays -}}
{{- $ca := genCA "observability-hub-ca" $days -}}
{{- $cert := genSignedCert (printf "%s.%s.svc" $svc $ns) $ips $dns $days $ca -}}
{{- $out = dict "ca" $ca.Cert "crt" $cert.Cert "key" $cert.Key -}}
{{- end -}}
{{- $_ := set .Values._cache "gatewayTLS" $out -}}
{{- end -}}
{{- .Values._cache.gatewayTLS | toJson -}}
{{- end }}

{{/* Namespaces restriction rendered as an Alloy `namespaces {}` block. */}}
{{- define "obs.alloyNamespaces" -}}
{{- if .Values.agent.namespaces }}
  namespaces {
    names = {{ .Values.agent.namespaces | toJson }}
  }
{{- end }}
{{- end }}

{{/* nginx config of the local demo site (templates/demo/demo-app.yaml) */}}
{{- define "obs.demoNginxConf" -}}
server {
  listen 8080;
  location / {
    default_type application/json;
    return 200 '{"service":"demo-app","cluster":"{{ .Values.cluster.name }}"}\n';
  }
  location = /api/items {
    default_type application/json;
    return 200 '{"items":[{"id":1,"name":"stream"},{"id":2,"name":"room"}]}\n';
  }
  location = /api/error {
    default_type application/json;
    return 500 '{"error":"simulated failure"}\n';
  }
  location = /stub_status { stub_status; access_log off; }
}
{{- end }}

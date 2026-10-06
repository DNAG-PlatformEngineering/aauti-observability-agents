#!/usr/bin/env python3
"""Dashboards as code.

Generates the Grafana dashboard JSON files in ../ (one template per
dashboard, shared by every tenant). Placeholders are substituted by the Helm
chart per tenant: __METRICS_DS__, __LOGS_DS__, __TENANT__, __TENANT_TITLE__.

    python dashboards/src/generate.py      # rewrite ../*.json

Keep hand edits here, not in the JSON files.
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent
M = {"type": "prometheus", "uid": "__METRICS_DS__"}
L = {"type": "loki", "uid": "__LOGS_DS__"}

C = 'cluster=~"$cluster"'
# Namespace-level metric queries follow the Environment selector PLUS "shared"
# (environment comes from the namespace suffix on multi-environment clusters; a
# workload serving several environments, like one Jitsi for dev/qa/demo/sandbox,
# is "shared"). Node-level ones (C) are per cluster: nodes are shared by all
# environments of a cluster.
CN = 'cluster=~"$cluster", environment=~"$environment|shared", namespace=~"$namespace"'


# --------------------------------------------------------------------------- helpers
class Grid:
    """Simple left-to-right, top-to-bottom panel placement on the 24-col grid."""

    def __init__(self):
        self.x, self.y, self.row_h, self.next_id = 0, 0, 0, 1

    def place(self, w, h):
        if self.x + w > 24:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        return pos

    def newline(self):
        if self.x:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0

    def pid(self):
        self.next_id += 1
        return self.next_id - 1


def target(expr, legend="", ds=M, instant=False, ref="A", fmt=None):
    t = {"datasource": ds, "expr": expr, "refId": ref, "legendFormat": legend}
    if ds is M:
        t["range"] = not instant
        t["instant"] = instant
    if fmt:
        t["format"] = fmt
    return t


def row(g, title):
    g.newline()
    p = {"type": "row", "title": title, "id": g.pid(), "collapsed": False,
         "gridPos": {"x": 0, "y": g.y, "w": 24, "h": 1}, "panels": []}
    g.y += 1
    return p


def stat(g, title, expr, unit="short", w=4, h=4, thresholds=None, decimals=None, desc=""):
    steps = thresholds or [{"color": "green", "value": None}]
    p = {
        "type": "stat", "title": title, "id": g.pid(), "gridPos": g.place(w, h), "datasource": M,
        "description": desc,
        "targets": [target(expr, instant=True)],
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps},
                                     "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
    }
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    return p


def ts(g, title, targets, unit="short", w=12, h=8, stack=False, desc="", ds=M, overrides=None):
    return {
        "type": "timeseries", "title": title, "id": g.pid(), "gridPos": g.place(w, h), "datasource": ds,
        "description": desc,
        "targets": [dict(t, refId=chr(65 + i)) for i, t in enumerate(targets)],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 15 if stack else 5,
                           "showPoints": "never", "spanNulls": True,
                           "stacking": {"mode": "normal" if stack else "none", "group": "A"}},
            },
            "overrides": overrides or [],
        },
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }


def table(g, title, expr, w=12, h=8, desc="", columns=None, unit="short"):
    excl = {"Time": True, "__name__": True}
    return {
        "type": "table", "title": title, "id": g.pid(), "gridPos": g.place(w, h), "datasource": M,
        "description": desc,
        "targets": [target(expr, instant=True, fmt="table")],
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "transformations": [{"id": "organize", "options": {"excludeByName": excl, "renameByName": columns or {}}}],
        "options": {"showHeader": True, "cellHeight": "sm"},
    }


def bargauge(g, title, expr, legend, unit="percentunit", w=12, h=8, maxv=1, ds=M, desc=""):
    return {
        "type": "bargauge", "title": title, "id": g.pid(), "gridPos": g.place(w, h), "datasource": ds,
        "description": desc,
        "targets": [dict(target(expr, legend, ds=ds, instant=True), **({"queryType": "instant"} if ds is L else {}))],
        "fieldConfig": {"defaults": {"unit": unit, "min": 0, "max": maxv,
                                     "thresholds": {"mode": "absolute", "steps": [
                                         {"color": "green", "value": None},
                                         {"color": "orange", "value": 0.7 * maxv},
                                         {"color": "red", "value": 0.9 * maxv}]}},
                        "overrides": []},
        "options": {"displayMode": "gradient", "orientation": "horizontal", "showUnfilled": True,
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    }


def logs(g, title, expr, w=24, h=10):
    return {
        "type": "logs", "title": title, "id": g.pid(), "gridPos": g.place(w, h), "datasource": L,
        "targets": [{"datasource": L, "expr": expr, "refId": "A", "queryType": "range"}],
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                    "enableLogDetails": True, "dedupStrategy": "none", "prettifyLogMessage": False},
    }


def var_query(name, label, query, ds=M, multi=True, include_all=True, all_value=".+", hide=0):
    # ".+" (not ".*"): Loki rejects selectors where every matcher matches empty.
    return {
        "name": name, "label": label, "type": "query", "datasource": ds,
        "query": {"query": query, "refId": f"{name}-var"} if ds is M else query,
        "definition": query, "refresh": 2, "sort": 1, "multi": multi, "includeAll": include_all,
        "allValue": all_value if include_all else None, "hide": hide,
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]} if include_all else {},
    }


def dashboard(uid_suffix, title, panels, variables, tags, desc, refresh="1m", time_from="now-6h"):
    return {
        "uid": f"__TENANT__-{uid_suffix}",
        "title": f"__TENANT_TITLE__ / {title}",
        "description": desc,
        "tags": ["observability-stack", "__TENANT__"] + tags,
        "timezone": "browser", "editable": False, "graphTooltip": 1,
        "schemaVersion": 39, "version": 1, "refresh": refresh,
        "time": {"from": time_from, "to": "now"},
        "templating": {"list": variables},
        "annotations": {"list": []},
        "links": [{"type": "dashboards", "tags": ["__TENANT__"], "asDropdown": True, "title": "__TENANT_TITLE__"}],
        "panels": panels,
    }


def env_var():
    # Fixed list, so every environment is selectable even before it has data.
    # __ENVIRONMENTS__ is replaced per tenant / folder at deploy time
    # (nonprod: dev,qa,demo,sandbox,shared; prod: prod,shared).
    return {
        "name": "environment", "label": "Environment", "type": "custom",
        "query": "__ENVIRONMENTS__", "multi": True, "includeAll": True, "allValue": ".+",
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "options": [], "hide": 0,
    }


def env_cluster_vars():
    # Cluster does not depend on the environment (an environment without
    # activity must not empty the cluster list); every query filters on both.
    return [
        env_var(),
        var_query("cluster", "Cluster", "label_values(up, cluster)"),
    ]


def log_env_cluster_vars(ns_sel=""):
    # Same selectors for log-centric dashboards (kept as a separate name for callers).
    return env_cluster_vars()

def cluster_vars(extra=None):
    # Environments come from the logs (superset: namespace envs + per-line envs).
    v = log_env_cluster_vars() + [
        var_query("namespace", "Namespace", 'label_values(kube_pod_info{cluster=~"$cluster", environment=~"$environment|shared"}, namespace)'),
    ]
    return v + (extra or [])


RED = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
UTIL = [{"color": "green", "value": None}, {"color": "orange", "value": 0.7}, {"color": "red", "value": 0.9}]


# --------------------------------------------------------------------------- cluster health
def cluster_health(extra_rows=None):
    g = Grid()
    p = [row(g, "Overview")]
    p += [
        stat(g, "Nodes ready", f'sum(kube_node_status_condition{{{C}, condition="Ready", status="true"}})'),
        stat(g, "Nodes not ready", f'sum(kube_node_status_condition{{{C}, condition="Ready", status!="true"}}) or vector(0)', thresholds=RED),
        stat(g, "Pods running", f'sum(kube_pod_status_phase{{{CN}, phase="Running"}})'),
        stat(g, "Pods pending / failed", f'sum(kube_pod_status_phase{{{CN}, phase=~"Pending|Failed|Unknown"}}) or vector(0)', thresholds=RED),
        stat(g, "Restarts (1h)", f'sum(increase(kube_pod_container_status_restarts_total{{{CN}}}[1h])) or vector(0)',
             thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 10}], decimals=0),
        stat(g, "Deployments degraded", f'count((kube_deployment_spec_replicas{{{CN}}} - kube_deployment_status_replicas_available{{{CN}}}) > 0) or vector(0)', thresholds=RED),
        stat(g, "CPU utilisation", f'sum(rate(container_cpu_usage_seconds_total{{{C}, container!=""}}[5m])) / sum(machine_cpu_cores{{{C}}})', "percentunit", thresholds=UTIL, w=4),
        stat(g, "Memory utilisation", f'sum(container_memory_working_set_bytes{{{C}, container!=""}}) / sum(machine_memory_bytes{{{C}}})', "percentunit", thresholds=UTIL, w=4),
        stat(g, "Scrape targets down", f'count(up{{{C}}} == 0) or vector(0)', thresholds=RED, w=4),
        stat(g, "Containers not ready", f'count(kube_pod_container_status_ready{{{CN}}} == 0) or vector(0)', thresholds=RED, w=4),
        stat(g, "Jobs failed", f'sum(kube_job_status_failed{{{CN}}}) or vector(0)', thresholds=RED, w=4),
        stat(g, "PVCs > 80% full", f'count((kubelet_volume_stats_used_bytes{{{CN}}} / kubelet_volume_stats_capacity_bytes{{{CN}}}) > 0.8) or vector(0)', thresholds=RED, w=4),
    ]
    p.append(row(g, "Workload state"))
    p += [
        ts(g, "Pods by phase", [target(f'sum by (phase) (kube_pod_status_phase{{{CN}}})', "{{phase}}")], stack=True),
        ts(g, "Container restarts by namespace", [target(f'sum by (namespace) (increase(kube_pod_container_status_restarts_total{{{CN}}}[10m]))', "{{namespace}}")]),
        table(g, "Problem pods", f'sum by (namespace, pod, phase) (kube_pod_status_phase{{{CN}, phase=~"Pending|Failed|Unknown"}}) > 0',
              columns={"Value": "count"}),
        table(g, "Containers waiting", f'sum by (namespace, pod, container, reason) (kube_pod_container_status_waiting_reason{{{CN}}}) > 0',
              columns={"Value": "count"}),
        table(g, "Degraded deployments", f'(kube_deployment_spec_replicas{{{CN}}} - kube_deployment_status_replicas_available{{{CN}}}) > 0',
              columns={"Value": "missing replicas"}, w=24, h=6),
    ]
    p.append(row(g, "Kubernetes events"))
    p.append(logs(g, "Warning events", f'{{{C}, log_type="k8s-event"}} |= "type=Warning"'))
    if extra_rows:
        p += extra_rows(g)
    return dashboard("cluster-health", "Cluster health", p, cluster_vars(), ["kubernetes", "health"],
                     "Node, pod and deployment health plus warning events for the tenant's cluster(s).")


# --------------------------------------------------------------------------- resource usage
def resource_usage(extra_rows=None):
    g = Grid()
    p = [row(g, "Namespaces")]
    p += [
        ts(g, "CPU usage by namespace", [target(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{{CN}, container!=""}}[$__rate_interval]))', "{{namespace}}")], "cores", stack=True),
        ts(g, "Memory working set by namespace", [target(f'sum by (namespace) (container_memory_working_set_bytes{{{CN}, container!=""}})', "{{namespace}}")], "bytes", stack=True),
        ts(g, "CPU: usage vs requests vs limits", [
            target(f'sum(rate(container_cpu_usage_seconds_total{{{CN}, container!=""}}[$__rate_interval]))', "usage"),
            target(f'sum(kube_pod_container_resource_requests{{{CN}, resource="cpu"}})', "requests"),
            target(f'sum(kube_pod_container_resource_limits{{{CN}, resource="cpu"}})', "limits"),
        ], "cores"),
        ts(g, "Memory: usage vs requests vs limits", [
            target(f'sum(container_memory_working_set_bytes{{{CN}, container!=""}})', "usage"),
            target(f'sum(kube_pod_container_resource_requests{{{CN}, resource="memory"}})', "requests"),
            target(f'sum(kube_pod_container_resource_limits{{{CN}, resource="memory"}})', "limits"),
        ], "bytes"),
    ]
    p.append(row(g, "Pods"))
    p += [
        ts(g, "Top 10 pods by CPU", [target(f'topk(10, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CN}, container!=""}}[$__rate_interval])))', "{{namespace}}/{{pod}}")], "cores"),
        ts(g, "Top 10 pods by memory", [target(f'topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{{{CN}, container!=""}}))', "{{namespace}}/{{pod}}")], "bytes"),
        ts(g, "CPU throttling (top 10)", [target(
            f'topk(10, sum by (namespace, pod) (increase(container_cpu_cfs_throttled_periods_total{{{CN}, container!=""}}[5m])) / sum by (namespace, pod) (increase(container_cpu_cfs_periods_total{{{CN}, container!=""}}[5m])))',
            "{{namespace}}/{{pod}}")], "percentunit"),
        ts(g, "OOM kills", [target(f'sum by (namespace, pod) (increase(container_oom_events_total{{{CN}}}[10m])) > 0', "{{namespace}}/{{pod}}")]),
        ts(g, "Network receive by namespace", [target(f'sum by (namespace) (rate(container_network_receive_bytes_total{{{CN}}}[$__rate_interval]))', "{{namespace}}")], "Bps"),
        ts(g, "Network transmit by namespace", [target(f'sum by (namespace) (rate(container_network_transmit_bytes_total{{{CN}}}[$__rate_interval]))', "{{namespace}}")], "Bps"),
    ]
    p.append(row(g, "Nodes"))
    p += [
        ts(g, "Node CPU utilisation", [target(f'1 - avg by (instance) (rate(node_cpu_seconds_total{{{C}, mode="idle"}}[$__rate_interval]))', "{{instance}}")], "percentunit", w=8),
        ts(g, "Node memory utilisation", [target(f'1 - node_memory_MemAvailable_bytes{{{C}}} / node_memory_MemTotal_bytes{{{C}}}', "{{instance}}")], "percentunit", w=8),
        ts(g, "Node filesystem used (/ or /var)", [target(f'1 - min by (instance) (node_filesystem_avail_bytes{{{C}, mountpoint=~"/|/var"}} / node_filesystem_size_bytes{{{C}, mountpoint=~"/|/var"}})', "{{instance}}")], "percentunit", w=8),
        ts(g, "Node load (1m) per core", [target(f'node_load1{{{C}}} / on (cluster, instance) group_left count by (cluster, instance) (node_cpu_seconds_total{{{C}, mode="idle"}})', "{{instance}}")], w=12),
        bargauge(g, "PVC usage", f'kubelet_volume_stats_used_bytes{{{CN}}} / kubelet_volume_stats_capacity_bytes{{{CN}}}', "{{namespace}}/{{persistentvolumeclaim}}"),
    ]
    if extra_rows:
        p += extra_rows(g)
    return dashboard("resource-usage", "Resource usage", p, cluster_vars(), ["kubernetes", "resources"],
                     "CPU, memory, network and storage consumption by namespace, pod and node.")


# --------------------------------------------------------------------------- workloads & logs
def workloads_logs():
    g = Grid()
    LSEL = 'cluster=~"$cluster", environment=~"$environment", namespace=~"$namespace", app=~"$app"'
    variables = log_env_cluster_vars() + [
        var_query("namespace", "Namespace", 'label_values(kube_pod_info{cluster=~"$cluster", environment=~"$environment"}, namespace)'),
        var_query("app", "App", 'label_values({cluster=~"$cluster", environment=~"$environment", namespace=~"$namespace"}, app)', ds=L),
        {"name": "search", "label": "Log search (regex)", "type": "textbox", "query": "", "current": {"value": ""}, "hide": 0},
    ]
    p = [row(g, "Logs")]
    p += [
        ts(g, "Log lines by app", [target(f'sum by (app) (count_over_time({{{LSEL}}} [$__auto]))', "{{app}}", ds=L)], stack=True, ds=L),
        ts(g, "Errors by app (detected_level)", [target(f'sum by (app) (count_over_time({{{LSEL}}} | detected_level=~"error|fatal|critical" [$__auto]))', "{{app}}", ds=L)],
           stack=True, ds=L, desc="Loki auto-detects the level of each line (structured metadata detected_level)."),
        ts(g, "Log bytes by log_type", [target(f'sum by (log_type) (bytes_over_time({{{LSEL}}} [$__auto]))', "{{log_type}}", ds=L)], "bytes", stack=True, ds=L,
           desc="log_type drives per-type retention on the hub."),
        ts(g, "Log lines by level", [target(f'sum by (detected_level) (count_over_time({{{LSEL}}} [$__auto]))', "{{detected_level}}", ds=L)], stack=True, ds=L),
        logs(g, "Logs", f'{{{LSEL}}} |~ "(?i)$search"', h=12),
    ]
    p.append(row(g, "Application metrics"))
    p += [
        ts(g, "HTTP requests / s (nginx exporter)", [target(f'sum by (namespace, app) (rate(nginx_http_requests_total{{{CN}}}[$__rate_interval]))', "{{namespace}}/{{app}}")], "reqps",
           desc="Any pod annotated prometheus.io/scrape is collected; add panels for your own app metrics here."),
        ts(g, "Active connections (nginx exporter)", [target(f'sum by (namespace, app) (nginx_connections_active{{{CN}}})', "{{namespace}}/{{app}}")]),
        ts(g, "CPU by pod", [target(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{CN}, container!=""}}[$__rate_interval]))', "{{pod}}")], "cores"),
        ts(g, "Memory by pod", [target(f'sum by (pod) (container_memory_working_set_bytes{{{CN}, container!=""}})', "{{pod}}")], "bytes"),
        table(g, "Scrape targets", f'up{{{C}}}', w=12, columns={"Value": "up"}),
        table(g, "Container restarts (24h)", f'sum by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total{{{CN}}}[24h])) > 0',
              w=12, columns={"Value": "restarts"}),
    ]
    return dashboard("workloads-logs", "Workloads & logs", p, variables, ["application", "logs"],
                     "Application-level view: log volume, errors, log search and workload metrics.")


# --------------------------------------------------------------------------- tenant usage (platform)
def tenant_usage():
    g = Grid()
    variables = [var_query("tenant", "Tenant", "label_values(cortex_distributor_received_samples_total, user)")]
    U = 'user=~"$tenant"'
    T = 'tenant=~"$tenant"'
    p = [row(g, "Metrics (Mimir)")]
    p += [
        ts(g, "Samples / s by tenant", [target(f'sum by (user) (rate(cortex_distributor_received_samples_total{{{U}}}[$__rate_interval]))', "{{user}}")]),
        bargauge(g, "Ingestion rate vs limit", f'sum by (user) (rate(cortex_distributor_received_samples_total{{{U}}}[5m])) / on (user) max by (user) (cortex_limits_overrides{{limit_name="ingestion_rate", {U}}})', "{{user}}"),
        ts(g, "Active series by tenant", [target(f'sum by (user) (cortex_ingester_active_series{{{U}}})', "{{user}}")]),
        bargauge(g, "Active series vs limit", f'sum by (user) (cortex_ingester_active_series{{{U}}}) / on (user) max by (user) (cortex_limits_overrides{{limit_name="max_global_series_per_user", {U}}})', "{{user}}"),
        ts(g, "Discarded samples by tenant / reason", [target(f'sum by (user, reason) (rate(cortex_discarded_samples_total{{{U}}}[$__rate_interval]))', "{{user}} {{reason}}")],
           desc="Anything here means a tenant hit a limit; only that tenant is affected."),
        ts(g, "Queries / s by tenant", [target(f'sum by (user) (rate(cortex_query_frontend_queries_total{{{U}}}[$__rate_interval]))', "{{user}}")], "reqps"),
    ]
    p.append(row(g, "Logs (Loki)"))
    p += [
        ts(g, "Log bytes / s by tenant", [target(f'sum by (tenant) (rate(loki_distributor_bytes_received_total{{{T}}}[$__rate_interval]))', "{{tenant}}")], "Bps"),
        ts(g, "Log lines / s by tenant", [target(f'sum by (tenant) (rate(loki_distributor_lines_received_total{{{T}}}[$__rate_interval]))', "{{tenant}}")]),
        ts(g, "Discarded log bytes by tenant / reason", [target(f'sum by (tenant, reason) (rate(loki_discarded_bytes_total{{{T}}}[$__rate_interval]))', "{{tenant}} {{reason}}")], "Bps"),
        ts(g, "Active streams by tenant", [target(f'sum by (tenant) (loki_ingester_memory_streams{{{T}}})', "{{tenant}}")]),
    ]
    p.append(row(g, "Gateway"))
    GW = '{app="observability-gateway"} | logfmt | tenant=~"$tenant"'
    p += [
        ts(g, "Gateway requests by tenant", [target(f'sum by (tenant) (count_over_time({GW} [$__auto]))', "{{tenant}}", ds=L)], ds=L),
        ts(g, "Gateway errors by tenant / status", [target(f'sum by (tenant, status) (count_over_time({GW} | status >= 400 [$__auto]))', "{{tenant}} {{status}}", ds=L)], ds=L,
           desc="401 = bad credentials, 403 = X-Scope-OrgID mismatch, 429 = tenant limit."),
        logs(g, "Rejected requests (401/403/429)", '{app="observability-gateway"} | logfmt | status=~"401|403|429"', h=8),
    ]
    p.append(row(g, "Storage"))
    p += [
        ts(g, "Mimir blocks in object storage by tenant", [target(f'max by (user) (cortex_bucket_blocks_count{{{U}}})', "{{user}}")], w=24),
    ]
    return dashboard("tenant-usage", "Tenant usage", p, variables, ["platform", "tenants"],
                     "Per-tenant ingestion, limits, rejections and query load for Loki and Mimir.")


# --------------------------------------------------------------------------- k6
def k6_load_testing():
    g = Grid()
    variables = [var_query("testid", "Test", "label_values(k6_vus, testid)")]
    S = 'testid=~"$testid"'
    ok = [{"color": "green", "value": None}, {"color": "red", "value": 0.01}]
    p = [row(g, "Summary")]
    p += [
        stat(g, "Requests (range)", f'sum(increase(k6_http_reqs_total{{{S}}}[$__range]))', decimals=0),
        stat(g, "Peak VUs", f'max(max_over_time(k6_vus{{{S}}}[$__range]))'),
        stat(g, "Peak RPS", f'max_over_time(sum(rate(k6_http_reqs_total{{{S}}}[30s]))[$__range:15s])', "reqps", decimals=1),
        stat(g, "Failed requests", f'avg(avg_over_time(k6_http_req_failed_rate{{{S}}}[$__range]))', "percentunit", thresholds=ok),
        stat(g, "p95 latency (max)", f'max(max_over_time(k6_http_req_duration_p95{{{S}}}[$__range]))', "s",
             thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.3}, {"color": "red", "value": 1}]),
        stat(g, "Checks passed", f'avg(avg_over_time(k6_checks_rate{{{S}}}[$__range]))', "percentunit",
             thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 0.99}]),
    ]
    p.append(row(g, "Load"))
    p += [
        ts(g, "Virtual users", [target(f'sum by (testid) (k6_vus{{{S}}})', "{{testid}}")]),
        ts(g, "Requests / s", [target(f'sum by (testid) (rate(k6_http_reqs_total{{{S}}}[$__rate_interval]))', "{{testid}}")], "reqps"),
        ts(g, "Latency", [
            target(f'max by (testid) (k6_http_req_duration_p50{{{S}}})', "p50 {{testid}}"),
            target(f'max by (testid) (k6_http_req_duration_p95{{{S}}})', "p95 {{testid}}"),
            target(f'max by (testid) (k6_http_req_duration_p99{{{S}}})', "p99 {{testid}}"),
        ], "s"),
        ts(g, "Failed request rate", [target(f'avg by (testid) (k6_http_req_failed_rate{{{S}}})', "{{testid}}")], "percentunit"),
        ts(g, "Requests / s by status", [target(f'sum by (status) (rate(k6_http_reqs_total{{{S}}}[$__rate_interval]))', "{{status}}")], "reqps", stack=True),
        ts(g, "Data transfer", [
            target(f'sum(rate(k6_data_sent_total{{{S}}}[$__rate_interval]))', "sent"),
            target(f'sum(rate(k6_data_received_total{{{S}}}[$__rate_interval]))', "received"),
        ], "Bps"),
        ts(g, "p95 latency by request name", [target(f'max by (name) (k6_http_req_duration_p95{{{S}}})', "{{name}}")], "s", w=24),
    ]
    return dashboard("k6-load-testing", "k6 load testing", p, variables, ["k6", "load-testing"],
                     "k6 results remote-written to Mimir (experimental-prometheus-rw output).",
                     refresh="10s", time_from="now-30m")


# --------------------------------------------------------------------------- jitsi (tenant-specific)
def jitsi_meet():
    """JVB (annotated pods), Jicofo (PodMonitor), Prosody (ServiceMonitor), Jibri and logs.
    Metric names are the ones exported by jitsi-meet stable-10741."""
    g = Grid()
    # One Jitsi serves several environments (room name ...-aauti-<env>): its
    # metrics are shared infrastructure (per cluster), only logs carry the
    # meeting's environment.
    J = 'cluster=~"$cluster"'
    JVB = f'{J}, pod=~".*-jvb-[0-9]+"'
    JIC = f'{J}, pod=~".*-jicofo-.*"'
    PRO = f'{J}, pod=~".*-prosody-.*"'
    variables = log_env_cluster_vars('namespace=~"jitsi.*"') + [
        var_query("pod", "Pod (logs)", 'label_values({cluster=~"$cluster", environment=~"$environment", namespace=~"jitsi.*"}, pod)', ds=L),
        {"name": "search", "label": "Log search (regex)", "type": "textbox", "query": "", "current": {"value": ""}, "hide": 0},
    ]
    STRESS = [{"color": "green", "value": None}, {"color": "orange", "value": 0.8}, {"color": "red", "value": 1}]
    p = [row(g, "Overview")]
    p += [
        stat(g, "Conferences", f'sum(jitsi_conferences{{{JVB}}}) or vector(0)', decimals=0, w=3),
        stat(g, "Participants", f'sum(jitsi_participants{{{JVB}}}) or vector(0)', decimals=0, w=3),
        stat(g, "Largest conference", f'max(jitsi_largest_conference{{{JVB}}}) or vector(0)', decimals=0, w=3),
        stat(g, "Operational bridges", f'max(jitsi_operational_bridge_count{{{JIC}}})', decimals=0, w=3,
             thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}]),
        stat(g, "Max JVB stress", f'max(jitsi_stress_level{{{JVB}}})', decimals=2, w=3, thresholds=STRESS,
             desc="1.0 = bridge at its configured capacity."),
        stat(g, "Jibri available", f'sum(jibri_available{{{JIC}}}) or vector(0)', decimals=0, w=3,
             thresholds=[{"color": "orange", "value": None}, {"color": "green", "value": 1}]),
        stat(g, "Recordings active", f'sum(jitsi_recording_active{{{JIC}}}) or vector(0)', decimals=0, w=3),
        stat(g, "XMPP client connections", f'sum(prosody_mod_c2s_connections{{{PRO}}}) or vector(0)', decimals=0, w=3),
    ]
    p.append(row(g, "Videobridge (JVB)"))
    p += [
        ts(g, "Participants by bridge", [target(f'sum by (pod) (jitsi_participants{{{JVB}}})', "{{pod}}")], stack=True),
        ts(g, "Conferences by bridge", [target(f'sum by (pod) (jitsi_conferences{{{JVB}}})', "{{pod}}")], stack=True),
        ts(g, "Stress level by bridge", [target(f'max by (pod) (jitsi_stress_level{{{JVB}}})', "{{pod}}")]),
        ts(g, "Bitrate by bridge", [
            target(f'sum by (pod) (jitsi_bit_rate_download{{{JVB}}})', "down {{pod}}"),
            target(f'sum by (pod) (jitsi_bit_rate_upload{{{JVB}}})', "up {{pod}}"),
        ], "Kbits"),
        ts(g, "Packet loss", [
            target(f'max by (pod) (jitsi_loss_rate_download{{{JVB}}})', "down {{pod}}"),
            target(f'max by (pod) (jitsi_loss_rate_upload{{{JVB}}})', "up {{pod}}"),
        ], "percentunit"),
        ts(g, "RTT / jitter (aggregate)", [
            target(f'max by (pod) (jitsi_rtt_aggregate{{{JVB}}})', "rtt {{pod}}"),
            target(f'max by (pod) (jitsi_jitter_aggregate{{{JVB}}})', "jitter {{pod}}"),
        ], "ms"),
        ts(g, "ICE connections (per 5m)", [
            target(f'sum(increase(total_ice_succeeded{{{JVB}}}[5m]))', "succeeded"),
            target(f'sum(increase(total_ice_failed{{{JVB}}}[5m]))', "failed"),
            target(f'sum(increase(total_ice_succeeded_relayed{{{JVB}}}[5m]))', "relayed (TURN)"),
        ]),
        ts(g, "Conferences created / failed (per 5m)", [
            target(f'sum(increase(jitsi_total_conferences_created{{{JVB}}}[5m]))', "created"),
            target(f'sum(increase(jitsi_total_failed_conferences{{{JVB}}}[5m]))', "failed"),
            target(f'sum(increase(jitsi_total_partially_failed_conferences{{{JVB}}}[5m]))', "partially failed"),
        ]),
    ]
    p.append(row(g, "Focus (Jicofo), Jibri, Prosody"))
    p += [
        ts(g, "Bridges seen by Jicofo", [
            target(f'max(jitsi_bridge_count{{{JIC}}})', "bridges"),
            target(f'max(jitsi_operational_bridge_count{{{JIC}}})', "operational"),
            target(f'max(jitsi_bridge_selector_lost_bridges{{{JIC}}})', "lost (total)"),
        ], w=8),
        ts(g, "Jibri", [
            target(f'sum(jibri_count{{{JIC}}})', "registered"),
            target(f'sum(jibri_available{{{JIC}}})', "available"),
            target(f'sum(jitsi_recording_active{{{JIC}}})', "recording"),
            target(f'sum(jitsi_live_streaming_active{{{JIC}}})', "live streaming"),
        ], w=8),
        ts(g, "Participant ICE failures / restarts (per 5m)", [
            target(f'sum(increase(jitsi_participants_notification_ice_failed{{{JIC}}}[5m]))', "ICE failed"),
            target(f'sum(increase(jitsi_participants_notification_request_restart{{{JIC}}}[5m]))', "restart requested"),
        ], w=8),
        ts(g, "Prosody sessions", [
            target(f'sum(prosody_mod_c2s_connections{{{PRO}}})', "c2s connections"),
            target(f'sum(prosody_mod_bosh_active_sessions{{{PRO}}})', "BOSH active"),
            target(f'sum(prosody_mod_muc_live_room{{{PRO}}})', "live MUC rooms"),
        ], w=12),
        ts(g, "Prosody token auth (per 5m)", [
            target(f'sum(increase(prosody_mod_auth_token_success_total{{{PRO}}}[5m]))', "success"),
            target(f'sum(increase(prosody_mod_auth_token_verify_fail_total{{{PRO}}}[5m]))', "verify failed"),
            target(f'sum(increase(prosody_mod_token_verification_fail_total{{{PRO}}}[5m]))', "token verification failed"),
        ], w=12),
    ]
    p.append(row(g, "Meetings by environment (from logs)"))
    E = 'cluster=~"$cluster", environment=~"$environment", namespace=~"jitsi.*"'
    p += [
        ts(g, "Conferences ended", [target(f'sum by (environment) (count_over_time({{{E}, pod=~".*-jicofo-.*"}} |= "JitsiMeetConferenceImpl.stop" [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=6, desc="Jicofo 'Stopped' per conference; environment from the room name (<title>-<id>-aauti-<env>)."),
        ts(g, "Avg conference duration", [target(f'avg by (environment) (avg_over_time({{{E}, pod=~".*-jvb-[0-9]+"}} |= "expire_conf" | regexp "duration=(?P<duration>[0-9]+)" | unwrap duration [$__auto]))', "{{environment}}", ds=L)],
           "s", ds=L, w=6, desc="From JVB expire_conf,duration=<s>."),
        ts(g, "Recordings finalized", [target(f'sum by (environment) (count_over_time({{{E}, pod=~".*-jibri-.*"}} |= "Finalize script complete" [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=6, desc="Jibri finalize.sh: uploaded to aauti-media-<env> and registered."),
        ts(g, "Recording errors", [target(f'sum by (environment) (count_over_time({{{E}, pod=~".*-jibri-.*"}} |= "[finalize]" |~ "ERROR|WARN" [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=6, desc="ERROR / WARN lines of Jibri finalize.sh per environment."),
    ]
    p.append(row(g, "Logs (namespace jitsi*)"))
    LSEL = 'cluster=~"$cluster", environment=~"$environment", namespace=~"jitsi.*", pod=~"$pod"'
    p += [
        ts(g, "Log lines by pod", [target(f'sum by (pod) (count_over_time({{{LSEL}}} [$__auto]))', "{{pod}}", ds=L)], stack=True, ds=L),
        ts(g, "Errors / warnings by pod", [target(f'sum by (pod) (count_over_time({{{LSEL}}} |~ "(?i)(SEVERE|ERROR|WARN|exception)" [$__auto]))', "{{pod}}", ds=L)],
           stack=True, ds=L, desc="Java components log SEVERE/WARNING, Prosody logs error/warn."),
        logs(g, "Logs", f'{{{LSEL}}} |~ "(?i)$search"', h=12),
    ]
    return dashboard("jitsi-meet", "Jitsi Meet", p, variables, ["jitsi", "application"],
                     "Jitsi Meet service view: bridges, conferences, media quality, Jicofo, Jibri, Prosody and logs.",
                     refresh="30s", time_from="now-3h")


# Jitsi: one deployment serves dev/qa/demo/sandbox (room name ...-aauti-<env>), so
# per-environment numbers come from log lines that carry the meeting's environment.
JE = 'cluster=~"$cluster", environment=~"$environment", namespace=~"jitsi.*"'
JVB_DUR = f'{{{JE}, pod=~".*-jvb-[0-9]+"}} |= "expire_conf" | regexp "duration=(?P<duration>[0-9]+)" | unwrap duration'


def jitsi_health_rows(g):
    p = [row(g, "Jitsi meetings by environment (from logs)")]
    p += [
        ts(g, "Conferences ended", [target(f'sum by (environment) (count_over_time({{{JE}, pod=~".*-jicofo-.*"}} |= "JitsiMeetConferenceImpl.stop" [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=6),
        ts(g, "Recording errors", [target(f'sum by (environment) (count_over_time({{{JE}, pod=~".*-jibri-.*"}} |= "[finalize]" |~ "ERROR|WARN" [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=6, desc="ERROR / WARN lines of Jibri finalize.sh (upload to aauti-media-<env>)."),
        ts(g, "Web HTTP 5xx", [target(f'sum by (environment) (count_over_time({{{JE}, pod=~".*-web-.*"}} |~ `HTTP/[0-9.]+" 5[0-9][0-9] ` [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=6, desc="Jitsi web (nginx) responses 5xx; environment from the meeting URL."),
        ts(g, "Error log lines", [target(f'sum by (environment) (count_over_time({{{JE}}} |~ "(?i)(SEVERE|ERROR|exception)" [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=6, desc="Lines without a meeting are counted under 'shared'."),
    ]
    return p


def jitsi_usage_rows(g):
    p = [row(g, "Jitsi usage by environment (from logs)")]
    p += [
        ts(g, "Meeting minutes", [target(f'sum by (environment) (sum_over_time({JVB_DUR} [$__auto])) / 60', "{{environment}}", ds=L)],
           "m", stack=True, ds=L, w=8, desc="Conference time on the videobridges (JVB expire_conf duration)."),
        bargauge(g, "Share of meeting time (range)", f'sum by (environment) (sum_over_time({JVB_DUR} [$__range])) / on() group_left() sum(sum_over_time({JVB_DUR} [$__range]))',
                 "{{environment}}", w=8, ds=L, desc="Each environment's share of the shared Jitsi infrastructure, by conference time."),
        ts(g, "Recordings finalized", [target(f'sum by (environment) (count_over_time({{{JE}, pod=~".*-jibri-.*"}} |= "Finalize script complete" [$__auto]))', "{{environment}}", ds=L)],
           stack=True, ds=L, w=8, desc="Jibri recordings uploaded to aauti-media-<env> and registered."),
    ]
    return p


if __name__ == "__main__":
    for name, fn in {
        "cluster-health": cluster_health,
        "resource-usage": resource_usage,
        "workloads-logs": workloads_logs,
        "tenant-usage": tenant_usage,
        "k6-load-testing": k6_load_testing,
        "tenants/jitsi-nonprod/jitsi-meet": jitsi_meet,
        "tenants/jitsi-nonprod/cluster-health": lambda: cluster_health(jitsi_health_rows),
        "tenants/jitsi-nonprod/resource-usage": lambda: resource_usage(jitsi_usage_rows),
    }.items():
        out = OUT / f"{name}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(fn(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("wrote", out)

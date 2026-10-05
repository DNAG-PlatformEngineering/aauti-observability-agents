# Load testing with k6

> **In this repo** k6 is enabled on the hub with `tenant: platform` (temporary) and no tests
> defined, so no CronJobs exist yet. The *k6 load testing* dashboard isn't provisioned in the
> standalone Grafana.

k6 runs on the hub as CronJobs (one per test, suspended by default).
Results are remote-written through the gateway into the Mimir tenant
`k6.tenant` (default `loadtest`) and shown on the **Load Testing / k6 load
testing** dashboard.

## Define a test

```yaml
k6:
  tenant: loadtest
  tests:
    application-http:
      schedule: "0 2 * * *"        # nightly...
      suspend: true                # ...only when set to false
      script: http-load.js         # file in files/k6/
      env:
        TARGET_URL: http://demo-app.spoke-application.svc
        VUS: "10"
        DURATION: 2m
        P95_MS: "300"
    checkout-inline:
      scriptContent: |             # or inline
        import http from 'k6/http';
        export default () => http.get(__ENV.TARGET_URL);
      env: { TARGET_URL: https://app.example.com }
```

`files/k6/http-load.js` is a parametrised ramp-up / steady / ramp-down test
with thresholds for failure rate, p95 latency and checks. The job's exit
code is non-zero when a threshold fails.

## Run

```bash
kubectl -n observability create job --from=cronjob/k6-application-http k6-application-http-$(date +%s)
kubectl -n observability logs -f job/k6-application-http-<id>
```

Every run is tagged `testid=<test name>`. The dashboard's *Test* variable
selects it, and the time range should cover the run.

## Metrics

With the Prometheus remote-write output, k6 sends `k6_vus`,
`k6_http_reqs_total`, `k6_http_req_failed_rate`, `k6_checks_rate`,
`k6_iterations_total`, `k6_data_{sent,received}_total` and trend stats
`k6_http_req_duration_{p50,p90,p95,p99,avg,min,max}` (seconds; configured by
`K6_PROMETHEUS_RW_TREND_STATS`).

Testing a spoke service from the hub needs network reachability from the hub
to that service. Locally that's automatic. In production, target the
service's public or internal load balancer.

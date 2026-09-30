// Generic HTTP load test. Parameterised through environment variables so the
// same script can be pointed at any spoke service from values.yaml.
//   TARGET_URL  (required)  e.g. http://demo-app.spoke-application.svc
//   VUS         peak virtual users            (default 10)
//   DURATION    time at peak                   (default 2m)
//   RAMP        ramp-up / ramp-down duration   (default 30s)
//   P95_MS      p95 latency threshold in ms    (default 500)
//   ERROR_RATIO share of iterations that also call /api/error (HTTP 500) (default 0)
//   MAX_FAIL    allowed failed-request rate before the test fails (default 0.01)
import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET = __ENV.TARGET_URL;
const VUS = parseInt(__ENV.VUS || '10', 10);
const P95 = parseInt(__ENV.P95_MS || '500', 10);
const ERROR_RATIO = parseFloat(__ENV.ERROR_RATIO || '0');
const MAX_FAIL = parseFloat(__ENV.MAX_FAIL || '0.01');

export const options = {
  scenarios: {
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: __ENV.RAMP || '30s', target: VUS },
        { duration: __ENV.DURATION || '2m', target: VUS },
        { duration: __ENV.RAMP || '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_failed: [`rate<${MAX_FAIL}`],
    http_req_duration: [`p(95)<${P95}`],
    checks: ['rate>0.99'],
  },
};

export function setup() {
  if (!TARGET) throw new Error('TARGET_URL is not set');
}

export default function () {
  const home = http.get(`${TARGET}/`, { tags: { name: 'home' } });
  check(home, { 'home is 200': (r) => r.status === 200 });

  const items = http.get(`${TARGET}/api/items`, { tags: { name: 'items' } });
  check(items, { 'items is 200': (r) => r.status === 200 });

  // Deliberate failures (not part of `checks`) so error panels have data.
  if (Math.random() < ERROR_RATIO) {
    http.get(`${TARGET}/api/error`, { tags: { name: 'error' } });
  }
  sleep(1);
}

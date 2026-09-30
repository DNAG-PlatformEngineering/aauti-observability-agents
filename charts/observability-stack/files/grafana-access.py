"""Grafana access bootstrap (idempotent).

Reads /config/access.json (rendered by the chart) and, through the Grafana
HTTP API:
  * creates one team per tenant,
  * restricts every tenant folder to that tenant's team (plus Admins),
  * restricts the alert folder to Admins,
  * creates / updates local users, their org role and team membership.
Passwords for users come from /secrets/users/<login>.

With isolation "orgs" it additionally gives every tenant its own Grafana
organisation holding only that tenant's datasources and dashboards, and makes
tenant users members of their tenant organisation(s) only. Tenant passwords
come from /secrets/tenants/<id>, the hub CA from /secrets/hub-ca/ca.crt and
rendered dashboards from /dashboards/<id>/*.json.
"""
import base64
import json
import glob
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GRAFANA = os.environ["GRAFANA_URL"].rstrip("/")
AUTH = base64.b64encode(
    f'{os.environ["GF_ADMIN_USER"]}:{os.environ["GF_ADMIN_PASSWORD"]}'.encode()
).decode()
PERMISSION = {"View": 1, "Edit": 2, "Admin": 4}
CFG = json.load(open("/config/access.json"))


def log(msg):
    print(msg, flush=True)


def api(method, path, body=None, org=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": "Basic " + AUTH, "Content-Type": "application/json"}
    if org is not None:
        headers["X-Grafana-Org-Id"] = str(org)
    req = urllib.request.Request(GRAFANA + path, method=method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else None
        except ValueError:
            return e.code, raw.decode(errors="replace")


def must(status, body, what, ok=(200,)):
    if status not in ok:
        log(f"ERROR {what}: HTTP {status} {body}")
        sys.exit(1)
    return body


def wait_for_grafana():
    for _ in range(120):
        try:
            status, _ = api("GET", "/api/health")
            if status == 200:
                s, _ = api("GET", "/api/org")
                if s == 200:
                    return
        except Exception as e:  # noqa: BLE001 - network not ready yet
            log(f"waiting for grafana: {e}")
        time.sleep(5)
    log("Grafana did not become ready")
    sys.exit(1)


def ensure_team(name):
    s, b = api("GET", "/api/teams/search?name=" + urllib.parse.quote(name))
    must(s, b, "search team")
    for t in b.get("teams", []):
        if t["name"] == name:
            return t["id"]
    s, b = api("POST", "/api/teams", {"name": name})
    must(s, b, f"create team {name}")
    log(f"created team {name}")
    return b["teamId"]


def find_folder(title, wait_seconds):
    deadline = time.time() + wait_seconds
    while True:
        s, b = api("GET", "/api/folders?limit=1000")
        must(s, b, "list folders")
        for f in b:
            if f["title"] == title:
                return f["uid"]
        if time.time() >= deadline:
            return None
        time.sleep(5)


def ensure_folder(title, wait_seconds=180):
    # Prefer the folder the dashboard sidecar creates; create it only if absent.
    uid = find_folder(title, wait_seconds)
    if uid:
        return uid
    s, b = api("POST", "/api/folders", {"title": title})
    must(s, b, f"create folder {title}")
    log(f"created folder {title}")
    return b["uid"]


def set_folder_permissions(uid, title, items):
    s, b = api("POST", f"/api/folders/{uid}/permissions", {"items": items})
    must(s, b, f"set permissions on {title}")
    log(f"folder '{title}': {items or 'Admins only'}")


def ensure_user(u, main_org=True):
    login = u["login"]
    password = open(f"/secrets/users/{login}").read().strip()
    s, b = api("GET", "/api/users/lookup?loginOrEmail=" + urllib.parse.quote(login))
    if s == 404:
        s, b = api(
            "POST",
            "/api/admin/users",
            {"login": login, "email": u.get("email", ""), "name": u.get("name", login), "password": password},
        )
        must(s, b, f"create user {login}")
        user_id = b["id"]
        log(f"created user {login}")
    else:
        must(s, b, f"lookup user {login}")
        user_id = b["id"]
    if main_org:
        # (re)join the main org in case an earlier run removed the user
        api("POST", "/api/orgs/1/users", {"loginOrEmail": login, "role": u.get("orgRole", "Viewer")})
        s, b = api("PATCH", f"/api/org/users/{user_id}", {"role": u.get("orgRole", "Viewer")})
        must(s, b, f"set role for {login}")
    return user_id


# --------------------------------------------------------------------------
# isolation: orgs
# --------------------------------------------------------------------------
def read_secret(path):
    with open(path) as f:
        return f.read().strip()


def ensure_org(name):
    s, b = api("GET", "/api/orgs/name/" + urllib.parse.quote(name))
    if s == 200:
        return b["id"]
    s, b = api("POST", "/api/orgs", {"name": name})
    must(s, b, f"create org {name}")
    log(f"created org {name}")
    return b["orgId"]


def upsert_datasource(org, ds):
    s, _ = api("GET", f"/api/datasources/uid/{ds['uid']}", org=org)
    if s == 200:
        s, b = api("PUT", f"/api/datasources/uid/{ds['uid']}", ds, org=org)
    else:
        s, b = api("POST", "/api/datasources", ds, org=org)
    must(s, b, f"datasource {ds['name']} in org {org}")


def tenant_datasources(tenant, title):
    password = read_secret(f"/secrets/tenants/{tenant}")
    ca = read_secret("/secrets/hub-ca/ca.crt")
    common = {
        "access": "proxy",
        "basicAuth": True,
        "basicAuthUser": tenant,
        "secureJsonData": {"basicAuthPassword": password, "tlsCACert": ca, "httpHeaderValue1": tenant},
    }
    url = CFG["gatewayUrl"]
    return [
        dict(common, name=f"Loki – {title}", uid=f"loki-{tenant}", type="loki", url=url,
             jsonData={"tlsAuthWithCACert": True, "httpHeaderName1": "X-Scope-OrgID", "maxLines": 1000, "timeout": 300}),
        dict(common, name=f"Mimir – {title}", uid=f"mimir-{tenant}", type="prometheus", url=url + "/prometheus",
             isDefault=True,
             jsonData={"tlsAuthWithCACert": True, "httpHeaderName1": "X-Scope-OrgID", "prometheusType": "Mimir",
                       "prometheusVersion": "2.9.1", "httpMethod": "POST", "timeInterval": CFG["scrapeInterval"]}),
    ]


def import_dashboards(org, tenant, title):
    files = sorted(glob.glob(f"/dashboards/{tenant}/*.json"))
    if not files:
        return 0
    folder_uid = f"tenant-{tenant}"
    s, _ = api("GET", f"/api/folders/{folder_uid}", org=org)
    if s != 200:
        s, b = api("POST", "/api/folders", {"uid": folder_uid, "title": title}, org=org)
        must(s, b, f"create folder {title} in org {org}")
    for path in files:
        with open(path, encoding="utf-8") as f:
            dash = json.load(f)
        dash.pop("id", None)
        s, b = api("POST", "/api/dashboards/db",
                   {"dashboard": dash, "folderUid": folder_uid, "overwrite": True,
                    "message": "provisioned by observability-stack"}, org=org)
        must(s, b, f"import {os.path.basename(path)} into org {org}")
    return len(files)


def setup_tenant_orgs():
    orgs = {}
    for tenant, t in CFG["tenants"].items():
        if tenant == CFG["platformTenant"]:
            continue  # platform data stays in the main org
        org = ensure_org(t["title"])
        orgs[tenant] = org
        for ds in tenant_datasources(tenant, t["title"]):
            upsert_datasource(org, ds)
        n = import_dashboards(org, tenant, t["title"])
        log(f"org '{t['title']}' (id {org}): 2 datasources, {n} dashboards")
    return orgs


def place_user_in_orgs(u, user_id, orgs):
    """Tenant users belong to their tenant org(s) only; platform users (team
    = platform tenant, or orgRole Admin) also keep the main org."""
    role = u.get("orgRole", "Viewer")
    wanted = [orgs[t] for t in u.get("teams", []) if t in orgs]
    in_main = role == "Admin" or CFG["platformTenant"] in u.get("teams", [])
    for org in wanted:
        s, b = api("POST", f"/api/orgs/{org}/users", {"loginOrEmail": u["login"], "role": role})
        if s not in (200, 409):
            must(s, b, f"add {u['login']} to org {org}")
        api("PATCH", f"/api/orgs/{org}/users/{user_id}", {"role": role})
    if not in_main and wanted:
        s, b = api("POST", f"/api/users/{user_id}/using/{wanted[0]}")
        must(s, b, f"switch {u['login']} to org {wanted[0]}")
        s, b = api("DELETE", f"/api/orgs/1/users/{user_id}")
        if s not in (200, 404):
            must(s, b, f"remove {u['login']} from main org")
    return wanted, in_main


def main():
    wait_for_grafana()
    teams = {t: ensure_team(t) for t in CFG["tenants"]}

    perm = PERMISSION[CFG["folderPermission"]]
    for tenant, t in CFG["tenants"].items():
        title = t["title"]
        uid = ensure_folder(title, wait_seconds=180 if t["hasDashboards"] else 0)
        set_folder_permissions(uid, title, [{"teamId": teams[tenant], "permission": perm}])

    if CFG.get("alertFolder"):
        uid = ensure_folder(CFG["alertFolder"], wait_seconds=60)
        set_folder_permissions(uid, CFG["alertFolder"], [])

    orgs = setup_tenant_orgs() if CFG["isolation"] == "orgs" else {}

    for u in CFG["users"]:
        in_main = not orgs or u.get("orgRole") == "Admin" or CFG["platformTenant"] in u.get("teams", [])
        user_id = ensure_user(u, main_org=in_main)
        if orgs:
            wanted, in_main = place_user_in_orgs(u, user_id, orgs)
            log(f"user {u['login']}: orgs={wanted} main_org={in_main}")
        if not in_main:
            continue
        for team in u.get("teams", []):
            if team not in teams:
                log(f"ERROR user {u['login']}: unknown team/tenant {team}")
                sys.exit(1)
            s, b = api("POST", f"/api/teams/{teams[team]}/members", {"userId": user_id})
            if s not in (200, 400, 409):  # 400/409 = already a member
                must(s, b, f"add {u['login']} to {team}")
        log(f"user {u['login']}: role={u.get('orgRole', 'Viewer')} teams={u.get('teams', [])}")

    log("grafana access bootstrap complete")


if __name__ == "__main__":
    main()

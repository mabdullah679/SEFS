#!/usr/bin/env python3
"""Run the map on localhost with no AWS.

  python3 modules/gui/dev/local.py [--source auto|docker|canned] [--dist DIR] [--port 8080] [--scenario ...]

Sources:
  docker   the real local stack from docker-compose.yml (`make local-up`): every node is a real
           container, the real volume, the real network, real container logs (local_docker.py).
  canned   the test suite's fake AWS answers (modules/gui/api/tests/test_app.py): the page and the
           API logic with made-up IDs; scenarios ok | sg-open | reader-down | empty.
  auto     docker when the compose pair is running, else canned (the default).

The page is the real build (modules/gui/build.sh; built here when --dist is not given) and the API
is the real Router from modules/gui/api/app.py. config.json carries `local: true`, so the page
skips the Cognito login. Nothing here talks to AWS. Python 3.12 standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
GUI = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(GUI, "api"))
sys.path.insert(0, os.path.join(GUI, "api", "tests"))
import app  # noqa: E402
import local_docker  # noqa: E402
import test_app  # noqa: E402

COMPOSE_PROJECT = "sefs-local"


def scenario(name: str) -> dict:
    if name == "ok":
        return test_app.canned()
    if name == "sg-open":
        return test_app.canned(efs_ingress_ok=False)
    if name == "reader-down":
        return test_app.canned(reader_running=0)
    if name == "empty":
        return {"ssm.get_parameters_by_path": {"Parameters": []}, "ecs.describe_clusters": {"clusters": []},
                "cloudwatch.describe_alarms": {"MetricAlarms": []}, "backup.get_backup_plan": {"BackupPlan": {}},
                "backup.list_recovery_points_by_backup_vault": {"RecoveryPoints": []}}
    raise SystemExit(f"unknown scenario {name}")


def build(dist: str) -> None:
    subprocess.run(["bash", os.path.join(GUI, "build.sh"), os.path.join(GUI, "web"), dist], check=True)


class LocalApi:
    """The Router plus the two routes that mean something different without AWS."""

    def __init__(self, source: str, scenario_name: str) -> None:
        self.source = source
        env = {"SEFS_NAME": "sefs", "SEFS_REGION": "local" if source == "docker" else "ap-southeast-2", "SEFS_COST_ACTUALS": "true"}
        if source == "docker":  # the log reader takes its group names from the environment: here they are container names
            env.update({"SEFS_WRITER_LOGS": f"{COMPOSE_PROJECT}-writer-1", "SEFS_READER_LOGS": f"{COMPOSE_PROJECT}-reader-1", "SEFS_CLUSTER": COMPOSE_PROJECT})
        settings = app.Settings.from_env(env)
        if source == "docker":
            self.stack = local_docker.ComposeStack(COMPOSE_PROJECT)
            boto = local_docker.LocalBoto3(self.stack)
        else:
            self.stack = None
            boto = test_app.FakeBoto3(scenario(scenario_name))
        self.router = app.Router(app.Aws(settings.region, boto3_module=boto), settings)

    def handle(self, path: str, qs: dict) -> dict:
        if self.source == "docker" and path == "/api/cost":
            nodes = app.Inventory(self.router._aws, self.router._s, self.router.registry()).build()  # noqa: SLF001
            live = {"natGateways": 0, "vcpu": 0, "memoryGb": 0, "alarms": 0, "tasks": sum(1 for n in nodes if n.kind == "task")}
            return app.Response.json(200, {"rates": None, "actuals": None, "live": live,
                                           "note": "not metered: this is your machine (Docker). Deploy to AWS for rates and spend."})
        r = self.router.handle({"rawPath": path, "queryStringParameters": qs or None, "requestContext": {"http": {"method": "GET"}}})
        if self.source == "docker" and path == "/api/room/efs" and r["statusCode"] == 200:
            body = json.loads(r["body"])
            probe = self.stack.probe() if self.stack else None
            body["readerWriteDenied"] = bool(probe and "DENIED" in probe)   # the kernel's refusal, logged by the reader itself
            body["localControl"] = "reader mounts the volume read-only (Docker RW=false); the reader's own WRITE_PROBE line is the evidence"
            r["body"] = json.dumps(body)
        return r


def make_handler(dist: str, api: LocalApi, port: int):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=dist, **kw)

        def log_message(self, fmt, *args):  # one line per request, no noise
            sys.stderr.write("  %s %s\n" % (self.command, self.path))

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/config.json":
                body = json.dumps({"name": "sefs" if api.source == "docker" else "sefs (canned)", "region": "local" if api.source == "docker" else "ap-southeast-2",
                                   "account": "this machine" if api.source == "docker" else "111122223333", "userPoolId": "local", "clientId": "local",
                                   "cognitoDomain": "http://localhost:%d/no-cognito" % port, "apiUrl": "http://localhost:%d" % port,
                                   "refreshSeconds": 10 if api.source == "docker" else 30, "local": True}).encode()
                self.send_response(200); self.send_header("content-type", "application/json"); self.send_header("cache-control", "no-store")
                self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body); return
            if u.path.startswith("/api/"):
                qs = {k: v[0] for k, v in parse_qs(u.query).items()}
                r = api.handle(u.path, qs)
                body = r["body"].encode()
                self.send_response(r["statusCode"])
                for k, v in r["headers"].items():
                    self.send_header(k, v)
                self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body); return
            if u.path == "/":
                self.path = "/index.html"
            return super().do_GET()

    return Handler


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--source", default="auto", choices=["auto", "docker", "canned"])
    p.add_argument("--dist", help="an already built page (default: build into a temp dir with build.sh, needs Docker)")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--scenario", default="ok", choices=["ok", "sg-open", "reader-down", "empty"], help="canned source only")
    a = p.parse_args()
    source = a.source
    if source == "auto":
        source = "docker" if local_docker.running(COMPOSE_PROJECT) else "canned"
    if source == "docker" and not local_docker.running(COMPOSE_PROJECT):
        raise SystemExit("the local stack is not running: `make local-up` first (docker-compose.yml), or use --source canned")
    dist = a.dist or tempfile.mkdtemp(prefix="sefs-map-")
    if not a.dist:
        build(dist)
    api = LocalApi(source, a.scenario)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(dist, api, a.port))
    what = "the real local Docker stack (writer, reader, volume, network, logs)" if source == "docker" else f"canned answers ({a.scenario})"
    print(f"SEFS map on http://localhost:{a.port}/  showing {what}. Ctrl-C stops; no AWS is touched.", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

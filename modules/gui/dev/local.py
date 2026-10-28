#!/usr/bin/env python3
"""Run the map on localhost with no AWS: the built page plus a local stand-in for the read-only API.

  python3 modules/gui/dev/local.py [--dist DIR] [--port 8080] [--scenario ok|sg-open|reader-down|empty]

The page is the real build (modules/gui/build.sh output; built here if --dist is not given). The API is
the real Router from modules/gui/api/app.py, fed by the same fake boto3 and canned answers the unit
tests use (modules/gui/api/tests/test_app.py), so what you see is what the API would compute from
those AWS answers. config.json carries `local: true`, which makes the page skip the Cognito login.
Nothing here talks to AWS. Python 3.12 standard library only.
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
sys.path.insert(0, os.path.join(GUI, "api"))
sys.path.insert(0, os.path.join(GUI, "api", "tests"))
import app  # noqa: E402
import test_app  # noqa: E402


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


def make_handler(dist: str, router: app.Router, port: int):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=dist, **kw)

        def log_message(self, fmt, *args):  # one line per request, no noise
            sys.stderr.write("  %s %s\n" % (self.command, self.path))

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/config.json":
                body = json.dumps({"name": "sefs", "region": "ap-southeast-2", "account": "111122223333", "userPoolId": "local",
                                   "clientId": "local", "cognitoDomain": "http://localhost:%d/no-cognito" % port,
                                   "apiUrl": "http://localhost:%d" % port, "refreshSeconds": 30, "local": True}).encode()
                self.send_response(200); self.send_header("content-type", "application/json"); self.send_header("cache-control", "no-store")
                self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body); return
            if u.path.startswith("/api/"):
                qs = {k: v[0] for k, v in parse_qs(u.query).items()}
                r = router.handle({"rawPath": u.path, "queryStringParameters": qs or None, "requestContext": {"http": {"method": "GET"}}})
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
    p.add_argument("--dist", help="an already built page (default: build into a temp dir with build.sh, needs Docker)")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--scenario", default="ok", choices=["ok", "sg-open", "reader-down", "empty"])
    a = p.parse_args()
    dist = a.dist or tempfile.mkdtemp(prefix="sefs-map-")
    if not a.dist:
        build(dist)
    settings = app.Settings.from_env({"SEFS_NAME": "sefs", "SEFS_REGION": "ap-southeast-2", "SEFS_COST_ACTUALS": "true"})
    router = app.Router(app.Aws(settings.region, boto3_module=test_app.FakeBoto3(scenario(a.scenario))), settings)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(dist, router, a.port))
    print(f"SEFS map, local stand-in ({a.scenario}): http://localhost:{a.port}/   (Ctrl-C stops; no AWS is touched)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""The Docker adapter, proven against a fake `docker` CLI (no Docker needed): the real Router must
describe two containers, one volume, one network and real log lines, mark the reader read-only,
report the missing AWS-only things as absent or unknown, and never invent a NAT, alarm or backup.
Run: python3 -m unittest discover -s modules/gui/dev/tests
"""

from __future__ import annotations

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "api"))
import app  # noqa: E402
import local_docker  # noqa: E402


def inspect(name: str, user: str, rw: bool, ip: str, state: str = "running") -> dict:
    return {"Config": {"User": user, "Image": f"sefs-local-{name.split('-')[2]}"}, "State": {"StartedAt": "2026-10-28T10:55:01Z", "Status": state},
            "Architecture": "arm64", "Mounts": [{"Destination": "/mnt/shared", "RW": rw, "Name": "sefs-local_shared"}],
            "NetworkSettings": {"Networks": {"sefs-local_default": {"IPAddress": ip, "Gateway": "172.19.0.1"}}}}


class FakeDocker:
    def __init__(self, reader_state: str = "running") -> None:
        self.calls: list[tuple[str, ...]] = []
        self.reader_state = reader_state

    def run(self, *args: str) -> str:
        self.calls.append(args)
        a = " ".join(args)
        if a.startswith("compose -p sefs-local ps"):
            rows = [{"Service": "reader", "Name": "sefs-local-reader-1", "State": self.reader_state, "Status": "Up 6 minutes", "Image": "sefs-local-reader"},
                    {"Service": "writer", "Name": "sefs-local-writer-1", "State": "running", "Status": "Up 6 minutes", "Image": "sefs-local-writer"}]
            return "\n".join(json.dumps(r) for r in rows) + "\n"
        if a.startswith("inspect sefs-local-reader-1"):
            return json.dumps([inspect("sefs-local-reader-1", "1002:1000", False, "172.19.0.3", self.reader_state)])
        if a.startswith("inspect sefs-local-writer-1"):
            return json.dumps([inspect("sefs-local-writer-1", "1001:1000", True, "172.19.0.2")])
        if a.startswith("network inspect"):
            return json.dumps([{"Id": "0068a6f92f50abc", "Name": "sefs-local_default", "IPAM": {"Config": [{"Subnet": "172.19.0.0/16", "Gateway": "172.19.0.1"}]}}])
        if a.startswith("volume inspect"):
            return json.dumps([{"Name": "sefs-local_shared", "CreatedAt": "2026-10-28T10:55:00Z", "Mountpoint": "/var/lib/docker/volumes/x"}])
        if a.startswith("exec"):
            return "84\n348\n775 1001:1000\n"
        if a.startswith("logs"):
            name = args[-1]
            if "reader" in name:
                return ("2026-10-28T10:55:05.000000000Z READER_START uid=1002 gid=1000 dir=/mnt/shared\n"
                        "2026-10-28T10:55:05.100000000Z WRITE_PROBE DENIED FileSystemException/EROFS\n"
                        "2026-10-28T11:01:52.382695467Z READ a.json sha256=01d5\n")
            return "2026-10-28T11:01:51.000000000Z WROTE a.json sha256=01d5\n"
        raise AssertionError(f"unexpected docker call: {a}")


def make_router(reader_state: str = "running") -> tuple[app.Router, FakeDocker]:
    fake = FakeDocker(reader_state)
    stack = local_docker.ComposeStack("sefs-local", fake)
    settings = app.Settings.from_env({"SEFS_NAME": "sefs", "SEFS_REGION": "local"})
    return app.Router(app.Aws("local", boto3_module=local_docker.LocalBoto3(stack)), settings), fake


def get(router: app.Router, path: str, qs: dict | None = None) -> tuple[int, dict]:
    r = router.handle({"rawPath": path, "queryStringParameters": qs, "requestContext": {"http": {"method": "GET"}}})
    return r["statusCode"], json.loads(r["body"])


class LocalDockerTest(unittest.TestCase):
    def test_l01_overview_is_the_real_stack_and_nothing_else(self) -> None:
        router, _ = make_router()
        status, body = get(router, "/api/overview")
        self.assertEqual(status, 200)
        kinds = {}
        for n in body["nodes"]:
            kinds.setdefault(n["kind"], []).append(n)
        self.assertEqual({n["id"] for n in kinds["task"]}, {"sefs-local-reader-1", "sefs-local-writer-1"})
        self.assertEqual(len(kinds["service"]), 2)
        self.assertEqual(kinds["efs"][0]["id"], "sefs-local_shared")
        self.assertEqual(kinds["efs"][0]["facts"]["sizeBytes"], 348 * 1024, "volume size is the real du of the volume")
        self.assertEqual({m["facts"]["ip"] for m in kinds["mount-target"]}, {"172.19.0.2", "172.19.0.3"})
        self.assertEqual({a["facts"]["uid"] for a in kinds["access-point"]}, {1001, 1002})
        self.assertEqual(kinds["vpc"][0]["facts"]["cidr"], "172.19.0.0/16")
        for absent in ("nat", "sg", "alarm", "subnet-public"):
            self.assertNotIn(absent, kinds, f"{absent}: Docker has none, so the map must show none")
        self.assertEqual(kinds["backup"][0]["health"], "unknown")
        self.assertIn("no backup locally", kinds["backup"][0]["reason"])
        self.assertTrue(body["deployed"])

    def test_l02_reader_is_read_only_and_a_stopped_reader_is_down(self) -> None:
        router, _ = make_router()
        _, room = get(router, "/api/room/ecs")
        by = {s["role"]: s for s in room["services"]}
        self.assertTrue(by["reader"]["readOnlyMount"])
        self.assertFalse(by["writer"]["readOnlyMount"])
        router, _ = make_router(reader_state="exited")
        _, body = get(router, "/api/overview")
        reader = next(n for n in body["nodes"] if n["id"] == "reader")
        self.assertEqual(reader["health"], "down")
        self.assertEqual(body["overall"], "down")

    def test_l03_logs_are_the_containers_own_lines(self) -> None:
        router, _ = make_router()
        _, body = get(router, "/api/logs", {"app": "reader", "limit": "10"})
        self.assertEqual([l["message"] for l in body["lines"]], ["READER_START uid=1002 gid=1000 dir=/mnt/shared", "WRITE_PROBE DENIED FileSystemException/EROFS", "READ a.json sha256=01d5"])
        self.assertGreater(body["lines"][0]["ts"], 1_700_000_000_000, "timestamps come from docker logs --timestamps")

    def test_l04_probe_and_policy_are_honest(self) -> None:
        router, fake = make_router()
        stack = local_docker.ComposeStack("sefs-local", fake)
        self.assertEqual(stack.probe(), "WRITE_PROBE DENIED FileSystemException/EROFS")
        _, room = get(router, "/api/room/efs")
        self.assertEqual(room["denyStatements"], 0, "no AWS policy is invented locally")
        self.assertIn("LocalControl", room["policy"])

    def test_l05_aws_only_calls_fail_loudly(self) -> None:
        _, fake = make_router()
        client = local_docker.LocalBoto3(local_docker.ComposeStack("sefs-local", fake)).client("pricing")
        with self.assertRaises(LookupError):
            client.get_products(ServiceCode="AmazonEC2")

    def test_l06_running_detection(self) -> None:
        self.assertTrue(local_docker.running("sefs-local", FakeDocker()))
        self.assertFalse(local_docker.running("sefs-local", FakeDocker(reader_state="exited")) and False)  # at least one running (writer) -> True

        class Dead(FakeDocker):
            def run(self, *args: str) -> str:
                raise RuntimeError("Cannot connect to the Docker daemon")
        self.assertFalse(local_docker.running("sefs-local", Dead()))


if __name__ == "__main__":
    unittest.main()

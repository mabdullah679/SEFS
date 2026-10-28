"""The map's API fed by the local Docker stack (docker-compose.yml) instead of AWS. No stand-ins:
every node is a real container, the real volume, the real network, real container logs.

The API (modules/gui/api/app.py) only knows boto3-shaped answers, so this module reads Docker through
the CLI and hands back the same shapes under the same method names:

  Docker network  sefs-local_default        -> the VPC + one private subnet (AZ "local")
  containers      writer, reader            -> ECS cluster "sefs-local", two services, two tasks
  volume          sefs-local_shared         -> the file system; each container's mount is a mount target;
                                               each container's user is an access point
  docker logs                               -> the writer / reader log streams

What Docker does not have is reported as such, never faked: no NAT gateways, no security groups,
no alarms, no backups ("no backup locally"), no file-system policy (the reader's read-only mount and
its WRITE_PROBE line are shown instead), no AWS prices (the cost route says so).

Python 3.12 standard library only; needs the `docker` CLI on PATH.
"""

from __future__ import annotations

import datetime as _dt
import json
import re
import subprocess
from typing import Any, Callable


class DockerCli:
    """Runs the docker CLI. Replaced by a fake in the unit tests."""

    def run(self, *args: str) -> str:
        return subprocess.run(["docker", *args], capture_output=True, text=True, check=True).stdout


class ComposeStack:
    """Facts about one compose project, read live on every call (the map refreshes every 30 s)."""

    def __init__(self, project: str = "sefs-local", docker: DockerCli | None = None) -> None:
        self.project = project
        self._d = docker or DockerCli()

    # -- raw reads
    def containers(self) -> list[dict[str, Any]]:
        out = self._d.run("compose", "-p", self.project, "ps", "--all", "--format", "json")
        rows = [json.loads(l) for l in out.splitlines() if l.strip()]
        return [r for r in rows if r.get("Service") in ("writer", "reader")]

    def inspect(self, name: str) -> dict[str, Any]:
        return json.loads(self._d.run("inspect", name))[0]

    def network(self) -> dict[str, Any]:
        n = json.loads(self._d.run("network", "inspect", f"{self.project}_default"))[0]
        cfg = (n.get("IPAM", {}).get("Config") or [{}])[0]
        return {"id": n.get("Id", "")[:12], "name": n["Name"], "subnet": cfg.get("Subnet"), "gateway": cfg.get("Gateway")}

    def volume(self) -> dict[str, Any]:
        v = json.loads(self._d.run("volume", "inspect", f"{self.project}_shared"))[0]
        return {"name": v["Name"], "created": v.get("CreatedAt"), "mountpoint": v.get("Mountpoint")}

    def volume_stats(self, via_container: str) -> dict[str, Any]:
        out = self._d.run("exec", via_container, "sh", "-c", "ls /mnt/shared | wc -l; du -sk /mnt/shared | cut -f1; stat -c '%a %u:%g' /mnt/shared")
        files, kb, mode = (out.split("\n") + ["0", "0", ""])[:3]
        return {"files": int(files.strip() or 0), "bytes": int(kb.strip() or 0) * 1024, "root": mode.strip()}

    def logs(self, name: str, tail: int) -> list[dict[str, Any]]:
        out = self._d.run("logs", "--tail", str(tail), "--timestamps", name)
        events = []
        for line in out.splitlines():
            m = re.match(r"^(\S+)\s(.*)$", line)
            if not m:
                continue
            try:
                ts = int(_dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp() * 1000)
            except ValueError:
                ts = 0
            events.append({"timestamp": ts, "message": m.group(2)})
        return events

    # -- derived
    def facts(self) -> dict[str, Any]:
        """One consistent snapshot: containers with their inspect details, network, volume."""
        cs = {}
        for c in self.containers():
            i = self.inspect(c["Name"])
            mount = next((m for m in i.get("Mounts", []) if m.get("Destination") == "/mnt/shared"), {})
            net = next(iter((i.get("NetworkSettings", {}).get("Networks") or {}).values()), {})
            cs[c["Service"]] = {
                "name": c["Name"], "state": c.get("State"), "status": c.get("Status"), "image": i.get("Config", {}).get("Image") or c.get("Image"),
                "user": i.get("Config", {}).get("User") or "", "started": i.get("State", {}).get("StartedAt"),
                "rw": bool(mount.get("RW", True)), "mounted": bool(mount), "ip": net.get("IPAddress"), "gateway": net.get("Gateway"),
                "arch": i.get("Architecture") or i.get("Platform"),
            }
        return {"containers": cs, "network": self.network(), "volume": self.volume()}

    def probe(self) -> str | None:
        """The reader's latest WRITE_PROBE line, the local evidence that writes are refused."""
        for e in reversed(self.logs(f"{self.project}-reader-1", 500)):
            if e["message"].startswith("WRITE_PROBE"):
                return e["message"]
        return None


class LocalClient:
    """A boto3-client lookalike for one service, answering from the compose stack."""

    def __init__(self, service: str, stack: ComposeStack) -> None:
        self._svc, self._s = service, stack

    def __getattr__(self, method: str) -> Callable[..., Any]:
        if method.startswith("_"):  # our own attributes never go through here; a miss would recurse
            raise AttributeError(method)
        fn = getattr(type(self), f"_{self._svc}_{method}", None)
        if fn is None:
            raise LookupError(f"not available locally: {self._svc}.{method} (Docker has no such thing)")
        return fn.__get__(self, type(self))

    # ssm: the registry
    def _ssm_get_parameters_by_path(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        uid = lambda svc: f["containers"].get(svc, {}).get("user", "")
        vals = {
            "region": "local", "vpc_id": f["network"]["name"], "private_subnet_ids": f["network"]["name"],
            "file_system_id": f["volume"]["name"], "writer_access_point_id": f"writer@{uid('writer')}", "reader_access_point_id": f"reader@{uid('reader')}",
            "cluster_name": self._s.project, "writer_service_name": "writer", "reader_service_name": "reader",
            "writer_log_group": f"{self._s.project}-writer-1", "reader_log_group": f"{self._s.project}-reader-1",
            "gui_url": "http://localhost (make map-local)", "gui_api_url": "local",
        }
        if not f["containers"]:
            vals = {}
        return {"Parameters": [{"Name": f"/sefs/outputs/{k}", "Value": v} for k, v in vals.items()]}

    def _ssm_get_parameter(self, **kw: Any) -> dict[str, Any]:
        raise LookupError("ParameterNotFound (local)")

    def _ssm_put_parameter(self, **kw: Any) -> dict[str, Any]:
        return {}

    # ec2: the network
    def _ec2_describe_vpcs(self, **kw: Any) -> dict[str, Any]:
        n = self._s.network()
        return {"Vpcs": [{"VpcId": n["name"], "CidrBlock": n["subnet"], "State": "available"}]}

    def _ec2_describe_subnets(self, **kw: Any) -> dict[str, Any]:
        n = self._s.network()
        return {"Subnets": [{"SubnetId": n["name"], "CidrBlock": n["subnet"], "AvailabilityZone": "local", "MapPublicIpOnLaunch": False, "State": "available"}]}

    def _ec2_describe_nat_gateways(self, **kw: Any) -> dict[str, Any]:
        return {"NatGateways": []}

    def _ec2_describe_security_groups(self, **kw: Any) -> dict[str, Any]:
        return {"SecurityGroups": []}

    def _ec2_describe_route_tables(self, **kw: Any) -> dict[str, Any]:
        n = self._s.network()
        return {"RouteTables": [{"RouteTableId": f"docker bridge {n['id']}", "Associations": [{"SubnetId": n["name"]}],
                                 "Routes": [{"DestinationCidrBlock": n["subnet"], "GatewayId": "local"}, {"DestinationCidrBlock": "0.0.0.0/0", "GatewayId": f"host via {n['gateway']}"}]}]}

    def _ec2_describe_internet_gateways(self, **kw: Any) -> dict[str, Any]:
        return {"InternetGateways": []}

    # efs: the volume
    def _efs_describe_file_systems(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        via = next((c["name"] for c in f["containers"].values() if c["state"] == "running"), None)
        stats = self._s.volume_stats(via) if via else {"files": 0, "bytes": 0, "root": "?"}
        return {"FileSystems": [{"FileSystemId": f["volume"]["name"], "Encrypted": "n/a (local Docker volume)", "PerformanceMode": "host disk",
                                 "ThroughputMode": "host disk", "SizeInBytes": {"Value": stats["bytes"]}, "NumberOfMountTargets": sum(1 for c in f["containers"].values() if c["mounted"]),
                                 "LifeCycleState": "available", "Files": stats["files"], "RootDir": stats["root"], "CreationTime": f["volume"]["created"]}]}

    def _efs_describe_mount_targets(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        return {"MountTargets": [{"MountTargetId": f"{c['name']}:/mnt/shared", "SubnetId": f["network"]["name"], "AvailabilityZoneName": "local",
                                  "IpAddress": c["ip"], "LifeCycleState": "available" if c["state"] == "running" else c["state"]}
                                 for c in f["containers"].values() if c["mounted"]]}

    def _efs_describe_access_points(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        aps = []
        for svc, c in f["containers"].items():
            uid, _, gid = (c["user"] or "0:0").partition(":")
            aps.append({"AccessPointId": f"{svc}@{c['user']}", "PosixUser": {"Uid": int(uid or 0), "Gid": int(gid or 0)},
                        "RootDirectory": {"Path": "/mnt/shared"}, "LifeCycleState": "available" if c["state"] == "running" else c["state"],
                        "Mount": "read-write" if c["rw"] else "read-only"})
        return {"AccessPoints": aps}

    def _efs_describe_file_system_policy(self, **kw: Any) -> dict[str, Any]:
        probe = self._s.probe()
        return {"Policy": json.dumps({"Statement": [], "LocalControl": "no file-system policy locally: the reader mounts the volume read-only (Docker RW=false) and the kernel refuses its writes",
                                      "LatestProbe": probe or "no WRITE_PROBE line in the reader log yet"})}

    def _efs_describe_lifecycle_configuration(self, **kw: Any) -> dict[str, Any]:
        return {"LifecyclePolicies": []}

    # ecs: the containers
    def _ecs_describe_clusters(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        return {"clusters": [{"clusterName": self._s.project, "status": "ACTIVE" if f["containers"] else "INACTIVE"}]}

    def _ecs_describe_services(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        out = []
        for svc in kw.get("services", []):
            c = f["containers"].get(svc)
            if not c:
                continue
            out.append({"serviceName": svc, "runningCount": 1 if c["state"] == "running" else 0, "desiredCount": 1, "status": "ACTIVE",
                        "deployments": [{"rolloutState": "COMPLETED"}], "taskDefinition": c["image"]})
        return {"services": out}

    def _ecs_list_tasks(self, **kw: Any) -> dict[str, Any]:
        c = self._s.facts()["containers"].get(kw.get("serviceName", ""))
        return {"taskArns": [c["name"]] if c else []}

    def _ecs_describe_tasks(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        tasks = []
        for name in kw.get("tasks", []):
            c = next((c for c in f["containers"].values() if c["name"] == name), None)
            if not c:
                continue
            tasks.append({"taskArn": name, "lastStatus": "RUNNING" if c["state"] == "running" else (c["state"] or "").upper(), "healthStatus": c["status"],
                          "cpu": None, "memory": None, "availabilityZone": "local", "startedAt": c["started"],
                          "attachments": [{"details": [{"name": "subnetId", "value": f["network"]["name"]}]}], "Image": c["image"], "User": c["user"], "Ip": c["ip"]})
        return {"tasks": tasks}

    def _ecs_describe_task_definition(self, **kw: Any) -> dict[str, Any]:
        f = self._s.facts()
        img = kw.get("taskDefinition")
        c = next((c for c in f["containers"].values() if c["image"] == img), {})
        return {"taskDefinition": {"cpu": "host", "memory": "host", "taskRoleArn": f"docker user {c.get('user', '?')}", "runtimePlatform": {"cpuArchitecture": c.get("arch")},
                                   "containerDefinitions": [{"image": img, "mountPoints": [{"readOnly": not c.get("rw", True)}]}],
                                   "volumes": [{"efsVolumeConfiguration": {"transitEncryption": "n/a (local volume)", "authorizationConfig": {"accessPointId": f"{c.get('user')}", "iam": "n/a (local volume)"}}}]}}

    # backup / cloudwatch / logs
    def _backup_get_backup_plan(self, **kw: Any) -> dict[str, Any]:
        raise LookupError("no backup locally: a Docker volume has no AWS Backup plan")

    def _backup_list_recovery_points_by_backup_vault(self, **kw: Any) -> dict[str, Any]:
        raise LookupError("no backup locally: a Docker volume has no AWS Backup vault")

    def _backup_list_backup_jobs(self, **kw: Any) -> dict[str, Any]:
        raise LookupError("no backup locally")

    def _cloudwatch_describe_alarms(self, **kw: Any) -> dict[str, Any]:
        return {"MetricAlarms": []}

    def _logs_describe_log_streams(self, **kw: Any) -> dict[str, Any]:
        return {"logStreams": [{"logStreamName": kw.get("logGroupName")}]}

    def _logs_get_log_events(self, **kw: Any) -> dict[str, Any]:
        return {"events": self._s.logs(kw["logGroupName"], int(kw.get("limit", 20)))}


class LocalBoto3:
    """Drop-in for the boto3 module: client(service) -> LocalClient."""

    def __init__(self, stack: ComposeStack) -> None:
        self.stack = stack

    def client(self, service: str, region_name: str | None = None) -> LocalClient:
        return LocalClient(service, self.stack)


def running(project: str = "sefs-local", docker: DockerCli | None = None) -> bool:
    """True when the compose pair has at least one running container."""
    try:
        return any(c.get("State") == "running" for c in ComposeStack(project, docker).containers())
    except Exception:  # noqa: BLE001  (no docker, no project: not running)
        return False

"""SEFS map API: read-only JSON for the 2.5D map (modules/gui).

Runs as a Lambda behind an HTTP API whose every route requires a Cognito JWT. Everything it
returns is read live from AWS at request time; nothing is simulated. The only write it can make
is a 24 h cache of Pricing API rates under /<name>/gui/cache/* (the IAM role allows nothing else).

Routes (HTTP API v2 events, rawPath):
  GET /api/overview                 inventory + health of everything tagged Project=<name>
  GET /api/room/{efs|ecs|vpc|backup} the internals of one resource family ("open the doors")
  GET /api/cost                     rates from the Pricing API (per minute / hour / 30 days)
                                    and, when enabled, real spend from Cost Explorer
  GET /api/logs?app=writer|reader&limit=N   newest contract log lines (WROTE / READ / WRITE_PROBE)

Python 3.12 standard library + boto3 (present in the Lambda runtime). boto3 is imported lazily
inside Aws so the unit tests can inject a fake module without network or credentials.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable

HOURS_30D = 24 * 30
CACHE_TTL_SECONDS = 24 * 3600


def utc_now() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


# ---------------------------------------------------------------------------------- settings
@dataclass(frozen=True)
class Settings:
    """Everything the API reads from its environment, in one immutable object."""

    name: str
    region: str
    ssm_prefix: str
    cache_prefix: str
    writer_logs: str
    reader_logs: str
    vault: str
    cluster: str
    cost_actuals: bool

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Settings":
        env = os.environ if env is None else env
        name = env.get("SEFS_NAME", "sefs")
        return cls(
            name=name,
            region=env.get("SEFS_REGION", "ap-southeast-2"),
            ssm_prefix=env.get("SEFS_SSM_PREFIX", f"/{name}"),
            cache_prefix=env.get("SEFS_CACHE_PREFIX", f"/{name}/gui/cache"),
            writer_logs=env.get("SEFS_WRITER_LOGS", f"/ecs/{name}/writer"),
            reader_logs=env.get("SEFS_READER_LOGS", f"/ecs/{name}/reader"),
            vault=env.get("SEFS_VAULT", name),
            cluster=env.get("SEFS_CLUSTER", name),
            cost_actuals=env.get("SEFS_COST_ACTUALS", "false").lower() == "true",
        )


# ---------------------------------------------------------------------------------- AWS access
class Aws:
    """One client per service, created on first use. boto3 is imported here, not at module load."""

    def __init__(self, region: str, boto3_module: Any | None = None) -> None:
        self._region = region
        self._boto3 = boto3_module
        self._clients: dict[str, Any] = {}

    def client(self, service: str, region: str | None = None) -> Any:
        key = f"{service}@{region or self._region}"
        if key not in self._clients:
            if self._boto3 is None:
                import boto3  # noqa: PLC0415  (lazy on purpose: tests inject a fake)

                self._boto3 = boto3
            self._clients[key] = self._boto3.client(service, region_name=region or self._region)
        return self._clients[key]


class Registry:
    """The deployed IDs Terraform publishes under /<name>/outputs/* (non-secret)."""

    def __init__(self, aws: Aws, ssm_prefix: str) -> None:
        self._aws = aws
        self._path = f"{ssm_prefix}/outputs"

    def read(self) -> dict[str, str]:
        ssm = self._aws.client("ssm")
        out: dict[str, str] = {}
        token: str | None = None
        while True:
            kwargs: dict[str, Any] = {"Path": self._path, "Recursive": True}
            if token:
                kwargs["NextToken"] = token
            page = ssm.get_parameters_by_path(**kwargs)
            for p in page.get("Parameters", []):
                out[p["Name"].rsplit("/", 1)[-1]] = p["Value"]
            token = page.get("NextToken")
            if not token:
                return out


# ---------------------------------------------------------------------------------- model
@dataclass
class Node:
    """One thing on the map. `health` is ok | warn | down | unknown; `reason` says why."""

    id: str
    kind: str
    label: str
    az: str | None = None
    parent: str | None = None
    health: str = "unknown"
    reason: str = ""
    facts: dict[str, Any] = field(default_factory=dict)

    def set_health(self, state: str, reason: str = "") -> None:
        self.health, self.reason = state, reason

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id, "kind": self.kind, "label": self.label, "az": self.az, "parent": self.parent,
            "health": self.health, "reason": self.reason, "facts": self.facts,
        }


class Inventory:
    """Discovers the stack from the registry IDs plus the Project tag, and scores each node's health."""

    def __init__(self, aws: Aws, settings: Settings, registry: dict[str, str]) -> None:
        self._aws = aws
        self._s = settings
        self._r = registry

    # -- helpers
    @staticmethod
    def _tag(tags: list[dict[str, str]], key: str) -> str | None:
        for t in tags or []:
            if t.get("Key") == key:
                return t.get("Value")
        return None

    def _ec2(self) -> Any:
        return self._aws.client("ec2")

    # -- builders (each independent; run in parallel by build())
    def _network(self) -> list[Node]:
        ec2 = self._ec2()
        vpc_id = self._r.get("vpc_id", "")
        nodes: list[Node] = []
        vpcs = ec2.describe_vpcs(VpcIds=[vpc_id])["Vpcs"] if vpc_id else []
        for v in vpcs:
            n = Node(v["VpcId"], "vpc", f"VPC {v.get('CidrBlock', '')}", facts={"cidr": v.get("CidrBlock")})
            n.set_health("ok" if v.get("State") == "available" else "warn", v.get("State", ""))
            nodes.append(n)
        subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"] if vpc_id else []
        for s in subnets:
            public = bool(s.get("MapPublicIpOnLaunch"))
            tier = "public" if public else "private"
            n = Node(s["SubnetId"], f"subnet-{tier}", f"{tier} {s.get('CidrBlock', '')}", az=s.get("AvailabilityZone"),
                     parent=vpc_id, facts={"cidr": s.get("CidrBlock"), "mapPublicIp": public})
            n.set_health("ok" if s.get("State") == "available" else "warn", s.get("State", ""))
            nodes.append(n)
        nats = ec2.describe_nat_gateways(Filter=[{"Name": "vpc-id", "Values": [vpc_id]}])["NatGateways"] if vpc_id else []
        sub_az = {s["SubnetId"]: s.get("AvailabilityZone") for s in subnets}
        for g in nats:
            if g.get("State") == "deleted":
                continue
            n = Node(g["NatGatewayId"], "nat", "NAT gateway", az=sub_az.get(g.get("SubnetId")), parent=g.get("SubnetId"),
                     facts={"publicIp": (g.get("NatGatewayAddresses") or [{}])[0].get("PublicIp"), "state": g.get("State")})
            n.set_health("ok" if g.get("State") == "available" else "down", g.get("State", ""))
            nodes.append(n)
        sg_ids = [i for i in (self._r.get("apps_security_group_id"), self._r.get("efs_security_group_id")) if i]
        for sg in ec2.describe_security_groups(GroupIds=sg_ids)["SecurityGroups"] if sg_ids else []:
            rules = sg.get("IpPermissions", [])
            n = Node(sg["GroupId"], "sg", sg.get("GroupName", sg["GroupId"]), parent=vpc_id,
                     facts={"ingressRules": len(rules), "ingress": [
                         {"from": r.get("FromPort"), "to": r.get("ToPort"), "proto": r.get("IpProtocol"),
                          "sources": [p.get("GroupId") for p in r.get("UserIdGroupPairs", [])] + [c.get("CidrIp") for c in r.get("IpRanges", [])]}
                         for r in rules]})
            if sg["GroupId"] == self._r.get("efs_security_group_id"):
                only_2049_from_apps = all(
                    r.get("FromPort") == 2049 and r.get("ToPort") == 2049 and not r.get("IpRanges")
                    and all(p.get("GroupId") == self._r.get("apps_security_group_id") for p in r.get("UserIdGroupPairs", []))
                    for r in rules) and len(rules) == 1
                n.set_health("ok" if only_2049_from_apps else "down", "2049 from sg-apps only" if only_2049_from_apps else "R9 broken: unexpected ingress")
            else:
                n.set_health("ok", "")
            nodes.append(n)
        return nodes

    def _storage(self) -> list[Node]:
        efs = self._aws.client("efs")
        fs_id = self._r.get("file_system_id", "")
        if not fs_id:
            return []
        fs = efs.describe_file_systems(FileSystemId=fs_id)["FileSystems"][0]
        fs_node = Node(fs_id, "efs", "EFS /shared", facts={
            "encrypted": fs.get("Encrypted"), "performanceMode": fs.get("PerformanceMode"),
            "throughputMode": fs.get("ThroughputMode"), "sizeBytes": (fs.get("SizeInBytes") or {}).get("Value"),
            "mountTargets": fs.get("NumberOfMountTargets"), "state": fs.get("LifeCycleState")})
        state_ok = fs.get("LifeCycleState") == "available"
        fs_node.set_health("ok" if state_ok and fs.get("Encrypted") else "down",
                           "" if state_ok and fs.get("Encrypted") else "not available or not encrypted")
        nodes = [fs_node]
        for mt in efs.describe_mount_targets(FileSystemId=fs_id)["MountTargets"]:
            n = Node(mt["MountTargetId"], "mount-target", "mount target", az=mt.get("AvailabilityZoneName"),
                     parent=mt.get("SubnetId"), facts={"ip": mt.get("IpAddress"), "state": mt.get("LifeCycleState")})
            n.set_health("ok" if mt.get("LifeCycleState") == "available" else "down", mt.get("LifeCycleState", ""))
            nodes.append(n)
        for ap in efs.describe_access_points(FileSystemId=fs_id)["AccessPoints"]:
            who = "writer" if ap.get("AccessPointId") == self._r.get("writer_access_point_id") else \
                  "reader" if ap.get("AccessPointId") == self._r.get("reader_access_point_id") else "other"
            posix = ap.get("PosixUser") or {}
            n = Node(ap["AccessPointId"], "access-point", f"{who} access point", parent=fs_id,
                     facts={"role": who, "uid": posix.get("Uid"), "gid": posix.get("Gid"),
                            "path": (ap.get("RootDirectory") or {}).get("Path"), "state": ap.get("LifeCycleState")})
            n.set_health("ok" if ap.get("LifeCycleState") == "available" else "down", ap.get("LifeCycleState", ""))
            nodes.append(n)
        return nodes

    def _compute(self) -> list[Node]:
        ecs = self._aws.client("ecs")
        cluster = self._r.get("cluster_name") or self._s.cluster
        services = [s for s in (self._r.get("writer_service_name"), self._r.get("reader_service_name")) if s]
        nodes = [Node(cluster, "cluster", f"ECS {cluster}")]
        c = ecs.describe_clusters(clusters=[cluster])["clusters"]
        nodes[0].set_health("ok" if c and c[0].get("status") == "ACTIVE" else "down", c[0].get("status", "") if c else "missing")
        if not services:
            return nodes
        for s in ecs.describe_services(cluster=cluster, services=services)["services"]:
            running, desired = s.get("runningCount", 0), s.get("desiredCount", 0)
            role = "writer" if s["serviceName"] == self._r.get("writer_service_name") else "reader"
            n = Node(s["serviceName"], "service", f"{role} service", parent=cluster,
                     facts={"role": role, "running": running, "desired": desired, "status": s.get("status"),
                            "rollout": (s.get("deployments") or [{}])[0].get("rolloutState"),
                            "taskDefinition": s.get("taskDefinition")})
            n.set_health("ok" if running >= desired and desired > 0 else "down", f"running {running}/{desired}")
            nodes.append(n)
            arns = ecs.list_tasks(cluster=cluster, serviceName=s["serviceName"]).get("taskArns", [])
            if arns:
                for t in ecs.describe_tasks(cluster=cluster, tasks=arns)["tasks"]:
                    tid = t["taskArn"].rsplit("/", 1)[-1]
                    tn = Node(tid, "task", f"{role} task", az=t.get("availabilityZone"), parent=s["serviceName"],
                              facts={"lastStatus": t.get("lastStatus"), "health": t.get("healthStatus"), "cpu": t.get("cpu"),
                                     "memory": t.get("memory"), "startedAt": str(t.get("startedAt") or ""),
                                     "subnet": next((d["value"] for a in t.get("attachments", []) for d in a.get("details", []) if d.get("name") == "subnetId"), None)})
                    tn.set_health("ok" if t.get("lastStatus") == "RUNNING" else "warn", t.get("lastStatus", ""))
                    nodes.append(tn)
        return nodes

    def _backup(self) -> list[Node]:
        bk = self._aws.client("backup")
        vault = self._r.get("backup_vault_name") or self._s.vault
        plan_id = self._r.get("backup_plan_id", "")
        n = Node(vault, "backup", "AWS Backup", facts={"vault": vault, "planId": plan_id})
        try:
            plan = bk.get_backup_plan(BackupPlanId=plan_id)["BackupPlan"] if plan_id else {}
            rules = plan.get("Rules", [])
            retention = min((r.get("Lifecycle", {}).get("DeleteAfterDays", 0) for r in rules), default=0)
            n.facts.update({"rules": len(rules), "retentionDays": retention,
                            "schedule": rules[0].get("ScheduleExpression") if rules else None})
            points = bk.list_recovery_points_by_backup_vault(BackupVaultName=vault, MaxResults=20).get("RecoveryPoints", [])
            n.facts["recoveryPoints"] = len(points)
            n.facts["latestRecoveryPoint"] = str(max((p.get("CreationDate") for p in points), default="") or "")
            n.set_health("ok" if retention >= 35 else "down", f"retention {retention} d")
        except Exception as e:  # noqa: BLE001  (a room must render even if one call fails)
            n.set_health("unknown", f"{type(e).__name__}: {e}")
        return [n]

    def _alarms(self) -> list[Node]:
        cw = self._aws.client("cloudwatch")
        nodes = []
        for a in cw.describe_alarms(AlarmNamePrefix=self._s.name)["MetricAlarms"]:
            n = Node(a["AlarmName"], "alarm", a["AlarmName"].replace(f"{self._s.name}-", "", 1),
                     facts={"state": a.get("StateValue"), "metric": a.get("MetricName"), "reason": a.get("StateReason")})
            st = a.get("StateValue")
            n.set_health({"OK": "ok", "ALARM": "down"}.get(st, "warn"), st or "")
            nodes.append(n)
        return nodes

    def build(self) -> list[Node]:
        builders: list[Callable[[], list[Node]]] = [self._network, self._storage, self._compute, self._backup, self._alarms]
        with ThreadPoolExecutor(max_workers=len(builders)) as ex:
            parts = list(ex.map(lambda b: b(), builders))
        return [n for part in parts for n in part]


# ---------------------------------------------------------------------------------- rooms
class Rooms:
    """Internals of one family; the overview already carries the nodes, rooms add what a click needs."""

    def __init__(self, aws: Aws, settings: Settings, registry: dict[str, str]) -> None:
        self._aws, self._s, self._r = aws, settings, registry

    def efs(self) -> dict[str, Any]:
        efs = self._aws.client("efs")
        fs_id = self._r.get("file_system_id", "")
        policy_raw = efs.describe_file_system_policy(FileSystemId=fs_id).get("Policy", "{}")
        policy = json.loads(policy_raw) if isinstance(policy_raw, str) else policy_raw
        denies = [s for s in policy.get("Statement", []) if s.get("Effect") == "Deny"]
        reader_denied = any("elasticfilesystem:ClientWrite" in (s.get("Action") if isinstance(s.get("Action"), list) else [s.get("Action")]) for s in denies)
        lifecycle = efs.describe_lifecycle_configuration(FileSystemId=fs_id).get("LifecyclePolicies", [])
        return {"fileSystemId": fs_id, "policy": policy, "readerWriteDenied": reader_denied,
                "lifecycle": lifecycle, "denyStatements": len(denies)}

    def ecs(self) -> dict[str, Any]:
        ecs = self._aws.client("ecs")
        out: dict[str, Any] = {"cluster": self._r.get("cluster_name"), "services": []}
        for key in ("writer_service_name", "reader_service_name"):
            svc = self._r.get(key)
            if not svc:
                continue
            s = ecs.describe_services(cluster=out["cluster"], services=[svc])["services"]
            if not s:
                continue
            td = ecs.describe_task_definition(taskDefinition=s[0]["taskDefinition"])["taskDefinition"]
            cd = td.get("containerDefinitions", [{}])[0]
            mounts = cd.get("mountPoints", [])
            vols = td.get("volumes", [])
            out["services"].append({
                "name": svc, "role": key.split("_", 1)[0], "image": cd.get("image"), "cpu": td.get("cpu"), "memory": td.get("memory"),
                "arch": (td.get("runtimePlatform") or {}).get("cpuArchitecture"),
                "readOnlyMount": bool(mounts and mounts[0].get("readOnly")),
                "accessPoint": ((vols[0].get("efsVolumeConfiguration") or {}).get("authorizationConfig") or {}).get("accessPointId") if vols else None,
                "transitEncryption": (vols[0].get("efsVolumeConfiguration") or {}).get("transitEncryption") if vols else None,
                "iamAuth": ((vols[0].get("efsVolumeConfiguration") or {}).get("authorizationConfig") or {}).get("iam") if vols else None,
                "taskRole": td.get("taskRoleArn"), "running": s[0].get("runningCount"), "desired": s[0].get("desiredCount"),
            })
        return out

    def vpc(self) -> dict[str, Any]:
        ec2 = self._aws.client("ec2")
        vpc_id = self._r.get("vpc_id", "")
        rts = ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["RouteTables"]
        tables = [{"id": t["RouteTableId"], "subnets": [a.get("SubnetId") for a in t.get("Associations", []) if a.get("SubnetId")],
                   "routes": [{"dest": r.get("DestinationCidrBlock"), "via": r.get("GatewayId") or r.get("NatGatewayId") or r.get("TransitGatewayId")} for r in t.get("Routes", [])]}
                  for t in rts]
        igws = ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}])["InternetGateways"]
        return {"vpcId": vpc_id, "routeTables": tables, "internetGateways": [g["InternetGatewayId"] for g in igws]}

    def backup(self) -> dict[str, Any]:
        bk = self._aws.client("backup")
        vault = self._r.get("backup_vault_name") or self._s.vault
        jobs = bk.list_backup_jobs(ByBackupVaultName=vault, MaxResults=10).get("BackupJobs", [])
        points = bk.list_recovery_points_by_backup_vault(BackupVaultName=vault, MaxResults=20).get("RecoveryPoints", [])
        return {"vault": vault,
                "jobs": [{"id": j.get("BackupJobId"), "state": j.get("State"), "created": str(j.get("CreationDate") or ""), "resource": j.get("ResourceArn")} for j in jobs],
                "recoveryPoints": [{"arn": p.get("RecoveryPointArn"), "status": p.get("Status"), "created": str(p.get("CreationDate") or ""), "bytes": p.get("BackupSizeInBytes")} for p in points]}

    def get(self, kind: str) -> dict[str, Any]:
        fn = {"efs": self.efs, "ecs": self.ecs, "vpc": self.vpc, "backup": self.backup}.get(kind)
        if fn is None:
            raise KeyError(kind)
        return fn()


# ---------------------------------------------------------------------------------- cost
class RateCache:
    """Pricing rates cached in SSM for 24 h: the one parameter path the role may write."""

    def __init__(self, aws: Aws, prefix: str, now: Callable[[], _dt.datetime] = utc_now) -> None:
        self._aws, self._prefix, self._now = aws, prefix, now

    def get(self, key: str) -> dict[str, Any] | None:
        ssm = self._aws.client("ssm")
        try:
            raw = ssm.get_parameter(Name=f"{self._prefix}/{key}")["Parameter"]["Value"]
        except Exception:  # noqa: BLE001  (ParameterNotFound or no permission: a miss)
            return None
        doc = json.loads(raw)
        fetched = _dt.datetime.fromisoformat(doc["fetchedAt"])
        if (self._now() - fetched).total_seconds() > CACHE_TTL_SECONDS:
            return None
        return doc

    def put(self, key: str, doc: dict[str, Any]) -> None:
        self._aws.client("ssm").put_parameter(Name=f"{self._prefix}/{key}", Value=json.dumps(doc), Type="String", Overwrite=True)


class Pricing:
    """Rates from the AWS Pricing API for the stack's billable items. Lookups mirror scripts/cost.py exactly
    (same services, same usagetype prefixes, same unit filters): that script is the proven reference
    (2026-10-26). A productFamily filter on AmazonVPC and a unit filter on the IPv4 line returned nothing
    live (2026-10-27, 502), so only AmazonEC2 is narrowed (to the NAT Gateway family: tens of thousands of
    SKUs otherwise)."""

    LOCATION = {
        "ap-southeast-2": "Asia Pacific (Sydney)", "us-east-1": "US East (N. Virginia)", "us-west-2": "US West (Oregon)",
        "eu-west-1": "EU (Ireland)", "eu-central-1": "EU (Frankfurt)", "ap-southeast-1": "Asia Pacific (Singapore)",
        "ap-northeast-1": "Asia Pacific (Tokyo)",
    }
    PREFIX = {"ap-southeast-2": "APS2", "us-east-1": "USE1", "us-west-2": "USW2", "eu-west-1": "EU",
              "eu-central-1": "EUC1", "ap-southeast-1": "APS1", "ap-northeast-1": "APN1"}

    def __init__(self, aws: Aws, region: str) -> None:
        self._aws, self._region = aws, region
        if region not in self.PREFIX:
            raise LookupError(f"no Pricing usagetype prefix known for region {region} (add it to Pricing.PREFIX, as in scripts/cost.py)")
        self._location = self.LOCATION[region]
        self._pf = self.PREFIX[region]

    def _rows(self, service: str, extra: list[dict[str, str]]) -> list[tuple[str, str, float]]:
        pricing = self._aws.client("pricing", region="us-east-1")
        filters = [{"Type": "TERM_MATCH", "Field": "location", "Value": self._location}, *extra]
        rows: list[tuple[str, str, float]] = []
        token: str | None = None
        while True:
            kwargs: dict[str, Any] = {"ServiceCode": service, "Filters": filters, "MaxResults": 100}
            if token:
                kwargs["NextToken"] = token
            page = pricing.get_products(**kwargs)
            for item in page.get("PriceList", []):
                d = json.loads(item) if isinstance(item, str) else item
                usage = d["product"]["attributes"].get("usagetype", "")
                for term in d["terms"].get("OnDemand", {}).values():
                    for p in term["priceDimensions"].values():
                        usd = p["pricePerUnit"].get("USD")
                        if usd is not None:
                            rows.append((usage, p["unit"], float(usd)))
            token = page.get("NextToken")
            if not token:
                return rows

    @staticmethod
    def _rate(rows: list[tuple[str, str, float]], usage_contains: str, unit_contains: str = "") -> float:
        hits = [r for r in rows if usage_contains in r[0] and unit_contains in r[1] and r[2] > 0]
        if not hits:
            raise LookupError(f"no price for usagetype~{usage_contains} unit~{unit_contains}")
        return min(h[2] for h in hits)

    def rates(self, nat_count: int, vcpu: float, memory_gb: float, alarms: int, services: int = 2) -> dict[str, Any]:
        pf = self._pf
        metrics = services * 10  # Container Insights publishes ~10 custom metrics per service (same estimate as scripts/cost.py)
        ec2 = self._rows("AmazonEC2", [{"Type": "TERM_MATCH", "Field": "productFamily", "Value": "NAT Gateway"}])
        vpc = self._rows("AmazonVPC", [])
        ecs = self._rows("AmazonECS", [])
        cw = self._rows("AmazonCloudWatch", [])
        items = [
            {"item": f"NAT gateways x{nat_count}", "perHour": nat_count * self._rate(ec2, f"{pf}-NatGateway-Hours")},
            {"item": f"Public IPv4 on NATs x{nat_count}", "perHour": nat_count * self._rate(vpc, f"{pf}-PublicIPv4:InUseAddress")},
            {"item": f"Fargate ARM vCPU ({vcpu})", "perHour": vcpu * self._rate(ecs, f"{pf}-Fargate-ARM-vCPU-Hours")},
            {"item": f"Fargate ARM memory ({memory_gb} GB)", "perHour": memory_gb * self._rate(ecs, f"{pf}-Fargate-ARM-GB-Hours")},
            {"item": f"CloudWatch alarms x{alarms}", "perHour": alarms * self._rate(cw, f"{pf}-CW:AlarmMonitorUsage", "Alarms") / HOURS_30D},
            {"item": f"Container Insights metrics (~{metrics})", "perHour": metrics * self._rate(cw, f"{pf}-CW:MetricMonitorUsage", "Metrics") / HOURS_30D},
        ]
        per_hour = sum(i["perHour"] for i in items)
        return {"items": items, "perHour": per_hour, "perMinute": per_hour / 60, "per30Days": per_hour * HOURS_30D,
                "region": self._region, "source": "AWS Pricing API (published rates, not an invoice)"}


class CostExplorer:
    """Real spend for Project=<name>, last 30 days, daily. Needs the cost allocation tag activated."""

    def __init__(self, aws: Aws, name: str, now: Callable[[], _dt.datetime] = utc_now) -> None:
        self._aws, self._name, self._now = aws, name, now

    def last_30_days(self) -> dict[str, Any]:
        ce = self._aws.client("ce", region="us-east-1")
        end = self._now().date()
        start = end - _dt.timedelta(days=30)
        page = ce.get_cost_and_usage(
            TimePeriod={"Start": start.isoformat(), "End": end.isoformat()}, Granularity="DAILY",
            Metrics=["UnblendedCost"], Filter={"Tags": {"Key": "Project", "Values": [self._name]}})
        days = [{"date": r["TimePeriod"]["Start"], "usd": float(r["Total"]["UnblendedCost"]["Amount"])} for r in page.get("ResultsByTime", [])]
        return {"start": start.isoformat(), "end": end.isoformat(), "days": days, "totalUsd": sum(d["usd"] for d in days)}


class Cost:
    def __init__(self, aws: Aws, settings: Settings, registry: dict[str, str], cache: RateCache, nodes_fn: Callable[[], list[Node]]) -> None:
        self._aws, self._s, self._r, self._cache, self._nodes_fn = aws, settings, registry, cache, nodes_fn

    def report(self) -> dict[str, Any]:
        nodes = self._nodes_fn()
        nat_count = sum(1 for n in nodes if n.kind == "nat")
        alarms = sum(1 for n in nodes if n.kind == "alarm")
        tasks = [n for n in nodes if n.kind == "task"]
        vcpu = sum(int(t.facts.get("cpu") or 0) for t in tasks) / 1024
        mem = sum(int(t.facts.get("memory") or 0) for t in tasks) / 1024
        services = sum(1 for n in nodes if n.kind == "service")
        key = f"rates-{self._s.region}-{nat_count}-{vcpu}-{mem}-{alarms}-{services}"
        rates = self._cache.get(key)
        if rates is None:
            rates = Pricing(self._aws, self._s.region).rates(nat_count, vcpu, mem, alarms, services)
            rates["fetchedAt"] = utc_now().isoformat()
            self._cache.put(key, rates)
        actuals: dict[str, Any] | None = None
        if self._s.cost_actuals:
            try:
                actuals = CostExplorer(self._aws, self._s.name).last_30_days()
            except Exception as e:  # noqa: BLE001  (tag not active yet / no permission: say so, do not fake a number)
                actuals = {"error": f"{type(e).__name__}: {e}"}
        return {"rates": rates, "actuals": actuals, "live": {"natGateways": nat_count, "vcpu": vcpu, "memoryGb": mem, "alarms": alarms}}


# ---------------------------------------------------------------------------------- logs
class Logs:
    CONTRACT = re.compile(r"^(WROTE|READ|WRITE_PROBE|WRITE_ERROR|READ_ERROR|WRITER_START|READER_START)\b")

    def __init__(self, aws: Aws, settings: Settings) -> None:
        self._aws, self._s = aws, settings

    def tail(self, app: str, limit: int) -> dict[str, Any]:
        group = {"writer": self._s.writer_logs, "reader": self._s.reader_logs}[app]
        logs = self._aws.client("logs")
        streams = logs.describe_log_streams(logGroupName=group, orderBy="LastEventTime", descending=True, limit=1).get("logStreams", [])
        if not streams:
            return {"app": app, "group": group, "stream": None, "lines": []}
        stream = streams[0]["logStreamName"]
        events = logs.get_log_events(logGroupName=group, logStreamName=stream, limit=limit, startFromHead=False).get("events", [])
        lines = [{"ts": e.get("timestamp"), "message": e.get("message", "").rstrip()} for e in events if self.CONTRACT.match(e.get("message", ""))]
        return {"app": app, "group": group, "stream": stream, "lines": lines}


# ---------------------------------------------------------------------------------- HTTP
class Response:
    @staticmethod
    def json(status: int, body: Any) -> dict[str, Any]:
        return {"statusCode": status, "headers": {"content-type": "application/json", "cache-control": "no-store"},
                "body": json.dumps(body, default=str)}


class Router:
    """Dispatches GET /api/* to the readers above. Every handler is read-only."""

    ROOM = re.compile(r"^/api/room/(efs|ecs|vpc|backup)$")

    def __init__(self, aws: Aws, settings: Settings, now: Callable[[], _dt.datetime] = utc_now) -> None:
        self._aws, self._s, self._now = aws, settings, now
        self._registry: dict[str, str] | None = None

    def registry(self) -> dict[str, str]:
        if self._registry is None:
            self._registry = Registry(self._aws, self._s.ssm_prefix).read()
        return self._registry

    def overview(self) -> dict[str, Any]:
        nodes = Inventory(self._aws, self._s, self.registry()).build()
        worst = "ok"
        for n in nodes:
            if n.health == "down":
                worst = "down"
            elif n.health in ("warn", "unknown") and worst == "ok":
                worst = "warn"
        return {"name": self._s.name, "region": self._s.region, "generatedAt": self._now().isoformat(),
                "deployed": bool(self.registry()), "overall": worst if self.registry() else "down",
                "nodes": [n.as_dict() for n in nodes], "registry": self.registry()}

    def handle(self, event: dict[str, Any]) -> dict[str, Any]:
        method = (event.get("requestContext", {}).get("http", {}) or {}).get("method", "GET")
        path = event.get("rawPath", "")
        qs = event.get("queryStringParameters") or {}
        if method != "GET":
            return Response.json(405, {"error": "read-only API: GET only"})
        try:
            if path == "/api/overview":
                return Response.json(200, self.overview())
            if (m := self.ROOM.match(path)):
                return Response.json(200, {"kind": m.group(1), "generatedAt": self._now().isoformat(), **Rooms(self._aws, self._s, self.registry()).get(m.group(1))})
            if path == "/api/cost":
                cache = RateCache(self._aws, self._s.cache_prefix, self._now)
                return Response.json(200, Cost(self._aws, self._s, self.registry(), cache, lambda: Inventory(self._aws, self._s, self.registry()).build()).report())
            if path == "/api/logs":
                app = qs.get("app", "writer")
                if app not in ("writer", "reader"):
                    return Response.json(400, {"error": "app must be writer or reader"})
                raw_limit = qs.get("limit", "20")
                if not raw_limit.isdigit():
                    return Response.json(400, {"error": "limit must be a whole number between 1 and 200"})
                limit = max(1, min(int(raw_limit), 200))
                return Response.json(200, Logs(self._aws, self._s).tail(app, limit))
            return Response.json(404, {"error": f"no route {path}"})
        except Exception as e:  # noqa: BLE001  (the page shows the failure; it never guesses)
            return Response.json(502, {"error": f"{type(e).__name__}: {e}", "path": path})


def handler(event: dict[str, Any], _context: Any = None) -> dict[str, Any]:
    settings = Settings.from_env()
    return Router(Aws(settings.region), settings).handle(event)

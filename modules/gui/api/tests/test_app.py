"""Offline proof of the map API. A fake boto3 is injected (no network, no credentials):
every call is recorded, canned responses are served, and any call that is not a read (or the
one allowed cache write) fails the test. Run: python3 -m unittest discover -s modules/gui/api/tests
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import unittest
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import app  # noqa: E402

READ_PREFIXES = ("describe_", "list_", "get_")
ALLOWED_WRITES = {"put_parameter"}


class FakeClient:
    def __init__(self, service: str, responses: dict[str, Any], calls: list[tuple[str, str, dict[str, Any]]]) -> None:
        self._service, self._responses, self._calls = service, responses, calls

    def __getattr__(self, method: str) -> Any:
        if not method.startswith(READ_PREFIXES) and method not in ALLOWED_WRITES:
            raise AssertionError(f"non-read call attempted: {self._service}.{method}")

        def call(**kwargs: Any) -> Any:
            self._calls.append((self._service, method, kwargs))
            if method == "put_parameter":
                assert kwargs["Name"].startswith("/sefs/gui/cache/"), f"write outside the cache prefix: {kwargs['Name']}"
                self._responses.setdefault("_cache", {})[kwargs["Name"]] = kwargs["Value"]
                return {}
            if method == "get_parameter":
                store = self._responses.get("_cache", {})
                if kwargs["Name"] in store:
                    return {"Parameter": {"Value": store[kwargs["Name"]]}}
                raise RuntimeError("ParameterNotFound")
            resp = self._responses.get(f"{self._service}.{method}")
            if callable(resp):
                return resp(kwargs)
            if resp is None:
                raise RuntimeError(f"no canned response for {self._service}.{method}")
            return resp

        return call


class FakeBoto3:
    def __init__(self, responses: dict[str, Any]) -> None:
        self.responses, self.calls = responses, []

    def client(self, service: str, region_name: str | None = None) -> FakeClient:
        self.calls.append((service, "__client__", {"region_name": region_name}))
        return FakeClient(service, self.responses, self.calls)


REG = {"region": "ap-southeast-2", "vpc_id": "vpc-1", "apps_security_group_id": "sg-apps", "efs_security_group_id": "sg-efs",
       "file_system_id": "fs-1", "writer_access_point_id": "fsap-w", "reader_access_point_id": "fsap-r",
       "backup_vault_name": "sefs", "backup_plan_id": "plan-1", "cluster_name": "sefs",
       "writer_service_name": "sefs-writer", "reader_service_name": "sefs-reader",
       "writer_log_group": "/ecs/sefs/writer", "reader_log_group": "/ecs/sefs/reader"}


def price(usage: str, unit: str, usd: str) -> str:
    return json.dumps({"product": {"attributes": {"usagetype": usage}},
                       "terms": {"OnDemand": {"x": {"priceDimensions": {"y": {"unit": unit, "pricePerUnit": {"USD": usd}}}}}}})


def canned(efs_ingress_ok: bool = True, reader_running: int = 1) -> dict[str, Any]:
    efs_rules = [{"FromPort": 2049, "ToPort": 2049, "IpProtocol": "tcp", "UserIdGroupPairs": [{"GroupId": "sg-apps"}], "IpRanges": []}]
    if not efs_ingress_ok:
        efs_rules.append({"FromPort": 22, "ToPort": 22, "IpProtocol": "tcp", "UserIdGroupPairs": [], "IpRanges": [{"CidrIp": "0.0.0.0/0"}]})
    return {
        "ssm.get_parameters_by_path": {"Parameters": [{"Name": f"/sefs/outputs/{k}", "Value": v} for k, v in REG.items()]},
        "ec2.describe_vpcs": {"Vpcs": [{"VpcId": "vpc-1", "CidrBlock": "10.40.0.0/16", "State": "available"}]},
        "ec2.describe_subnets": {"Subnets": [
            {"SubnetId": "sub-pub-a", "CidrBlock": "10.40.0.0/24", "AvailabilityZone": "ap-southeast-2a", "MapPublicIpOnLaunch": True, "State": "available"},
            {"SubnetId": "sub-pub-b", "CidrBlock": "10.40.1.0/24", "AvailabilityZone": "ap-southeast-2b", "MapPublicIpOnLaunch": True, "State": "available"},
            {"SubnetId": "sub-pri-a", "CidrBlock": "10.40.10.0/24", "AvailabilityZone": "ap-southeast-2a", "MapPublicIpOnLaunch": False, "State": "available"},
            {"SubnetId": "sub-pri-b", "CidrBlock": "10.40.11.0/24", "AvailabilityZone": "ap-southeast-2b", "MapPublicIpOnLaunch": False, "State": "available"}]},
        "ec2.describe_nat_gateways": {"NatGateways": [
            {"NatGatewayId": "nat-a", "SubnetId": "sub-pub-a", "State": "available", "NatGatewayAddresses": [{"PublicIp": "1.1.1.1"}]},
            {"NatGatewayId": "nat-b", "SubnetId": "sub-pub-b", "State": "available", "NatGatewayAddresses": [{"PublicIp": "2.2.2.2"}]},
            {"NatGatewayId": "nat-old", "SubnetId": "sub-pub-b", "State": "deleted"}]},
        "ec2.describe_security_groups": {"SecurityGroups": [
            {"GroupId": "sg-apps", "GroupName": "sefs-apps", "IpPermissions": []},
            {"GroupId": "sg-efs", "GroupName": "sefs-efs", "IpPermissions": efs_rules}]},
        "efs.describe_file_systems": {"FileSystems": [{"FileSystemId": "fs-1", "Encrypted": True, "PerformanceMode": "generalPurpose",
                                                       "ThroughputMode": "bursting", "SizeInBytes": {"Value": 6144}, "NumberOfMountTargets": 2, "LifeCycleState": "available"}]},
        "efs.describe_mount_targets": {"MountTargets": [
            {"MountTargetId": "fsmt-a", "SubnetId": "sub-pri-a", "AvailabilityZoneName": "ap-southeast-2a", "IpAddress": "10.40.10.5", "LifeCycleState": "available"},
            {"MountTargetId": "fsmt-b", "SubnetId": "sub-pri-b", "AvailabilityZoneName": "ap-southeast-2b", "IpAddress": "10.40.11.5", "LifeCycleState": "available"}]},
        "efs.describe_access_points": {"AccessPoints": [
            {"AccessPointId": "fsap-w", "PosixUser": {"Uid": 1001, "Gid": 1000}, "RootDirectory": {"Path": "/shared"}, "LifeCycleState": "available"},
            {"AccessPointId": "fsap-r", "PosixUser": {"Uid": 1002, "Gid": 1000}, "RootDirectory": {"Path": "/shared"}, "LifeCycleState": "available"}]},
        "efs.describe_file_system_policy": {"Policy": json.dumps({"Statement": [
            {"Effect": "Allow", "Action": ["elasticfilesystem:ClientMount"]},
            {"Effect": "Deny", "Action": ["elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"], "Principal": {"AWS": "arn:aws:iam::1:role/reader"}}]})},
        "efs.describe_lifecycle_configuration": {"LifecyclePolicies": [{"TransitionToIA": "AFTER_30_DAYS"}]},
        "ecs.describe_clusters": {"clusters": [{"clusterName": "sefs", "status": "ACTIVE"}]},
        "ecs.describe_services": lambda kw: {"services": [
            s for s in [
                {"serviceName": "sefs-writer", "runningCount": 1, "desiredCount": 1, "status": "ACTIVE", "deployments": [{"rolloutState": "COMPLETED"}], "taskDefinition": "td-w"},
                {"serviceName": "sefs-reader", "runningCount": reader_running, "desiredCount": 1, "status": "ACTIVE", "deployments": [{"rolloutState": "COMPLETED"}], "taskDefinition": "td-r"}]
            if s["serviceName"] in kw["services"]]},
        "ecs.list_tasks": lambda kw: {"taskArns": [f"arn:aws:ecs:x:1:task/sefs/{kw['serviceName']}-task"]},
        "ecs.describe_tasks": lambda kw: {"tasks": [{"taskArn": kw["tasks"][0], "lastStatus": "RUNNING", "healthStatus": "UNKNOWN", "cpu": "256" if "writer" in kw["tasks"][0] else "512",
                                                     "memory": "512" if "writer" in kw["tasks"][0] else "1024", "availabilityZone": "ap-southeast-2a", "startedAt": dt.datetime(2026, 10, 27, tzinfo=dt.timezone.utc),
                                                     "attachments": [{"details": [{"name": "subnetId", "value": "sub-pri-a"}]}]}]},
        "ecs.describe_task_definition": lambda kw: {"taskDefinition": {"cpu": "256", "memory": "512", "taskRoleArn": "arn:role", "runtimePlatform": {"cpuArchitecture": "ARM64"},
                                                                        "containerDefinitions": [{"image": "img", "mountPoints": [{"readOnly": kw["taskDefinition"] == "td-r"}]}],
                                                                        "volumes": [{"efsVolumeConfiguration": {"transitEncryption": "ENABLED", "authorizationConfig": {"accessPointId": "fsap-x", "iam": "ENABLED"}}}]}},
        "backup.get_backup_plan": {"BackupPlan": {"Rules": [{"ScheduleExpression": "cron(0 5 * * ? *)", "Lifecycle": {"DeleteAfterDays": 35}}]}},
        "backup.list_recovery_points_by_backup_vault": {"RecoveryPoints": [{"RecoveryPointArn": "rp-1", "Status": "COMPLETED", "CreationDate": dt.datetime(2026, 10, 26, tzinfo=dt.timezone.utc), "BackupSizeInBytes": 10}]},
        "backup.list_backup_jobs": {"BackupJobs": [{"BackupJobId": "j1", "State": "COMPLETED", "CreationDate": "2026-10-26", "ResourceArn": "arn:efs"}]},
        "cloudwatch.describe_alarms": {"MetricAlarms": [
            {"AlarmName": "sefs-writer-down", "StateValue": "OK", "MetricName": "RunningTaskCount", "StateReason": "fine"},
            {"AlarmName": "sefs-reader-write-allowed", "StateValue": "INSUFFICIENT_DATA", "MetricName": "WriteProbeAllowed", "StateReason": "no data"}]},
        "ec2.describe_route_tables": {"RouteTables": [{"RouteTableId": "rtb-1", "Associations": [{"SubnetId": "sub-pri-a"}], "Routes": [{"DestinationCidrBlock": "0.0.0.0/0", "NatGatewayId": "nat-a"}]}]},
        "ec2.describe_internet_gateways": {"InternetGateways": [{"InternetGatewayId": "igw-1"}]},
        "pricing.get_products": lambda kw: {"PriceList": {
            "AmazonEC2": [price("APS2-NatGateway-Hours", "Hrs", "0.059")],
            "AmazonVPC": [price("APS2-PublicIPv4:InUseAddress", "Hrs", "0.005")],
            "AmazonECS": [price("APS2-Fargate-ARM-vCPU-Hours:perCPU", "hours", "0.03885"), price("APS2-Fargate-ARM-GB-Hours", "hours", "0.00426")],
            "AmazonCloudWatch": [price("APS2-AlarmMonitorUsage", "Alarms", "0.10")]}[kw["ServiceCode"]]},
        "ce.get_cost_and_usage": {"ResultsByTime": [{"TimePeriod": {"Start": "2026-10-25"}, "Total": {"UnblendedCost": {"Amount": "2.2"}}},
                                                    {"TimePeriod": {"Start": "2026-10-26"}, "Total": {"UnblendedCost": {"Amount": "0.3"}}}]},
        "logs.describe_log_streams": {"logStreams": [{"logStreamName": "s1"}]},
        "logs.get_log_events": {"events": [{"timestamp": 1, "message": "WROTE a.json sha256=ab"}, {"timestamp": 2, "message": "INFO noise"}, {"timestamp": 3, "message": "WRITE_PROBE DENIED EROFS"}]},
    }


def make_router(responses: dict[str, Any], env: dict[str, str] | None = None) -> tuple[app.Router, FakeBoto3]:
    fake = FakeBoto3(responses)
    settings = app.Settings.from_env({"SEFS_NAME": "sefs", "SEFS_REGION": "ap-southeast-2", "SEFS_COST_ACTUALS": "true", **(env or {})})
    router = app.Router(app.Aws(settings.region, boto3_module=fake), settings, now=lambda: dt.datetime(2026, 10, 27, 12, 0, tzinfo=dt.timezone.utc))
    return router, fake


def get(router: app.Router, path: str, qs: dict[str, str] | None = None, method: str = "GET") -> tuple[int, dict[str, Any]]:
    r = router.handle({"rawPath": path, "queryStringParameters": qs, "requestContext": {"http": {"method": method}}})
    return r["statusCode"], json.loads(r["body"])


class OverviewTest(unittest.TestCase):
    def test_a01_overview_discovers_every_family_and_scores_health(self) -> None:
        router, _ = make_router(canned())
        status, body = get(router, "/api/overview")
        self.assertEqual(status, 200)
        kinds = {n["kind"] for n in body["nodes"]}
        self.assertTrue({"vpc", "subnet-public", "subnet-private", "nat", "sg", "efs", "mount-target", "access-point", "cluster", "service", "task", "backup", "alarm"} <= kinds, kinds)
        self.assertEqual(body["overall"], "warn", "INSUFFICIENT_DATA alarm must surface as warn, not ok")
        self.assertEqual(sum(1 for n in body["nodes"] if n["kind"] == "nat"), 2, "a deleted NAT is not on the map")
        self.assertTrue(body["deployed"])

    def test_a02_efs_security_group_health_is_the_r9_rule(self) -> None:
        router, _ = make_router(canned(efs_ingress_ok=False))
        _, body = get(router, "/api/overview")
        sg = next(n for n in body["nodes"] if n["id"] == "sg-efs")
        self.assertEqual(sg["health"], "down")
        self.assertIn("R9", sg["reason"])
        self.assertEqual(body["overall"], "down")

    def test_a03_service_below_desired_is_down(self) -> None:
        router, _ = make_router(canned(reader_running=0))
        _, body = get(router, "/api/overview")
        reader = next(n for n in body["nodes"] if n["id"] == "sefs-reader")
        self.assertEqual(reader["health"], "down")
        self.assertEqual(reader["reason"], "running 0/1")

    def test_a04_nothing_deployed_is_reported_not_guessed(self) -> None:
        router, _ = make_router({"ssm.get_parameters_by_path": {"Parameters": []}, "ecs.describe_clusters": {"clusters": []},
                                 "cloudwatch.describe_alarms": {"MetricAlarms": []}, "backup.get_backup_plan": {"BackupPlan": {}},
                                 "backup.list_recovery_points_by_backup_vault": {"RecoveryPoints": []}})
        _, body = get(router, "/api/overview")
        self.assertFalse(body["deployed"])
        self.assertEqual(body["overall"], "down")


class RoomTest(unittest.TestCase):
    def test_b01_efs_room_proves_the_reader_deny(self) -> None:
        router, _ = make_router(canned())
        status, body = get(router, "/api/room/efs")
        self.assertEqual(status, 200)
        self.assertTrue(body["readerWriteDenied"])
        self.assertEqual(body["lifecycle"][0]["TransitionToIA"], "AFTER_30_DAYS")

    def test_b02_ecs_room_shows_mount_flags_per_service(self) -> None:
        router, _ = make_router(canned())
        _, body = get(router, "/api/room/ecs")
        by = {s["role"]: s for s in body["services"]}
        self.assertFalse(by["writer"]["readOnlyMount"])
        self.assertTrue(by["reader"]["readOnlyMount"])
        self.assertEqual(by["reader"]["transitEncryption"], "ENABLED")

    def test_b03_vpc_and_backup_rooms(self) -> None:
        router, _ = make_router(canned())
        _, vpc = get(router, "/api/room/vpc")
        self.assertEqual(vpc["routeTables"][0]["routes"][0]["via"], "nat-a")
        _, bk = get(router, "/api/room/backup")
        self.assertEqual(bk["recoveryPoints"][0]["status"], "COMPLETED")

    def test_b04_unknown_room_is_404(self) -> None:
        router, _ = make_router(canned())
        self.assertEqual(get(router, "/api/room/nat")[0], 404)


class CostTest(unittest.TestCase):
    def test_c01_rates_use_live_counts_and_are_cached_for_24h(self) -> None:
        router, fake = make_router(canned())
        _, body = get(router, "/api/cost")
        self.assertEqual(body["live"]["natGateways"], 2)
        self.assertAlmostEqual(body["live"]["vcpu"], 0.75)
        self.assertAlmostEqual(body["live"]["memoryGb"], 1.5)
        expect = 2 * 0.059 + 2 * 0.005 + 0.75 * 0.03885 + 1.5 * 0.00426 + 2 * 0.10 / 720
        self.assertAlmostEqual(body["rates"]["perHour"], expect, places=6)
        self.assertAlmostEqual(body["rates"]["per30Days"], expect * 720, places=4)
        self.assertEqual(body["actuals"]["totalUsd"], 2.5)
        pricing_calls = [c for c in fake.calls if c[0] == "pricing" and c[1] == "get_products"]
        get(router, "/api/cost")
        self.assertEqual(len([c for c in fake.calls if c[0] == "pricing" and c[1] == "get_products"]), len(pricing_calls), "second call must hit the SSM cache")
        writes = [c for c in fake.calls if c[1] == "put_parameter"]
        self.assertEqual(len(writes), 1)
        self.assertTrue(writes[0][2]["Name"].startswith("/sefs/gui/cache/"))

    def test_c02_stale_cache_is_refetched(self) -> None:
        router, fake = make_router(canned())
        old = {"items": [], "perHour": 0, "perMinute": 0, "per30Days": 0, "fetchedAt": "2026-10-25T00:00:00+00:00"}
        fake.responses["_cache"] = {"/sefs/gui/cache/rates-ap-southeast-2-2-0.75-1.5-2": json.dumps(old)}
        _, body = get(router, "/api/cost")
        self.assertGreater(body["rates"]["perHour"], 0, "a >24 h cache entry must not be served")

    def test_c03_cost_explorer_failure_is_reported_not_faked(self) -> None:
        responses = canned()
        responses["ce.get_cost_and_usage"] = lambda kw: (_ for _ in ()).throw(RuntimeError("AccessDenied"))
        router, _ = make_router(responses)
        _, body = get(router, "/api/cost")
        self.assertIn("error", body["actuals"])
        self.assertIn("AccessDenied", body["actuals"]["error"])

    def test_c04_actuals_off_means_no_cost_explorer_call(self) -> None:
        router, fake = make_router(canned(), env={"SEFS_COST_ACTUALS": "false"})
        _, body = get(router, "/api/cost")
        self.assertIsNone(body["actuals"])
        self.assertFalse([c for c in fake.calls if c[0] == "ce"])


class LogsAndGuardTest(unittest.TestCase):
    def test_d01_logs_keep_only_contract_lines(self) -> None:
        router, _ = make_router(canned())
        _, body = get(router, "/api/logs", {"app": "reader", "limit": "5"})
        self.assertEqual([l["message"] for l in body["lines"]], ["WROTE a.json sha256=ab", "WRITE_PROBE DENIED EROFS"])
        self.assertEqual(get(router, "/api/logs", {"app": "db"})[0], 400)
        self.assertEqual(get(router, "/api/logs", {"app": "writer", "limit": "lots"})[0], 400, "a non-numeric limit is the caller's mistake, not a 502")
        self.assertEqual(get(router, "/api/logs", {"app": "writer", "limit": "-5"})[0], 400)
        _, capped = get(router, "/api/logs", {"app": "writer", "limit": "99999"})
        self.assertEqual(capped["app"], "writer", "an oversize limit is capped, not refused")

    def test_d05_empty_log_group_is_not_an_error(self) -> None:
        responses = canned()
        responses["logs.describe_log_streams"] = {"logStreams": []}
        router, _ = make_router(responses)
        status, body = get(router, "/api/logs", {"app": "reader"})
        self.assertEqual(status, 200)
        self.assertIsNone(body["stream"])
        self.assertEqual(body["lines"], [])

    def test_d06_unknown_path_is_404_and_touches_nothing(self) -> None:
        router, fake = make_router(canned())
        self.assertEqual(get(router, "/api/whatever")[0], 404)
        self.assertEqual(get(router, "/")[0], 404)
        self.assertFalse([c for c in fake.calls if c[1] != "__client__"])

    def test_d02_non_get_is_refused(self) -> None:
        router, fake = make_router(canned())
        status, _ = get(router, "/api/overview", method="POST")
        self.assertEqual(status, 405)
        self.assertFalse([c for c in fake.calls if c[1] != "__client__"], "a refused method must touch nothing")

    def test_d03_aws_failure_is_a_502_with_the_reason(self) -> None:
        responses = canned()
        responses["efs.describe_file_systems"] = lambda kw: (_ for _ in ()).throw(RuntimeError("Throttling"))
        router, _ = make_router(responses)
        status, body = get(router, "/api/overview")
        self.assertEqual(status, 502)
        self.assertIn("Throttling", body["error"])

    def test_d04_only_reads_plus_the_cache_write_ever_happen(self) -> None:
        router, fake = make_router(canned())
        for p in ("/api/overview", "/api/room/efs", "/api/room/ecs", "/api/room/vpc", "/api/room/backup", "/api/cost", "/api/logs"):
            get(router, p)
        bad = [c for c in fake.calls if c[1] != "__client__" and not c[1].startswith(READ_PREFIXES) and c[1] != "put_parameter"]
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()

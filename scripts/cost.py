#!/usr/bin/env python3
"""Per-minute / per-hour / 30-day cost of the SEFS stack from the AWS Pricing API.

Rates are fetched live (us-east-1 pricing endpoint; prices for --region), quantities come
from the Terraform code (counts below mirror main.tf and the modules). Usage-based lines
(EFS bytes, logs, ECR storage, NAT bytes) take the volumes given on the command line.

  scripts/cost.py --region ap-southeast-2 [--nat 2] [--efs-gb 0.1] [--log-gb-day 0.02] [--ecr-gb 0.5]
Needs AWS credentials with pricing:GetProducts. Nothing is modified.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

LOCATION = {
    "ap-southeast-2": "Asia Pacific (Sydney)", "us-east-1": "US East (N. Virginia)",
    "us-west-2": "US West (Oregon)", "eu-west-1": "EU (Ireland)", "eu-central-1": "EU (Frankfurt)",
    "ap-southeast-1": "Asia Pacific (Singapore)", "ap-northeast-1": "Asia Pacific (Tokyo)",
}
HOURS_30D = 24 * 30


class Pricing:
    """Thin wrapper over `aws pricing get-products`; one call per service, filtered locally."""

    def __init__(self, location: str) -> None:
        self.location = location
        self._cache: dict[str, list[tuple[str, str, float, str]]] = {}

    def rows(self, service: str) -> list[tuple[str, str, float, str]]:
        if service in self._cache:
            return self._cache[service]
        cmd = ["aws", "pricing", "get-products", "--region", "us-east-1", "--service-code", service,
               "--filters", f"Type=TERM_MATCH,Field=location,Value={self.location}", "--output", "json"]
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
        rows = []
        for item in json.loads(out)["PriceList"]:
            d = json.loads(item)
            attrs = d["product"]["attributes"]
            for term in d["terms"].get("OnDemand", {}).values():
                for p in term["priceDimensions"].values():
                    usd = p["pricePerUnit"].get("USD")
                    if usd is None:
                        continue
                    rows.append((attrs.get("usagetype", ""), p["unit"], float(usd), p["description"]))
        self._cache[service] = rows
        return rows

    def rate(self, service: str, usagetype_contains: str, unit_contains: str = "") -> float:
        hits = [r for r in self.rows(service) if usagetype_contains in r[0] and unit_contains in r[1]]
        if not hits:
            raise LookupError(f"{service}: no price with usagetype~'{usagetype_contains}' unit~'{unit_contains}'")
        # several tiers can match; the first (lowest tier) is what a small stack pays
        return sorted(hits, key=lambda r: r[2], reverse=True)[0][2]


class Line:
    def __init__(self, name: str, per_hour: float, basis: str) -> None:
        self.name, self.per_hour, self.basis = name, per_hour, basis


class StackCost:
    """Quantities mirror the Terraform code; change the code, change these."""

    def __init__(self, p: Pricing, region: str, nat: int, efs_gb: float, log_gb_day: float, ecr_gb: float) -> None:
        self.p, self.region = p, region
        self.nat, self.efs_gb, self.log_gb_day, self.ecr_gb = nat, efs_gb, log_gb_day, ecr_gb
        self.prefix = {"ap-southeast-2": "APS2", "us-east-1": "USE1", "us-west-2": "USW2", "eu-west-1": "EU",
                       "eu-central-1": "EUC1", "ap-southeast-1": "APS1", "ap-northeast-1": "APN1"}[region]

    def lines(self) -> list[Line]:
        pf = self.prefix
        r = self.p.rate
        fixed = [
            Line(f"NAT gateways x{self.nat}", self.nat * r("AmazonEC2", f"{pf}-NatGateway-Hours"), "per NAT-hour"),
            Line(f"Public IPv4 on NATs x{self.nat}", self.nat * r("AmazonVPC", f"{pf}-PublicIPv4:InUseAddress"), "per address-hour"),
            Line("Fargate ARM vCPU (0.25 writer + 0.5 reader)", 0.75 * r("AmazonECS", f"{pf}-Fargate-ARM-vCPU-Hours"), "per vCPU-hour"),
            Line("Fargate ARM memory (0.5 + 1.0 GB)", 1.5 * r("AmazonECS", f"{pf}-Fargate-ARM-GB-Hours"), "per GB-hour"),
            Line("CloudWatch alarms x10", 10 * r("AmazonCloudWatch", f"{pf}-CW:AlarmMonitorUsage", "Alarms") / HOURS_30D, "per alarm-month"),
            Line("Container Insights metrics (~2 services x 10 metrics)", 20 * r("AmazonCloudWatch", f"{pf}-CW:MetricMonitorUsage", "Metrics") / HOURS_30D, "per metric-month (estimate of metric count)"),
        ]
        usage = [
            Line(f"EFS standard storage {self.efs_gb} GB", self.efs_gb * r("AmazonEFS", f"{pf}-TimedStorage-ByteHrs") / HOURS_30D, "per GB-month"),
            Line(f"CloudWatch Logs ingest {self.log_gb_day} GB/day", self.log_gb_day / 24 * r("AmazonCloudWatch", f"{pf}-DataProcessing-Bytes"), "per GB"),
            Line(f"ECR storage {self.ecr_gb} GB", self.ecr_gb * r("AmazonECR", f"{pf}-TimedStorage-ByteHrs") / HOURS_30D, "per GB-month"),
            Line("AWS Backup warm storage (EFS, tiny)", self.efs_gb * r("AWSBackup", f"{pf}-WarmStorage-ByteHrs-EFS") / HOURS_30D, "per GB-month"),
        ]
        return fixed + usage

    def report(self) -> str:
        ls = self.lines()
        total = sum(l.per_hour for l in ls)
        out = [f"SEFS running cost, {self.region}, rates from the AWS Pricing API (not an invoice)", ""]
        out.append(f"{'item':58s} {'$/hour':>10s}  basis")
        for l in ls:
            out.append(f"{l.name:58s} {l.per_hour:10.5f}  {l.basis}")
        out += ["", f"{'TOTAL per hour':58s} {total:10.5f}", f"{'per minute':58s} {total/60:10.5f}",
                f"{'30 calendar days (720 h)':58s} {total*HOURS_30D:10.2f}", "",
                "Not metered here (free at this scale or one-off): VPC, security groups, ECS cluster, IAM, EFS mount targets/access points,",
                "SNS (first 1k notifications), dashboard (first 3), log metric filters, SSM standard parameters, S3 state bucket and",
                "DynamoDB lock table (cents), NAT data processing (depends on traffic; image pulls ~0.5 GB per fresh deploy),",
                "GitHub Actions minutes (free for public repos). The daily backup job itself is free; only its storage is metered."]
        return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", default="ap-southeast-2")
    ap.add_argument("--nat", type=int, default=2)
    ap.add_argument("--efs-gb", type=float, default=0.1)
    ap.add_argument("--log-gb-day", type=float, default=0.02)
    ap.add_argument("--ecr-gb", type=float, default=0.5)
    a = ap.parse_args()
    if a.region not in LOCATION:
        print(f"region {a.region} not in the location map; add it", file=sys.stderr)
        return 2
    print(StackCost(Pricing(LOCATION[a.region]), a.region, a.nat, a.efs_gb, a.log_gb_day, a.ecr_gb).report())
    return 0


if __name__ == "__main__":
    sys.exit(main())

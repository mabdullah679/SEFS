# CONTRACTS — read before touching anything

Owner of this file: lead. Established 2026-10-25 against Terraform 1.9.8, hashicorp/aws 6.70.0 (lock file).
Requirement IDs R1–R15 are defined in [../PLAN.md](../PLAN.md) §1.

## 0. Rules of collaboration

1. **You only write inside the paths you own** (table in §1). Anything else is read-only to you.
2. `modules/*/variables.tf` and the **names** in `modules/*/outputs.tf` are the interface, fixed by the lead and already wired in the mother [`main.tf`](../main.tf). You replace `value = null` with the real value. You may add `validation` blocks to existing variables. You may NOT rename, remove, retype, or add variables/outputs. If you need a change, stop and say so in your report; do not work around it.
3. Never edit `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `Makefile`, `docs/CONTRACTS.md` at the repo root (lead-owned).
4. Commit only your owned paths, small commits, message prefix `[<your-area>]`, citing R-IDs.
5. No AWS calls of any kind. No `terraform apply`. `terraform init/validate/fmt/test` (mock providers) and local Docker only. Don't touch other projects' Docker containers (`docker ps` shows many; leave them alone). Name any container/network/volume you create with prefix `sefs-` and remove it when you're done.
6. Report honestly: what you proved (with command + output), what you didn't prove, and any spec ambiguity you hit.

## 1. Ownership

| Area | Owns | R-IDs |
|---|---|---|
| network | `modules/network/` | R5, R6 |
| storage | `modules/security/`, `modules/efs/` | R3 (FS policy), R4, R7, R9, R10, R12, R13, R15 |
| backup | `modules/backup/` | R14 |
| compute | `modules/apps/` | R2, R3 (roles + mount), R6, R8 |
| apps | `apps/`, `modules/images/`, `tests/contract/` | R2/R3 behavior, R10 behavior |
| verification | `tests/unit/`, `tests/mutation/`, `tests/live/`, `docs/TRACEABILITY.md` | all |
| lead | everything at repo root, `docs/` (other than TRACEABILITY) | integration |
| lead (added after the fleet) | `modules/access`, `modules/registry`, `modules/observability`, `modules/bootstrap`, `bootstrap/`, `bruno/`, `scripts/`, `setup.sh`, `.github/`, `tests/setup`, `tests/ci` | Bruno, SSM registry, alarms/dashboard, remote state + CI role, CI workflow |

## 2. Fixed values

| Thing | Value |
|---|---|
| Region default | `us-east-1` (var) |
| Shared GID / writer UID / reader UID | 1000 / 1001 / 1002 |
| Access-point root (both APs, same path) | `/shared`, creation_info owner 1001:1000, perms `0775` |
| Container mount path (both) | `/mnt/shared` |
| Fargate CPU arch | `ARM64` (native build on the M1 host, no emulation); image platform `linux/arm64` |
| Tags | provider `default_tags` adds `Project = var.name`, `ManagedBy = terraform`. Don't fight it. Name resources `"${var.name}-<thing>"` |

## 3. Behavioral contract per child

### network
- `data "aws_availability_zones"` (state `available`), take first `az_count`. `az_count` validation `>= 2`.
- Public + private subnet per AZ (cidrsubnet of `vpc_cidr`), IGW, NAT (per AZ when `nat_per_az`, else one), private route tables → NAT. Private subnets: `map_public_ip_on_launch = false`.
- `private_subnets_by_az` keys = AZ names (known at plan), so `for_each` downstream works.
- VPC `enable_dns_hostnames = true`, `enable_dns_support = true` (EFS mount by DNS needs both).

### security
- `sg-apps` (`"${name}-apps"`): no ingress. Egress all (ECR pull via NAT, logs, NFS).
- `sg-efs` (`"${name}-efs"`): **exactly one** ingress rule: TCP 2049 with `referenced_security_group_id = sg-apps`. No CIDR ingress, ever. Use `aws_vpc_security_group_ingress_rule` (not inline rules).

### efs
- `aws_efs_file_system`: `encrypted = true`, `performance_mode = "generalPurpose"`, `throughput_mode = "bursting"`, `kms_key_id = var.kms_key_arn` (null → AWS-managed), `lifecycle_policy { transition_to_ia = var.transition_to_ia }`, `lifecycle { prevent_destroy = true }`. Validations: `transition_to_ia` must be one of the provider-allowed `AFTER_*_DAY(S)` values.
- `aws_efs_backup_policy` status `DISABLED`. Reason: EFS automatic backups create an AWS-owned default vault that Terraform doesn't track; R14 is met by `modules/backup`.
- `aws_efs_mount_target` `for_each = var.private_subnets_by_az`, `security_groups = [var.efs_security_group_id]`.
- Two `aws_efs_access_point`s (writer, reader): both `root_directory.path = var.shared_root_path`, identical `creation_info` (owner_uid = writer_uid, owner_gid = posix_gid, permissions `"0775"`); `posix_user` writer = writer_uid:posix_gid, reader = reader_uid:posix_gid.
- `aws_efs_file_system_policy` (the compensating control for the spec drift: access points have no ro switch). Statements:
  1. Deny `*` to `*` when `aws:SecureTransport = false`.
  2. Allow writer role `ClientMount` + `ClientWrite`, condition `elasticfilesystem:AccessPointArn = writer AP ARN`.
  3. Allow reader role `ClientMount` only, condition `elasticfilesystem:AccessPointArn = reader AP ARN`.
  4. **Explicit Deny** reader role `ClientWrite` + `ClientRootAccess` (unconditional), so a later identity-policy grant can't re-open write.
  No statement grants anonymous/`*` access. No one gets `ClientRootAccess`.
- `file_system_policy_id` output = the policy resource id.

### backup
- `aws_backup_vault` (`force_destroy = true` so teardown can remove recovery points; kms per var), `aws_backup_plan` with one daily rule (`cron(0 5 * * ? *)`), `lifecycle { delete_after = var.retention_days }`, `aws_backup_selection` over `var.resource_arns`, IAM role trusting `backup.amazonaws.com` with AWS managed policies `AWSBackupServiceRolePolicyForBackup` and `...ForRestores`.
- `retention_days` validation `>= 35`.

### images
- One `aws_ecr_repository` each (`"${name}-writer"`, `"${name}-reader"`), `force_delete = true`, scan on push.
- Build + push **inside the apply** (`terraform_data` + `local-exec`): `aws ecr get-login-password | docker login`, `docker buildx build --platform var.platform --push`. Re-trigger on a hash of the build context files. Tag = content hash. Output image refs must not be known before the push finished (outputs reference the build resource).
- Host requirement: Docker + AWS CLI only. No Java/Maven/Python on host required (multi-stage builds).

### apps (compute)
- `aws_ecs_cluster` (`"${name}"`), CloudWatch log groups `/ecs/${name}/writer` and `/ecs/${name}/reader` (retention 7 days).
- Task execution role (ECR pull + logs). Two task roles:
  - writer: identity policy `elasticfilesystem:ClientMount`, `ClientWrite` on `file_system_arn` with AccessPointArn condition.
  - reader: `ClientMount` only.
- Task defs: Fargate, `runtime_platform { operating_system_family = "LINUX", cpu_architecture = "ARM64" }`, 256 CPU / 512 MB writer, 512 / 1024 reader (JVM). Volume `efs_volume_configuration { file_system_id, transit_encryption = "ENABLED", authorization_config { access_point_id, iam = "ENABLED" } }`. Mount at `container_mount_path`; writer `readOnly = false`, reader `readOnly = true`. Env: `SHARED_DIR`, `WRITER_INTERVAL_SECONDS` / `READER_POLL_SECONDS`.
- Services: `launch_type = "FARGATE"`, `platform_version = "1.4.0"` or LATEST, desired 1 each, `network_configuration { subnets = private_subnet_ids, security_groups = [apps_security_group_id], assign_public_ip = false }`. Services must not be created before `efs_dependency_ids` exist (e.g. a `terraform_data` with `triggers_replace = var.efs_dependency_ids` that the services `depends_on`). `wait_for_steady_state = true` on both.

### observability (lead)
- Alarms (10) all notify `aws_sns_topic.alerts`; service-down alarms treat a missing metric as breaching; `WRITE_PROBE ALLOWED` in the reader log alarms within one minute (R3 control broken). NAT alarms are keyed by AZ, never by NAT ID (unknown at plan). Dashboard `<name>-overview`. Cost allocation tag activation is opt-in.

### gui (lead; optional child, D23/D25/D32)
- Inputs: `name`, `region`, `admin_email` (nullable), `ssm_prefix`, `writer_log_group`, `reader_log_group`, `backup_vault_name`, `cluster_name`, `cost_actuals`, `build_web`. Outputs: `url`, `api_url`, `user_pool_id`, `user_pool_client_id`, `cognito_domain`, `bucket`, `distribution_id`, `lambda_function_name`, `api_role_arn`.
- Every `/api/*` route requires a Cognito JWT for this pool's client; the API is GET-only; CORS admits the page's own origin only. The API role holds Describe/List/Get actions, its own log stream, `pricing:GetProducts`, `ce:GetCostAndUsage` only when `cost_actuals`, and exactly one write: `ssm:PutParameter` under `/<name>/gui/cache/*`.
- API contract (JSON, `modules/gui/api/app.py` ⇄ `modules/gui/web/src/model.ts`): `GET /api/overview` → `{name, region, generatedAt, deployed, overall, nodes[], registry}` where each node is `{id, kind, label, az, parent, health, reason, facts}` and `health ∈ ok|warn|down|unknown`; `GET /api/room/{efs|ecs|vpc|backup}`; `GET /api/cost` → `{rates{items[], perHour, perMinute, per30Days}, actuals|{error}|null, live}`; `GET /api/logs?app=writer|reader&limit=1..200` → contract lines only. Bad input → 400 with a reason; an AWS failure → 502 with the exception name; nothing is ever estimated in place of a failed read.
- The page bucket blocks all public access and is read by CloudFront through OAC only; `config.json` is never cached at the edge; HTTPS only. The page is compiled by `modules/gui/build.sh` in a pinned Node container during the apply (`build_web = false` skips it: unit tests).

### apps (application code) — log lines are a test interface
- **writer (Python 3.12, stdlib only):** every `WRITER_INTERVAL_SECONDS`, write `$SHARED_DIR/<utc-iso>-<uuid>.json` (payload incl. timestamp + seq) via temp file + `fsync` + atomic rename (reader never sees a partial file). Log exactly: `WROTE <filename> sha256=<hex>`. Startup log: `WRITER_START uid=<uid> gid=<gid> dir=<dir>`. Any write error: `WRITE_ERROR <errno-name> <message>` and keep running.
- **reader (Java 21, Spring Boot 3.x, `@Scheduled`):** every `READER_POLL_SECONDS`, list `*.json` (ignore temp files), read each new one once, log `READ <filename> sha256=<hex>`. Never modifies or deletes. Startup: `READER_START uid=<uid> gid=<gid> dir=<dir>`, then a write probe: try to create `$SHARED_DIR/.reader-write-probe` and log exactly one of `WRITE_PROBE DENIED <exception-class/errno>` or `WRITE_PROBE ALLOWED` (delete the probe if it was created). Repeat the probe every poll at DEBUG level only.
- Both containers run as UID/GID matching the access point (Dockerfile `USER`), so local Docker tests reflect the AP-forced identity.

## 4. Interfaces between agents (who consumes what)
efs ⇄ apps: efs consumes `writer_task_role_arn`/`reader_task_role_arn`; apps consumes AP ids/arns + `file_system_policy_id`. This is a module-level loop, not a resource-level cycle (roles → FS policy → services). Keep it that way: the `aws_iam_role` resources for the task roles must not reference any efs output (their attached `aws_iam_role_policy` may reference the FS/AP ARNs; that's fine).

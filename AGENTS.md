# SEFS — the whole picture in one file

Read this first. It is written for an agent (or a person) who has never seen this repository and must understand, run, verify, change, or tear down the stack. Everything below is checked against the tree at the date in the footer; where a claim rests on a live run, the date of that run is given.

## 1. What this is

A Terraform project that deploys, with **one command**, a shared AWS EFS file system used by two apps on ECS Fargate: a **Python writer** (writes JSON files) and a **Spring Boot reader** (reads the same path, and must not be able to write). Around it: a multi-AZ VPC, backups kept 35 days, an IA lifecycle, a least-privilege read-only role for verification, deployed IDs published to SSM, and a GitHub Actions workflow that redeploys only what changed when a push to `main` contains the word `check`.

Spec: [Shared EFS for Multi-App.docx](Shared%20EFS%20for%20Multi-App.docx). Requirements are numbered **R1–R15** in [PLAN.md §1](PLAN.md); every test, mutation and live check cites one.

```
                      VPC 10.40.0.0/16, 2 AZs
 public  subnets:  IGW, NAT per AZ (EIP each)
 private subnets:  ECS Fargate ARM64 ─ writer (uid 1001)  reader (uid 1002)   both in sg-apps
                        │ NFS 2049 over TLS, IAM-authorised mount, via access points
                   EFS mount target per AZ (sg-efs: 2049 from sg-apps ONLY)
                   EFS /shared (0775, gid 1000)  ── AWS Backup daily, 35 d
 outside the VPC:  ECR (2 repos), CloudWatch Logs, SSM /sefs/outputs/*, IAM roles,
                   S3 state bucket + DynamoDB lock, GitHub OIDC deploy role
```

## 2. The one rule that shapes everything: read-only is enforced by IAM, not by a flag

An EFS access point has **no read-only setting** (spec drift, documented in [docs/DECISIONS.md](docs/DECISIONS.md#spec-drift-read-only-on-an-access-point)). The container `readOnly` flag is a convenience, not a control. The control is:
1. mounts are IAM-authorised over TLS ([modules/apps/main.tf](modules/apps/main.tf));
2. the reader role may only `ClientMount`;
3. the file-system policy carries an **explicit, unconditional Deny** of `ClientWrite`/`ClientRootAccess` for the reader role ([modules/efs/policy/main.tf](modules/efs/policy/main.tf));
4. services wait for that policy to exist before starting (an EFS with no policy lets anyone write).

Proven live 2026-10-25: a reader-role task with `readOnly=false` still got `EROFS` on write (`tests/live/e2e.sh` step E3).

## 3. Layout and the mother/child protocol

One root ("mother", [main.tf](main.tf)) calls child modules; **one state** (S3). `make up` applies everything. One component: `make apply-one CHILD=<child>` (= `terraform apply -target=module.<child>`); the map of component → child is [docs/COMPONENTS.md](docs/COMPONENTS.md).

| Child | Owns | Key facts |
|---|---|---|
| `network` | VPC, subnets, IGW, NATs, routes | `az_count ≥ 2` (validated), ≤ 8; private subnets never get public IPs |
| `security` | `sg-apps`, `sg-efs` | `sg-efs` has exactly one ingress rule: TCP 2049 from `sg-apps`, no CIDR |
| `efs` (+ `efs/policy`) | file system, mount targets, access points, FS policy, IA lifecycle | `encrypted`, `generalPurpose`, `bursting`, `prevent_destroy = true`, auto-backups DISABLED |
| `backup` | vault, daily plan, selection, role | `retention_days ≥ 35` (validated) |
| `images` | ECR repos + build/push **inside the apply** | tag = content hash; 20-min watchdog × 3 attempts; needs ~250 KB/s uplink |
| `apps` | ECS cluster, task defs, task roles (`name_prefix`), services, log groups | writer 256/512, reader 512/1024, ARM64, private subnets |
| `observability` | SNS alerts, 10 alarms, log metric filters, dashboard, opt-in cost tag | NAT alarms keyed by AZ; `WRITE_PROBE ALLOWED` in reader logs alarms within 1 min |
| `access` | `sefs-bruno-reader` role | read-only, SSM scoped to `/sefs/*`, KMS decrypt only via SSM |
| `registry` | SSM `/sefs/outputs/*` | non-secret deployed IDs; secrets go under `/sefs/secrets/*` and are written only by `setup.sh` |
| `bootstrap/` (separate root, local state) | state bucket, lock table, GitHub OIDC role | run once per account+region; never managed by CI |

Interfaces between children are fixed in [docs/CONTRACTS.md](docs/CONTRACTS.md). Variables with defaults: [variables.tf](variables.tf). Outputs: [outputs.tf](outputs.tf).

## 4. Running it

| Goal | Command | Notes |
|---|---|---|
| Fresh clone, everything | `./setup.sh` | tool checks → confirm AWS account → `account.auto.tfvars` (git-ignored) → bootstrap state → secrets → `make up`. `--no-deploy` stops before deploying |
| Deploy / redeploy | `make up` (`AUTO=1` skips the prompt) | preflight refuses the wrong account, a missing `backend.hcl`, or an `aws login` session profile (see §7) |
| One child | `make apply-one CHILD=efs` | |
| Live checks | `make verify` | every R-ID against AWS + `terraform plan` must be clean |
| Live behaviour | `E2E_CONFIRM=yes make e2e` | write/read, IAM read-only proof, destroy-apps-and-recover |
| Bruno collection | `make bruno-profile SOURCE=<login profile>` once, then `make bruno` | signs with a credential-free profile that assumes `sefs-bruno-reader`; hydrates IDs from SSM |
| All local proofs (no AWS) | `make test` | unit (mocked), mutation, Docker contract, setup self-test |
| Tear down | `CONFIRM_DESTROY_DATA=yes make down` | deletes the EFS and its data; keeps state bucket unless `DESTROY_STATE=yes`; sweeps the account per service |
| CI | push to `main` with `check` in the message | [docs/CI.md](docs/CI.md); first deploy on empty state is always full |

Account guard: `allowed_account_id` in `account.auto.tfvars` is enforced by the provider **and** by `make preflight`; a mismatched login fails before anything is created.

## 5. How it is proven (and what is not)

| Layer | Where | Latest result |
|---|---|---|
| Unit, mocked provider, offline | `tests/unit/` | 45/45 + 4/4 apply-mode (2026-10-25) |
| Mutation (each guard broken on purpose must be caught) | `tests/mutation/run.sh` | 48/48 killed, no-op control survives |
| Docker contract (writer/reader as real UIDs) | `tests/contract/` | 16/16 |
| setup.sh secret safety (fake `aws`) | `tests/setup/selftest.sh` | 5/5; mutation-proven |
| CI change mapper | `tests/ci/selftest.sh` | 9/9; mutation-proven |
| Live verify | `tests/live/verify.sh` | 16/16 + zero drift (2026-10-25, ap-southeast-2, run from GitHub Actions) |
| Live e2e | `tests/live/e2e.sh` | E1–E4 pass (2026-10-25) |
| Bruno collection live | `bruno/sefs` | **not yet run live** (see PLAN.md §7) |
| GitHub Actions "check" | `.github/workflows/check.yml` | **Live-proven 2026-10-25** (run 40216156247): full apply from GitHub, zero drift, verify 16/16 incl. OBS; deploy job 1 m 47 s |

Requirement → code → test map: [docs/TRACEABILITY.md](docs/TRACEABILITY.md). Not established: the errno EFS returns for a denied write is undocumented (observed `EROFS`); no backup job has been observed completing; no writer-role control run for E3.

## 6. Where the truth lives

- **Terraform state:** `s3://sefs-tfstate-<account>-<region>/sefs/terraform.tfstate`, lock `sefs-tfstate-lock`. Local `backend.hcl` is generated by `make bootstrap` and git-ignored.
- **Deployed IDs:** SSM `/sefs/outputs/*` (plain Strings, Terraform-managed).
- **Secrets:** SSM `/sefs/secrets/*` (SecureString, written by `setup.sh` only, never by Terraform). Today: none.
- **Logs:** CloudWatch `/ecs/sefs/writer`, `/ecs/sefs/reader`. Log lines are a test interface: `WROTE <file> sha256=<hex>`, `READ <file> sha256=<hex>`, `WRITE_PROBE DENIED <reason>`.
- **Decisions:** [docs/DECISIONS.md](docs/DECISIONS.md) (D1–D24 so far). **Plan and queue:** [PLAN.md](PLAN.md).

## 7. Things that bit us (so you don't re-learn them)

- Parallel `docker login` collides in the macOS keychain → each image build uses a throwaway Docker config with the ECR auth written inline.
- An unbounded image push crawled for 2 h on a 35 KB/s uplink → watchdog + retry; the link needs ≳ 250 KB/s.
- Terraform only *deregisters* ECS task definitions → teardown deletes them and checks each service directly (the tagging API lags).
- Terraform 1.9's S3 backend can't read `aws login` session profiles → `make tf-profile` creates `sefs-tf` (credential_process), preflight refuses otherwise.
- Once the S3 backend is initialised, `init -backend=false` *reuses* it → offline suites use their own `TF_DATA_DIR`.
- GitHub's OIDC `sub` claim now includes numeric IDs (`repo:owner@id/repo@id:ref:…`) → the deploy role trusts that exact string.
- The image-push watchdog once held Terraform's stdout pipe (orphaned `sleep`) → a 1-minute push "took" 40 minutes; watchdog fds are now detached.
- A cancelled apply left ECS services in AWS but not in state → `scripts/adopt-orphans.sh` runs before every apply.
- A fixed task-role name would be locked out of the EFS if the role were ever recreated → `name_prefix`.

## 8. If you are asked to change something

1. Find the child in §3; read its `variables.tf`/`outputs.tf` (the contract) before its `main.tf`.
2. Change code, then add or adjust the unit assertion **and** a mutation row that would catch the regression.
3. `make test` (offline). Then `make apply-one CHILD=<child>` or push with `check`.
4. `make verify` must be 15/15 with zero drift. Record non-obvious choices in `docs/DECISIONS.md`.
5. Never weaken a validation to pass a test; never put a secret in Terraform; never deploy to an account you have not confirmed.

---
Tree checked 2026-10-25. Live-run dates are stated inline; anything without a date is a code-level fact.

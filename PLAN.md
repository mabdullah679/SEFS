# SEFS — Implementation Plan (Shared EFS for Multi-App)

Source: [Shared EFS for Multi-App.docx](Shared%20EFS%20for%20Multi-App.docx) (full text extracted 2026-10-25; the 529 KB size is embedded fonts, there are no images or hidden sections).
Status (2026-10-25): **built and proven locally** — unit, mutation (28/28) and Docker contract all green on main. **Real-AWS layer run and torn down 2026-10-25** (verify 15/15, e2e E1–E4 pass, account verified clean). See README.

---

## 1. Requirements, numbered (so every file and test can cite one)

| ID | Requirement (from spec) | How it gets enforced (the code path, not prose) |
|----|----|----|
| R1 | EFS persists independently of app lifecycle | Storage lives in its own Terraform stack + state; destroying the apps stack cannot touch it |
| R2 | Python writer has rw on the shared path | Writer task role gets `ClientMount`+`ClientWrite`; access point root dir; ECS volume `readOnly=false` |
| R3 | Spring Boot reader has ro (or rw) on the **same** path | Reader task role gets `ClientMount` only; file-system policy denies write to anyone without `ClientWrite`; ECS mount `readOnly=true` |
| R4 | EFS lifecycle isolated and/or `prevent_destroy = true` | Both: separate stack (R1) **and** `lifecycle { prevent_destroy = true }` on the file system |
| R5 | Multi-AZ VPC, ≥2 AZs, public + private subnets | Network module; `length(azs) >= 2` variable validation |
| R6 | Apps run in private subnets | Services pinned to private subnet IDs, `assign_public_ip = false` |
| R7 | One mount target per private-subnet AZ | `aws_efs_mount_target` via `for_each` over private subnets |
| R8 | `sg-apps` attached to both apps | Single SG output from apps stack, set on both services |
| R9 | `sg-efs` allows 2049 inbound **only** from `sg-apps` | One ingress rule, `referenced_security_group_id = sg-apps`, no CIDR rules |
| R10 | Access point enforces POSIX UID/GID | `aws_efs_access_point` with `posix_user` + `root_directory.creation_info` |
| R11 | Modular Terraform | `modules/{network,efs,backup,apps}` consumed by `stacks/*` |
| R12 | `encrypted=true`, `generalPurpose`, `bursting` | Hard-coded on the resource; variable validation rejects other values |
| R13 | Encryption at rest, AWS-managed or CMK | `kms_key_arn` optional variable; null = `aws/elasticfilesystem` |
| R14 | AWS Backup, ≥35-day retention | `aws_backup_vault` + `plan` + `selection` + IAM role; `delete_after` validated `>= 35` |
| R15 | Transition to IA after 30 days | `lifecycle_policy { transition_to_ia = "AFTER_30_DAYS" }` |

## 2. Gaps and traps in the spec (my calls — argue if you disagree)

1. **SPEC DRIFT (honest caveat, goes in README + DECISIONS): "read-only" has no switch on an access point.** The spec implies `ro` can be set at the access point; it can't. Compensating solution below.
    Access points set UID/GID and root path only. A ro reader enforced only by a mount flag is a control that is never code — the container can remount rw. Real enforcement = IAM authorization on the mount (needs transit encryption on) + file-system policy. R3 above is wired that way.
2. **Same path + different runtimes = permission errors** (the exact thing R10 warns about). Plan: both access points use the same root dir (`/shared`) and the same GID (e.g. 1000), writer UID 1001, reader UID 1002, dir perms `0775`, files created group-readable. Writer and reader then can't fight over ownership.
3. **Transit encryption isn't in the spec** but is required for IAM-authorized mounts (point 1). Adding it.
4. **Apps aren't supplied.** The spec names a Python writer and a Spring Boot reader but provides neither. A minimal pair is in scope, because without them R2/R3 can't be proven end to end.
5. **ALB is mentioned in the diagram but nothing needs it** (the reader processes files; no inbound HTTP is required). Leaving it out; noting as future work.
6. **NAT gateways.** Owner doesn't care about hourly rate (2026-10-25), so one NAT per AZ, matching the spec diagram.
7. **Spec's two open questions** (compute service, monolith vs decoupled) are the blockers below.

## 3. Target layout (mother root + child modules, ONE state — decided 2026-10-25)

```
SEFS/
  main.tf, variables.tf, outputs.tf, versions.tf   MOTHER: wires every child; one apply deploys all
  modules/network/    VPC, 2+ AZ public/private subnets, IGW, NAT per AZ, routes
  modules/security/   sg-apps, sg-efs (2049 from sg-apps only)
  modules/efs/        file system, mount targets, access points, FS policy, lifecycle, prevent_destroy
  modules/backup/     vault, 35-day plan, selection, IAM role
  modules/images/     ECR repos + image build/push inside the apply (ARM64, native on M1)
  modules/apps/       ECS cluster, task defs w/ EFS volumes, task roles, services, logs
  apps/writer-python/       minimal writer + Dockerfile
  apps/reader-springboot/   minimal reader + Dockerfile (multi-stage; host needs no Java)
  tests/unit/         terraform test, mock providers (fake AWS)
  tests/mutation/     mutation harness
  tests/contract/     docker-compose writer/reader POSIX test
  tests/live/         real-AWS verifier + end-to-end script
  Makefile            up / test / verify / down
  docs/               CONTRACTS, DECISIONS, TRACEABILITY, COMPONENTS (which child updates what)
  README.md + README.txt
```

Single-component update = `terraform apply -target=module.<child>`; the component → child map lives in `docs/COMPONENTS.md`.
Images are built and pushed inside the apply, so one `terraform apply` should deploy everything. `make up` wraps it (preflight checks + apply). If a non-Terraform step proves unavoidable, it moves into `make up` and gets documented.

**Two honest constraints this layout creates:**
- `terraform test` in apply mode on real AWS auto-destroys what it created, which `prevent_destroy` blocks for the EFS. So the real-AWS layer is: `make up` → a verifier that checks every R-ID against live AWS (`aws efs describe-*` etc.) → `terraform plan` must show **no changes** (declared = live) → behavior e2e.
- Teardown: `prevent_destroy` can't be toggled by a variable (Terraform requires a literal). `make down` is a deliberate two-step: `terraform state rm` the file system, `terraform destroy` the rest, then delete the EFS via the AWS CLI. Gated by `CONFIRM_DESTROY_DATA=yes` and verified against AWS. EFS automatic backups (`aws_efs_backup_policy`) stay DISABLED so no untracked default vault is left behind; our own Backup plan covers R14.

## 4. How it gets proven (free/local first)

| Layer | Proof | Needs AWS? |
|----|----|----|
| Every R-ID in Terraform | `terraform test` with `mock_provider` (TF 1.9.8 installed) asserting each attribute; `terraform validate`; `tflint`; `checkov` | No |
| Each guard is real | Mutation run: flip the guard (e.g. `encrypted=false`, retention 34, add a CIDR to sg-efs, drop `prevent_destroy`) and watch the matching test go red, then reverse the exact edit | No |
| Writer/reader POSIX contract | docker-compose: shared volume, writer as 1001:1000, reader as 1002:1000 with ro mount; reader reads what writer wrote; reader write attempt fails | No |
| Terraform on real AWS | `terraform test` run against the live account (real provider, not mocks), same assertions | **Yes** |
| Real EFS end to end | ONE command (`make up`) deploys everything; writer writes, reader reads, reader write is denied; **IAM mutation on real AWS**: run a reader-role task with the mount flag set rw and confirm writes are still denied (proves the compensating control, not just the flag); apps destroyed and re-applied, data still there (R1); then `make down` and teardown verified against AWS | **Yes** |

**Single-command spin-up (owner, 2026-10-25):** proof target is that one `terraform apply`, or one `make` target if infra isn't the only spin-up step, deploys the entire thing. My call: **Makefile**, because container images must be built and pushed to ECR before ECS can start tasks. `make up` = build/push images + mother `terraform apply`.

floci (local AWS emulator) is not running here (container not found 2026-10-25), and whether it emulates EFS/Backup is **unverified**. If you want it tried, it's a 5-minute probe; the plan doesn't depend on it. Fallback (owner, 2026-10-25): if floci can't do EFS, owner will auth into an AWS account with credits for the live layer. Credits don't waive the consent gate below.

**Live AWS gate:** before any apply I show account ID/name, region and resource list and wait for a yes. Owner: hourly rate not a concern; everything is destroyed as soon as the single-command deploy is proven. Teardown note: `prevent_destroy` means final cleanup needs a deliberate override, which I'd do and verify the same session.

## 5. Agent fleet (approved 2026-10-25)

Collaboration without overwriting = **hard file ownership + contracts first + one git worktree per agent.**

0. **Lead (me):** `git init`, scaffold, `docs/CONTRACTS.md` (every child's variables/outputs, names fixed), mother root files, Makefile. Nobody edits a path they don't own; contract changes go through me.
1. **Network** — `modules/network`. R5, R6.
2. **Storage** — `modules/security`, `modules/efs`. R3 (FS policy), R4, R7, R9, R10, R12, R13, R15.
3. **Backup** — `modules/backup`. R14.
4. **Compute** — `modules/apps`. R2, R3 (mount + roles), R6, R8.
5. **Apps** — `apps/*`, `modules/images`, `tests/contract`. Writer, reader, image build, POSIX test.
6. **Verification** — `tests/unit`, `tests/mutation`, `tests/live`, `docs/TRACEABILITY.md`.
7. **Lead integrates:** merge order network → storage/backup → compute → apps → tests; run every proof; README.md/.txt (golden shape), `docs/DECISIONS.md`, `docs/COMPONENTS.md`. Then the AWS gate.

## 6. Blocking decisions (asked one at a time)

- **Q1: Compute service** — **DECIDED 2026-10-25: ECS Fargate.**
- **Q2: Monolith vs decoupled** — **DECIDED 2026-10-25: decoupled stacks (network / storage / apps, separate state).**
- **Q3: Fleet** — owner approved 2026-10-25 with changes: tests on both mock and real AWS; ro-access-point drift documented with compensating control; destroy right after proof; Q2 reversed to mother-orchestrates-children (see below).
- **Q2 REVISED 2026-10-25:** one **mother Terraform** orchestrates **child** Terraform. Docs map every component to the child that updates it, so a single-component update has a known command. Larger deployments: docs explain mother-child; use the mother file or go granular, user's choice.

## 7. Queue — final vision (owner, 2026-10-25; intent restated, not yet built)

> One script, enter credentials once, platform provisioned. Then test per child or full mother deploy. CI detects which children changed and redeploys only those. After one-time setup, pushing to `main` with the keyword **"check"** handles everything.

| # | Item | State 2026-10-25 |
|---|---|---|
| Q1 | `setup.sh`: fresh-clone checks (tools, Docker, AWS identity), prompts for creds → SSM SecureString only, writes `account.auto.tfvars`, runs `make up` | not started |
| Q2 | Bruno collection, self-hydrating from SSM via the read-only role | **Done, live-proven 2026-10-26** against the CI-deployed stack: 20 requests, 58/58 tests under `sefs-bruno-reader`; negative control (bogus SG IDs) fails R9 + group-exists. Fixed on the way: EC2 Query moved to GET (form body was rejected), Logs `filterPattern` JSON escaping, nested `<tagSet><item>` ending a rule early, and `FilterLogEvents` wide windows returning an empty first page (probe now read from the stream head). Mutations m30–m37 killed 8/8. |
| Q3 | CI on GitHub Actions (D20) | **Done and live-proven 2026-10-25** (run 40216156247): S3 state + DynamoDB lock (bootstrap), OIDC deploy role pinned to `mabdullah679/SEFS` main (ID-form sub), `check` / `check full` keywords, adopt-orphans, verify 16/16 from GitHub |
| Q4 | Mutation-prove everything above as it lands | pending |
| Q10 | **Credits and inputs (owner, 2026-10-27):** keep every credit (the Oct 2026 "$8" was US$7.41 of burst usage fully offset by credits; nothing was left running, both accounts scrubbed the same day); the owner tests manually before the client handoff; `setup.sh` remembers every prompt answer for 24 h from entry, per boot session, never secrets | **Done 2026-10-27:** D30 input cache (`ask()` keyed by kernel boot time, `./sefs forget`, `SEFS_NO_CACHE=1`; selftest S6–S9, 4 mutations killed); D31 burn visibility (`make up`/`setup.sh` warn with the hourly and daily rate, `./sefs burn` and `./sefs status` show hours up × rate). **Not done (owner's consent needed):** an AWS Budgets alert on the payer account for pre-credit usage |

Usage rule (owner, 2026-10-25): owner gates on `/usage`; small stoppable chunks; no agent fan-out without an explicit go.
Credits rule (owner, 2026-10-27): credits are not free money; no deploy, e2e or `check` push by an agent; the stack is torn down at the end of every manual test session (D31).

## 8. Queue — client experience + observability + 2.5D GUI (owner, 2026-10-25; not yet built)

> The client's agent reads ONE markdown file and grasps the whole stack. Telemetry/observability is Terraform-managed. A GUI microservice shows the live `Project=sefs` infrastructure as a 3D / 2.5D top-down model: hover/click for live health; click a resource to "open the doors" into a 2.5D room of its internals (preferred over linking to the AWS console). Budgets (per minute / per hour) updated for the new services, plus a 30-day figure from real cost/usage, shown in the GUI. Acceptance: fresh clone → 2.5D internals, everything in between proven.

| # | Item | Design call / open question | State |
|---|---|---|---|
| Q5 | **One file for agents**: `AGENTS.md` at the root (the convention coding agents read); `CLAUDE.md` is a one-line pointer to it. Contents: what/why, topology, every `make` target, mother/child protocol, contracts, proofs and how to re-run them, decisions, live-run history, where truth lives (SSM, state bucket), and the honest-limits list | lead's call | not started |
| Q6 (**deployed + verified live 2026-10-25**: OBS PASS) | **Telemetry/observability in Terraform** (`modules/observability`): ECS Container Insights, CloudWatch dashboard, alarms (writer/reader running count, EFS burst credits + client errors, NAT error port allocation, backup job failures), log metric filters on `WRITE_ERROR` / `READ_ERROR`; cost allocation tag `Project` activated (24 h lag before Cost Explorer can group by it) | lead's call; alarms need a destination: SNS topic + owner email (prompted by setup.sh) | not started |
| Q7 | **GUI microservice, 2.5D/3D** (D23: optional child `enable_gui`, default on): serverless so idle cost ≈ 0 (owner: "without eating compute"): S3 + CloudFront for the static three.js app; Lambda (Python) behind API Gateway as a read-only data API using a Bruno-like least-privilege role (Resource Groups Tagging API for inventory, EFS/ECS/EC2 describes + CloudWatch metrics for health, Cost Explorer for spend). Per-resource "rooms" (EFS: mount targets/APs/policy; ECS: services/tasks/containers; VPC: subnets/NATs/routes; Backup: vault/plan/recovery points) | **decided D25: Cognito login** (user pool + hosted UI; API Gateway JWT authoriser; CloudFront serves the static app) | **Built 2026-10-27 (D32), proven offline, not yet deployed:** `modules/gui` wired behind `enable_gui`; API `api/app.py` (overview, rooms efs/ecs/vpc/backup, cost with rates + Cost Explorer, logs) 18/18 tests on a fake boto3; page `web/` (PKCE login, 2.5D overview, rooms, cost panel, alarms, logs) type-checked and built in Docker; `gui.tftest.hcl` 6 runs; mutations g01–g07; teardown sweeps the 6 new families; `./sefs map`; `setup.sh` asks for the map login e-mail. Live proof is the next step |
| Q8 | **Cost**: per-minute/per-hour budget from the Pricing API for the final stack; 30-day figure | lead | **Done (rates), 2026-10-26:** `make cost` → $0.174/h, $0.0029/min, $125.23/30 d for `ap-southeast-2` (README "Running cost"). **Not done:** Cost Explorer actuals need days of runtime; 30-day figure is rate × 720 h until then. GUI cost panel moves to chunk 5. |
| Q9 | **End-to-end proof**: fresh clone → `./sefs setup` → verify → bruno → GUI → "check" push → teardown clean | after Q5–Q8 | **Partly done 2026-10-26:** "check" push → gated CI deploy (run 40261693403) → whole workflow through `./sefs` (plan, verify 16/16, e2e E1–E4, bruno 58/58, cost, no-op up, clean plan, down + independent sweep). Found and fixed on the way: environment OIDC subject, substring `check` gate, e2e E3 name from console, wrapper hang on a stalled API call, teardown flagging the kept CI role. **Not done:** fresh-machine `./sefs setup` by a second person (owner is doing it now); GUI steps are chunk 5. |

Chunking (owner gates on usage): chunk 4 = Q5 + Q6 + Q8-rates; chunk 5 = Q7 overview (model + live health + cost panel); chunk 6 = Q7 rooms + Q9.

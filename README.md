# SEFS — Shared EFS for a Python writer and a Spring Boot reader

One Terraform apply builds, in your AWS account, a multi-AZ VPC, an encrypted EFS shared by two ECS Fargate apps (a Python writer and a Spring Boot reader on the same path, the reader unable to write), 35-day backups, an IA lifecycle, alarms and a dashboard, a read-only verification role, and the state/CI plumbing so that every later change deploys itself from a push to `main`.
Implements [Shared EFS for Multi-App.docx](Shared%20EFS%20for%20Multi-App.docx); requirements are numbered R1–R15 in [PLAN.md §1](PLAN.md#1-requirements-numbered-so-every-file-and-test-can-cite-one). Agents: read [AGENTS.md](AGENTS.md) first.

```
 your laptop ──./setup.sh──► bootstrap (state bucket, lock table, CI role)  ──┐
 your GitHub ──push "check"─► Actions: OIDC → shared state → apply → verify ──┤
                                                                               ▼
                 VPC (2+ AZs)            ┌────────────── AWS account ──────────────┐
  public  ┌─ NAT (AZ-a) ─┐   ┌─ NAT (AZ-b) ─┐                                     │
  private │ writer task  │   │ reader task  │   ECS Fargate ARM64, sg-apps        │
          │ (py, 1001)   │   │ (java, 1002) │                                     │
          └──────┬───────┘   └──────┬───────┘                                     │
                 │ NFS 2049, TLS, IAM-authorised mount via access points          │
          ┌──────▼───────┐   ┌──────▼───────┐                                     │
          │ mount target │   │ mount target │   sg-efs: 2049 from sg-apps only    │
          └──────┬───────┘   └──────┬───────┘                                     │
                 └────► EFS /shared ◄┘ ── AWS Backup (35 d) ── alarms → SNS       │
           writer AP 1001:1000 rw     reader AP 1002:1000, write DENIED by policy  │
                 ECR (2 repos)   CloudWatch (logs, dashboard)   SSM /sefs/outputs/* │
                                                                                   └┘
```

Nothing is emulated: it needs a **real AWS account** and, for the automation, a **GitHub repository you own**. Container images are built on your machine (or the GitHub runner) and pushed to ECR during the apply.

## Prerequisites

- An AWS account you can administer, and a login for it (`aws login`, SSO or keys). The deploy needs rights to create VPC, EFS, ECS, ECR, IAM roles, AWS Backup, CloudWatch, SNS, SSM, S3 and DynamoDB.
- A GitHub repository you own (empty is fine) to hold your copy of this code; the CI deploy role is trusted by that one repo and its `main` branch only.
- Terraform ≥ 1.9 (tested 1.9.8; provider `hashicorp/aws` 6.70.0 pinned in [.terraform.lock.hcl](.terraform.lock.hcl)), Docker with `buildx` (tested 29.8.2), AWS CLI v2, `jq`, `make`, `bash`. macOS and Linux as-is; Windows via WSL2. Optional: `gh` (lets `setup.sh` resolve your repo's numeric IDs for the CI trust automatically), `bru` (Bruno CLI).
- Uplink of roughly ≥ 250 KB/s: `make up` pushes ~290 MB of images, bounded by a 20-minute watchdog × 3 attempts. A healthy link pushes in under 7 min; a 35 KB/s link crawled for 2 h and broke (measured 2026-10-25). GitHub's runners have no such problem.
- No inbound ports, no domain, no load balancer.

The host does **not** need Java, Maven or Python: both apps build inside Docker.

## Run it

1. Create an empty repository on GitHub (say `you/sefs`), then:
   ```bash
   git clone https://github.com/mabdullah679/SEFS.git sefs && cd sefs
   git remote set-url origin https://github.com/you/sefs.git && git push -u origin main
   ```
2. Sign in to AWS in your shell (for example `aws login --profile work`, then `export AWS_PROFILE=work`).
3. One command:
   ```bash
   ./setup.sh
   ```
   It checks the tools, shows the account your credentials resolve to and asks you to confirm it, asks for the region, an alarm e-mail (optional) and your GitHub repo (`you/sefs`), writes the git-ignored `account.auto.tfvars`, creates the state bucket, lock table and CI role (once), prompts for any secret in [secrets.manifest](secrets.manifest) (none today) and stores it only in SSM, then runs `make up` (≈ 8 min). `./setup.sh --no-deploy` stops before the deploy.
4. Wire CI once: in GitHub → Settings → Secrets and variables → Actions → **Variables**, add `AWS_REGION`, `AWS_ACCOUNT_ID`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_LOCK_TABLE` from `setup.sh`'s final output (no secrets: OIDC replaces keys). Details: [docs/CI.md](docs/CI.md#one-time-setup-owner-10-min).
5. From now on, push to `main` with **`check`** in the commit message: the changed children redeploy and the live checks run. `check full` redeploys everything.

Identical on macOS, Linux and WSL2:

```bash
make verify                            # every requirement checked against live AWS + plan must be clean
E2E_CONFIRM=yes make e2e               # write/read, read-only proof with the mount flag off, persistence
make bruno                             # the Bruno collection (after make bruno-profile SOURCE=<login profile>)
CONFIRM_DESTROY_DATA=yes make down     # deletes everything incl. the EFS data; keeps the state bucket
```

### If something refuses to run

- `Refusing: credentials are account X, allowed is Y`: you are signed in to the wrong account. The guard is `allowed_account_id` in `account.auto.tfvars`, enforced by `make preflight` and by the provider.
- `profile '…' is an 'aws login' session`: Terraform 1.9's S3 backend cannot read that profile type. `make tf-profile SOURCE=<that profile>` creates `sefs-tf` (a `credential_process` helper over the same login; nothing stored) and `export AWS_PROFILE=sefs-tf`. `setup.sh` does this for you. See [docs/CI.md](docs/CI.md#five-things-learned-the-hard-way).
- `backend.hcl missing`: run `make bootstrap` (what `setup.sh` step 3b does).
- A cancelled or failed run: push again with `check full`; `scripts/adopt-orphans.sh` re-attaches anything AWS kept.
- Region: anything with ≥ 2 AZs; set it in `account.auto.tfvars` (`region = "…"`). Only `ap-southeast-2` has been exercised live.

## What it does

| Action | Expected result | R-ID |
|---|---|---|
| `make up` / `check` push | VPC across ≥ 2 AZs, public + private subnets, NAT per AZ | R5 |
| Apps start | Both services in private subnets, no public IP, both on `sg-apps` | R6, R8 |
| EFS reachable | One mount target per private AZ; `sg-efs` admits only TCP 2049 from `sg-apps` | R7, R9 |
| Writer runs | Writes `/mnt/shared/<time>-<uuid>.json` atomically as 1001:1000 | R2, R10 |
| Reader runs | Reads every file at the **same** path as 1002:1000; writes are denied | R3, R10 |
| EFS settings | Encrypted (AWS-managed key or your CMK), General Purpose, Bursting, IA after 30 days | R12, R13, R15 |
| Backup | Daily AWS Backup, kept ≥ 35 days | R14 |
| Destroy the apps | Data is still on the EFS; apps re-attach on the next apply | R1, R4 |
| Something breaks | 10 alarms → SNS (apps down, EFS credits/clients, NAT port errors, backup failures, app log errors, **reader managed to write**); dashboard `sefs-overview` | ops |

### Spec drift: read-only reader

An EFS access point has **no read-only setting**; it only sets user, group and directory. A container `readOnly` flag is easy to remove, and the shared directory is group-writable by design. The read-only guarantee is enforced by IAM instead: the reader's role can only mount, and the file-system policy explicitly denies it write and root access. `make e2e` proves it by running the reader's role with the mount flag **off**; the write still fails. Write-up: [docs/DECISIONS.md](docs/DECISIONS.md#spec-drift-read-only-on-an-access-point).

## Interface

| Command | What | Touches AWS |
|---|---|---|
| `./setup.sh` | Fresh-clone setup, end to end | yes (creates) |
| `make up` | Deploy everything (one apply) | yes (creates) |
| `make apply-one CHILD=x` | Update one child ([docs/COMPONENTS.md](docs/COMPONENTS.md)) | yes (changes) |
| `make plan` | Show pending changes | read-only |
| `make test` | Unit + mutation + Docker contract + setup self-test | no |
| `make verify` | Live checks + no-drift plan | read-only |
| `E2E_CONFIRM=yes make e2e` | Live behaviour proofs | yes (one-off task; destroys + re-applies apps) |
| `make bruno` | Bruno collection against the live stack | read-only (assumed role) |
| `make bootstrap` / `make tf-profile` / `make bruno-profile` | One-time helpers | bootstrap: yes; profiles: no |
| `CONFIRM_DESTROY_DATA=yes make down` | Delete everything (+`DESTROY_STATE=yes` for the state bucket) | yes (deletes) |
| push to `main` with `check` / `check full` | CI deploy + verify | yes |

Inputs: [variables.tf](variables.tf) (all with defaults; your values go in `account.auto.tfvars`). Outputs: [outputs.tf](outputs.tf), also published to SSM `/sefs/outputs/*`.

## Bruno collection (live, read-only, self-hydrating)

[bruno/sefs](bruno/sefs) checks every requirement by calling the AWS APIs directly (SigV4). It holds **no credentials**: requests sign with the `sefs-bruno` profile, whose `credential_process` ([scripts/bruno-creds.sh](scripts/bruno-creds.sh)) assumes the least-privilege role `sefs-bruno-reader` ([modules/access](modules/access/main.tf)) through your own login. Folder `00-hydrate` reads every deployed ID from SSM; nothing is typed by hand. Folders: `01-storage` (R12 R13 R4 R15 R7 R10 R2/R3), `02-network` (R9 R8), `03-compute` (R6 R8 R3 R2), `04-backup` (R14), `05-behaviour` (WROTE/READ lines, write probe). Not in Bruno: the AWS-managed-key alias check and the IAM mutation; `make verify` and `make e2e` cover those.

## Tests

Local suites are free and need no AWS account (mock provider, network blocked):

```bash
make test-unit       # terraform test on mocked AWS, one run per requirement
make test-mutation   # breaks each guard in a temp copy; every break must be caught
make test-contract   # Docker: writer + reader on one volume, as their real UIDs
make test-setup      # setup.sh with a fake aws: a secret never touches argv or disk
```

| Suite | Result on `main` (2026-10-25) |
|---|---|
| Unit | 45/45 + 4/4 apply-mode (mocked) + static `prevent_destroy` check |
| Mutation | 48/48 deliberate breaks caught; a no-op control break correctly survives |
| Contract (Docker) | 16/16; with the reader mounted rw it fails, as it should |
| Setup self-test | 5/5; mutation-proven |
| CI mapper self-test | 9/9; mutation-proven |
| Live verifier self-test | 29/29 scenarios (stub AWS) |
| Live (`ap-southeast-2`, 2026-10-25) | `make up` 55 resources ≈ 8 min; `make verify` 15/15 + zero drift; e2e E1–E4 pass (40 files round-tripped; reader denied with `readOnly=false`; 46 files survived destroy/re-apply); `make down` clean, account re-checked independently |
| GitHub Actions `check` (run 40216156247) | OIDC → shared state → full apply → zero drift → verify **16/16** incl. observability; deploy job 1 m 47 s |

**Not established:** the errno EFS returns for a denied write is undocumented (observed `EROFS`); no backup job has been observed completing (R14 is proven as configuration); no writer-role control run for the IAM mutation. Mapping: [docs/TRACEABILITY.md](docs/TRACEABILITY.md).

## Layout

| Path | What |
|---|---|
| [main.tf](main.tf) · [variables.tf](variables.tf) · [outputs.tf](outputs.tf) · [backend.tf](backend.tf) | The mother: wires every child; S3 backend |
| [modules/network](modules/network/main.tf) | VPC, subnets, NAT, routes |
| [modules/security](modules/security/main.tf) | `sg-apps`, `sg-efs`, the 2049 rule |
| [modules/efs](modules/efs/main.tf) · [modules/efs/policy](modules/efs/policy/main.tf) | File system, mount targets, access points, IA lifecycle, `prevent_destroy`; the read-only policy |
| [modules/backup](modules/backup/main.tf) | Vault, 35-day plan, selection, role |
| [modules/images](modules/images/main.tf) | ECR repos + build/push during the apply (watchdog + retry) |
| [modules/apps](modules/apps/main.tf) | ECS cluster (Container Insights), task definitions, task roles, services |
| [modules/observability](modules/observability/main.tf) | Alarms → SNS, dashboard, log-derived metrics, opt-in cost allocation tag |
| [modules/access](modules/access/main.tf) · [modules/registry](modules/registry/main.tf) | Read-only verification role; deployed IDs in SSM |
| [modules/bootstrap](modules/bootstrap/main.tf) · [bootstrap/](bootstrap/main.tf) | State bucket, lock table, GitHub OIDC deploy role (once, local state) |
| [apps/writer-python](apps/writer-python/writer.py) · [apps/reader-springboot](apps/reader-springboot/src/main/java/com/sefs/reader/SharedDirPoller.java) | The two apps |
| [setup.sh](setup.sh) · [Makefile](Makefile) · [scripts/](scripts) | Fresh-clone setup; targets; teardown, orphan adoption, credential-free profiles, CI change mapper |
| [.github/workflows/check.yml](.github/workflows/check.yml) | "check" push → changed children redeploy → verify |
| [bruno/sefs](bruno/sefs) | Live verification collection |
| [tests/unit](tests/unit) · [tests/mutation](tests/mutation/run.sh) · [tests/contract](tests/contract) · [tests/setup](tests/setup/selftest.sh) · [tests/ci](tests/ci/selftest.sh) · [tests/live](tests/live) | Test suites |
| [AGENTS.md](AGENTS.md) | The whole picture in one file, for an agent that has never seen the repo |
| [docs/CI.md](docs/CI.md) · [docs/COMPONENTS.md](docs/COMPONENTS.md) · [docs/CONTRACTS.md](docs/CONTRACTS.md) · [docs/DECISIONS.md](docs/DECISIONS.md) · [docs/TRACEABILITY.md](docs/TRACEABILITY.md) | CI setup; component → child map; module contracts; decisions ledger; requirement → test map |
| [PLAN.md](PLAN.md) | Requirements, plan, and the queue of what ships next (the 2.5D GUI, PLAN §8) |

Every `.md` here has a plain-text `.txt` twin.

## Notes on design decisions

**One state, not one per layer.** Separate states would put the EFS out of reach of an apps destroy by construction, but "one apply deploys everything" would become a script running several applies. The EFS is protected by `prevent_destroy` instead, and any component can still be applied alone with `-target`; a clean plan after each targeted apply is what keeps that safe.

**Images build inside the apply.** Pushing first would need the ECR repo to exist first, which means two applies. A `terraform_data` resource builds and pushes when app source changes; the Maven stage runs on the builder's native platform (bytecode is portable), so x86 runners never emulate a JVM build.

**Apps wait for the file-system policy.** An EFS with no policy lets any client write. If the reader mounted before the deny policy existed, it would keep write access for the life of the mount.

**Task roles use generated names.** The EFS policy pins roles by internal ID; a role recreated under the same name would keep its ARN, Terraform would see nothing to change, and the role would be locked out.

**The CI role is created by you, not by CI.** The bootstrap stack (local state) owns the state bucket, the lock table and the deploy role, and the role explicitly denies IAM on itself, so a workflow can never widen its own permissions or delete the state it runs on.

**Secrets never pass through Terraform.** `setup.sh` streams them to SSM on stdin as SecureStrings; nothing in state, argv or the repo (proven by `make test-setup`).

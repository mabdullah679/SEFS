# SEFS — Shared EFS for a Python writer and a Spring Boot reader

One Terraform apply builds a multi-AZ VPC, an encrypted EFS shared by two ECS Fargate apps (the Python app writes, the Spring Boot app reads the same path), 35-day AWS Backup and an IA lifecycle.
Implements [Shared EFS for Multi-App.docx](Shared%20EFS%20for%20Multi-App.docx); requirements are numbered R1–R15 in [PLAN.md](PLAN.md#1-requirements-numbered-so-every-file-and-test-can-cite-one).

```
                 VPC (2+ AZs)
  public  ┌─ NAT (AZ-a) ─┐   ┌─ NAT (AZ-b) ─┐
  private │ writer task  │   │ reader task  │   ECS Fargate ARM64, sg-apps
          │ (py, 1001)   │   │ (java, 1002) │
          └──────┬───────┘   └──────┬───────┘
                 │ NFS 2049, TLS, IAM-authorized mount
          ┌──────▼───────┐   ┌──────▼───────┐
          │ mount target │   │ mount target │   sg-efs: 2049 from sg-apps only
          └──────┬───────┘   └──────┬───────┘
                 └────► EFS /shared ◄┘ ── AWS Backup (35 d)
           writer AP 1001:1000 rw     reader AP 1002:1000, write DENIED by FS policy
```

Nothing here is emulated at deploy time: it needs a **real AWS account**. Images are built on your machine and pushed to ECR during the apply.

## Prerequisites

- Terraform ≥ 1.9 (tested 1.9.8; provider `hashicorp/aws` 6.70.0 pinned in [.terraform.lock.hcl](.terraform.lock.hcl))
- Docker with `buildx` (tested Docker 29.8.2, arm64 host). Images are `linux/arm64`; an x86 host builds them under emulation (slower, works)
- AWS CLI v2, signed in to the target account. **If you sign in with `aws login`** (session profiles): Terraform 1.9's S3 backend can't read that profile type, so run `make tf-profile SOURCE=<that profile>` once and work with `AWS_PROFILE=sefs-tf` (a `credential_process` helper over the same login; nothing stored). `setup.sh` does this automatically and `make preflight` refuses to run without it (`aws sts get-caller-identity` works) with rights to create VPC, EFS, ECS, ECR, IAM, AWS Backup, CloudWatch Logs
- `make` and `bash`. macOS/Linux as-is; on Windows use WSL2
- No inbound ports, no domain, no load balancer

The host does **not** need Java, Maven or Python; both apps build inside Docker.
- **Uplink:** `make up` pushes ~290 MB of images (writer 145 MB, reader 352 MB compressed to ~165 MB + ~120 MB layers). Each push attempt is bounded by a 20-minute watchdog with 3 attempts (`modules/images` variables `build_timeout_seconds`, `build_attempts`), so the link needs to sustain roughly ≥ 250 KB/s. Measured 2026-10-25: a healthy run pushed in under 7 min; a ~35 KB/s link crawled for 2 h 09 m and broke.

## Run it

**Fresh clone, one command:** `./setup.sh` (or `make setup`). It checks the host tools, shows which AWS account your credentials resolve to and asks you to confirm it, writes the git-ignored `account.auto.tfvars`, prompts for any secret listed in [secrets.manifest](secrets.manifest) and stores it only as an SSM SecureString (streamed on stdin, never on argv, never in Terraform state), then runs `make up`. `./setup.sh --no-deploy` stops before the deploy. Proof that a secret never leaks: `make test-setup` ([tests/setup/selftest.sh](tests/setup/selftest.sh)).

Step by step instead:

```bash
make up          # preflight (tools, AWS identity) + terraform init + ONE terraform apply
make verify      # every R-ID checked against live AWS, then terraform plan must show no changes
make e2e         # E2E_CONFIRM=yes required: write/read, ro proof with the mount flag off, persistence
CONFIRM_DESTROY_DATA=yes make down   # deletes everything, INCLUDING the EFS data, then sweeps for leftovers
```

`make up AUTO=1` skips the apply prompt.

### Account and region (required before `make up`)

Create `account.auto.tfvars` in the repo root (git-ignored, so it never leaves your machine):

```hcl
allowed_account_id = "<12-digit AWS account ID>"   # the ONLY account Terraform may touch
region             = "ap-southeast-2"              # optional; the code default is us-east-1
```

`make up` refuses to run without the file, or if your AWS credentials resolve to any other account, and the provider repeats the check, so a mismatched login fails before anything is created.

**The live proof of 2026-10-25 deployed to `ap-southeast-2` (Sydney), account `445137568806`**, set through that file. Without a `region` line, the default is `us-east-1`; `TF_VAR_region=<region>` also overrides it. Region is not baked into any resource name, so any region with at least 2 AZs works, but only Sydney has been run.

### Updating one component

`make apply-one CHILD=<network|security|efs|backup|images|apps>`. The full component → child map is in [docs/COMPONENTS.md](docs/COMPONENTS.md).

### Why `make down` isn't `terraform destroy`

The EFS has `prevent_destroy = true` (R4), and Terraform does not allow that to be switched off by a variable. [scripts/teardown.sh](scripts/teardown.sh) removes the file system from state, destroys everything else, deletes the EFS by API, then lists anything still tagged `Project=sefs`.

## What it does

| Action | Expected result | R-ID |
|---|---|---|
| `make up` | VPC across ≥2 AZs, public + private subnets, NAT per AZ | R5 |
| Apps start | Both services in private subnets, no public IP, both on `sg-apps` | R6, R8 |
| EFS reachable | One mount target per private AZ; `sg-efs` admits only TCP 2049 from `sg-apps` | R7, R9 |
| Writer runs | Writes `/mnt/shared/<time>-<uuid>.json` atomically as 1001:1000 | R2, R10 |
| Reader runs | Reads every file at the **same** path as 1002:1000; writes are denied | R3, R10 |
| EFS settings | Encrypted (AWS-managed key or CMK), General Purpose, Bursting, IA after 30 days | R12, R13, R15 |
| Backup | Daily AWS Backup, kept 35 days | R14 |
| Destroy the apps | Data is still on the EFS; apps re-attach on the next apply | R1, R4 |

### Spec drift: read-only reader

An EFS access point has **no read-only setting**; it only sets the user, group and directory. A container `readOnly` flag is easy to remove, and the shared directory is group-writable by design. The read-only guarantee is therefore enforced by IAM: the reader's role can only mount, and the file-system policy explicitly denies it write and root access. `make e2e` proves this by running the reader's role with the mount flag **off**; the write must still fail. Full write-up: [docs/DECISIONS.md](docs/DECISIONS.md#spec-drift-read-only-on-an-access-point).

## Interface

| Command | What | Touches AWS |
|---|---|---|
| `make up` | Deploy everything | yes (creates) |
| `make apply-one CHILD=x` | Update one child module | yes (changes) |
| `make plan` | Show pending changes | read-only |
| `make test` | Unit + mutation + Docker contract | no |
| `make verify` | Live R-ID check + no-drift plan | read-only |
| `make e2e` | Live behaviour proofs (`E2E_CONFIRM=yes`) | yes (runs a one-off task, destroys + re-applies apps) |
| `make down` | Delete everything (`CONFIRM_DESTROY_DATA=yes`) | yes (deletes) |

Mother inputs are in [variables.tf](variables.tf) (all have defaults); outputs in [outputs.tf](outputs.tf).

## Bruno collection (live, read-only, self-hydrating)

[bruno/sefs](bruno/sefs) checks every requirement against the live deployment by calling the AWS APIs directly (SigV4). It holds **no credentials**: requests sign with the `sefs-bruno` AWS profile, whose `credential_process` ([scripts/bruno-creds.sh](scripts/bruno-creds.sh)) assumes the least-privilege role `sefs-bruno-reader` ([modules/access](modules/access/main.tf), read-only, SSM scoped to `/sefs/*`) through your own login. Folder `00-hydrate` reads every deployed ID from SSM (`/sefs/outputs/*`, published by [modules/registry](modules/registry/main.tf)); nothing is typed by hand.

```bash
make bruno-profile SOURCE=<your AWS login profile>   # once (setup.sh does this)
make bruno                                           # bru run bruno/sefs --env aws
```

| Folder | Checks |
|---|---|
| `00-hydrate` | SSM outputs → runtime vars (prerequisite) |
| `01-storage` | R12 R13 R4 R15 R7 R10 R2/R3 (same path) R3 (FS policy Deny) + auto-backups off |
| `02-network` | R9 (sg-efs: one rule, 2049 from sg-apps), R8 (sg-apps: no ingress) |
| `03-compute` | R6 R8 (services), R3 (reader readOnly + IAM auth + same role the policy denies), R2 (writer rw) |
| `04-backup` | R14 (plan ≥ 35 days, selection covers the EFS) |
| `05-behaviour` | R2 WROTE lines, R3/R1 READ lines match sha256, reader WRITE_PROBE DENIED |

Honest limits: R13's "AWS-managed key" alias check and the IAM mutation (write denied with the mount flag off) are not in Bruno; `make verify` and `make e2e` cover them.

## Tests

All local tests are free and need no AWS account: the unit tests use Terraform's mock provider with network access blocked, so a passing run made no AWS call.

```bash
make test-unit       # terraform test on mocked AWS, one run per R-ID
make test-mutation   # breaks each guard in a temp copy; every break must be caught
make test-contract   # Docker: writer + reader on one volume, as their real UIDs
```

| Suite | Result on `main` (2026-10-25) |
|---|---|
| Unit | 23/23 plan-mode + 4/4 apply-mode (mocked) + static `prevent_destroy` check — all pass |
| Mutation | 28/28 deliberate breaks caught (every R-ID with a code guard, plus "EFS auto-backups off"); a no-op control break correctly survives |
| Contract (Docker) | 16/16 assertions pass; with the reader mounted rw the suite fails, as it should |
| Live verifier / e2e | Run 2026-10-25 against real AWS (ap-southeast-2): `make verify` 15/15 PASS + zero drift (before and after the rebuild); `make e2e` E1–E4 all PASS. See below |

### Live run (2026-10-25, account 445137568806, ap-southeast-2)

| Proof | Result |
|---|---|
| `make up` from empty state | 55 resources, one apply, ~8 min |
| `make verify` | 15/15 PASS; `terraform plan` exit 0 (no drift), re-checked after the apps were rebuilt |
| E1 writer → reader | 40 files, every sha256 identical |
| E3 reader write with `readOnly=false` | Denied. The kernel showed the mount `rw` and POSIX allowed the write (`drwxrwxr-x`, group 1000, reader gid 1000), so only the EFS file-system policy could refuse it |
| E4 destroy + re-apply the apps | All 46 pre-existing files read back intact; file system unchanged |
| `make down` | 54 destroyed + EFS deleted + inactive task definitions deleted; per-service sweep clean; account re-checked independently |

Found only by the live run, since fixed: parallel `docker login` collided in the macOS keychain (-25299), leaving the first `make up` at 52/55; teardown missed INACTIVE task definitions; `verify.sh` misread `tostring(null)` as a configured CMK.

**Not established:** the errno EFS returns for a missing `ClientWrite` is not documented by AWS. Observed here: `EROFS`. There is no control run of the same readOnly=false task using the *writer* role; E1 (the writer writing 40 files) is the nearest evidence. Backup jobs were not run (the daily schedule never fired in the test window), so R14 is proven as configuration, not as a completed backup.

Requirement → code → test mapping: [docs/TRACEABILITY.md](docs/TRACEABILITY.md).

## Layout

| Path | What |
|---|---|
| [main.tf](main.tf) | The mother: wires every child module |
| [modules/network](modules/network) | VPC, subnets, NAT, routes |
| [modules/security](modules/security) | `sg-apps`, `sg-efs`, the 2049 rule |
| [modules/efs](modules/efs/main.tf) | File system, mount targets, access points, IA lifecycle, `prevent_destroy` |
| [modules/efs/policy](modules/efs/policy/main.tf) | File-system policy (the read-only control) |
| [modules/backup](modules/backup/main.tf) | Vault, 35-day plan, selection, role |
| [modules/images](modules/images/main.tf) | ECR repos + build/push during apply |
| [modules/apps](modules/apps/main.tf) | ECS cluster, task definitions, task roles, services |
| [apps/writer-python](apps/writer-python/writer.py) | Writer |
| [apps/reader-springboot](apps/reader-springboot/src/main/java/com/sefs/reader/SharedDirPoller.java) | Reader |
| [scripts/teardown.sh](scripts/teardown.sh) | Full delete including data |
| [tests/unit](tests/unit) · [tests/mutation](tests/mutation/run.sh) · [tests/contract](tests/contract) · [tests/live](tests/live) | Test suites |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Every non-obvious choice and the spec drift |
| [docs/COMPONENTS.md](docs/COMPONENTS.md) | Which child updates which component |
| [docs/CONTRACTS.md](docs/CONTRACTS.md) | Module interfaces and behaviour |
| [docs/TRACEABILITY.md](docs/TRACEABILITY.md) | R-ID → code → test |
| [PLAN.md](PLAN.md) | Requirements and plan |

## Notes on design decisions

**One state, not one per layer.** Separate states would put the EFS out of reach of an apps destroy by construction. But "one apply deploys everything" would then become a script running several applies, and cross-layer wiring would go through remote-state lookups. Here the EFS is protected by `prevent_destroy` instead, and every component can still be applied on its own with `-target`.

**Images build inside the apply.** The usual alternative is to push images first and then apply. That needs the ECR repo to exist first, which means two applies, so deploying would no longer be one step. A `terraform_data` resource builds and pushes when the app source changes, and the task definitions take the pushed tag.

**Apps wait for the file-system policy.** An EFS with no policy lets any client that can reach it write. If the reader mounted before the deny policy existed, it would keep write access for the life of the mount. Both services depend on the policy and the mount targets.

**Task roles use generated names.** The EFS policy names the roles by ARN, and AWS pins that to the role's internal ID. A role recreated under the same name would keep its ARN, Terraform would see nothing to update, and the role would be locked out. Generated names give a new ARN, which forces the policy update in the same apply.

# SEFS — Shared EFS for a Python writer and a Spring Boot reader

One Terraform apply builds, in your AWS account, a multi-AZ VPC, an encrypted EFS shared by two ECS Fargate apps (a Python writer and a Spring Boot reader on the same path, the reader unable to write), 35-day backups, an IA lifecycle, alarms and a dashboard, a read-only verification role, a login-gated 2.5D map of the live stack, and the state/CI plumbing so that every later change deploys itself from a push to `main`.
Implements [Shared EFS for Multi-App.docx](Shared%20EFS%20for%20Multi-App.docx); requirements are numbered R1–R15 in [PLAN.md §1](PLAN.md#1-requirements-numbered-so-every-file-and-test-can-cite-one). Agents: read [AGENTS.md](AGENTS.md) first.

**Run this single command and enter inputs where requested:** `./sefs setup` (after signing in to AWS in your shell). Everything else is `./sefs <verb>`; `./sefs help` lists them. [sefs](sefs) is a thin wrapper over [setup.sh](setup.sh), the [Makefile](Makefile) and the SSM registry; the longer steps below are the same thing spelled out.

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
  browser ──Cognito login──► CloudFront ──► S3 page (2.5D map)
          ──JWT──► HTTP API ──► Lambda (read-only role) ──► the stack above, by tag + SSM
```

Nothing is emulated: it needs a **real AWS account** and, for the automation, a **GitHub repository you own**. Container images and the map's page are built on your machine (or the GitHub runner) inside the apply.

## Prerequisites

- An AWS account you can administer, and a login for it (`aws login`, SSO or keys). The deploy needs rights to create VPC, EFS, ECS, ECR, IAM roles, AWS Backup, CloudWatch, SNS, SSM, S3, DynamoDB, and for the map: Cognito, CloudFront, Lambda and API Gateway.
- A GitHub repository you own (empty is fine) to hold your copy of this code; the CI deploy role is trusted by that one repo and its `main` branch only.
- Terraform ≥ 1.9 (tested 1.9.8; provider `hashicorp/aws` 6.70.0 pinned in [.terraform.lock.hcl](.terraform.lock.hcl)), Docker with `buildx` (tested 29.8.2), AWS CLI v2, `jq`, `make`, `bash`. macOS and Linux as-is; Windows via WSL2. Optional: `gh` (lets `setup.sh` resolve your repo's numeric IDs for the CI trust automatically), `bru` (Bruno CLI).
- Uplink of roughly ≥ 250 KB/s: `make up` pushes ~290 MB of images, bounded by a 20-minute watchdog × 3 attempts. A healthy link pushes in under 7 min; a 35 KB/s link crawled for 2 h and broke (measured 2026-10-25). GitHub's runners have no such problem.
- No inbound ports, no domain, no load balancer.

The host does **not** need Java, Maven, Python or Node: both apps and the map's page build inside Docker (pinned images; the Node image is ~50 MB on first use).

## Run it

1. Create an empty repository on GitHub (say `you/sefs`), then:
   ```bash
   git clone https://github.com/mabdullah679/SEFS.git sefs && cd sefs
   git remote set-url origin https://github.com/you/sefs.git && git push -u origin main
   ```
2. Sign in to AWS in your shell (for example `aws login --profile work`, then `export AWS_PROFILE=work`).
3. One command:
   ```bash
   ./sefs setup        # same as ./setup.sh
   ```
   It checks the tools, shows the account your credentials resolve to and asks you to confirm it, asks for the region, an alarm e-mail (optional), the map's login e-mail (blank = the alarm e-mail; Cognito mails that address a temporary password) and your GitHub repo (`you/sefs`), writes the git-ignored `account.auto.tfvars`, creates the state bucket, lock table and CI role (once), prompts for any secret in [secrets.manifest](secrets.manifest) (none today) and stores it only in SSM, then runs `make up` (≈ 8 min). `./setup.sh --no-deploy` stops before the deploy.
   Every answer you type is remembered for **24 hours from the moment you entered it, for the current boot session only** (`~/.cache/sefs/inputs.tsv`, keyed by the kernel boot time, so a restart, reboot or shutdown forgets everything); a re-run replays them and shows each one as `(cached answer …)`. Secrets are never remembered. `./sefs forget` clears the cache; `SEFS_NO_CACHE=1` ignores it for one run. Proven by `make test-setup` S6–S9.
4. Wire CI once. `./sefs setup` prints the five values and, if the GitHub CLI is signed in, sets them for you when you answer `y`. Otherwise in GitHub → Settings → Secrets and variables → Actions → **Variables**, add `AWS_REGION`, `AWS_ACCOUNT_ID`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_LOCK_TABLE` from `setup.sh`'s final output (no secrets: OIDC replaces keys). Details: [docs/CI.md](docs/CI.md#one-time-setup-owner-10-min).
5. From now on, push to `main` with the whole word **`check`** in the commit message (`checks`/`checked` do not count): the changed children redeploy and the live checks run. `check full` redeploys everything.

Identical on macOS, Linux and WSL2 (`./sefs <verb>` and `make <verb>` are the same thing):

```bash
./sefs show efs                        # any deployed ID by keyword (efs, subnet, cluster, log, backup, ...) from SSM
./sefs status                          # services, file system, alarms, credits burned, on one screen; also: logs writer|reader, alarms, url
./sefs burn                            # how long the stack has been up and ≈ what it has cost so far (US$0.174/h); US$0 when nothing is deployed
./sefs map                             # the 2.5D map's address; sign in with the e-mailed user, hover for health, click a resource to open its room
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
- The map's login mail never arrived: the user is created only when `gui_admin_email` is set; `./sefs map` prints the address, and `aws cognito-idp admin-create-user` adds another user. `enable_gui = false` in `account.auto.tfvars` removes the map entirely.
- `make up` fails inside the map's build step: Docker must be running and able to pull `node:22.12.0-alpine3.20`; `make test-web` runs that step alone.

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
| Open the map | Sign in (Cognito, PKCE); a 2.5D plate per VPC, a column per AZ (NAT above, tasks below), the EFS slab with a mount target per AZ and both access points, backup and cluster beside it; every box coloured by live health; hover for facts, click to open the EFS / ECS / VPC / Backup room; cost panel (rates per minute, hour, 30 days, plus real spend), alarms, log tail | D23, D25, D32 |

### Spec drift: read-only reader

An EFS access point has **no read-only setting**; it only sets user, group and directory. A container `readOnly` flag is easy to remove, and the shared directory is group-writable by design. The read-only guarantee is enforced by IAM instead: the reader's role can only mount, and the file-system policy explicitly denies it write and root access. `make e2e` proves it by running the reader's role with the mount flag **off**; the write still fails. Write-up: [docs/DECISIONS.md](docs/DECISIONS.md#spec-drift-read-only-on-an-access-point).

## Interface

| Command | What | Touches AWS |
|---|---|---|
| `./setup.sh` | Fresh-clone setup, end to end | yes (creates) |
| `make up` | Deploy everything (one apply) | yes (creates) |
| `make apply-one CHILD=x` | Update one child ([docs/COMPONENTS.md](docs/COMPONENTS.md)) | yes (changes) |
| `make plan` | Show pending changes | read-only |
| `make test` | Unit + mutation + Docker contract + setup self-test + map API + map page build | no |
| `make test-api` / `make test-web` | The map's API on a fake boto3 / the page built in Docker as the apply builds it | no |
| `./sefs map` · `GET <api>/api/{overview,room/*,cost,logs}` | The map and its JSON (Cognito JWT required; GET only) | read-only |
| `make verify` | Live checks + no-drift plan | read-only |
| `E2E_CONFIRM=yes make e2e` | Live behaviour proofs | yes (one-off task; destroys + re-applies apps) |
| `make bruno` | Bruno collection against the live stack | read-only (assumed role) |
| `make bootstrap` / `make tf-profile` / `make bruno-profile` | One-time helpers | bootstrap: yes; profiles: no |
| `CONFIRM_DESTROY_DATA=yes make down` | Delete everything (+`DESTROY_STATE=yes` for the state bucket) | yes (deletes) |
| push to `main` with `check` / `check full` | CI deploy + verify | yes |

Inputs: [variables.tf](variables.tf) (all with defaults; your values go in `account.auto.tfvars`; `enable_gui`, `gui_admin_email`, `activate_cost_allocation_tag` govern the map). Outputs: [outputs.tf](outputs.tf), also published to SSM `/sefs/outputs/*` (`gui_url`, `gui_api_url` included).

## Bruno collection (live, read-only, self-hydrating)

[bruno/sefs](bruno/sefs) checks every requirement by calling the AWS APIs directly (SigV4). It holds **no credentials**: requests sign with the `sefs-bruno` profile, whose `credential_process` ([scripts/bruno-creds.sh](scripts/bruno-creds.sh)) assumes the least-privilege role `sefs-bruno-reader` ([modules/access](modules/access/main.tf)) through your own login. Folder `00-hydrate` reads every deployed ID from SSM; nothing is typed by hand. Folders: `01-storage` (R12 R13 R4 R15 R7 R10 R2/R3), `02-network` (R9 R8), `03-compute` (R6 R8 R3 R2), `04-backup` (R14), `05-behaviour` (WROTE/READ lines over the last 10 minutes; the write probe read from the head of the reader's current log stream, because CloudWatch answers wide `FilterLogEvents` windows with an empty first page). Not in Bruno: the AWS-managed-key alias check and the IAM mutation; `make verify` and `make e2e` cover those. `bru run` must start inside `bruno/sefs`; `make bruno` does that.

## Running cost

`make cost` fetches today's rates from the AWS Pricing API for your region ([scripts/cost.py](scripts/cost.py)); quantities mirror the Terraform code. It runs in about half a minute (the EC2 query is narrowed to the NAT Gateway family; unfiltered it downloaded for 47 minutes on a slow uplink). Measured for `ap-southeast-2` on 2026-10-26 (published rates, not an invoice):

| Item | $/hour |
|---|---|
| 2 NAT gateways + their public IPv4 | 0.128 |
| Fargate ARM (0.75 vCPU, 1.5 GB) | 0.036 |
| 10 alarms + Container Insights metrics | 0.010 |
| EFS, logs, ECR, backup storage at proof volumes | 0.001 |
| **Total** | **0.174 per hour · 0.0029 per minute · 125.23 per 30 days** |

**The stack burns this for every hour it is left up**, credits included: about US$4.20 a day. `make up` and `setup.sh` say so when they finish, `./sefs status` and `./sefs burn` show the running total (from the EFS creation time × the rate above; `SEFS_RATE_PER_HOUR` overrides the rate after a `make cost` in another region), and `CONFIRM_DESTROY_DATA=yes make down` is the end of every test session. A CI `check` push leaves the stack up too. Three quarters of it is the two NAT gateways; `nat_per_az = false` halves that line. Not metered: VPC, security groups, IAM, SNS at this volume, SSM, the state bucket and lock table (cents), NAT data processing (image pulls ≈ 0.5 GB per fresh deploy), GitHub Actions minutes (free for public repos). A 30-day figure from Cost Explorer actuals needs a stack that has run for days; this one has not, so the 30-day number above is rate × 720 h.

## Tests

Local suites are free and need no AWS account (mock provider, network blocked):

```bash
make test-unit       # terraform test on mocked AWS, one run per requirement
make test-mutation   # breaks each guard in a temp copy; every break must be caught
make test-contract   # Docker: writer + reader on one volume, as their real UIDs
make test-setup      # setup.sh with a fake aws: a secret never touches argv or disk; prompt answers cached per boot
make test-api        # the map's API on a fake boto3 that refuses any non-read call
make test-web        # the map's page compiled in the pinned Node container, as the apply does it
```

| Suite | Result on `main` (2026-10-25) |
|---|---|
| Unit | 51/51 main (2026-10-27, incl. `gui.tftest.hcl` 6 runs) + 4/4 apply-mode (mocked) + static `prevent_destroy` check |
| Mutation | 48/48 deliberate breaks caught; a no-op control break correctly survives; map rows g01–g07 (see the ledger line below) |
| Map API (fake boto3) | 18/18: discovery, health rules (R9 on sg-efs, running ≥ desired, alarm states), rooms, rates + 24 h SSM cache + Cost Explorer failure reported not faked, logs filtered to contract lines, bad input → 400, non-read calls refused |
| Contract (Docker) | 16/16; with the reader mounted rw it fails, as it should |
| Setup self-test | 9/9 (2026-10-27: S6–S9 cover the 24 h per-boot input cache); mutation-proven (boot check, 24 h expiry, cache off, secret through the cache: 4/4 killed) |
| CI mapper self-test | 9/9; mutation-proven |
| Live verifier self-test | 29/29 scenarios (stub AWS) |
| Live (`ap-southeast-2`, 2026-10-25) | `make up` 55 resources ≈ 8 min; `make verify` 15/15 + zero drift; e2e E1–E4 pass (40 files round-tripped; reader denied with `readOnly=false`; 46 files survived destroy/re-apply); `make down` clean, account re-checked independently |
| GitHub Actions `check` (run 40216156247) | OIDC → shared state → full apply → zero drift → verify **16/16** incl. observability; deploy job 1 m 47 s |
| Bruno (live, 2026-10-26, against the CI-deployed stack) | 20 requests, **58/58** tests under the `sefs-bruno-reader` role; negative control with bogus security-group IDs fails R9 and the group-exists check, as it should |
| `./sefs` wrapper, whole workflow (live, 2026-10-26, CI-deployed stack) | `preflight` → `plan` (clean) → `verify` 16/16 → `e2e` E1–E4 PASS (89 files round-tripped; `EROFS` on both probes; 92 files survived destroy/re-apply) → `bruno` 58/58 → `cost` → `up` (no-op: 0 changed) → `plan` (clean) → `down`; every read verb (`show`, `status`, `alarms`, `logs`, `url`) answered from the live registry |
| GitHub Actions `check` (run 40261693403) | first run after the deploy job moved behind the `production` approval: OIDC with the environment subject → empty state → full apply → zero drift → verify 16/16 |

**Not established:** a fresh-machine `./sefs setup` run end to end by someone other than the author (every step is self-tested and the pieces are live-proven, but the single-command path on a clean laptop is yours to confirm); the errno EFS returns for a denied write is undocumented (observed `EROFS`); no backup job has been observed completing (R14 is proven as configuration); no writer-role control run for the IAM mutation. Mapping: [docs/TRACEABILITY.md](docs/TRACEABILITY.md).

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
| [modules/gui](modules/gui/main.tf) · [api/app.py](modules/gui/api/app.py) · [web/src](modules/gui/web/src) · [build.sh](modules/gui/build.sh) | The map: Cognito, CloudFront + S3, HTTP API + Lambda (read-only); the data API; the TypeScript/three.js page; the in-apply page build |
| [modules/bootstrap](modules/bootstrap/main.tf) · [bootstrap/](bootstrap/main.tf) | State bucket, lock table, GitHub OIDC deploy role (once, local state) |
| [apps/writer-python](apps/writer-python/writer.py) · [apps/reader-springboot](apps/reader-springboot/src/main/java/com/sefs/reader/SharedDirPoller.java) | The two apps |
| [sefs](sefs) · [setup.sh](setup.sh) · [Makefile](Makefile) · [scripts/](scripts) | The one command (wrapper + keyword reads from SSM); fresh-clone setup; targets; teardown, orphan adoption, credential-free profiles, CI change mapper |
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

**The map scores health on the server, not in the browser.** The API applies the same rules the verifier does (sg-efs admits 2049 from sg-apps only, running ≥ desired, alarm state) and the page only colours what it is told; one place holds the rules. The alternative, a page that reads AWS directly, would need AWS credentials in the browser or a wide role; instead the page holds a Cognito token and the Lambda holds a role that can only read.

**The page is compiled during the apply, from a lock file, in a pinned container.** A bundler would add tooling to pin for one entry point; `tsc` plus an import map to a vendored copy of three.js is enough and keeps the client's browser off any CDN (D27). A pre-built bundle committed to git would be a 700 KB binary-like blob the repo forbids (D24).

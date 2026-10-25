# Decisions ledger

Settled decisions, newest last. Each says who decided, when, and what the obvious alternative was.

| # | Date | By | Decision | Alternative rejected, and why |
|---|---|---|---|---|
| D1 | 2026-10-25 | owner | Compute = **ECS Fargate** | EKS: cluster + EFS CSI driver to build and prove, for no gain here. EC2: OS patching, and ro is harder to enforce |
| D2 | 2026-10-25 | owner | **Mother root + child modules, one state** (reverses an earlier "separate stacks" answer) | Separate state per stack: more moving parts, and "one apply deploys everything" becomes "one script runs N applies" |
| D3 | 2026-10-25 | owner | Cost/hour is not a constraint; destroy as soon as single-command deploy is proven | — |
| D4 | 2026-10-25 | owner | Tests on fake AWS (mock provider) **and** real AWS | — |
| D5 | 2026-10-25 | owner | Read-only gap documented as **spec drift** with compensating control (below) | Pretending the access point enforces ro |
| D6 | 2026-10-25 | lead | `make up` is the entry point; images build + push **inside** the apply (`terraform_data` + `local-exec`) so one `terraform apply` deploys everything | A pre-apply `docker push` step: makes infra not the only spin-up step, and the ECR repo would have to exist first (two applies) |
| D7 | 2026-10-25 | lead | NAT per AZ (`nat_per_az = true`) | Single NAT: cheaper, but D3 removed cost as a constraint and the spec diagram shows NAT per public subnet |
| D8 | 2026-10-25 | lead | Fargate **ARM64**, images `linux/arm64` | x86_64: the M1 host would build under emulation (slow, a different binary than tested locally) |
| D9 | 2026-10-25 | lead | Shared GID 1000; writer 1001, reader 1002; both APs rooted at `/shared`, `0775` | Same UID for both: hides which app did what, and the reader's write-denial would rest on nothing but POSIX ownership |
| D10 | 2026-10-25 | lead | Transit encryption ON + IAM-authorized mounts (not in spec) | Off: IAM authorization requires it, and without IAM there is no real ro control |
| D11 | 2026-10-25 | lead | `aws_efs_backup_policy = DISABLED`; R14 met by our own AWS Backup vault/plan | EFS automatic backups: they create an AWS-owned default vault Terraform doesn't track, which survives teardown |
| D12 | 2026-10-25 | lead | No ALB | The diagram mentions one but nothing needs inbound HTTP. Listed as future work |
| D13 | 2026-10-25 | lead | Real-AWS layer = live verifier + `terraform plan` shows no changes + e2e, **not** apply-mode `terraform test` | `prevent_destroy` makes apply-mode `terraform test` fail at its auto-cleanup, even with mocks (observed on TF 1.9.8) |
| D14 | 2026-10-25 | lead | Teardown: `state rm` the EFS → `terraform destroy` → delete the EFS via CLI → tag sweep; gated by `CONFIRM_DESTROY_DATA=yes` | Variable-driven `prevent_destroy`: Terraform requires a literal there, by design |
| D15 | 2026-10-25 | lead | Task roles use `name_prefix` | Fixed names: a replaced role keeps its ARN, the FS policy doesn't update, and AWS's stored principal ID goes stale, locking the role out of the EFS |
| D16 | 2026-10-25 | lead | Network: `az_count` capped at 8 (subnet slicing), and public subnets don't auto-assign public IPs | Uncapped: subnets would overlap above 8 AZs. Public IPs: nothing needs them; the NATs use their own EIPs |
| D17 | 2026-10-25 | owner | Live proof runs in account **445137568806 ("production")**, region **ap-southeast-2**, after the lead flagged it is the prod-named account | The "Costs and Credits" account (346208529954): owner chose the current session. Isolation: own VPC, all resources tagged `Project=sefs`, teardown deletes only Terraform-tracked + tagged resources |
| D18 | 2026-10-25 | owner | Final-vision build is gated by the owner on `/usage`; lead works one item at a time in small stoppable chunks, no agent fan-out without an explicit go | Agent fleet: fastest, but the lead cannot read usage meters, so a fan-out could overrun the owner's budget unseen |
| D19 | 2026-10-25 | lead | Secrets: none exist today. `setup.sh` prompts from `secrets.manifest` (empty) and stores each ONLY as an SSM SecureString under `/<name>/secrets/`, streamed on stdin; Terraform never creates secrets | Terraform-managed secrets: values land in state. A verifier IAM user with stored keys: circular, Bruno needs an AWS login to read SSM anyway |
| D20 | 2026-10-25 | owner | Change-driven CI runs on **GitHub Actions** (owner's acronym: GHA): push to `main` with "check" in the commit message → detect changed children → apply only those (full mother if root files changed) → verify | Local Jenkins: the owner's usual free path, but a client cloning the repo has no Jenkins; GHA ships with the repo |
| D21 | 2026-10-25 | lead | Bruno auth = AWS profile `sefs-bruno` with a `credential_process` that assumes `sefs-bruno-reader` through the client's own login (Bruno's awsv4 uses the SDK's `fromIni`, which runs credential_process; proven with a stub) | Temporary keys exported into the shell or an env file: works for the CLI only, and the keys sit in process env/history. A `role_arn`+`source_profile` profile: depends on the SDK understanding the client's login type (`aws login` sessions are new); credential_process delegates that to the CLI, which always does |

## Spec drift: "read-only" on an access point

**What the spec implies:** the Spring Boot reader can be given read-only access at the access point.
**What AWS actually provides:** an access point sets POSIX user/group and root directory only. It has no read-only option.
**Why a mount flag isn't enough:** ECS `readOnly = true` is a container setting; anyone who edits the task definition removes it. The shared directory is group-writable (`0775`, GID 1000) by design, so POSIX permissions alone would let the reader write.
**Compensating control (code):**
1. IAM-authorized mounts with transit encryption ([modules/apps/main.tf](../modules/apps/main.tf)).
2. Reader task role: `ClientMount` only, scoped to the reader access point ([modules/apps/main.tf](../modules/apps/main.tf)).
3. File-system policy with an **explicit, unconditional Deny** of `ClientWrite` + `ClientRootAccess` for the reader role ([modules/efs/policy/main.tf](../modules/efs/policy/main.tf)). An explicit Deny overrides any Allow, so a later grant on the role can't reopen write.
4. Services are gated on the FS policy existing ([modules/apps/main.tf](../modules/apps/main.tf), `terraform_data.efs_ready`). EFS with no policy allows any client to write, so a reader that mounted first would keep write access.

**Proof:** a live test runs the reader role with the mount flag switched **off**; the write must still be denied (`tests/live/e2e.sh`).

## Known limits (not defects, recorded honestly)
- The reader's in-memory "already read" set grows without bound. Fine for a proof deployment; a real service would checkpoint.
- Replacing the FS policy or mount targets later re-creates the readiness gate but does not restart running tasks.

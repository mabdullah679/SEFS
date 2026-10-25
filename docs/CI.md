# CI: push to `main` with "check"

Owner's intent (2026-10-25): set the project up once; afterwards, pushing to `main` with the word **check** in the commit message redeploys whatever changed and re-verifies, so you read results instead of fighting the system.

## What a "check" push does

`check full` in the message forces a full apply regardless of which paths changed (use it after a failed or cancelled run, or when a child was added).

1. **Unit job** (every push, no AWS): `tests/unit/run.sh` (mocked Terraform), `tests/ci/selftest.sh`.
2. **Deploy job** (only if the commit message contains `check`):
   - assumes the deploy role via OIDC (no AWS keys in GitHub),
   - `scripts/changed-children.sh <before> <head>` maps changed paths to child modules ([COMPONENTS.md](COMPONENTS.md) is the human version):
     `modules/<x>/**` → `x`; `apps/**` → `images apps`; root `*.tf`/`*.tfvars` → **full**; docs/tests/bruno/scripts → **none**; anything unknown → **full** (fail safe),
   - `terraform init` against the shared S3 state, then `apply -target=module.<child>…`, or a full apply, or nothing,
   - `terraform plan -detailed-exitcode` must be clean afterwards (a targeted apply must leave no drift),
   - `tests/live/verify.sh`: every R-ID against live AWS.

Concurrency: one deploy at a time (`concurrency: sefs-deploy`), and the DynamoDB lock protects against a laptop apply colliding with CI.

## One-time setup (owner, ~10 min)

1. `./setup.sh` → at step 3b answer the GitHub repo as `owner/repo`. This runs `make bootstrap GITHUB_REPO=owner/repo`, which creates, with **local** state in [`bootstrap/`](../bootstrap/main.tf):
   - state bucket `sefs-tfstate-<account>-<region>` (versioned, encrypted, private, TLS-only),
   - lock table `sefs-tfstate-lock`,
   - GitHub OIDC provider + role `sefs-github-deploy`, trusted **only** by `repo:owner/repo:ref:refs/heads/main`,
   and writes `backend.hcl` (git-ignored). Keep `bootstrap/terraform.tfstate`: it is the only record of the state bucket.
2. In the GitHub repo → Settings → Secrets and variables → Actions → **Variables**:

   | Variable | Value |
   |---|---|
   | `AWS_REGION` | e.g. `ap-southeast-2` |
   | `AWS_ACCOUNT_ID` | the 12-digit account (the Terraform account guard reads it) |
   | `AWS_DEPLOY_ROLE_ARN` | `make -C bootstrap output` → `github_deploy_role_arn` |
   | `TF_STATE_BUCKET` | `bootstrap` output `state_bucket` |
   | `TF_LOCK_TABLE` | `bootstrap` output `lock_table` |

   No secrets are needed: OIDC replaces access keys.
3. Push to `main` with `check` in the message.

Already have a GitHub OIDC provider in the account? AWS allows one per issuer: run bootstrap with `-var create_oidc_provider=false`.

## Local workflow after bootstrap

`make up`, `make apply-one CHILD=x`, `make down` all use the shared state (`make init` refuses to run without `backend.hcl`). Offline suites (`make test`) never touch the backend.

## Teardown

`CONFIRM_DESTROY_DATA=yes make down` removes the deployment but **keeps** the state bucket, lock table and CI role. Add `DESTROY_STATE=yes` to remove those too (the bucket is versioned, so this needs the explicit flag).

## Five things learned the hard way

- **A watchdog must not hold Terraform's pipes.** The image-push watchdog's `sleep` inherited the local-exec stdout; Terraform waits for EOF, so a push that finished in 1 minute "completed" after the full 40-minute timeout. Now the watchdog runs with its fds detached and its `sleep` is killed explicitly; the proof runs the loop under `$(...)` and times it.
- **A cancelled apply can orphan ECS services.** AWS had `sefs-writer`/`sefs-reader`, state did not, and the next `CreateService` failed ("not idempotent"). `scripts/adopt-orphans.sh` imports such services before every apply (`make up` and CI).

- **GitHub's `sub` claim carries numeric IDs.** Observed 2026-10-25 on the first "check" run: `repo:mabdullah679@131607929/SEFS@1433201237:ref:refs/heads/main`, not the documented `repo:owner/repo:ref:...`. IAM therefore refused the ID-less trust ("Not authorized to perform sts:AssumeRoleWithWebIdentity"). The role now trusts the exact ID-pinned string (plus the plain form), still `StringEquals`, no wildcards; `make bootstrap` resolves both IDs with `gh api`. The workflow prints `iss/aud/sub` (never the token) before assuming the role so a future format change is visible in one glance.

- **`aws login` sessions and the S3 backend.** Terraform 1.9's built-in backend cannot read the `login_session` profile type; the provider can. `make tf-profile SOURCE=<login profile>` creates `sefs-tf`, a `credential_process` helper that exports the same session, and `make preflight` refuses to run on a `login_session` profile. CI is unaffected (OIDC puts credentials in the environment).
- **Offline suites after `make init`.** Once the S3 backend is initialised in `.terraform/`, `terraform init -backend=false` *reuses* it and demands credentials. The unit and mutation runners therefore set their own `TF_DATA_DIR`, so `make test` works with no AWS access at all.

## Honest limits

- **Deploy role breadth.** `sefs-github-deploy` holds `PowerUserAccess` plus IAM limited to `role/sefs-*`, and an explicit Deny on itself. That is broad: the stack creates VPC, EFS, ECS, ECR, Backup, Logs and SSM resources, and AWS offers no practical resource-level scoping for most create calls. The control that actually bounds it is the trust policy (one repo, one branch) and the fact that CI never manages the bootstrap stack.
- **`-target` is Terraform's "exceptional use" flag.** The post-apply clean-plan check is what makes targeted applies safe here; if it fails, the run fails and the next push should be a full apply (touch a root file or run `make up` locally).
- **Not yet run on GitHub.** Everything here is unit-/self-tested locally (bootstrap module 6 runs, mapper 9 cases, workflow YAML parsed). The first real "check" push is the live proof and needs the owner's repo.
- **Runner architecture.** Images are `linux/arm64`; the x86 runner builds them under QEMU (slower). A fresh runner has no Docker layer cache, so every "check" that touches `apps/` rebuilds from scratch.

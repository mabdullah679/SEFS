# CLAUDE.md — SEFS

Standing owner rules live in `~/.claude/CLAUDE.md` (read it; not copied here). The full picture of this repo is [AGENTS.md](AGENTS.md); read it before changing anything.

What this is: Terraform that deploys a shared EFS used by a Python writer and a Spring Boot reader on ECS Fargate (reader read-only by IAM policy, not by a flag), plus an optional 2.5D map. `./sefs local` runs the same two apps in Docker with no AWS.

## Commands (run on 2026-11-18 at the PR's base; all offline, no AWS)

| Do | Command | Result then |
|---|---|---|
| Terraform unit (mocked AWS) | `make test-unit` (needs `terraform` 1.9.x) | 51/51 + 4/4 apply-mode |
| Mutation (each guard broken must be caught) | `make test-mutation` (slow: several minutes) | 54/54 killed, control survives |
| Docker contract | `make test-contract` | 16/16 |
| Selftests | `bash tests/ci/selftest.sh` · `make test-setup` (needs `expect`) · `bash tests/live/selftest.sh` | 11 · 9 · 29 scenarios |
| Map API + local adapter | `make test-api` | 20 + 6 |
| Map page build | `make test-web` (Docker) | builds 12 files |
| Everything above | `make test` | |

CI: [.github/workflows/ci.yml](.github/workflows/ci.yml) runs these on every pull request, plus gitleaks over the working tree and history. [.github/workflows/check.yml](.github/workflows/check.yml) is the deploy workflow (push to `main` with the whole word `check`), see [docs/CI.md](docs/CI.md).

## Rules for changes

- A logic change needs a unit assertion and a mutation row that would catch its regression (`tests/mutation/run.sh`). Never weaken a validation or threshold to pass.
- Child module contracts: [docs/CONTRACTS.md](docs/CONTRACTS.md); component to module map: [docs/COMPONENTS.md](docs/COMPONENTS.md). Decisions go in [docs/DECISIONS.md](docs/DECISIONS.md).
- Every `.md` plan/README/report has a plain `.txt` twin; update both together.

## Do NOT

- Run `make up`, `make e2e`, `make down`, `./sefs setup`, or push to `main` with `check` in the message: these touch a real AWS account and cost money (about US$4.20/day while up). Owner only.
- Commit `account.auto.tfvars`, `backend.hcl`, `*.tfstate`, or any credential. This is a PUBLIC repo; secrets live only in SSM (`secrets.manifest`).
- Edit `.terraform.lock.hcl` by hand, or `Shared EFS for Multi-App.docx` (the spec).

# One entry point. `make up` deploys EVERYTHING (images are built + pushed inside the apply).
# Single component: make apply-one CHILD=<network|security|efs|backup|images|apps>  (see docs/COMPONENTS.md)
SHELL := /bin/bash
TF    ?= terraform
AUTO  ?=
APPROVE := $(if $(AUTO),-auto-approve,)

.PHONY: help setup test-setup bruno-profile bruno bootstrap tf-profile cost preflight init up apply-one plan test test-unit test-mutation test-contract verify e2e down

help:
	@grep -E '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

setup: ## Fresh clone: host checks, confirm AWS account, store secrets in SSM, deploy (./setup.sh)
	./setup.sh

test-setup: ## Prove setup.sh never leaks a secret (fake aws, no AWS calls)
	bash tests/setup/selftest.sh

tf-profile: ## If you sign in with `aws login`: make tf-profile SOURCE=<login profile>, then use AWS_PROFILE=sefs-tf
	@test -n "$(SOURCE)" || { echo "usage: make tf-profile SOURCE=<your AWS login profile>"; exit 1; }
	bash scripts/bruno-profile.sh tf "$(SOURCE)" "$$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' account.auto.tfvars)"

preflight: ## Check host tools and show which AWS account/region you're about to touch
	@if [ -n "$$(aws configure get login_session --profile "$${AWS_PROFILE:-default}" 2>/dev/null)" ]; then \
	  echo "Refusing: profile '$${AWS_PROFILE:-default}' is an 'aws login' session, which Terraform 1.9's S3 backend cannot read."; \
	  echo "Fix: make tf-profile SOURCE=$${AWS_PROFILE:-default}   then   export AWS_PROFILE=sefs-tf"; exit 1; fi
	@test -f account.auto.tfvars || { echo "Refusing: create account.auto.tfvars with allowed_account_id = \"<12-digit id>\" (the ONLY account to deploy into)"; exit 1; }
	@want=$$(sed -nE 's/^allowed_account_id *= *"([0-9]{12})".*/\1/p' account.auto.tfvars); have=$$(aws sts get-caller-identity --query Account --output text); \
	  [ -n "$$want" ] && [ "$$want" = "$$have" ] || { echo "Refusing: credentials are account $$have, allowed is '$$want'"; exit 1; }; echo "Account guard OK: $$have"
	@for t in $(TF) docker aws; do command -v $$t >/dev/null || { echo "MISSING: $$t"; exit 1; }; done
	@docker info >/dev/null 2>&1 || { echo "Docker daemon not running"; exit 1; }
	@aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
	@echo "Region: $$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' account.auto.tfvars 2>/dev/null || true)"

bootstrap: ## One-time per account+region: state bucket + lock table (+ GitHub deploy role if GITHUB_REPO=owner/repo); writes backend.hcl
	cd bootstrap && $(TF) init -input=false >/dev/null && $(TF) apply $(APPROVE) \
	  -var "name=$$(sed -nE 's/^name *= *"([^"]+)".*/\1/p' ../account.auto.tfvars | grep . || echo sefs)" \
	  -var "region=$$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' ../account.auto.tfvars)" \
	  -var "allowed_account_id=$$(sed -nE 's/^allowed_account_id *= *"([0-9]+)".*/\1/p' ../account.auto.tfvars)" \
	  $(if $(GITHUB_REPO),-var "github_repo=$(GITHUB_REPO)" -var "github_owner_id=$$(gh api repos/$(GITHUB_REPO) --jq .owner.id 2>/dev/null || echo null)" -var "github_repo_id=$$(gh api repos/$(GITHUB_REPO) --jq .id 2>/dev/null || echo null)",)
	cd bootstrap && $(TF) output -raw backend_hcl > ../backend.hcl && echo "backend.hcl written"

init: ## terraform init against the shared S3 state (needs backend.hcl from `make bootstrap`)
	@test -f backend.hcl || { echo "Refusing: backend.hcl missing. Run 'make bootstrap' once (creates the state bucket + lock table)."; exit 1; }
	$(TF) init -input=false -backend-config=backend.hcl -migrate-state -force-copy

up: preflight init ## Deploy everything with ONE terraform apply (AUTO=1 to skip the prompt)
	bash scripts/adopt-orphans.sh
	$(TF) apply $(APPROVE)
	@echo "LIVE: the stack now burns about US\$$0.17/h (US\$$4.20/day) of credits until 'make down'. './sefs burn' shows the running total."

apply-one: init ## Update one child only: make apply-one CHILD=efs
	@test -n "$(CHILD)" || { echo "usage: make apply-one CHILD=<name>"; exit 1; }
	$(TF) apply -target=module.$(CHILD) $(APPROVE)

plan: init ## Show pending changes against the shared state
	$(TF) plan

test: test-unit test-mutation test-contract test-setup ## All local (fake-AWS + Docker) proofs

test-unit: ## terraform test against mocked AWS (offline, -backend=false)
	bash tests/unit/run.sh

test-mutation: ## Break each guard in a temp copy; every mutation must be caught
	bash tests/mutation/run.sh

test-contract: ## Writer/reader POSIX + ro contract in local Docker
	bash tests/contract/run.sh

bruno-profile: ## Install the credential-free 'sefs-bruno' AWS profile: make bruno-profile SOURCE=<your login profile>
	@test -n "$(SOURCE)" || { echo "usage: make bruno-profile SOURCE=<your AWS login profile>"; exit 1; }
	bash scripts/bruno-profile.sh install "$(SOURCE)" "$$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' account.auto.tfvars)"

bruno: ## Run the self-hydrating Bruno collection against the live deployment (read-only role)
	cd bruno/sefs && bru run --env aws --env-var awsRegion="$$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' ../../account.auto.tfvars)"

cost: ## Running cost from the AWS Pricing API: per hour, per minute, 30 days (read-only; needs pricing:GetProducts)
	python3 scripts/cost.py --region "$$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' account.auto.tfvars)"

verify: ## Real AWS: every R-ID checked against live state + plan shows no drift
	bash tests/live/verify.sh

e2e: ## Real AWS: write/read, IAM ro mutation, persistence across app destroy
	bash tests/live/e2e.sh

down: preflight init ## Destroy EVERYTHING incl. the EFS data (keeps state bucket unless DESTROY_STATE=yes). Requires CONFIRM_DESTROY_DATA=yes
	bash scripts/teardown.sh

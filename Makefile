# One entry point. `make up` deploys EVERYTHING (images are built + pushed inside the apply).
# Single component: make apply-one CHILD=<network|security|efs|backup|images|apps>  (see docs/COMPONENTS.md)
SHELL := /bin/bash
TF    ?= terraform
AUTO  ?=
APPROVE := $(if $(AUTO),-auto-approve,)

.PHONY: help preflight init up apply-one plan test test-unit test-mutation test-contract verify e2e down

help:
	@grep -E '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

preflight: ## Check host tools and show which AWS account/region you're about to touch
	@for t in $(TF) docker aws; do command -v $$t >/dev/null || { echo "MISSING: $$t"; exit 1; }; done
	@docker info >/dev/null 2>&1 || { echo "Docker daemon not running"; exit 1; }
	@aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
	@echo "Region: $$($(TF) console <<< 'var.region' 2>/dev/null || echo us-east-1)"

init:
	$(TF) init -input=false

up: preflight init ## Deploy everything with ONE terraform apply (AUTO=1 to skip the prompt)
	$(TF) apply $(APPROVE)

apply-one: init ## Update one child only: make apply-one CHILD=efs
	@test -n "$(CHILD)" || { echo "usage: make apply-one CHILD=<name>"; exit 1; }
	$(TF) apply -target=module.$(CHILD) $(APPROVE)

plan: init
	$(TF) plan

test: test-unit test-mutation test-contract ## All local (fake-AWS + Docker) proofs

test-unit: ## terraform test against mocked AWS
	bash tests/unit/run.sh

test-mutation: ## Break each guard in a temp copy; every mutation must be caught
	bash tests/mutation/run.sh

test-contract: ## Writer/reader POSIX + ro contract in local Docker
	bash tests/contract/run.sh

verify: ## Real AWS: every R-ID checked against live state + plan shows no drift
	bash tests/live/verify.sh

e2e: ## Real AWS: write/read, IAM ro mutation, persistence across app destroy
	bash tests/live/e2e.sh

down: ## Destroy EVERYTHING incl. the EFS data. Requires CONFIRM_DESTROY_DATA=yes
	bash scripts/teardown.sh

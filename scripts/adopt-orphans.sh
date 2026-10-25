#!/usr/bin/env bash
# Adopts resources that exist in AWS but not in Terraform state, so a re-run does not fail
# with "already exists". Today this happens when an apply is cancelled while an ECS service
# waits for steady state: AWS has the service, state does not, and CreateService then fails
# with "Creation of service was not idempotent".
#
# Read-only against AWS except `terraform import`, which only edits state. Idempotent.
#   scripts/adopt-orphans.sh            (uses backend.hcl / current init; name from var default)
set -euo pipefail
TF="${TF:-terraform}"
# name/region: env first (CI exports TF_VAR_*), then account.auto.tfvars, then defaults.
# `terraform console` is deliberately avoided here: slow, and it needs backend credentials.
name="${TF_VAR_name:-$(sed -nE 's/^name *= *"([^"]+)".*/\1/p' account.auto.tfvars 2>/dev/null)}"; name="${name:-sefs}"
region="${TF_VAR_region:-${AWS_REGION:-$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' account.auto.tfvars 2>/dev/null)}}"; region="${region:-us-east-1}"
state="$($TF state list 2>/dev/null || true)"
echo "adopt-orphans: cluster=$name region=$region state_entries=$(grep -c . <<<"$state" || true)"
adopted=0

for who in writer reader; do
  addr="module.apps.aws_ecs_service.$who"
  svc="$name-$who"
  if grep -qx "$addr" <<<"$state"; then echo "  $svc: already in state"; continue; fi
  raw="$(aws ecs describe-services --region "$region" --cluster "$name" --services "$svc" --output json 2>&1 || true)"
  status="$(jq -r '.services[0].status // (.failures[0].reason // "MISSING")' <<<"$raw" 2>/dev/null || echo "UNPARSEABLE: $raw")"
  echo "  $svc: aws says '$status'"
  case "$status" in
    ACTIVE|DRAINING)
      echo "  adopting orphaned ECS service $svc -> $addr"
      $TF import -input=false "$addr" "$name/$svc"
      adopted=$((adopted + 1)) ;;
  esac
done

echo "adopt-orphans: $adopted resource(s) imported"

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
name="$($TF console <<<'var.name' 2>/dev/null | tr -d '"' || true)"; name="${name:-sefs}"
region="$($TF console <<<'var.region' 2>/dev/null | tr -d '"' || true)"; region="${region:-${AWS_REGION:-us-east-1}}"
state="$($TF state list 2>/dev/null || true)"
adopted=0

for who in writer reader; do
  addr="module.apps.aws_ecs_service.$who"
  svc="$name-$who"
  grep -qx "$addr" <<<"$state" && continue
  status="$(aws ecs describe-services --region "$region" --cluster "$name" --services "$svc" \
            --query 'services[0].status' --output text 2>/dev/null || echo MISSING)"
  if [ "$status" = "ACTIVE" ]; then
    echo "adopting orphaned ECS service $svc -> $addr"
    $TF import -input=false "$addr" "$name/$svc" >/dev/null
    adopted=$((adopted + 1))
  fi
done

echo "adopt-orphans: $adopted resource(s) imported"

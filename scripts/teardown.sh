#!/usr/bin/env bash
# Full teardown, including the EFS and its data.
# prevent_destroy is a literal Terraform can't switch off with a variable (by design),
# so the file system is released from state, everything else is destroyed by Terraform,
# then the file system is deleted directly and the account is swept for leftovers.
set -euo pipefail
TF=${TF:-terraform}

if [[ "${CONFIRM_DESTROY_DATA:-}" != "yes" ]]; then
  echo "Refusing: this deletes the shared EFS and all its data. Re-run with CONFIRM_DESTROY_DATA=yes"
  exit 1
fi

# Inputs as JSON, never `output -raw`: on a half-destroyed state `-raw` printed its "No outputs found"
# warning on STDOUT and the script used it as the region (2026-10-28, second pass of a teardown).
out_json=$($TF output -json 2>/dev/null || echo '{}')
oj() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$out_json" 2>/dev/null; }
region=$(oj region); [ -n "$region" ] || region=$(sed -nE 's/^region *= *"([^"]+)".*/\1/p' account.auto.tfvars 2>/dev/null | head -1)
region=${region:-${AWS_REGION:-us-east-1}}
name=$(oj name); [ -n "$name" ] || name=$(sed -nE 's/^name *= *"([^"]+)".*/\1/p' account.auto.tfvars 2>/dev/null | head -1); name=${name:-sefs}
fs_id=$(oj file_system_id)
# No output (state already emptied by an earlier pass)? The file system may still exist: find it by tag.
if [[ -z "$fs_id" ]]; then
  fs_id=$(aws efs describe-file-systems --region "$region" --query "FileSystems[?Tags[?Key=='Project'&&Value=='$name']].FileSystemId" --output text | tr '\t' ' ' | awk '{print $1}')
fi
fs_addr=$($TF state list 2>/dev/null | grep -E '^module\.efs\.aws_efs_file_system\.' || true)
echo "Region=$region  Project tag=$name  EFS=${fs_id:-<none>}  state address=${fs_addr:-<none>}"

if [[ -n "$fs_addr" ]]; then
  $TF state rm "$fs_addr"
fi

$TF destroy -auto-approve

if [[ -n "$fs_id" ]]; then
  echo "Waiting for mount targets on $fs_id to be gone..."
  for _ in $(seq 1 60); do
    n=$(aws efs describe-mount-targets --region "$region" --file-system-id "$fs_id" --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)
    [[ "$n" == "0" ]] && break
    sleep 10
  done
  aws efs delete-file-system --region "$region" --file-system-id "$fs_id"
  for _ in $(seq 1 30); do
    aws efs describe-file-systems --region "$region" --file-system-id "$fs_id" >/dev/null 2>&1 || { echo "EFS $fs_id deleted"; break; }
    sleep 10
  done
else
  echo "No file system tagged Project=$name to delete"
fi

# Terraform only deregisters the revision it holds in state (and leaves it INACTIVE forever). A targeted
# destroy + re-apply (tests/live/e2e.sh E4) can leave earlier revisions ACTIVE outside state: observed
# 2026-10-26 (writer:4, reader:5 after a clean destroy). The cluster is gone, so every revision in our
# families is ours to deregister, then delete.
for fam in "$name-writer" "$name-reader" "$name-reader-iam-mutation"; do
  active=$(aws ecs list-task-definitions --region "$region" --family-prefix "$fam" --status ACTIVE \
    --query 'taskDefinitionArns' --output text)
  if [[ -n "$active" && "$active" != "None" ]]; then
    for a in $active; do aws ecs deregister-task-definition --region "$region" --task-definition "$a" >/dev/null; done
    echo "Deregistered stray active task definitions: $active"
  fi
  arns=$(aws ecs list-task-definitions --region "$region" --family-prefix "$fam" --status INACTIVE \
    --query 'taskDefinitionArns' --output text)
  if [[ -n "$arns" && "$arns" != "None" ]]; then
    # shellcheck disable=SC2086
    aws ecs delete-task-definitions --region "$region" --task-definitions $arns >/dev/null
    echo "Deleted inactive task definitions: $arns"
  fi
done

# Authoritative check: ask each service directly. A check that can't run counts as NOT clean.
echo "--- Direct checks (Project=$name, $region) ---"
fail=0
check() { # name, command printing what remains (empty = clean)
  local out
  if ! out=$(eval "$2" 2>&1); then echo "UNVERIFIED $1: $out"; fail=1; return; fi
  if [[ -n "$out" && "$out" != "None" ]]; then echo "LEFT $1: $out"; fail=1; else echo "clean $1"; fi
}
T="Name=tag:Project,Values=$name"
check "VPCs"            "aws ec2 describe-vpcs --region $region --filters $T --query 'Vpcs[].VpcId' --output text"
check "subnets"         "aws ec2 describe-subnets --region $region --filters $T --query 'Subnets[].SubnetId' --output text"
check "security groups" "aws ec2 describe-security-groups --region $region --filters $T --query 'SecurityGroups[].GroupId' --output text"
check "NAT gateways"    "aws ec2 describe-nat-gateways --region $region --filter $T --query 'NatGateways[?State!=\`deleted\`].NatGatewayId' --output text"
check "Elastic IPs"     "aws ec2 describe-addresses --region $region --filters $T --query 'Addresses[].AllocationId' --output text"
check "internet gws"    "aws ec2 describe-internet-gateways --region $region --filters $T --query 'InternetGateways[].InternetGatewayId' --output text"
check "route tables"    "aws ec2 describe-route-tables --region $region --filters $T --query 'RouteTables[].RouteTableId' --output text"
check "EFS"             "aws efs describe-file-systems --region $region --query \"FileSystems[?Tags[?Key=='Project'&&Value=='$name']].FileSystemId\" --output text"
check "ECR repos"       "aws ecr describe-repositories --region $region --query \"repositories[?starts_with(repositoryName,'$name-')].repositoryName\" --output text"
check "ECS clusters"    "aws ecs describe-clusters --region $region --clusters $name --query \"clusters[?status!='INACTIVE'].clusterName\" --output text"
# --family-prefix takes a FULL family name (a partial one silently matches nothing).
for fam in "$name-writer" "$name-reader" "$name-reader-iam-mutation"; do
  check "task defs $fam"          "aws ecs list-task-definitions --region $region --family-prefix $fam --status ACTIVE --query 'taskDefinitionArns' --output text"
  check "inactive task defs $fam" "aws ecs list-task-definitions --region $region --family-prefix $fam --status INACTIVE --query 'taskDefinitionArns' --output text"
done
check "log groups"      "aws logs describe-log-groups --region $region --log-group-name-prefix /ecs/$name/ --query 'logGroups[].logGroupName' --output text"
check "backup vaults"   "aws backup list-backup-vaults --region $region --query \"BackupVaultList[?starts_with(BackupVaultName,'$name')].BackupVaultName\" --output text"
check "backup plans"    "aws backup list-backup-plans --region $region --query \"BackupPlansList[?starts_with(BackupPlanName,'$name')].BackupPlanName\" --output text"
check "IAM roles"       "aws iam list-roles --query \"Roles[?starts_with(RoleName,'$name-') && RoleName!='$name-github-deploy'].RoleName\" --output text"
# The map (modules/gui): login pool, page bucket + distribution, API + its function and log group.
check "Cognito pools"   "aws cognito-idp list-user-pools --region $region --max-results 60 --query \"UserPools[?Name=='$name-gui'].Id\" --output text"
check "page buckets"    "aws s3api list-buckets --query \"Buckets[?starts_with(Name,'$name-gui-')].Name\" --output text"
check "CloudFront"      "aws cloudfront list-distributions --query \"DistributionList.Items[?Comment=='$name 2.5D map'].Id\" --output text"
check "HTTP APIs"       "aws apigatewayv2 get-apis --region $region --query \"Items[?Name=='$name-gui-api'].ApiId\" --output text"
check "Lambda"          "aws lambda list-functions --region $region --query \"Functions[?FunctionName=='$name-gui-api'].FunctionName\" --output text"
check "Lambda logs"     "aws logs describe-log-groups --region $region --log-group-name-prefix /aws/lambda/$name-gui-api --query 'logGroups[].logGroupName' --output text"

# Advisory only: the tagging API keeps deleted resources listed for a while.
lag=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --tag-filters "Key=Project,Values=$name" --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo "?")
echo "(advisory) tagging API still lists $lag ARN(s) for Project=$name; it lags behind deletions"

if [[ $fail -ne 0 ]]; then echo "NOT CLEAN"; exit 2; fi
echo "CLEAN: no $name resources remain in $region"

# The state bucket, lock table and CI role are NOT part of `make down`: the next `make up`
# needs them. DESTROY_STATE=yes removes them too (versioned bucket included).
if [[ "${DESTROY_STATE:-}" == "yes" ]]; then
  echo "--- DESTROY_STATE=yes: removing the state bucket, lock table and CI role ---"
  ( cd bootstrap && $TF init -input=false >/dev/null \
      && $TF apply -auto-approve -var allow_state_destroy=true -var "region=$region" -var "name=$name" >/dev/null \
      && $TF destroy -auto-approve -var allow_state_destroy=true -var "region=$region" -var "name=$name" )
  rm -f backend.hcl
  aws s3api head-bucket --bucket "$name-tfstate-$(aws sts get-caller-identity --query Account --output text)-$region" 2>/dev/null \
    && { echo "LEFT state bucket"; exit 2; } || echo "clean state bucket"
fi

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

region=$($TF output -raw region 2>/dev/null || echo "${AWS_REGION:-us-east-1}")
name=$($TF output -raw name 2>/dev/null || echo "sefs")
fs_id=$($TF output -raw file_system_id)
fs_addr=$($TF state list | grep -E '^module\.efs\.aws_efs_file_system\.' || true)
echo "Region=$region  Project tag=$name  EFS=$fs_id  state address=${fs_addr:-<none>}"

if [[ -n "$fs_addr" ]]; then
  $TF state rm "$fs_addr"
fi

$TF destroy -auto-approve

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

# Terraform only deregisters task definitions (they stay INACTIVE forever); delete them.
for fam in "$name-writer" "$name-reader" "$name-reader-iam-mutation"; do
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
check "IAM roles"       "aws iam list-roles --query \"Roles[?starts_with(RoleName,'$name-')].RoleName\" --output text"

# Advisory only: the tagging API keeps deleted resources listed for a while.
lag=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --tag-filters "Key=Project,Values=$name" --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo "?")
echo "(advisory) tagging API still lists $lag ARN(s) for Project=$name; it lags behind deletions"

if [[ $fail -ne 0 ]]; then echo "NOT CLEAN"; exit 2; fi
echo "CLEAN: no $name resources remain in $region"

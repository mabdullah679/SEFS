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

echo "--- Sweep: anything still tagged Project=$name (tagging API can lag a few minutes) ---"
left=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --tag-filters "Key=Project,Values=$name" --query 'ResourceTagMappingList[].ResourceARN' --output text)
if [[ -n "$left" && "$left" != "None" ]]; then
  echo "LEFTOVER (verify each directly before calling this clean):"; echo "$left" | tr '\t' '\n'
  exit 2
fi
echo "No tagged resources remain for Project=$name"

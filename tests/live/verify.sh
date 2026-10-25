#!/usr/bin/env bash
# Live verifier: checks every Terraform-checkable R-ID against REAL AWS state,
# then proves declared == live with `terraform plan -detailed-exitcode`.
#
#   bash tests/live/verify.sh            (from the repo root, after `make up`)
#
# READ-ONLY. Only describe/list/get AWS CLI calls, plus `terraform output`,
# `terraform console` and `terraform plan` (refresh = reads). Nothing is
# created, changed or deleted.
#
# Verdicts per R-ID line:
#   PASS        every sub-check ran and held
#   FAIL        at least one sub-check ran and did not hold
#   UNVERIFIED  at least one sub-check could not run (API error, missing
#               output, missing tool). NEVER counted as a pass.
# Exit 0 only if every line is PASS.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
TF="${TF:-terraform}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
n_pass=0; n_fail=0; n_unv=0

for t in aws jq "$TF"; do
  command -v "$t" >/dev/null 2>&1 || { echo "${YEL}UNVERIFIED${RST} ALL  missing tool: $t"; exit 3; }
done

# ---------------------------------------------------------------- per-R-ID aggregation
CUR_STATUS="PASS"; CUR_NOTES=()
begin() { CUR_STATUS="PASS"; CUR_NOTES=(); }
ok()    { :; }
bad()   { [ "$CUR_STATUS" = "UNVERIFIED" ] || CUR_STATUS="FAIL"; CUR_NOTES+=("FAIL: $*"); }
unv()   { CUR_STATUS="UNVERIFIED"; CUR_NOTES+=("UNVERIFIED: $*"); }
# A FAIL that coexists with an UNVERIFIED still prints UNVERIFIED (could not
# finish) but the FAIL note is kept so nothing is hidden.
report() {
  local rid="$1" what="$2" c
  case "$CUR_STATUS" in
    PASS) c="$GRN"; n_pass=$((n_pass + 1)) ;;
    FAIL) c="$RED"; n_fail=$((n_fail + 1)) ;;
    *)    c="$YEL"; n_unv=$((n_unv + 1)) ;;
  esac
  printf '%s%-10s%s %-4s %s\n' "$c" "$CUR_STATUS" "$RST" "$rid" "$what"
  local n; for n in ${CUR_NOTES[@]+"${CUR_NOTES[@]}"}; do printf '             - %s\n' "$n"; done
}
# check "<description>" <jq-filter> <json>  -> ok / bad
check() {
  local desc="$1" filter="$2" json="$3"
  if [ -z "$json" ]; then unv "$desc (no data)"; return; fi
  if jq -e "$filter" >/dev/null 2>&1 <<<"$json"; then ok; else bad "$desc"; fi
}

# AWS call wrapper: prints JSON or returns 1. Errors go to $ERRLOG.
ERRLOG="$(mktemp "${TMPDIR:-/tmp}/sefs-verify-err.XXXXXX")"
trap 'rm -f "$ERRLOG"' EXIT
a() { aws --region "$REGION" --output json "$@" 2>>"$ERRLOG"; }
# fetch VAR cmd...: VAR := output or "" (caller must handle "")
fetch() { local __v="$1"; shift; local out; out="$(a "$@")" || out=""; printf -v "$__v" '%s' "$out"; }

# ---------------------------------------------------------------- inputs
OUT="$("$TF" output -json 2>>"$ERRLOG")" || { echo "${YEL}UNVERIFIED${RST} ALL  terraform output -json failed (no state?)"; cat "$ERRLOG"; exit 3; }
o() { jq -r --arg k "$1" '.[$k].value // empty | if type=="array" then join(" ") else . end' <<<"$OUT"; }
# TF 1.9 console prints a null string var as `tostring(null)`, not `null`; normalise every form to "".
tfvar() { echo "$1" | "$TF" console 2>/dev/null | tr -d '"' | sed -E 's/^(to[a-z]+\()?null\)?$//' ; }

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "$REGION" ] || REGION="$(tfvar var.region)"
[ -n "$REGION" ] || { echo "${YEL}UNVERIFIED${RST} ALL  could not determine region"; exit 3; }
NAME="$(tfvar var.name)"; NAME="${NAME:-sefs}"
KMS_VAR="$(tfvar var.kms_key_arn)"
EXPECT_AZ="$(tfvar var.az_count)"

VPC_ID="$(o vpc_id)"; PRIV="$(o private_subnet_ids)"
SG_APPS="$(o apps_security_group_id)"; SG_EFS="$(o efs_security_group_id)"
FS_ID="$(o file_system_id)"; AP_W="$(o writer_access_point_id)"; AP_R="$(o reader_access_point_id)"
VAULT="$(o backup_vault_name)"; PLAN_ID="$(o backup_plan_id)"
CLUSTER="$(o cluster_name)"; SVC_W="$(o writer_service_name)"; SVC_R="$(o reader_service_name)"
TD_R_OUT="$(o reader_task_definition_arn)"

ACCOUNT="$(aws --region "$REGION" sts get-caller-identity --query Account --output text 2>>"$ERRLOG" || echo "?")"
echo "SEFS live verify  account=$ACCOUNT region=$REGION name=$NAME  $(date -u +%Y-%m-%dT%H:%M:%SZ)  tree=$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo

PRIV_JSON="$(jq -Rc 'split(" ") | map(select(length > 0))' <<<"$PRIV")"

# ---------------------------------------------------------------- shared fetches
fetch FS        efs describe-file-systems --file-system-id "$FS_ID"
fetch LCFG      efs describe-lifecycle-configuration --file-system-id "$FS_ID"
fetch MTS       efs describe-mount-targets --file-system-id "$FS_ID"
fetch APS       efs describe-access-points --file-system-id "$FS_ID"
fetch FSPOL     efs describe-file-system-policy --file-system-id "$FS_ID"
fetch EFSBK     efs describe-backup-policy --file-system-id "$FS_ID"
fetch SUBNETS   ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID"
fetch RTS       ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID"
fetch SGRULES   ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_EFS"
fetch SVCS      ecs describe-services --cluster "$CLUSTER" --services "$SVC_W" "$SVC_R"
TD_W="$(jq -r --arg s "$SVC_W" '.services[]? | select(.serviceName==$s) | .taskDefinition' <<<"${SVCS:-{\}}" 2>/dev/null || true)"
TD_R="$(jq -r --arg s "$SVC_R" '.services[]? | select(.serviceName==$s) | .taskDefinition' <<<"${SVCS:-{\}}" 2>/dev/null || true)"
TDW=""; TDR=""
[ -n "$TD_W" ] && fetch TDW ecs describe-task-definition --task-definition "$TD_W"
[ -n "$TD_R" ] && fetch TDR ecs describe-task-definition --task-definition "$TD_R"
fetch BPLAN     backup get-backup-plan --backup-plan-id "$PLAN_ID"
fetch BSELS     backup list-backup-selections --backup-plan-id "$PLAN_ID"
fetch BVAULT    backup describe-backup-vault --backup-vault-name "$VAULT"
FS_ARN="$(jq -r '.FileSystems[0].FileSystemArn // empty' <<<"${FS:-{\}}" 2>/dev/null || true)"
POLICY="$(jq -r '.Policy // empty' <<<"${FSPOL:-{\}}" 2>/dev/null || true)"
ROLE_W="$(jq -r '.taskDefinition.taskRoleArn // empty' <<<"${TDW:-{\}}" 2>/dev/null || true)"
ROLE_R="$(jq -r '.taskDefinition.taskRoleArn // empty' <<<"${TDR:-{\}}" 2>/dev/null || true)"
AP_W_ARN="$(jq -r --arg i "$AP_W" '.AccessPoints[]? | select(.AccessPointId==$i) | .AccessPointArn' <<<"${APS:-{\}}" 2>/dev/null || true)"
AP_R_ARN="$(jq -r --arg i "$AP_R" '.AccessPoints[]? | select(.AccessPointId==$i) | .AccessPointArn' <<<"${APS:-{\}}" 2>/dev/null || true)"

# jq helper library for policy statements (Principal / Action may be string or list)
JQLIB='def arr: if type=="array" then . else [.] end;
       def princ: (.Principal | if type=="object" then (.AWS // []) else . end) | arr;'

# ---------------------------------------------------------------- R1 / R4
begin
check "file system exists and is available" '.FileSystems[0].LifeCycleState == "available"' "$FS"
if grep -REq 'prevent_destroy[[:space:]]*=[[:space:]]*true' modules/efs/*.tf; then ok; else bad "prevent_destroy = true missing from modules/efs (static)"; fi
report R4 "EFS present; prevent_destroy declared (data-survives-app-destroy is proven in e2e.sh R1)"

# ---------------------------------------------------------------- R5
begin
[ -n "$PRIV" ] || unv "private_subnet_ids output empty"
if [ -n "$SUBNETS" ] && [ -n "$PRIV" ]; then
  if jq -e --argjson p "$PRIV_JSON" '[.Subnets[] | select(.SubnetId as $s | $p | index($s)) | .AvailabilityZone] | unique | length >= 2' >/dev/null <<<"$SUBNETS"; then ok; else bad "private subnets span < 2 AZs"; fi
  if jq -e --argjson p "$PRIV_JSON" '[.Subnets[] | select(.SubnetId as $s | ($p | index($s)) | not) | .AvailabilityZone] | unique | length >= 2' >/dev/null <<<"$SUBNETS"; then ok; else bad "public subnets span < 2 AZs"; fi
  if [ -n "$EXPECT_AZ" ] && jq -e --argjson p "$PRIV_JSON" --argjson n "$EXPECT_AZ" '[.Subnets[] | select(.SubnetId as $s | $p | index($s))] | length == $n' >/dev/null <<<"$SUBNETS"; then ok; else bad "private subnet count != az_count ($EXPECT_AZ)"; fi
else unv "describe-subnets failed"; fi
# public subnets must route 0.0.0.0/0 to an IGW
if [ -n "$RTS" ] && [ -n "$SUBNETS" ]; then
  if jq -e --argjson p "$PRIV_JSON" --slurpfile s <(printf '%s' "$SUBNETS") '
      ($s[0].Subnets | map(.SubnetId) | map(select(. as $x | ($p | index($x)) | not))) as $pub
      | [ $pub[] as $sid | [.RouteTables[] | select(any(.Associations[]?; .SubnetId == $sid))
          | .Routes[] | select(.DestinationCidrBlock == "0.0.0.0/0") | (.GatewayId // "")] | any(startswith("igw-")) ] | all' >/dev/null <<<"$RTS"; then ok; else bad "a public subnet has no 0.0.0.0/0 -> igw route"; fi
else unv "describe-route-tables failed"; fi
report R5 "multi-AZ VPC: >=2 AZs, public + private subnets"

# ---------------------------------------------------------------- R6
begin
if [ -n "$SUBNETS" ] && [ -n "$PRIV" ]; then
  if jq -e --argjson p "$PRIV_JSON" '[.Subnets[] | select(.SubnetId as $s | $p | index($s)) | .MapPublicIpOnLaunch] | all(. == false)' >/dev/null <<<"$SUBNETS"; then ok; else bad "a private subnet has MapPublicIpOnLaunch=true"; fi
else unv "describe-subnets failed"; fi
if [ -n "$RTS" ] && [ -n "$PRIV" ]; then
  if jq -e --argjson p "$PRIV_JSON" '[ $p[] as $sid | [.RouteTables[] | select(any(.Associations[]?; .SubnetId == $sid)) | .Routes[] | select(.DestinationCidrBlock == "0.0.0.0/0")]
        | (length == 1 and (.[0].NatGatewayId // "" | startswith("nat-")) and ((.[0].GatewayId // "") | startswith("igw-") | not)) ] | all' >/dev/null <<<"$RTS"; then ok; else bad "a private subnet's default route is not exactly one NAT route"; fi
else unv "describe-route-tables failed"; fi
if [ -n "$SVCS" ]; then
  if jq -e --argjson p "$PRIV_JSON" '(.services | length == 2) and all(.services[]; .networkConfiguration.awsvpcConfiguration as $n | ($n.assignPublicIp == "DISABLED") and (($n.subnets | sort) == ($p | sort)))' >/dev/null <<<"$SVCS"; then ok; else bad "a service is not pinned to exactly the private subnets with assignPublicIp DISABLED"; fi
  if jq -e '(.failures | length) == 0' >/dev/null <<<"$SVCS"; then ok; else bad "describe-services reported failures (service missing?)"; fi
else unv "describe-services failed"; fi
report R6 "apps in private subnets, no public IPs, egress via NAT"

# ---------------------------------------------------------------- R7
begin
if [ -n "$MTS" ] && [ -n "$PRIV" ]; then
  if jq -e --argjson p "$PRIV_JSON" '(.MountTargets | map(.SubnetId) | sort) == ($p | sort)' >/dev/null <<<"$MTS"; then ok; else bad "mount target subnets != private subnets"; fi
  if jq -e '(.MountTargets | map(.AvailabilityZoneName) | unique | length) == (.MountTargets | length)' >/dev/null <<<"$MTS"; then ok; else bad "more than one mount target in an AZ"; fi
  if jq -e --argjson n "${EXPECT_AZ:-0}" '(.MountTargets | length) == $n' >/dev/null <<<"$MTS"; then ok; else bad "mount target count != az_count ($EXPECT_AZ)"; fi
  if jq -e 'all(.MountTargets[]; .LifeCycleState == "available")' >/dev/null <<<"$MTS"; then ok; else bad "a mount target is not available"; fi
  for mt in $(jq -r '.MountTargets[].MountTargetId' <<<"$MTS"); do
    fetch MTSG efs describe-mount-target-security-groups --mount-target-id "$mt"
    if [ -n "$MTSG" ]; then
      if jq -e --arg g "$SG_EFS" '.SecurityGroups == [$g]' >/dev/null <<<"$MTSG"; then ok; else bad "mount target $mt SGs != [sg-efs]"; fi
    else unv "describe-mount-target-security-groups $mt failed"; fi
  done
else unv "describe-mount-targets failed"; fi
report R7 "one mount target per private-subnet AZ, each with sg-efs"

# ---------------------------------------------------------------- R8
begin
if [ -n "$SVCS" ]; then
  if jq -e --arg g "$SG_APPS" '(.services | length == 2) and all(.services[]; .networkConfiguration.awsvpcConfiguration.securityGroups == [$g])' >/dev/null <<<"$SVCS"; then ok; else bad "a service does not carry exactly [sg-apps]"; fi
else unv "describe-services failed"; fi
fetch APPSRULES ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_APPS"
if [ -n "$APPSRULES" ]; then
  if jq -e '[.SecurityGroupRules[] | select(.IsEgress == false)] | length == 0' >/dev/null <<<"$APPSRULES"; then ok; else bad "sg-apps has ingress rules (contract: none)"; fi
else unv "describe-security-group-rules sg-apps failed"; fi
report R8 "sg-apps on both services (and no ingress)"

# ---------------------------------------------------------------- R9
begin
if [ -n "$SGRULES" ]; then
  if jq -e --arg a "$SG_APPS" '[.SecurityGroupRules[] | select(.IsEgress == false)] as $in
      | ($in | length == 1)
        and ($in[0].IpProtocol == "tcp" and $in[0].FromPort == 2049 and $in[0].ToPort == 2049)
        and ($in[0].ReferencedGroupInfo.GroupId == $a)
        and ($in[0].CidrIpv4 == null and $in[0].CidrIpv6 == null and $in[0].PrefixListId == null)' >/dev/null <<<"$SGRULES"; then ok
  else bad "sg-efs ingress is not exactly one rule: tcp 2049 from sg-apps ($(jq -c '[.SecurityGroupRules[] | select(.IsEgress==false) | {IpProtocol,FromPort,ToPort,CidrIpv4,CidrIpv6,PrefixListId,src:.ReferencedGroupInfo.GroupId}]' <<<"$SGRULES"))"; fi
else unv "describe-security-group-rules sg-efs failed"; fi
report R9 "sg-efs ingress is exactly TCP 2049 from sg-apps"

# ---------------------------------------------------------------- R10
begin
if [ -n "$APS" ]; then
  if jq -e --arg w "$AP_W" --arg r "$AP_R" '
      (.AccessPoints | map(select(.AccessPointId == $w))[0]) as $W
      | (.AccessPoints | map(select(.AccessPointId == $r))[0]) as $R
      | $W != null and $R != null
      and $W.PosixUser.Uid == 1001 and $W.PosixUser.Gid == 1000
      and $R.PosixUser.Uid == 1002 and $R.PosixUser.Gid == 1000
      and $W.RootDirectory.Path == "/shared" and $R.RootDirectory.Path == "/shared"
      and all([$W, $R][]; .RootDirectory.CreationInfo.OwnerUid == 1001 and .RootDirectory.CreationInfo.OwnerGid == 1000 and .RootDirectory.CreationInfo.Permissions == "0775")
      and all([$W, $R][]; .LifeCycleState == "available")' >/dev/null <<<"$APS"; then ok
  else bad "access points do not force 1001:1000 / 1002:1000 at /shared with creation_info 1001:1000 0775"; fi
else unv "describe-access-points failed"; fi
report R10 "access points enforce POSIX UID/GID on the same root"

# ---------------------------------------------------------------- R12
begin
check "Encrypted=true"                      '.FileSystems[0].Encrypted == true'                   "$FS"
check "PerformanceMode=generalPurpose"      '.FileSystems[0].PerformanceMode == "generalPurpose"' "$FS"
check "ThroughputMode=bursting"             '.FileSystems[0].ThroughputMode == "bursting"'        "$FS"
report R12 "encrypted, generalPurpose, bursting"

# ---------------------------------------------------------------- R13
begin
KMS_LIVE="$(jq -r '.FileSystems[0].KmsKeyId // empty' <<<"${FS:-{\}}" 2>/dev/null || true)"
if [ -z "$KMS_LIVE" ]; then unv "no KmsKeyId on the file system"
elif [ -n "$KMS_VAR" ]; then
  [ "$KMS_LIVE" = "$KMS_VAR" ] && ok || bad "KmsKeyId $KMS_LIVE != configured CMK $KMS_VAR"
else
  fetch ALIASES kms list-aliases --key-id "$KMS_LIVE"
  if [ -n "$ALIASES" ]; then
    if jq -e 'any(.Aliases[]; .AliasName == "alias/aws/elasticfilesystem")' >/dev/null <<<"$ALIASES"; then ok; else bad "kms_key_arn is null but key is not alias/aws/elasticfilesystem"; fi
  else unv "kms list-aliases failed"; fi
fi
report R13 "encryption at rest with AWS-managed key (or the configured CMK)"

# ---------------------------------------------------------------- R14
begin
check "every plan rule keeps >= 35 days" '(.BackupPlan.Rules | length >= 1) and all(.BackupPlan.Rules[]; (.Lifecycle.DeleteAfterDays // 0) >= 35)' "$BPLAN"
if [ -n "$BPLAN" ]; then
  if jq -e --arg v "$VAULT" 'all(.BackupPlan.Rules[]; .TargetBackupVaultName == $v)' >/dev/null <<<"$BPLAN"; then ok; else bad "a rule targets a vault other than $VAULT"; fi
fi
[ -n "$BVAULT" ] && ok || unv "describe-backup-vault $VAULT failed"
if [ -n "$BSELS" ] && [ -n "$FS_ARN" ]; then
  found=0
  for sid in $(jq -r '.BackupSelectionsList[].SelectionId' <<<"$BSELS"); do
    fetch SEL backup get-backup-selection --backup-plan-id "$PLAN_ID" --selection-id "$sid"
    if [ -z "$SEL" ]; then unv "get-backup-selection $sid failed"; continue; fi
    jq -e --arg f "$FS_ARN" '.BackupSelection.Resources | index($f)' >/dev/null <<<"$SEL" && found=1
  done
  [ "$found" = 1 ] && ok || bad "no backup selection includes $FS_ARN"
else unv "list-backup-selections or FS ARN unavailable"; fi
report R14 "AWS Backup: >= 35-day retention, selection includes the EFS"

# ---------------------------------------------------------------- R15
begin
check "TransitionToIA = AFTER_30_DAYS" 'any(.LifecyclePolicies[]; .TransitionToIA == "AFTER_30_DAYS")' "$LCFG"
report R15 "IA transition after 30 days"

# ---------------------------------------------------------------- R2
begin
[ -n "$TDW" ] || unv "writer task definition not found"
check "writer mount readOnly=false at /mnt/shared" '.taskDefinition.containerDefinitions[0].mountPoints | length == 1 and .[0].readOnly == false and .[0].containerPath == "/mnt/shared"' "$TDW"
if [ -n "$TDW" ]; then
  if jq -e --arg fs "$FS_ID" --arg ap "$AP_W" '.taskDefinition.volumes | length == 1 and (.[0].efsVolumeConfiguration as $e | $e.fileSystemId == $fs and $e.transitEncryption == "ENABLED" and $e.authorizationConfig.iam == "ENABLED" and $e.authorizationConfig.accessPointId == $ap)' >/dev/null <<<"$TDW"; then ok; else bad "writer volume config wrong"; fi
fi
if [ -n "$POLICY" ] && [ -n "$ROLE_W" ] && [ -n "$AP_W_ARN" ]; then
  if jq -e --arg r "$ROLE_W" --arg ap "$AP_W_ARN" "$JQLIB"' .Statement | arr | any(.[]; .Effect == "Allow" and (princ | index($r)) and ((.Action | arr | sort) == ["elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite"]) and (.Condition.StringEquals["elasticfilesystem:AccessPointArn"] == $ap))' >/dev/null <<<"$POLICY"; then ok; else bad "FS policy lacks writer Allow ClientMount+ClientWrite via writer AP"; fi
else unv "FS policy / writer role / writer AP ARN unavailable"; fi
report R2 "writer has rw on the shared path (mount + FS policy)"

# ---------------------------------------------------------------- R3
begin
[ -n "$TDR" ] || unv "reader task definition not found"
if [ -n "$TD_R_OUT" ] && [ -n "$TD_R" ] && [ "$TD_R_OUT" != "$TD_R" ]; then bad "reader service runs $TD_R but terraform output says $TD_R_OUT"; fi
check "reader mount readOnly=true at /mnt/shared" '.taskDefinition.containerDefinitions[0].mountPoints | length == 1 and .[0].readOnly == true and .[0].containerPath == "/mnt/shared"' "$TDR"
if [ -n "$TDR" ]; then
  if jq -e --arg fs "$FS_ID" --arg ap "$AP_R" '.taskDefinition.volumes | length == 1 and (.[0].efsVolumeConfiguration as $e | $e.fileSystemId == $fs and $e.transitEncryption == "ENABLED" and $e.authorizationConfig.iam == "ENABLED" and $e.authorizationConfig.accessPointId == $ap)' >/dev/null <<<"$TDR"; then ok; else bad "reader volume config wrong (IAM auth must be ENABLED or the FS-policy Deny never applies)"; fi
fi
[ -n "$ROLE_R" ] && [ "$ROLE_R" != "$ROLE_W" ] && ok || bad "reader task role missing or same as writer"
if [ -n "$POLICY" ] && [ -n "$ROLE_R" ] && [ -n "$AP_R_ARN" ]; then
  if jq -e --arg r "$ROLE_R" "$JQLIB"' .Statement | arr | any(.[]; .Effect == "Deny" and (princ | index($r)) and ((.Action | arr) as $a | ($a | index("elasticfilesystem:ClientWrite")) and ($a | index("elasticfilesystem:ClientRootAccess"))) and (.Condition == null))' >/dev/null <<<"$POLICY"; then ok; else bad "FS policy lacks the unconditional reader Deny on ClientWrite+ClientRootAccess"; fi
  if jq -e --arg r "$ROLE_R" --arg ap "$AP_R_ARN" "$JQLIB"' .Statement | arr | any(.[]; .Effect == "Allow" and (princ | index($r)) and ((.Action | arr) == ["elasticfilesystem:ClientMount"]) and (.Condition.StringEquals["elasticfilesystem:AccessPointArn"] == $ap))' >/dev/null <<<"$POLICY"; then ok; else bad "FS policy lacks reader Allow ClientMount-only via reader AP"; fi
  if jq -e "$JQLIB"' .Statement | arr | all(.[]; .Effect != "Allow" or ((princ | index("*")) | not))' >/dev/null <<<"$POLICY"; then ok; else bad "FS policy has an Allow for *"; fi
  if jq -e "$JQLIB"' .Statement | arr | any(.[]; .Effect == "Deny" and (.Condition.Bool["aws:SecureTransport"] == "false"))' >/dev/null <<<"$POLICY"; then ok; else bad "FS policy lacks the deny-non-TLS statement"; fi
else unv "FS policy / reader role / reader AP ARN unavailable"; fi
# Reader identity policies must not allow ClientWrite (defence in depth; the Deny wins anyway).
if [ -n "$ROLE_R" ]; then
  RNAME="${ROLE_R##*/}"
  fetch INL iam list-role-policies --role-name "$RNAME"
  fetch ATT iam list-attached-role-policies --role-name "$RNAME"
  if [ -n "$INL" ] && [ -n "$ATT" ]; then
    for pn in $(jq -r '.PolicyNames[]' <<<"$INL"); do
      fetch RP iam get-role-policy --role-name "$RNAME" --policy-name "$pn"
      if [ -z "$RP" ]; then unv "get-role-policy $pn failed"; continue; fi
      if jq -e "$JQLIB"' .PolicyDocument.Statement | arr | all(.[]; .Effect != "Allow" or ((.Action | arr) | any(. == "elasticfilesystem:ClientWrite" or . == "elasticfilesystem:*" or . == "*") | not))' >/dev/null <<<"$RP"; then ok; else bad "reader inline policy $pn allows ClientWrite/wildcard"; fi
    done
    jq -e '.AttachedPolicies | length == 0' >/dev/null <<<"$ATT" && ok || bad "reader role has managed policies attached ($(jq -c '[.AttachedPolicies[].PolicyName]' <<<"$ATT")); review for ClientWrite"
  else unv "list reader role policies failed"; fi
fi
report R3 "reader is read-only on the SAME path (mount flag + IAM auth + FS-policy Deny)"

# ---------------------------------------------------------------- EFS automatic backups
begin
check "EFS automatic backup policy DISABLED" '.BackupPolicy.Status == "DISABLED"' "$EFSBK"
report CTR "EFS automatic backups DISABLED (no untracked default vault)"

# ---------------------------------------------------------------- drift
begin
set +e
"$TF" plan -detailed-exitcode -input=false -lock=false -no-color >"${ERRLOG}.plan" 2>&1
rc=$?
set -e
case "$rc" in
  0) ok ;;
  2) bad "terraform plan shows changes: declared != live ($(grep -E '^Plan:|will be|must be' "${ERRLOG}.plan" | head -5 | tr '\n' ';'))" ;;
  *) unv "terraform plan errored (exit $rc): $(tail -3 "${ERRLOG}.plan" | tr '\n' ' ')" ;;
esac
rm -f "${ERRLOG}.plan"
report DRIFT "terraform plan -detailed-exitcode == 0 (declared == live)"

echo
if [ -s "$ERRLOG" ]; then echo "AWS/terraform stderr (first 10 lines):"; head -10 "$ERRLOG"; echo; fi
echo "summary: ${n_pass} PASS, ${n_fail} FAIL, ${n_unv} UNVERIFIED"
[ "$n_fail" -eq 0 ] && [ "$n_unv" -eq 0 ]

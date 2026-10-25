#!/usr/bin/env bash
# Offline self-test for tests/live/verify.sh. NO AWS: `aws` and `terraform` are
# replaced on PATH by stubs that serve fixture JSON shaped like real AWS CLI
# responses. Proves the verifier itself is a real guard:
#   - a contract-conforming fixture gives all PASS, exit 0
#   - each broken fixture flips the expected R-ID to FAIL (and exit != 0)
#   - an API error flips the R-ID to UNVERIFIED (never PASS) and exit != 0
#   - plan drift (exit 2) -> DRIFT FAIL; plan error (exit 1) -> UNVERIFIED
#
#   bash tests/live/selftest.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sefs-live-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'

ACC=111122223333
FSARN="arn:aws:elasticfilesystem:us-east-1:$ACC:file-system/fs-1"
APW="arn:aws:elasticfilesystem:us-east-1:$ACC:access-point/fsap-w"
APR="arn:aws:elasticfilesystem:us-east-1:$ACC:access-point/fsap-r"
ROLEW="arn:aws:iam::$ACC:role/sefs-writer-task"
ROLER="arn:aws:iam::$ACC:role/sefs-reader-task"

# ------------------------------------------------------------------ fixtures
mkfix() {
  local d="$1"; mkdir -p "$d"
  cat >"$d/tf-output.json" <<EOF
{"vpc_id":{"value":"vpc-1"},"private_subnet_ids":{"value":["subnet-p1","subnet-p2"]},
 "apps_security_group_id":{"value":"sg-a"},"efs_security_group_id":{"value":"sg-e"},
 "file_system_id":{"value":"fs-1"},"writer_access_point_id":{"value":"fsap-w"},"reader_access_point_id":{"value":"fsap-r"},
 "backup_vault_name":{"value":"sefs-vault"},"backup_plan_id":{"value":"plan-1"},"cluster_name":{"value":"sefs"},
 "writer_service_name":{"value":"sefs-writer"},"reader_service_name":{"value":"sefs-reader"},
 "writer_log_group":{"value":"/ecs/sefs/writer"},"reader_log_group":{"value":"/ecs/sefs/reader"},
 "reader_task_definition_arn":{"value":"arn:aws:ecs:us-east-1:$ACC:task-definition/sefs-reader:1"},
 "alarm_names":{"value":["sefs-reader-no-running-task","sefs-writer-no-running-task","sefs-efs-burst-credits-low"]},
 "region":{"value":"us-east-1"},"name":{"value":"sefs"},"az_count":{"value":2},"kms_key_arn":{"value":null}}
EOF
  cat >"$d/cloudwatch.describe-alarms.json" <<'EOF'
{"MetricAlarms":[
 {"AlarmName":"sefs-reader-no-running-task","AlarmActions":["arn:aws:sns:us-east-1:111122223333:sefs-alerts"]},
 {"AlarmName":"sefs-writer-no-running-task","AlarmActions":["arn:aws:sns:us-east-1:111122223333:sefs-alerts"]},
 {"AlarmName":"sefs-efs-burst-credits-low","AlarmActions":["arn:aws:sns:us-east-1:111122223333:sefs-alerts"]}]}
EOF
  echo '{"clusters":[{"clusterName":"sefs","settings":[{"name":"containerInsights","value":"enabled"}]}]}' >"$d/ecs.describe-clusters.json"
  echo '{"DashboardName":"sefs-overview","DashboardBody":"{}"}' >"$d/cloudwatch.get-dashboard.json"
  cat >"$d/tf-console.txt" <<'EOF'
var.region "us-east-1"
var.name "sefs"
var.kms_key_arn null
var.az_count 2
EOF
  echo 0 >"$d/plan-rc"
  cat >"$d/efs.describe-file-systems.json" <<EOF
{"FileSystems":[{"FileSystemId":"fs-1","FileSystemArn":"$FSARN","LifeCycleState":"available","Encrypted":true,
 "PerformanceMode":"generalPurpose","ThroughputMode":"bursting","KmsKeyId":"arn:aws:kms:us-east-1:$ACC:key/k1"}]}
EOF
  echo '{"LifecyclePolicies":[{"TransitionToIA":"AFTER_30_DAYS"}]}' >"$d/efs.describe-lifecycle-configuration.json"
  cat >"$d/efs.describe-mount-targets.json" <<'EOF'
{"MountTargets":[{"MountTargetId":"fsmt-1","SubnetId":"subnet-p1","AvailabilityZoneName":"us-east-1a","LifeCycleState":"available"},
                 {"MountTargetId":"fsmt-2","SubnetId":"subnet-p2","AvailabilityZoneName":"us-east-1b","LifeCycleState":"available"}]}
EOF
  echo '{"SecurityGroups":["sg-e"]}' >"$d/efs.describe-mount-target-security-groups.json"
  cat >"$d/efs.describe-access-points.json" <<EOF
{"AccessPoints":[
 {"AccessPointId":"fsap-w","AccessPointArn":"$APW","LifeCycleState":"available","PosixUser":{"Uid":1001,"Gid":1000},
  "RootDirectory":{"Path":"/shared","CreationInfo":{"OwnerUid":1001,"OwnerGid":1000,"Permissions":"0775"}}},
 {"AccessPointId":"fsap-r","AccessPointArn":"$APR","LifeCycleState":"available","PosixUser":{"Uid":1002,"Gid":1000},
  "RootDirectory":{"Path":"/shared","CreationInfo":{"OwnerUid":1001,"OwnerGid":1000,"Permissions":"0775"}}}]}
EOF
  jq -n --arg fs "$FSARN" --arg w "$ROLEW" --arg r "$ROLER" --arg apw "$APW" --arg apr "$APR" '{Version:"2012-10-17",Statement:[
    {Sid:"DenyInsecureTransport",Effect:"Deny",Principal:{AWS:"*"},Action:"*",Resource:$fs,Condition:{Bool:{"aws:SecureTransport":"false"}}},
    {Sid:"AllowWriterMountWriteViaWriterAP",Effect:"Allow",Principal:{AWS:$w},Action:["elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite"],Resource:$fs,Condition:{StringEquals:{"elasticfilesystem:AccessPointArn":$apw}}},
    {Sid:"AllowReaderMountViaReaderAP",Effect:"Allow",Principal:{AWS:$r},Action:"elasticfilesystem:ClientMount",Resource:$fs,Condition:{StringEquals:{"elasticfilesystem:AccessPointArn":$apr}}},
    {Sid:"DenyReaderWriteAndRoot",Effect:"Deny",Principal:{AWS:$r},Action:["elasticfilesystem:ClientWrite","elasticfilesystem:ClientRootAccess"],Resource:$fs}]}' >"$d/policy.json"
  jq -n --rawfile p "$d/policy.json" '{FileSystemId:"fs-1",Policy:$p}' >"$d/efs.describe-file-system-policy.json"
  echo '{"BackupPolicy":{"Status":"DISABLED"}}' >"$d/efs.describe-backup-policy.json"
  cat >"$d/ec2.describe-subnets.json" <<'EOF'
{"Subnets":[{"SubnetId":"subnet-p1","AvailabilityZone":"us-east-1a","MapPublicIpOnLaunch":false},
            {"SubnetId":"subnet-p2","AvailabilityZone":"us-east-1b","MapPublicIpOnLaunch":false},
            {"SubnetId":"subnet-u1","AvailabilityZone":"us-east-1a","MapPublicIpOnLaunch":false},
            {"SubnetId":"subnet-u2","AvailabilityZone":"us-east-1b","MapPublicIpOnLaunch":false}]}
EOF
  cat >"$d/ec2.describe-route-tables.json" <<'EOF'
{"RouteTables":[
 {"RouteTableId":"rtb-pub","Associations":[{"SubnetId":"subnet-u1"},{"SubnetId":"subnet-u2"}],"Routes":[{"DestinationCidrBlock":"10.40.0.0/16","GatewayId":"local"},{"DestinationCidrBlock":"0.0.0.0/0","GatewayId":"igw-1"}]},
 {"RouteTableId":"rtb-p1","Associations":[{"SubnetId":"subnet-p1"}],"Routes":[{"DestinationCidrBlock":"10.40.0.0/16","GatewayId":"local"},{"DestinationCidrBlock":"0.0.0.0/0","NatGatewayId":"nat-1"}]},
 {"RouteTableId":"rtb-p2","Associations":[{"SubnetId":"subnet-p2"}],"Routes":[{"DestinationCidrBlock":"10.40.0.0/16","GatewayId":"local"},{"DestinationCidrBlock":"0.0.0.0/0","NatGatewayId":"nat-2"}]}]}
EOF
  echo '{"SecurityGroupRules":[{"SecurityGroupRuleId":"sgr-e1","GroupId":"sg-e","IsEgress":false,"IpProtocol":"tcp","FromPort":2049,"ToPort":2049,"ReferencedGroupInfo":{"GroupId":"sg-a"}}]}' >"$d/ec2.describe-security-group-rules.sg-e.json"
  echo '{"SecurityGroupRules":[{"SecurityGroupRuleId":"sgr-a1","GroupId":"sg-a","IsEgress":true,"IpProtocol":"-1","FromPort":-1,"ToPort":-1,"CidrIpv4":"0.0.0.0/0"}]}' >"$d/ec2.describe-security-group-rules.sg-a.json"
  cat >"$d/ecs.describe-services.json" <<EOF
{"failures":[],"services":[
 {"serviceName":"sefs-writer","taskDefinition":"arn:aws:ecs:us-east-1:$ACC:task-definition/sefs-writer:1",
  "networkConfiguration":{"awsvpcConfiguration":{"subnets":["subnet-p2","subnet-p1"],"securityGroups":["sg-a"],"assignPublicIp":"DISABLED"}}},
 {"serviceName":"sefs-reader","taskDefinition":"arn:aws:ecs:us-east-1:$ACC:task-definition/sefs-reader:1",
  "networkConfiguration":{"awsvpcConfiguration":{"subnets":["subnet-p1","subnet-p2"],"securityGroups":["sg-a"],"assignPublicIp":"DISABLED"}}}]}
EOF
  for who in writer reader; do
    local ro=false ap=fsap-w role="$ROLEW"
    [ "$who" = reader ] && ro=true ap=fsap-r role="$ROLER"
    jq -n --arg role "$role" --arg ap "$ap" --argjson ro "$ro" '{taskDefinition:{taskRoleArn:$role,
      containerDefinitions:[{name:"x",mountPoints:[{sourceVolume:"shared",containerPath:"/mnt/shared",readOnly:$ro}]}],
      volumes:[{name:"shared",efsVolumeConfiguration:{fileSystemId:"fs-1",transitEncryption:"ENABLED",authorizationConfig:{accessPointId:$ap,iam:"ENABLED"}}}]}}' \
      >"$d/ecs.describe-task-definition.$who.json"
  done
  echo '{"BackupPlan":{"BackupPlanName":"sefs-plan","Rules":[{"RuleName":"daily","TargetBackupVaultName":"sefs-vault","Lifecycle":{"DeleteAfterDays":35}}]}}' >"$d/backup.get-backup-plan.json"
  echo '{"BackupSelectionsList":[{"SelectionId":"sel-1"}]}' >"$d/backup.list-backup-selections.json"
  jq -n --arg fs "$FSARN" '{BackupSelection:{SelectionName:"s",Resources:[$fs]}}' >"$d/backup.get-backup-selection.json"
  echo '{"BackupVaultName":"sefs-vault"}' >"$d/backup.describe-backup-vault.json"
  echo '{"Aliases":[{"AliasName":"alias/aws/elasticfilesystem"}]}' >"$d/kms.list-aliases.json"
  echo '{"PolicyNames":["sefs-reader-efs"]}' >"$d/iam.list-role-policies.json"
  echo '{"AttachedPolicies":[]}' >"$d/iam.list-attached-role-policies.json"
  jq -n --arg fs "$FSARN" --arg ap "$APR" '{PolicyDocument:{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["elasticfilesystem:ClientMount"],Resource:$fs,Condition:{StringEquals:{"elasticfilesystem:AccessPointArn":$ap}}}]}}' >"$d/iam.get-role-policy.json"
}

# ------------------------------------------------------------------ stubs
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'EOF'
#!/usr/bin/env bash
# Stub AWS CLI: serves $FIX/<service>.<op>[.<key>].json. Never touches the network.
args=(); query=""; text=0
while [ $# -gt 0 ]; do
  case "$1" in
    --region|--output) [ "$1" = --output ] && [ "$2" = text ] && text=1; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
svc="${args[0]}"; op="${args[1]}"
case " ${FAIL_OPS:-} " in *" $svc.$op "*) echo "An error occurred (AccessDenied) when calling $op" >&2; exit 254 ;; esac
if [ "$svc.$op" = "sts.get-caller-identity" ]; then echo 111122223333; exit 0; fi
key=""
case "$svc.$op" in
  ec2.describe-security-group-rules) for a in "${args[@]}"; do case "$a" in Name=group-id,Values=*) key="${a#Name=group-id,Values=}";; esac; done ;;
  ecs.describe-task-definition)      for a in "${args[@]}"; do case "$a" in *sefs-writer*) key=writer;; *sefs-reader*) key=reader;; esac; done ;;
esac
f="$FIX/$svc.$op${key:+.$key}.json"
[ -f "$f" ] || { echo "stub: no fixture $f" >&2; exit 255; }
cat "$f"
EOF
cat >"$WORK/bin/terraform" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  output)  cat "$FIX/tf-output.json" ;;
  console) read -r q; awk -v q="$q" '$1==q { $1=""; sub(/^ /,""); print }' "$FIX/tf-console.txt" ;;
  plan)    echo "stub plan"; exit "$(cat "$FIX/plan-rc")" ;;
  *)       echo "stub terraform: unsupported $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/aws" "$WORK/bin/terraform"

# ------------------------------------------------------------------ scenarios
fails=0
# scenario NAME "<fixture edit cmd>" EXPECT_EXIT(0|nonzero) "<R-ID> <STATUS>" ...
scenario() {
  local name="$1" edit="$2" want_exit="$3"; shift 3
  local fix="$WORK/fix-$name"; mkfix "$fix"
  (cd "$fix" && eval "$edit")
  local out rc=0
  out="$(PATH="$WORK/bin:$PATH" FIX="$fix" FAIL_OPS="${FAIL_OPS:-}" TF=terraform bash "$ROOT/tests/live/verify.sh" 2>&1)" || rc=$?
  out="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
  local okk=1 exp
  if [ "$want_exit" = 0 ] && [ "$rc" -ne 0 ]; then okk=0; fi
  if [ "$want_exit" != 0 ] && [ "$rc" -eq 0 ]; then okk=0; fi
  for exp in "$@"; do
    local rid="${exp% *}" st="${exp#* }"
    grep -Eq "^${st}[[:space:]]+${rid}[[:space:]]" <<<"$out" || okk=0
  done
  if [ "$want_exit" = 0 ] && grep -Eq '^(FAIL|UNVERIFIED) ' <<<"$out"; then okk=0; fi
  if [ "$okk" = 1 ]; then echo "${GRN}ok${RST}   $name (exit $rc)"; else
    echo "${RED}BAD${RST}  $name (exit $rc, wanted ${want_exit}; expected: $*)"; echo "$out" | sed 's/^/     | /'; fails=$((fails + 1)); fi
}
J() { local f="$1" q="$2"; jq "$q" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }

scenario good ":" 0 "R2 PASS" "R3 PASS" "R4 PASS" "R5 PASS" "R6 PASS" "R7 PASS" "R8 PASS" "R9 PASS" "R10 PASS" "R12 PASS" "R13 PASS" "R14 PASS" "R15 PASS" "CTR PASS" "OBS PASS" "DRIFT PASS"
scenario alarm_missing    "J cloudwatch.describe-alarms.json '.MetricAlarms |= .[:2]'" 1 "OBS FAIL"
scenario alarm_no_action  "J cloudwatch.describe-alarms.json '.MetricAlarms[0].AlarmActions=[]'" 1 "OBS FAIL"
scenario insights_off     "J ecs.describe-clusters.json '.clusters[0].settings[0].value=\"disabled\"'" 1 "OBS FAIL"
scenario legacy_no_obs    "J tf-output.json 'del(.alarm_names)'" 1 "OBS UNVERIFIED"
scenario no_az_count_out  "J tf-output.json 'del(.az_count)'" 1
scenario sg_efs_cidr      "J ec2.describe-security-group-rules.sg-e.json '.SecurityGroupRules += [{IsEgress:false,IpProtocol:\"tcp\",FromPort:2049,ToPort:2049,CidrIpv4:\"10.0.0.0/8\"}]'" 1 "R9 FAIL"
scenario sg_efs_from_cidr "J ec2.describe-security-group-rules.sg-e.json '.SecurityGroupRules[0] |= (del(.ReferencedGroupInfo) | .CidrIpv4=\"0.0.0.0/0\")'" 1 "R9 FAIL"
scenario reader_rw_mount  "J ecs.describe-task-definition.reader.json '.taskDefinition.containerDefinitions[0].mountPoints[0].readOnly=false'" 1 "R3 FAIL"
scenario reader_iam_off   "J ecs.describe-task-definition.reader.json '.taskDefinition.volumes[0].efsVolumeConfiguration.authorizationConfig.iam=\"DISABLED\"'" 1 "R3 FAIL"
scenario no_reader_deny   "J policy.json 'del(.Statement[3])' && jq -n --rawfile p policy.json '{Policy:\$p}' > efs.describe-file-system-policy.json" 1 "R3 FAIL"
scenario reader_inline_write "J iam.get-role-policy.json '.PolicyDocument.Statement[0].Action += [\"elasticfilesystem:ClientWrite\"]'" 1 "R3 FAIL"
scenario retention_34     "J backup.get-backup-plan.json '.BackupPlan.Rules[0].Lifecycle.DeleteAfterDays=34'" 1 "R14 FAIL"
scenario selection_no_efs "J backup.get-backup-selection.json '.BackupSelection.Resources=[]'" 1 "R14 FAIL"
scenario not_encrypted    "J efs.describe-file-systems.json '.FileSystems[0].Encrypted=false'" 1 "R12 FAIL"
scenario maxio            "J efs.describe-file-systems.json '.FileSystems[0].PerformanceMode=\"maxIO\"'" 1 "R12 FAIL"
scenario ia_60            "J efs.describe-lifecycle-configuration.json '.LifecyclePolicies[0].TransitionToIA=\"AFTER_60_DAYS\"'" 1 "R15 FAIL"
scenario one_mount_target "J efs.describe-mount-targets.json '.MountTargets |= .[:1]'" 1 "R7 FAIL"
scenario public_ip        "J ecs.describe-services.json '.services[1].networkConfiguration.awsvpcConfiguration.assignPublicIp=\"ENABLED\"'" 1 "R6 FAIL"
scenario svc_public_subnet "J ecs.describe-services.json '.services[0].networkConfiguration.awsvpcConfiguration.subnets=[\"subnet-u1\",\"subnet-p2\"]'" 1 "R6 FAIL"
scenario wrong_sg         "J ecs.describe-services.json '.services[0].networkConfiguration.awsvpcConfiguration.securityGroups=[\"sg-x\"]'" 1 "R8 FAIL"
scenario ap_uid           "J efs.describe-access-points.json '.AccessPoints[1].PosixUser.Uid=0'" 1 "R10 FAIL"
scenario single_az        "J ec2.describe-subnets.json '.Subnets |= map(.AvailabilityZone=\"us-east-1a\")'" 1 "R5 FAIL"
scenario efs_auto_backup  "J efs.describe-backup-policy.json '.BackupPolicy.Status=\"ENABLED\"'" 1 "CTR FAIL"
scenario drift            "echo 2 > plan-rc" 1 "DRIFT FAIL"
scenario plan_error       "echo 1 > plan-rc" 1 "DRIFT UNVERIFIED"
FAIL_OPS="efs.describe-file-system-policy" scenario api_denied_policy ":" 1 "R3 UNVERIFIED" "R2 UNVERIFIED"
FAIL_OPS="ec2.describe-security-group-rules" scenario api_denied_sg ":" 1 "R9 UNVERIFIED"
FAIL_OPS="backup.get-backup-plan" scenario api_denied_backup ":" 1 "R14 UNVERIFIED"

echo
if [ "$fails" -eq 0 ]; then echo "${GRN}verify.sh selftest: all scenarios behaved${RST}"; else echo "${RED}verify.sh selftest: $fails scenario(s) misbehaved${RST}"; fi
[ "$fails" -eq 0 ]

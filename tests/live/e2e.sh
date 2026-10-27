#!/usr/bin/env bash
# End-to-end behaviour on REAL AWS, after `make up` and a clean `verify.sh`.
#
#   E2E_CONFIRM=yes bash tests/live/e2e.sh
#
# THIS SCRIPT CHANGES LIVE AWS (gated by E2E_CONFIRM=yes):
#   - E3 registers a temporary task definition + runs one Fargate task,
#     then deregisters/deletes that task definition (always, via trap)
#   - E4 runs `terraform destroy -target=module.apps` and `terraform apply`
#     (set E2E_SKIP_PERSISTENCE=1 to skip E4)
#
# Steps (each prints exactly one PASS / FAIL / UNVERIFIED line):
#   E1 R2+R3  writer WROTE files; reader READ the same files with the same sha256
#   E2 R3     reader startup probe logged `WRITE_PROBE DENIED ...` (and never ALLOWED)
#             NOTE: this only proves the readOnly mount FLAG (EROFS). It is not the R3 proof.
#   E3 R3     IAM mutation: a COPY of the reader task def with readOnly=false
#             (same reader task role, same reader access point, IAM auth on)
#             tries to write. POSIX would allow it (dir 0775, group 1000), so the
#             ONLY thing that can stop it is the EFS file-system-policy Deny.
#             PASS = write denied with EACCES / EPERM / EROFS (errno recorded).
#             FAIL = write succeeded. UNVERIFIED = task never ran / never logged.
#   E4 R1     persistence: files written before `terraform destroy -target=module.apps`
#             are READ again (same sha256) by the fresh reader after re-apply, and
#             the file system ID + creation time are unchanged.
#   E5 GUI    the map's API, probed with a throwaway Cognito user (created + deleted
#             here): overview lists the live stack with nothing "down", the EFS room
#             proves the reader deny, the cost report has a positive rate, the page loads.
#
# Silence is never success: a step that cannot observe its evidence is
# UNVERIFIED, and any non-PASS makes the exit code non-zero.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
TF="${TF:-terraform}"
WAIT="${E2E_WAIT_SECONDS:-300}"       # max seconds to wait for log evidence
MIN_FILES="${E2E_MIN_FILES:-3}"       # E1: at least this many files must round-trip
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
declare -a RESULTS=()
overall=0

say()    { printf '%s\n' "$*" >&2; }
result() { # result <PASS|FAIL|UNVERIFIED> <step> <message>
  local c
  case "$1" in PASS) c="$GRN" ;; FAIL) c="$RED"; overall=1 ;; *) c="$YEL"; overall=1 ;; esac
  printf '%s%-10s%s %-3s %s\n' "$c" "$1" "$RST" "$2" "$3"
  RESULTS+=("$1 $2 $3")
}

[ "${E2E_CONFIRM:-}" = "yes" ] || { say "Refusing: this script changes live AWS. Re-run with E2E_CONFIRM=yes."; exit 2; }
for t in aws jq "$TF"; do command -v "$t" >/dev/null || { say "missing tool: $t"; exit 3; }; done

OUT="$("$TF" output -json)"
o() { jq -r --arg k "$1" '.[$k].value // empty | if type=="array" then join(",") else . end' <<<"$OUT"; }
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(o region)}}"   # from outputs: `terraform console` under remote state hung for 16 min when AWS_REGION was unset (2026-10-27)
NAME="$(o name)"   # from outputs: under remote state `terraform console` prints "Acquiring state lock..." into stdout
CLUSTER="$(o cluster_name)"; SVC_W="$(o writer_service_name)"; SVC_R="$(o reader_service_name)"
LG_W="$(o writer_log_group)"; LG_R="$(o reader_log_group)"
SUBNETS="$(o private_subnet_ids)"; SG_APPS="$(o apps_security_group_id)"; FS_ID="$(o file_system_id)"
for v in REGION CLUSTER SVC_W SVC_R LG_W LG_R SUBNETS SG_APPS FS_ID; do
  [ -n "${!v}" ] || { say "terraform output missing: $v"; exit 3; }
done
aws_() { aws --region "$REGION" "$@"; }
ACCOUNT="$(aws_ sts get-caller-identity --query Account --output text)"
now_ms() { echo $(( $(date +%s) * 1000 )); }
T_START="$(( $(now_ms) - ${E2E_LOOKBACK_SECONDS:-3600} * 1000 ))"    # E1/E4 evidence window (default 1h)
T_PROBE="$(( $(now_ms) - 7 * 86400 * 1000 ))"                          # E2: startup probe may be old; logs keep 7 days

say "SEFS e2e  account=$ACCOUNT region=$REGION cluster=$CLUSTER  $(date -u +%Y-%m-%dT%H:%M:%SZ)  tree=$(git rev-parse --short HEAD 2>/dev/null || echo '?')"

# messages GROUP START_MS PATTERN [STREAM_PREFIX] -> one message per line (CLI auto-paginates)
messages() {
  local args=(logs filter-log-events --log-group-name "$1" --start-time "$2" --filter-pattern "$3" --output json)
  [ -n "${4:-}" ] && args+=(--log-stream-name-prefix "$4")
  # An API error yields no lines (stderr shown); callers then report UNVERIFIED, never PASS.
  { aws_ "${args[@]}" | jq -r '.events[].message' | tr -d '\r'; } || true
}
# file -> sha pairs from WROTE/READ lines: "<file> <sha>"
pairs() { sed -nE "s/^$1 ([^ ]+\.json) sha256=([0-9a-f]{64})\$/\1 \2/p"; }

say "waiting for services to be stable..."
aws_ ecs wait services-stable --cluster "$CLUSTER" --services "$SVC_W" "$SVC_R" || say "warning: services-stable waiter timed out"

# ======================================================================== E1
e1() {
  local deadline=$(( $(date +%s) + WAIT )) w r matched mism
  while :; do
    w="$(messages "$LG_W" "$T_START" '"WROTE"' | pairs WROTE | sort -u)"
    r="$(messages "$LG_R" "$T_START" '"READ"'  | pairs READ  | sort -u)"
    matched="$(comm -12 <(echo "$w") <(echo "$r") | grep -c . || true)"
    # same filename, different sha = corruption / partial read
    mism="$(join <(echo "$w") <(echo "$r") 2>/dev/null | awk '$2 != $3' | head -3 || true)"
    if [ -n "$mism" ]; then result FAIL E1 "R2/R3: sha256 mismatch between WROTE and READ: $mism"; return; fi
    if [ "$matched" -ge "$MIN_FILES" ]; then
      result PASS E1 "R2/R3: $matched files written by writer and read back by reader with identical sha256 (e.g. $(comm -12 <(echo "$w") <(echo "$r") | head -1))"
      return
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 15
  done
  if [ -z "$w" ]; then result UNVERIFIED E1 "no WROTE lines in $LG_W within ${WAIT}s (writer not running or not logging)"
  else result FAIL E1 "only $matched of $(echo "$w" | grep -c .) written files were READ with matching sha256 within ${WAIT}s"; fi
}

# ======================================================================== E2
e2() {
  local deadline=$(( $(date +%s) + WAIT )) denied allowed
  while :; do
    denied="$(messages "$LG_R" "$T_PROBE" '"WRITE_PROBE DENIED"' | grep -E '^WRITE_PROBE DENIED ' | tail -1 || true)"
    allowed="$(messages "$LG_R" "$T_PROBE" '"WRITE_PROBE ALLOWED"' | grep -E '^WRITE_PROBE ALLOWED' | tail -1 || true)"
    if [ -n "$allowed" ]; then result FAIL E2 "R3: reader logged '$allowed'"; return; fi
    if [ -n "$denied" ]; then result PASS E2 "R3 (mount flag only): reader logged '$denied'"; return; fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 15
  done
  result UNVERIFIED E2 "no WRITE_PROBE line in $LG_R within ${WAIT}s"
}

# ======================================================================== E3
MUT_TD_ARN=""
cleanup_e3() {
  if [ -n "$MUT_TD_ARN" ]; then
    aws_ ecs deregister-task-definition --task-definition "$MUT_TD_ARN" >/dev/null 2>&1 \
      && say "E3 cleanup: deregistered $MUT_TD_ARN" || say "E3 cleanup: WARNING could not deregister $MUT_TD_ARN"
    aws_ ecs delete-task-definitions --task-definitions "$MUT_TD_ARN" >/dev/null 2>&1 \
      && say "E3 cleanup: deleted $MUT_TD_ARN" || say "E3 cleanup: note: delete-task-definitions failed (INACTIVE revision remains; harmless, no cost)"
    MUT_TD_ARN=""
  fi
}
trap cleanup_e3 EXIT

# Runs inside the reader image (eclipse-temurin JRE, has /bin/sh). Single-quoted
# heredoc: nothing here is expanded by this script.
read -r -d '' PROBE_SCRIPT <<'SH' || true
echo "IAM_MUTATION_START uid=$(id -u) gid=$(id -g)"
echo "IAM_MUTATION_MOUNT $(grep ' /mnt/shared ' /proc/mounts || echo none)"
echo "IAM_MUTATION_DIR $(ls -ldn /mnt/shared)"
f="/mnt/shared/.iam-mutation-probe-$(date +%s)-$$"
if err=$( { printf 'x' > "$f"; } 2>&1 ); then
  echo "IAM_MUTATION_WRITE ALLOWED $f"
  rm -f "$f"
else
  case "$err" in
    *"Permission denied"*)       e=EACCES ;;
    *"Operation not permitted"*) e=EPERM ;;
    *"Read-only file system"*)   e=EROFS ;;
    *)                           e=OTHER ;;
  esac
  echo "IAM_MUTATION_WRITE DENIED $e $err"
fi
echo "IAM_MUTATION_END"
SH

e3() {
  local td_r td_json reg_in reg task_arn task_id cname stream lines wl desc exit_code reason
  td_r="$(aws_ ecs describe-services --cluster "$CLUSTER" --services "$SVC_R" --query 'services[0].taskDefinition' --output text)" || td_r=""
  td_json="$(aws_ ecs describe-task-definition --task-definition "$td_r" --output json)" || td_json=""
  if [ -z "$td_json" ]; then result UNVERIFIED E3 "could not read the live reader task definition"; return; fi
  cname="$(jq -r '.taskDefinition.containerDefinitions[0].name' <<<"$td_json")"
  reg_in="$(jq --arg s "$PROBE_SCRIPT" --arg n "$NAME" '.taskDefinition | {
      family: (.family + "-iam-mutation"),
      taskRoleArn, executionRoleArn, networkMode, requiresCompatibilities, cpu, memory, runtimePlatform, volumes,
      containerDefinitions: [ .containerDefinitions[0]
        | .mountPoints |= map(.readOnly = false)
        | .entryPoint = ["/bin/sh", "-c"]
        | .command = [$s]
        | .logConfiguration.options["awslogs-stream-prefix"] = "iam-mutation"
        | del(.healthCheck) ],
      tags: [{key: "Project", value: $n}, {key: "ManagedBy", value: "tests/live/e2e.sh"}] }' <<<"$td_json")"
  reg="$(aws_ ecs register-task-definition --cli-input-json "$reg_in" --output json)" || reg=""
  if [ -z "$reg" ]; then result UNVERIFIED E3 "register-task-definition failed"; return; fi
  MUT_TD_ARN="$(jq -r '.taskDefinition.taskDefinitionArn' <<<"$reg")"
  say "E3: registered $MUT_TD_ARN"
  # Guard: the copy must really be readOnly=false, same role, same AP, IAM on.
  if ! jq -e --argjson o "$td_json" '.taskDefinition as $t
        | ($t.containerDefinitions[0].mountPoints | all(.readOnly == false))
        and $t.taskRoleArn == $o.taskDefinition.taskRoleArn
        and $t.volumes == $o.taskDefinition.volumes
        and ($t.volumes[0].efsVolumeConfiguration.authorizationConfig.iam == "ENABLED")' >/dev/null <<<"$reg"; then
    result UNVERIFIED E3 "registered copy is not (readOnly=false, same role, same volume/AP, iam ENABLED); refusing to interpret"
    return
  fi
  task_arn="$(aws_ ecs run-task --cluster "$CLUSTER" --task-definition "$MUT_TD_ARN" --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG_APPS],assignPublicIp=DISABLED}" \
      --query 'tasks[0].taskArn' --output text)" || task_arn=""
  if [ -z "$task_arn" ] || [ "$task_arn" = "None" ]; then result UNVERIFIED E3 "run-task returned no task"; return; fi
  task_id="${task_arn##*/}"
  say "E3: started task $task_id, waiting for it to stop..."
  aws_ ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn" || say "E3: tasks-stopped waiter timed out"
  desc="$(aws_ ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" --output json)" || desc='{}'
  exit_code="$(jq -r '.tasks[0].containers[0].exitCode // "none"' <<<"$desc")"
  reason="$(jq -r '.tasks[0].stoppedReason // ""' <<<"$desc")"
  stream="iam-mutation/$cname/$task_id"
  lines=""
  local deadline=$(( $(date +%s) + 120 ))
  while :; do
    lines="$(aws_ logs get-log-events --log-group-name "$LG_R" --log-stream-name "$stream" --start-from-head --output json 2>/dev/null \
               | jq -r '.events[].message' | tr -d '\r' || true)"
    grep -q '^IAM_MUTATION_END' <<<"$lines" && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 10
  done
  printf '%s\n' "$lines" | grep '^IAM_MUTATION' | sed 's/^/     | /' >&2 || true
  wl="$(grep -E '^IAM_MUTATION_WRITE ' <<<"$lines" | tail -1 || true)"
  case "$wl" in
    "IAM_MUTATION_WRITE ALLOWED"*)
      result FAIL E3 "R3: reader role WROTE through a readOnly=false mount: the FS-policy Deny is NOT enforcing ($wl)" ;;
    "IAM_MUTATION_WRITE DENIED EACCES"*|"IAM_MUTATION_WRITE DENIED EPERM"*|"IAM_MUTATION_WRITE DENIED EROFS"*)
      result PASS E3 "R3: reader role denied write with readOnly=false; errno=$(awk '{print $3}' <<<"$wl") (only EFS IAM can deny here). line: $wl" ;;
    "IAM_MUTATION_WRITE DENIED"*)
      result UNVERIFIED E3 "R3: write failed but not with EACCES/EPERM/EROFS, cannot attribute to IAM: $wl" ;;
    *)
      result UNVERIFIED E3 "R3: no IAM_MUTATION_WRITE line (task exit=$exit_code, stoppedReason='$reason'); the task may have failed to mount or never ran" ;;
  esac
  cleanup_e3
}

# ======================================================================== E4
e4() {
  if [ "${E2E_SKIP_PERSISTENCE:-}" = "1" ]; then result UNVERIFIED E4 "R1: skipped by E2E_SKIP_PERSISTENCE=1"; return; fi
  local before fs_before fs_after t1 after missing n
  before="$(messages "$LG_W" "$T_START" '"WROTE"' | pairs WROTE | sort -u)"
  n="$(echo "$before" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then result UNVERIFIED E4 "R1: no files known to exist before destroy (no WROTE lines)"; return; fi
  fs_before="$(aws_ efs describe-file-systems --file-system-id "$FS_ID" --query 'FileSystems[0].[FileSystemId,CreationTime]' --output text)"
  say "E4: $n files on EFS before destroy; fs=$fs_before"
  say "E4: terraform destroy -target=module.apps (EFS must survive: prevent_destroy + not targeted)"
  if ! "$TF" destroy -target=module.apps -auto-approve -input=false; then
    result FAIL E4 "R1: terraform destroy -target=module.apps failed (if prevent_destroy blocked it, the EFS was in the destroy graph). Apps may be partly destroyed: run terraform apply."
    return
  fi
  fs_after="$(aws_ efs describe-file-systems --file-system-id "$FS_ID" --query 'FileSystems[0].[FileSystemId,CreationTime]' --output text 2>/dev/null || echo GONE)"
  if [ "$fs_after" != "$fs_before" ]; then result FAIL E4 "R1: file system changed or vanished after apps destroy ($fs_before -> $fs_after)"; return; fi
  t1="$(now_ms)"
  say "E4: terraform apply (re-create apps)"
  if ! "$TF" apply -auto-approve -input=false; then
    result FAIL E4 "R1: terraform apply after apps destroy failed; apps are DOWN until a successful apply"
    return
  fi
  OUT="$("$TF" output -json)"
  if [ "$(o file_system_id)" != "$FS_ID" ]; then result FAIL E4 "R1: file_system_id changed after re-apply ($FS_ID -> $(o file_system_id))"; return; fi
  # The fresh reader has an empty 'seen' set, so it READs every existing file.
  local deadline=$(( $(date +%s) + WAIT ))
  while :; do
    after="$(messages "$LG_R" "$t1" '"READ"' | pairs READ | sort -u)"
    missing="$(comm -23 <(echo "$before") <(echo "$after") | grep -c . || true)"
    [ "$missing" -eq 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 15
  done
  if [ "$missing" -eq 0 ]; then
    result PASS E4 "R1: all $n pre-destroy files READ back (same name + sha256) by the re-created reader; fs unchanged ($fs_after)"
  elif [ -z "$after" ]; then
    result UNVERIFIED E4 "R1: re-created reader logged no READ lines within ${WAIT}s"
  else
    result FAIL E4 "R1: $missing of $n pre-destroy files not READ back with the same sha256 after re-apply"
  fi
}

# ======================================================================== E5
# The map (D32): a throwaway Cognito user is created with the deployer's IAM rights, a token is minted
# with ADMIN_USER_PASSWORD_AUTH, and the read-only API is probed end to end: the overview must list the
# live stack with no "down" node, the EFS room must prove the reader deny, the cost report must carry a
# positive hourly rate, and the page must load. The user is deleted afterwards (trap).
e5() {
  OUT="$("$TF" output -json)"
  local url api pool client user pw tok ov room cost page http n_down n_nodes
  url="$(o gui_url)"; api="$(o gui_api_url)"; pool="$(o gui_user_pool_id)"
  if [ -z "$url" ]; then result UNVERIFIED E5 "GUI: not deployed (enable_gui = false)"; return; fi
  client="$(aws_ cognito-idp list-user-pool-clients --user-pool-id "$pool" --query 'UserPoolClients[0].ClientId' --output text)"
  user="e2e-probe-$(date +%s)@example.invalid"
  pw="E2e-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)!x"
  trap 'aws_ cognito-idp admin-delete-user --user-pool-id "$pool" --username "$user" >/dev/null 2>&1 || true' RETURN
  aws_ cognito-idp admin-create-user --user-pool-id "$pool" --username "$user" --message-action SUPPRESS \
    --user-attributes Name=email,Value="$user" Name=email_verified,Value=true >/dev/null
  aws_ cognito-idp admin-set-user-password --user-pool-id "$pool" --username "$user" --password "$pw" --permanent
  tok="$(aws_ cognito-idp admin-initiate-auth --user-pool-id "$pool" --client-id "$client" --auth-flow ADMIN_USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=$user,PASSWORD=$pw" --query 'AuthenticationResult.IdToken' --output text)"
  unset pw
  if [ -z "$tok" ] || [ "$tok" = "None" ]; then result UNVERIFIED E5 "GUI: could not mint a token for the probe user"; return; fi
  ov="$(curl -sS --max-time 40 -H "authorization: Bearer $tok" "$api/api/overview")" || { result UNVERIFIED E5 "GUI: /api/overview unreachable"; return; }
  n_nodes="$(jq -r '.nodes | length' <<<"$ov" 2>/dev/null || echo 0)"
  n_down="$(jq -r '[.nodes[] | select(.health=="down")] | length' <<<"$ov" 2>/dev/null || echo "?")"
  room="$(curl -sS --max-time 40 -H "authorization: Bearer $tok" "$api/api/room/efs")"
  cost="$(curl -sS --max-time 60 -H "authorization: Bearer $tok" "$api/api/cost")"
  http="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url")"
  page="$(curl -sS --max-time 20 "$url")"
  if [ "$(jq -r '.deployed' <<<"$ov")" != "true" ] || [ "$n_nodes" -lt 10 ]; then
    result FAIL E5 "GUI: overview did not describe the stack (deployed=$(jq -r .deployed <<<"$ov"), nodes=$n_nodes): $(jq -c '.error // empty' <<<"$ov")"; return; fi
  if [ "$n_down" != "0" ]; then
    result FAIL E5 "GUI: $n_down node(s) scored down: $(jq -c '[.nodes[] | select(.health=="down") | {id, reason}]' <<<"$ov")"; return; fi
  if [ "$(jq -r '.readerWriteDenied' <<<"$room")" != "true" ]; then result FAIL E5 "GUI: EFS room does not show the reader deny: $(jq -c . <<<"$room" | head -c 300)"; return; fi
  if ! jq -e '.rates.perHour > 0 and .live.natGateways >= 1' <<<"$cost" >/dev/null 2>&1; then result FAIL E5 "GUI: cost report invalid: $(jq -c '{error, rates: .rates.perHour, live}' <<<"$cost" 2>/dev/null | head -c 300)"; return; fi
  if [ "$http" != "200" ] || ! grep -q 'js/main.js' <<<"$page"; then result FAIL E5 "GUI: page HTTP $http or missing js/main.js"; return; fi
  result PASS E5 "GUI: overview $n_nodes nodes, 0 down; EFS room proves the reader deny; cost US\$$(jq -r '.rates.perHour' <<<"$cost")/h ($(jq -r '.live.natGateways' <<<"$cost") NAT); actuals: $(jq -r 'if .actuals==null then "off" elif .actuals.error then "unavailable: "+.actuals.error[0:60] else "US$"+(.actuals.totalUsd|tostring)+" / 30 d" end' <<<"$cost"); page 200"
}

# E2E_ONLY="e3" (space-separated) re-runs a subset; default is all five in order.
for step in ${E2E_ONLY:-e1 e2 e3 e4 e5}; do case "$step" in e1|e2|e3|e4|e5) "$step" ;; *) echo "unknown step $step" >&2; exit 2 ;; esac; done

echo
echo "== e2e summary =="
for r in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "$r"; done
[ "$overall" -eq 0 ] && echo "${GRN}E2E: ALL PASS${RST}" || echo "${RED}E2E: NOT ALL PASS${RST}"
exit "$overall"

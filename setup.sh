#!/usr/bin/env bash
# One-time setup for a fresh clone. Checks the host, confirms the AWS account, writes the
# local (git-ignored) account/region file, stores any secrets in SSM Parameter Store as
# SecureStrings, then deploys everything with `make up`.
#
# Secrets never touch argv, the shell history, Terraform state, or any file in this repo:
# they are read with a silent prompt and streamed to `aws ssm put-parameter` on stdin.
#
#   ./setup.sh                 interactive
#   ./setup.sh --no-deploy     everything except `make up`
#   ./setup.sh --full-tests    also run the local proof suites before deploying
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
NAME="${SEFS_NAME:-sefs}"
MANIFEST="secrets.manifest"       # one secret name per line; see the file for format
DEPLOY=1; FULL_TESTS=0
for a in "$@"; do
  case "$a" in
    --no-deploy) DEPLOY=0 ;;
    --full-tests) FULL_TESTS=1 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
ok()   { echo "${GRN}ok${RST}    $*"; }
warn() { echo "${YEL}warn${RST}  $*"; }
die()  { echo "${RED}FAIL${RST}  $*" >&2; exit 1; }
ask()  { local r; read -r -p "$1 " r </dev/tty; printf '%s' "$r"; }

echo "== 1/6 host tools"
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"; }
need terraform "https://developer.hashicorp.com/terraform/install"
need docker    "Docker Desktop or Engine with buildx"
need aws       "AWS CLI v2"
need make      "build-essential / Xcode CLT"
need jq        "brew install jq | apt install jq (tests/live needs it)"
tfv="$(terraform version -json | jq -r .terraform_version)"
[ "$(printf '%s\n' 1.9.0 "$tfv" | sort -V | head -1)" = "1.9.0" ] || die "terraform >= 1.9.0 required, found $tfv"
ok "terraform $tfv"
docker info >/dev/null 2>&1 || die "Docker daemon is not running"
docker buildx version >/dev/null 2>&1 || die "docker buildx is missing"
ok "docker $(docker version --format '{{.Server.Version}}') + buildx, host arch $(docker info --format '{{.Architecture}}')"
awsv="$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)"
[ "${awsv%%.*}" = "2" ] || die "AWS CLI v2 required, found $awsv"
ok "aws cli $awsv"
if command -v bru >/dev/null 2>&1; then ok "bru $(bru --version) (Bruno CLI)"; else warn "bru not installed; the Bruno collection still works in the Bruno app (npm i -g @usebruno/cli for the CLI)"; fi

echo "== 2/6 AWS identity"
ident="$(aws sts get-caller-identity --output json 2>/dev/null)" || die "No usable AWS credentials. Sign in first (aws login / aws sso login / aws configure), then re-run."
acct="$(jq -r .Account <<<"$ident")"; arn="$(jq -r .Arn <<<"$ident")"
region_default="$(aws configure get region 2>/dev/null || true)"; region_default="${region_default:-us-east-1}"
echo "      account: $acct"
echo "      identity: $arn"
[ "$(ask "Deploy into THIS account? [y/N]")" = "y" ] || die "Aborted. Sign in to the right account and re-run."
region="$(ask "Region [$region_default]:")"; region="${region:-$region_default}"
azs="$(aws ec2 describe-availability-zones --region "$region" --query 'length(AvailabilityZones)' --output text 2>/dev/null)" || die "Region '$region' is not usable with these credentials"
[ "$azs" -ge 2 ] || die "Region $region has $azs AZs; the design needs at least 2"
ok "$region has $azs AZs"

echo "== 3/6 local config (git-ignored)"
if [ -f account.auto.tfvars ] && ! grep -q "\"$acct\"" account.auto.tfvars; then
  warn "account.auto.tfvars points at a different account; replacing it"
fi
umask 077
printf 'allowed_account_id = "%s"\nregion             = "%s"\n' "$acct" "$region" > account.auto.tfvars
git check-ignore -q account.auto.tfvars || die "account.auto.tfvars is NOT git-ignored; refusing to continue"
ok "account.auto.tfvars written (allowed_account_id=$acct, region=$region)"

echo "== 4/6 secrets -> SSM SecureString (/$NAME/secrets/<name>)"
count=0
if [ -f "$MANIFEST" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [ -z "$line" ] && continue
    sname="${line%% *}"; sdesc="${line#"$sname"}"; sdesc="$(echo "$sdesc" | xargs)"
    pname="/$NAME/secrets/$sname"
    if aws ssm get-parameter --region "$region" --name "$pname" >/dev/null 2>&1; then
      [ "$(ask "  $sname already stored. Replace? [y/N]")" = "y" ] || { ok "  $sname kept"; continue; }
    fi
    printf '  %s%s: ' "$sname" "${sdesc:+ ($sdesc)}"
    read -r -s value </dev/tty; echo
    [ -n "$value" ] || die "empty value for $sname"
    # Value goes in on stdin as JSON; it is never an argv token and never written to disk.
    jq -n --arg n "$pname" --arg v "$value" --arg d "SEFS secret (written by setup.sh only)" \
      '{Name:$n, Value:$v, Type:"SecureString", Overwrite:true, Description:$d}' \
      | aws ssm put-parameter --region "$region" --cli-input-json file:///dev/stdin >/dev/null
    unset value
    aws ssm add-tags-to-resource --region "$region" --resource-type Parameter --resource-id "$pname" \
      --tags "Key=Project,Value=$NAME" "Key=ManagedBy,Value=setup.sh" >/dev/null
    ok "  $sname stored as SecureString"
    count=$((count+1))
  done < "$MANIFEST"
fi
[ "$count" -gt 0 ] && ok "$count secret(s) stored" || ok "no secrets to store (manifest empty); nothing in this deployment needs one"

echo "== 5/6 configuration checks"
terraform init -input=false >/dev/null
terraform validate >/dev/null && ok "terraform validate"
if [ "$FULL_TESTS" = 1 ]; then
  make test && ok "local proof suites green"
else
  echo "      (skipping the local proof suites; --full-tests runs them, ~15 min)"
fi

echo "== 6/6 deploy"
if [ "$DEPLOY" = 1 ]; then
  [ "$(ask "Run 'make up' now (≈8 min, ≈US\$0.16/h while live)? [y/N]")" = "y" ] || { warn "skipped; run 'make up' when ready"; exit 0; }
  make up AUTO=1
  echo
  ok "deployed. Next: 'make verify' (live checks), 'make e2e' (behaviour), 'bru run bruno/sefs --env aws' (Bruno), 'CONFIRM_DESTROY_DATA=yes make down' (teardown)"
else
  ok "--no-deploy: stopping before 'make up'"
fi

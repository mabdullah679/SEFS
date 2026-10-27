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

# ---------- input cache (owner, 2026-10-27): every answer typed at a prompt is kept for 24 h from
# the moment it was entered, for this boot session only. The file carries the kernel boot time; a
# restart, reboot or shutdown changes it and the whole cache is discarded. Secrets never go through
# ask(): they are read by the silent prompt in step 4 and are never written here.
#   SEFS_NO_CACHE=1 ./sefs setup   ignore and do not write the cache     ./sefs forget   delete it
CACHE="${SEFS_INPUT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sefs/inputs.tsv}"
CACHE_TTL=86400
boot_id() {
  if [ -r /proc/stat ]; then awk '/^btime/{print $2}' /proc/stat
  else sysctl -n kern.boottime 2>/dev/null | sed -nE 's/.*sec = ([0-9]+).*/\1/p'; fi
}
BOOT="$(boot_id)"; BOOT="${BOOT:-unknown}"
cache_get() { # key -> value on stdout; exit 1 when missing, older than 24 h, or from another boot
  [ -z "${SEFS_NO_CACHE:-}" ] && [ -f "$CACHE" ] || return 1
  awk -F'\t' -v k="$1" -v boot="$BOOT" -v now="$(date +%s)" -v ttl="$CACHE_TTL" '
    NR==1 { if ($1!="boot" || $2!=boot) exit 1; next }
    $1==k && (now-$2) < ttl { print $3; found=1; exit }
    END { exit found?0:1 }' "$CACHE"
}
cache_put() { # key value: rewrite the file atomically, keeping only entries from this boot
  [ -z "${SEFS_NO_CACHE:-}" ] || return 0
  local dir tmp; dir="$(dirname "$CACHE")"; mkdir -p "$dir"; chmod 700 "$dir"
  tmp="$(mktemp "$CACHE.XXXXXX")"
  { printf 'boot\t%s\n' "$BOOT"
    [ -f "$CACHE" ] && awk -F'\t' -v k="$1" -v boot="$BOOT" 'NR==1{ if ($1!="boot"||$2!=boot) exit; next } $1!=k' "$CACHE"
    printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "$2"; } > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$CACHE"
}
ask() { # ask <cache-key> <prompt>: prints the answer; a cached answer is shown, not asked again
  local key="$1" prompt="$2" r
  if r="$(cache_get "$key")"; then
    echo "      $prompt ${r:-<blank>}   (cached answer from this session; './sefs forget' clears)" >&2
    printf '%s' "$r"; return 0
  fi
  read -r -p "$prompt " r </dev/tty; cache_put "$key" "$r"; printf '%s' "$r"
}

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

git config core.hooksPath .githooks && ok "git hooks enabled (.githooks/pre-commit refuses files > 5 MB)"

echo "== 2/6 AWS identity"
ident="$(aws sts get-caller-identity --output json 2>/dev/null)" || die "No usable AWS credentials. Sign in first (aws login / aws sso login / aws configure), then re-run."
acct="$(jq -r .Account <<<"$ident")"; arn="$(jq -r .Arn <<<"$ident")"
region_default="$(aws configure get region 2>/dev/null || true)"; region_default="${region_default:-us-east-1}"
echo "      account: $acct"
echo "      identity: $arn"
[ "$(ask "confirm_account:$acct" "Deploy into THIS account? [y/N]")" = "y" ] || die "Aborted. Sign in to the right account and re-run."
region="$(ask region "Region [$region_default]:")"; region="${region:-$region_default}"
azs="$(aws ec2 describe-availability-zones --region "$region" --query 'length(AvailabilityZones)' --output text 2>/dev/null)" || die "Region '$region' is not usable with these credentials"
[ "$azs" -ge 2 ] || die "Region $region has $azs AZs; the design needs at least 2"
ok "$region has $azs AZs"

src_profile="${AWS_PROFILE:-default}"
if [ -n "$(aws configure get login_session --profile "$src_profile" 2>/dev/null)" ]; then
  bash scripts/bruno-profile.sh tf "$src_profile" "$region" "$NAME" >/dev/null
  export AWS_PROFILE="$NAME-tf"
  ok "'$src_profile' is an 'aws login' session; Terraform will use helper profile '$NAME-tf' (same login, no stored keys)"
fi

echo "== 3/6 local config (git-ignored)"
if [ -f account.auto.tfvars ] && ! grep -q "\"$acct\"" account.auto.tfvars; then
  warn "account.auto.tfvars points at a different account; replacing it"
fi
alert_email="$(ask alert_email "Email for alarm notifications (blank = none; you confirm the SNS subscription mail once):")"
umask 077
{
  printf 'allowed_account_id = "%s"\nregion             = "%s"\n' "$acct" "$region"
  [ -n "$alert_email" ] && printf 'alert_email        = "%s"\n' "$alert_email"
} > account.auto.tfvars
git check-ignore -q account.auto.tfvars || die "account.auto.tfvars is NOT git-ignored; refusing to continue"
ok "account.auto.tfvars written (allowed_account_id=$acct, region=$region)"

echo "== 3b/6 shared Terraform state (S3 bucket + lock table, once per account+region)"
gh_repo="$(ask gh_repo "GitHub repo for CI deploys as owner/repo (blank = no CI role):")"
if [ -n "$gh_repo" ]; then make bootstrap AUTO=1 GITHUB_REPO="$gh_repo"; else make bootstrap AUTO=1; fi
ok "state backend ready: $(sed -nE 's/^bucket *= *"([^"]+)".*/\1/p' backend.hcl)"

if [ -n "$gh_repo" ] && [ -f backend.hcl ]; then
  echo "== 3c/6 GitHub Actions variables (the only CI wiring; no secrets, OIDC replaces keys)"
  ci_bucket="$(sed -nE 's/^bucket *= *"([^"]+)".*/\1/p' backend.hcl)"
  ci_table="$(sed -nE 's/^dynamodb_table *= *"([^"]+)".*/\1/p' backend.hcl)"
  ci_role="$(terraform -chdir=bootstrap output -raw github_deploy_role_arn 2>/dev/null || true)"
  printf '      %s=%s\n' AWS_REGION "$region" AWS_ACCOUNT_ID "$acct" AWS_DEPLOY_ROLE_ARN "${ci_role:-<bootstrap output github_deploy_role_arn>}" TF_STATE_BUCKET "$ci_bucket" TF_LOCK_TABLE "$ci_table"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && [ -n "$ci_role" ]; then
    if [ "$(ask "gh_vars:$gh_repo" "Set these 5 variables on $gh_repo now with the GitHub CLI? [y/N]")" = "y" ]; then
      gh variable set AWS_REGION --body "$region" -R "$gh_repo" && gh variable set AWS_ACCOUNT_ID --body "$acct" -R "$gh_repo" \
        && gh variable set AWS_DEPLOY_ROLE_ARN --body "$ci_role" -R "$gh_repo" && gh variable set TF_STATE_BUCKET --body "$ci_bucket" -R "$gh_repo" \
        && gh variable set TF_LOCK_TABLE --body "$ci_table" -R "$gh_repo" && ok "5 variables set on $gh_repo; a push to main with 'check' now deploys"
    else warn "not set; add them under Settings > Secrets and variables > Actions > Variables (docs/CI.md)"; fi
  else
    warn "GitHub CLI not signed in (or no role ARN yet): add the 5 values above under Settings > Secrets and variables > Actions > Variables (docs/CI.md)"
  fi
fi

echo "== 4/6 secrets -> SSM SecureString (/$NAME/secrets/<name>)"
count=0
if [ -f "$MANIFEST" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [ -z "$line" ] && continue
    sname="${line%% *}"; sdesc="${line#"$sname"}"; sdesc="$(echo "$sdesc" | xargs)"
    pname="/$NAME/secrets/$sname"
    if aws ssm get-parameter --region "$region" --name "$pname" >/dev/null 2>&1; then
      [ "$(ask "secret_replace:$sname" "  $sname already stored. Replace? [y/N]")" = "y" ] || { ok "  $sname kept"; continue; }
    fi
    printf '  %s%s: ' "$sname" "${sdesc:+ ($sdesc)}"
    read -r -s value </dev/tty; echo         # silent, never through ask(): a secret is never cached
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
make init >/dev/null
terraform validate >/dev/null && ok "terraform validate (shared state)"
if [ "$FULL_TESTS" = 1 ]; then
  make test && ok "local proof suites green"
else
  echo "      (skipping the local proof suites; --full-tests runs them, ~15 min)"
fi

echo "== 5b/6 Bruno profile (no credentials stored)"
bash scripts/bruno-profile.sh install "$src_profile" "$region" "$NAME" >/dev/null && ok "AWS profile '$NAME-bruno' assumes the read-only role via '$src_profile'"

echo "== 6/6 deploy"
if [ "$DEPLOY" = 1 ]; then
  # Rate: `make cost`, ap-southeast-2, 2026-10-26 (README "Running cost"). Credits are finite: the stack
  # burns them for as long as it is up, so the teardown is part of every test session.
  [ "$(ask deploy "Run 'make up' now (≈8 min; then ≈US\$0.17/h ≈ US\$4.20/day of credits until './sefs down')? [y/N]")" = "y" ] || { warn "skipped; run 'make up' when ready"; exit 0; }
  make up AUTO=1
  echo
  ok "deployed. Next: 'make verify' (live checks), 'make e2e' (behaviour), 'make bruno' (Bruno collection), 'CONFIRM_DESTROY_DATA=yes make down' (teardown)"
  warn "the stack is LIVE and burning ≈US\$0.17/h of credits; './sefs burn' shows the running total, './sefs down' stops it"
else
  ok "--no-deploy: stopping before 'make up'"
fi

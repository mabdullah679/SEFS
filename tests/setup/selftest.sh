#!/usr/bin/env bash
# Proves setup.sh handles a secret safely, with NO AWS calls: a fake `aws` on PATH records
# every argv and every stdin it receives. Assertions:
#   S1 the secret value never appears in ANY argv of any aws call
#   S2 put-parameter received the value on stdin, Type SecureString, under /<name>/secrets/
#   S3 nothing but account.auto.tfvars was written in the repo, and it holds the chosen account+region
#   S4 the secret value appears in no file in the repo copy
#   S5 a wrong account answer ('n') aborts before writing anything
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/sefs-setup.XXXXXX")"; [ -n "${KEEP:-}" ] && echo "W=$W" || trap 'rm -rf "$W"' EXIT
SECRET="hunter2-$(date +%s)-$$"
fail=0; pass() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }

# --- repo copy (git-tracked files only, plus a .git so check-ignore works)
mkdir -p "$W/repo"; (cd "$REPO" && git ls-files -z | xargs -0 tar cf - ) | tar xf - -C "$W/repo"
echo "api_key test secret" > "$W/repo/secrets.manifest"
git -C "$W/repo" init -q && git -C "$W/repo" add -A && git -C "$W/repo" -c user.email=t@t -c user.name=t commit -qm init

# --- fake aws / terraform / make / docker
mkdir -p "$W/bin"
cat > "$W/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG.argv"
case "$1 $2" in
  "sts get-caller-identity") echo '{"Account":"111122223333","Arn":"arn:aws:sts::111122223333:assumed-role/T/x","UserId":"X"}' ;;
  "configure get") case "${3:-}" in region) echo "eu-west-1" ;; *) exit 1 ;; esac ;;   # no login_session => plain profile
  "configure set") : ;;
  "ec2 describe-availability-zones") echo 3 ;;
  "ssm get-parameter") exit 255 ;;              # not stored yet
  "ssm put-parameter") cat > "$FAKE_LOG.put-stdin" ;;
  "ssm add-tags-to-resource") : ;;
  "--version "*) echo "aws-cli/2.17.0 Python/3.11" ;;
  *) echo "fake aws: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "$W/bin/terraform" <<'EOF'
#!/usr/bin/env bash
case "$1" in version) echo '{"terraform_version":"1.9.8"}';; init|validate) :;; *) exit 99;; esac
EOF
cat > "$W/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in info) [ "${2:-}" = "--format" ] && echo arm64 || :;; buildx) :;; version) echo 29.0;; *) exit 99;; esac
EOF
printf '#!/usr/bin/env bash\necho "fake make $*" >> "$FAKE_LOG.make"\n' > "$W/bin/make"
chmod +x "$W/bin/"*
export FAKE_LOG="$W/log" PATH="$W/bin:$PATH"

# ---- happy path: y, region (blank = default), secret
# `script` gives setup.sh a tty so /dev/tty reads work; answers arrive on that tty.
rm -f "$FAKE_LOG".*
( cd "$W/repo" && expect -c "
  set timeout 60
  spawn ./setup.sh --no-deploy
  expect \"THIS account\" { send \"y\r\" }
  expect \"Region\"       { send \"\r\" }
  expect \"Email for alarm\" { send \"ops@example.com\r\" }
  expect \"GitHub repo\"    { send \"\r\" }
  expect \"api_key\"      { send \"$SECRET\r\" }
  expect eof
" ) >"$W/out" 2>&1 || true

if grep -q "$SECRET" "$FAKE_LOG.argv" 2>/dev/null; then bad "S1 secret appeared in an aws argv"; else pass "S1 secret never in any aws argv"; fi
if [ -f "$FAKE_LOG.put-stdin" ] && jq -e --arg v "$SECRET" '.Value==$v and .Type=="SecureString" and (.Name|startswith("/sefs/secrets/api_key"))' "$FAKE_LOG.put-stdin" >/dev/null; then
  pass "S2 put-parameter got the value on stdin as SecureString under /sefs/secrets/"
else bad "S2 put-parameter stdin wrong or missing: $(cat "$FAKE_LOG.put-stdin" 2>/dev/null | jq -c 'del(.Value)' 2>/dev/null)"; fi
changed="$(git -C "$W/repo" status --porcelain --ignored | grep -v '^!! .terraform' | awk '{print $2}' | sort | tr '\n' ' ')"
if [ "$changed" = "account.auto.tfvars " ] && grep -q 'allowed_account_id = "111122223333"' "$W/repo/account.auto.tfvars" && grep -q 'region             = "eu-west-1"' "$W/repo/account.auto.tfvars" && grep -q 'alert_email        = "ops@example.com"' "$W/repo/account.auto.tfvars"; then
  pass "S3 only account.auto.tfvars written, with the confirmed account + region"
else bad "S3 unexpected files or content: [$changed]"; fi
if grep -rq "$SECRET" "$W/repo"; then bad "S4 secret found on disk in the repo copy"; else pass "S4 secret in no repo file"; fi

# ---- abort path
rm -f "$W/repo/account.auto.tfvars" "$FAKE_LOG".*
( cd "$W/repo" && expect -c "set timeout 60; spawn ./setup.sh --no-deploy; expect \"THIS account\" { send \"n\r\" }; expect eof" ) >"$W/out2" 2>&1 || true
if [ ! -f "$W/repo/account.auto.tfvars" ] && [ ! -f "$FAKE_LOG.put-stdin" ] && grep -q "Aborted" "$W/out2"; then pass "S5 'n' aborts before writing anything"; else bad "S5 abort path wrote something or did not abort"; fi

[ $fail = 0 ] && echo "setup selftest: ALL PASS" || { echo "setup selftest: FAIL"; exit 1; }

#!/usr/bin/env bash
# AWS `credential_process` for the `sefs-bruno` profile: assumes the read-only Bruno role
# through the caller's OWN login profile and prints one-hour temporary credentials in the
# format the AWS SDK/CLI expect. Nothing is stored anywhere.
#
#   bruno-creds.sh <source-profile> [name]
set -euo pipefail
SRC="${1:?usage: bruno-creds.sh <source-profile> [name]}"
NAME="${2:-sefs}"
[ "$SRC" != "$NAME-bruno" ] || { echo "source profile must not be the bruno profile itself" >&2; exit 2; }
ident="$(aws --profile "$SRC" sts get-caller-identity --output json)"
acct="$(printf '%s' "$ident" | sed -n 's/.*"Account": *"\([0-9]*\)".*/\1/p')"
partition="$(printf '%s' "$ident" | sed -n 's/.*"Arn": *"arn:\([a-z-]*\):.*/\1/p')"
exec aws --profile "$SRC" sts assume-role \
  --role-arn "arn:${partition}:iam::${acct}:role/${NAME}-bruno-reader" \
  --role-session-name "bruno-$(id -un | tr -c 'A-Za-z0-9_=,.@-' '_')" \
  --duration-seconds 3600 \
  --query '{Version:`1`,AccessKeyId:Credentials.AccessKeyId,SecretAccessKey:Credentials.SecretAccessKey,SessionToken:Credentials.SessionToken,Expiration:Credentials.Expiration}' \
  --output json

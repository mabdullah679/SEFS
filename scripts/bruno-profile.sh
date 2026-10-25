#!/usr/bin/env bash
# Installs (or refreshes) the `sefs-bruno` AWS CLI profile. The profile holds NO
# credentials: only a credential_process that assumes the read-only role via the
# source profile you name. Idempotent (`aws configure set` rewrites the same keys).
#
#   bruno-profile.sh install <source-profile> <region> [name]   Bruno read-only role profile
#   bruno-profile.sh tf      <source-profile> <region> [name]   Terraform backend helper profile
#   bruno-profile.sh remove  [name]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-}"; shift || true
case "$cmd" in
  install)
    SRC="${1:?source profile}"; REGION="${2:?region}"; NAME="${3:-sefs}"
    P="$NAME-bruno"
    aws configure set --profile "$P" credential_process "$HERE/bruno-creds.sh $SRC $NAME"
    aws configure set --profile "$P" region "$REGION"
    aws configure set --profile "$P" output json
    echo "profile '$P' -> assumes role $NAME-bruno-reader via profile '$SRC' (no stored credentials)"
    ;;
  tf)
    # Terraform 1.9's built-in S3 backend uses an AWS SDK that does not understand the
    # `aws login` session profile type (login_session); the provider does. This profile
    # exports the same login session through credential_process, which both understand.
    SRC="${1:?source profile}"; REGION="${2:?region}"; NAME="${3:-sefs}"
    P="$NAME-tf"
    aws configure set --profile "$P" credential_process "aws --profile $SRC configure export-credentials --format process"
    aws configure set --profile "$P" region "$REGION"
    echo "profile '$P' -> exports the '$SRC' login session for Terraform's S3 backend (no stored credentials)"
    ;;
  remove)
    NAME="${1:-sefs}"; P="$NAME-bruno"
    for k in credential_process region output; do aws configure set --profile "$P" "$k" "" 2>/dev/null || true; done
    echo "profile '$P' keys cleared (an empty [profile $P] header may remain in ~/.aws/config)"
    ;;
  *) echo "usage: $0 install|tf <source-profile> <region> [name] | remove [name]" >&2; exit 2 ;;
esac

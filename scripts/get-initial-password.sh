#!/usr/bin/env bash
# Print a new engineer's generated first-login password so an onboarding admin
# can hand it over through a secure channel (never chat, email or the repo).
# The engineer must change it at first sign-in, after which it no longer works.
#
# Usage: scripts/get-initial-password.sh USERNAME
set -euo pipefail

USER_NAME="${1:?usage: $0 USERNAME}"
PREFIX="${PROJECT_PREFIX:-onward}"

aws secretsmanager get-secret-value \
  --secret-id "${PREFIX}/onboarding/${USER_NAME}/initial-password" \
  --query SecretString --output text |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["password"])'

echo "Sign-in URL: https://$(aws sts get-caller-identity --query Account --output text).signin.aws.amazon.com/console" >&2

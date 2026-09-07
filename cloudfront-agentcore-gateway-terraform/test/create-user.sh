#!/usr/bin/env bash
#
# Creates a Cognito user and prints an access token for testing.
#
#   ./test/create-user.sh                       # prompts for a password
#   ./test/create-user.sh myuser 'MyP@ssw0rd'   # non-interactive
#
# Then:
#   export TOKEN=$(./test/create-user.sh --token-only)
#   ./test/smoke.sh
#
# WHY THIS IS A SCRIPT AND NOT TERRAFORM
#
# Terraform deliberately creates no users. aws_cognito_user requires a password,
# and a password in a resource argument lands in Terraform state — which for a
# published pattern sits as plaintext on the reader's disk. Keeping user creation
# out of Terraform means no credential is ever written to state.
#
# The consequence: `terraform destroy` will NOT remove users created here, and
# deleting a user pool that still contains users can fail. Use --delete first.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

USERNAME="${1:-testuser}"
PASSWORD="${2:-}"
TOKEN_ONLY=0
DELETE=0

for arg in "$@"; do
  case "$arg" in
    --token-only) TOKEN_ONLY=1 ;;
    --delete)     DELETE=1 ;;
  esac
done
# Positional defaults must not absorb the flags.
case "$USERNAME" in --*) USERNAME="testuser" ;; esac
case "$PASSWORD" in --*) PASSWORD="" ;; esac

say() { [ "$TOKEN_ONLY" -eq 1 ] || echo "$@"; }
die() { echo "$@" >&2; exit 1; }

# --- inputs from terraform ----------------------------------------------------

POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null)
CLIENT_ID=$(terraform output -raw cognito_client_id 2>/dev/null)

if [ -z "$POOL_ID" ] || [ "$POOL_ID" = "null" ]; then
  die "No Cognito user pool found in terraform output.

This pattern only creates one when auth_mode = \"cognito\". With
auth_mode = \"external\" you obtain a token from your own identity provider
instead."
fi

# Cognito is regional and the CLI needs to be told which one. Derived from the
# pool ID (us-east-1_xxxx) rather than from AWS_DEFAULT_REGION, so this works
# regardless of how the caller's environment is configured.
REGION="${POOL_ID%%_*}"

# --- delete mode --------------------------------------------------------------

if [ "$DELETE" -eq 1 ]; then
  say "Deleting user '$USERNAME' from $POOL_ID"
  aws cognito-idp admin-delete-user --region "$REGION" \
    --user-pool-id "$POOL_ID" --username "$USERNAME" 2>&1 | sed 's/^/  /'
  say "Done. terraform destroy can now delete the pool."
  exit 0
fi

# --- password -----------------------------------------------------------------
#
# Never defaulted to a literal. A published pattern that hands out an example
# password means every deployment of it shares one credential.

if [ -z "$PASSWORD" ]; then
  [ "$TOKEN_ONLY" -eq 1 ] && die "--token-only needs the password as argument 2."
  echo "Cognito requires 8+ characters with upper, lower, digit and symbol."
  read -r -s -p "Password for '$USERNAME': " PASSWORD
  echo
  [ -z "$PASSWORD" ] && die "No password given."
fi

# --- create -------------------------------------------------------------------

say "pool     $POOL_ID"
say "region   $REGION"
say "user     $USERNAME"
say

EXISTING=$(aws cognito-idp admin-get-user --region "$REGION" \
  --user-pool-id "$POOL_ID" --username "$USERNAME" \
  --query 'UserStatus' --output text 2>/dev/null)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  say "User already exists (status $EXISTING). Resetting the password."
else
  # --message-action SUPPRESS stops Cognito emailing an invitation to an address
  # that does not exist.
  OUT=$(aws cognito-idp admin-create-user --region "$REGION" \
    --user-pool-id "$POOL_ID" --username "$USERNAME" \
    --message-action SUPPRESS --query 'User.UserStatus' --output text 2>&1) \
    || die "Could not create the user: $OUT"
  say "Created (status $OUT)."
fi

# --permanent is required. Without it the user lands in FORCE_CHANGE_PASSWORD and
# initiate-auth returns a challenge rather than a token, which reads as a broken
# deployment.
OUT=$(aws cognito-idp admin-set-user-password --region "$REGION" \
  --user-pool-id "$POOL_ID" --username "$USERNAME" \
  --password "$PASSWORD" --permanent 2>&1) \
  || die "Could not set the password: $OUT

Cognito requires 8+ characters with upper, lower, digit and symbol."
say "Password set, status CONFIRMED."

# --- sign in ------------------------------------------------------------------
#
# This is the exchange the README describes: username and password go to Cognito,
# and Cognito returns a short-lived access token. The password never reaches the
# MCP endpoint — only this token does.

TOKEN=$(aws cognito-idp initiate-auth --region "$REGION" \
  --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT_ID" \
  --auth-parameters "USERNAME=$USERNAME,PASSWORD=$PASSWORD" \
  --query 'AuthenticationResult.AccessToken' --output text 2>&1)

case "$TOKEN" in
  *.*.*) : ;;
  *) die "Sign-in failed: $TOKEN" ;;
esac

if [ "$TOKEN_ONLY" -eq 1 ]; then
  printf '%s\n' "$TOKEN"
  exit 0
fi

EXPIRES=$(printf '%s' "$TOKEN" | python3 -c '
import base64, json, sys, datetime
p = sys.stdin.read().split(".")[1]
p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
left = datetime.datetime.utcfromtimestamp(c["exp"]) - datetime.datetime.utcnow()
print(f"{int(left.total_seconds() / 60)} minutes")
' 2>/dev/null || echo "unknown")

echo
echo "Access token valid for $EXPIRES:"
echo
printf '%s\n' "$TOKEN"
echo
echo "Run the smoke test:"
echo
echo "  export TOKEN=\$(./test/create-user.sh $USERNAME '<password>' --token-only)"
echo "  ./test/smoke.sh"
echo
echo "Remove the user before terraform destroy:"
echo
echo "  ./test/create-user.sh $USERNAME --delete"

#!/usr/bin/env bash
#
# Verifies a deployed front door.
#
#   export TOKEN="<access token>"
#   ./test/smoke.sh
#
# MCP_URL is read from terraform output when not set, preferring the custom domain
# and falling back to the CloudFront name so this works before DNS is finished.
#
# Checks run in dependency order and stop at the first failure, so the check that
# fails names the broken hop rather than leaving you to guess.

set -uo pipefail

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS + 1)); printf '  %s %s\n' "$(green PASS)" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  %s %s\n' "$(red FAIL)" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

cd "$(dirname "$0")/.." || exit 1

# --- inputs ------------------------------------------------------------------

if [ -z "${MCP_URL:-}" ]; then
  MCP_URL=$(terraform output -raw mcp_url 2>/dev/null)
  if [ -z "$MCP_URL" ] || [ "$MCP_URL" = "null" ]; then
    MCP_URL=$(terraform output -raw cloudfront_url 2>/dev/null)
  fi
fi

if [ -z "${MCP_URL:-}" ]; then
  echo "MCP_URL is not set and could not be read from terraform output." >&2
  exit 1
fi

if [ -z "${TOKEN:-}" ]; then
  echo "TOKEN is not set. Obtain an access token first:" >&2
  echo >&2
  terraform output -raw create_user_commands 2>/dev/null >&2
  echo >&2
  exit 1
fi

BASE="${MCP_URL%/mcp}"

echo "endpoint : $MCP_URL"
echo

mcp() {
  curl -sS --max-time 60 -X POST "$MCP_URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$1" 2>/dev/null
}

# The Gateway may answer with a bare JSON object or with an SSE frame. Handled in
# python rather than sed: BSD sed on macOS rejects the branch-label syntax GNU sed
# accepts, and this script has to run on both.
unframe() {
  python3 -c '
import sys
raw = sys.stdin.read()
for line in raw.splitlines():
    if line.startswith("data:"):
        print(line[5:].strip())
        break
else:
    print(raw)
'
}

# --- 1. tools/list -----------------------------------------------------------

echo "1/4  tools/list"
BODY=$(mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | unframe)
TOOLS=$(printf '%s' "$BODY" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(" ".join(t["name"] for t in d.get("result", {}).get("tools", [])))' 2>/dev/null)

if [ -z "$TOOLS" ]; then
  bad "no tools returned" "$(printf '%s' "$BODY" | head -c 300)"
  echo
  echo "A 400 here usually means the Host header never reached the Gateway correctly."
  echo "A 401 means the token was rejected. Stopping."
  exit 1
fi
ok "tools: $TOOLS"

# --- 2. tools/call against every tool ---------------------------------------

echo "2/4  tools/call"
for TOOL in $TOOLS; do
  RESULT=$(mcp "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":{}}}" | unframe)
  IS_ERROR=$(printf '%s' "$RESULT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("result", {}).get("isError"))
except Exception:
    print("unparseable")' 2>/dev/null)
  TEXT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys
try:
    c = json.load(sys.stdin).get("result", {}).get("content") or []
    print((c[0].get("text") if c else "")[:90])
except Exception:
    print("")' 2>/dev/null)

  # A tool failure is HTTP 200 with isError true, never an HTTP error code, so the
  # field is the only thing worth checking.
  if [ "$IS_ERROR" = "False" ]; then
    ok "$TOOL -> $TEXT"
  else
    bad "$TOOL isError=$IS_ERROR" "$TEXT"
  fi
done

# --- 3. auth is actually enforced -------------------------------------------

echo "3/4  unauthenticated request is rejected"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' 2>/dev/null)

if [ "$CODE" = "401" ]; then
  ok "401 without a token"
else
  bad "expected 401, got $CODE" "The Gateway is not validating tokens."
fi

# --- 4. the protected-resource document names YOUR domain -------------------
#
# The check that curl-with-a-token cannot catch. Without the edge function this
# returns the Gateway's own document, naming a bedrock-agentcore hostname, and
# spec-compliant MCP clients then refuse to authenticate even though checks 1 and 2
# pass. That is the failure mode this whole pattern exists to avoid.

echo "4/4  protected-resource document"
PRM=$(curl -sS --max-time 30 "$BASE/.well-known/oauth-protected-resource" 2>/dev/null)
RESOURCE=$(printf '%s' "$PRM" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("resource", ""))
except Exception:
    print("")' 2>/dev/null)

EXPECTED_HOST=$(printf '%s' "$BASE" | sed 's|^https://||')

if [ -z "$RESOURCE" ]; then
  bad "no resource field" "$(printf '%s' "$PRM" | head -c 200)"
elif printf '%s' "$RESOURCE" | grep -q 'bedrock-agentcore'; then
  bad "resource names the Gateway, not your front door" "$RESOURCE"
elif printf '%s' "$RESOURCE" | grep -q "$EXPECTED_HOST"; then
  ok "resource = $RESOURCE"
else
  bad "resource does not match the endpoint" "got $RESOURCE, expected host $EXPECTED_HOST"
fi

# --- result ------------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  printf '%s  %d checks passed\n' "$(green ALL PASS)" "$PASS"
  exit 0
fi
printf '%s  %d passed, %d failed\n' "$(red FAILED)" "$PASS" "$FAIL"
exit 1

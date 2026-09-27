#!/usr/bin/env bash
# Runs policy-sandbox e2e scenarios 1-3 against the local Gateway runtime and prints PASS/FAIL per
# assertion. Scenarios 4 (concurrency/429) and 5 (flag disabled/404) touch runtime config and are
# run manually (see policy-editor-sandbox-STATUS.md) since they require restarting the gateway.
#
# Usage: run-e2e.sh [gateway-base-url]
#   default gateway-base-url: https://localhost:9444/api/am/gateway/v2

set -uo pipefail

BASE_URL="${1:-https://localhost:9444/api/am/gateway/v2}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURL_AUTH=(-u admin:admin -k)

PASS=0
FAIL=0

assert() {
  local description="$1"
  local condition="$2"
  if [ "$condition" = "true" ]; then
    echo "PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $description"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Scenario 1: mock token 200 -> COMPLETED, Authorization Bearer abc, payload restored, no token leak ==="
node "$DIR/build-request.js" ok > "$DIR/scenario1-request.json"
HTTP_CODE=$(curl -s "${CURL_AUTH[@]}" -H "Content-Type: application/json" -X POST \
  "$BASE_URL/policy-sandbox/execute" -d @"$DIR/scenario1-request.json" \
  -o "$DIR/scenario1-response.json" -w "%{http_code}")

assert "scenario1: HTTP 200" "$( [ "$HTTP_CODE" = "200" ] && echo true || echo false )"
STATUS=$(grep -o '"status":"[A-Z]*"' "$DIR/scenario1-response.json" | head -1)
assert "scenario1: status=COMPLETED (got $STATUS)" "$( [ "$STATUS" = '"status":"COMPLETED"' ] && echo true || echo false )"
assert "scenario1: Authorization: Bearer abc present" "$( grep -q '"Authorization":"Bearer abc"' "$DIR/scenario1-response.json" && echo true || echo false )"
assert "scenario1: payload {\"a\":1} restored" "$( grep -q '\\"a\\":1' "$DIR/scenario1-response.json" && echo true || echo false )"
assert "scenario1: no X-APIM-Sandbox-Token anywhere in response" "$( ! grep -qi 'x-apim-sandbox-token' "$DIR/scenario1-response.json" && echo true || echo false )"
assert "scenario1: trace[].tag preserves original case (payloadFactory)" "$( grep -q '"tag":"payloadFactory"' "$DIR/scenario1-response.json" && echo true || echo false )"

echo ""
echo "=== Scenario 2: mock token 401 -> FAULT, trace ends at nodeId 10 (the call) ==="
node "$DIR/build-request.js" unauthorized > "$DIR/scenario2-request.json"
HTTP_CODE=$(curl -s "${CURL_AUTH[@]}" -H "Content-Type: application/json" -X POST \
  "$BASE_URL/policy-sandbox/execute" -d @"$DIR/scenario2-request.json" \
  -o "$DIR/scenario2-response.json" -w "%{http_code}")

assert "scenario2: HTTP 200 (sandbox contract: 200 whenever the run was attempted)" "$( [ "$HTTP_CODE" = "200" ] && echo true || echo false )"
STATUS=$(grep -o '"status":"[A-Z]*"' "$DIR/scenario2-response.json" | head -1)
assert "scenario2: status=FAULT (got $STATUS)" "$( [ "$STATUS" = '"status":"FAULT"' ] && echo true || echo false )"
assert "scenario2: fault.nodeId=10" "$( grep -q '"nodeId":"10"' "$DIR/scenario2-response.json" && echo true || echo false )"
LAST_TRACE_NODE=$(grep -o '"nodeId":"[^"]*","tag":"call"' "$DIR/scenario2-response.json" | tail -1)
assert "scenario2: trace includes the call node (10)" "$( [ -n "$LAST_TRACE_NODE" ] && echo true || echo false )"
assert "scenario2: no X-APIM-Sandbox-Token anywhere in response" "$( ! grep -qi 'x-apim-sandbox-token' "$DIR/scenario2-response.json" && echo true || echo false )"

echo ""
echo "=== Scenario 3: filter else -> respond (early response) -> RESPONDED ==="
node "$DIR/build-request.js" respond > "$DIR/scenario3-request.json"
HTTP_CODE=$(curl -s "${CURL_AUTH[@]}" -H "Content-Type: application/json" -X POST \
  "$BASE_URL/policy-sandbox/execute" -d @"$DIR/scenario3-request.json" \
  -o "$DIR/scenario3-response.json" -w "%{http_code}")

assert "scenario3: HTTP 200" "$( [ "$HTTP_CODE" = "200" ] && echo true || echo false )"
STATUS=$(grep -o '"status":"[A-Z]*"' "$DIR/scenario3-response.json" | head -1)
assert "scenario3: status=RESPONDED (got $STATUS)" "$( [ "$STATUS" = '"status":"RESPONDED"' ] && echo true || echo false )"
assert "scenario3: respondedEarly=true" "$( grep -q '"respondedEarly":true' "$DIR/scenario3-response.json" && echo true || echo false )"
assert "scenario3: no X-APIM-Sandbox-Token anywhere in response" "$( ! grep -qi 'x-apim-sandbox-token' "$DIR/scenario3-response.json" && echo true || echo false )"

echo ""
echo "=== Scenario 4: mock with blank method (\"\") matches any request method -> COMPLETED ==="
node "$DIR/build-request.js" blank-method > "$DIR/scenario4-request.json"
HTTP_CODE=$(curl -s "${CURL_AUTH[@]}" -H "Content-Type: application/json" -X POST \
  "$BASE_URL/policy-sandbox/execute" -d @"$DIR/scenario4-request.json" \
  -o "$DIR/scenario4-response.json" -w "%{http_code}")

assert "scenario4: HTTP 200" "$( [ "$HTTP_CODE" = "200" ] && echo true || echo false )"
STATUS=$(grep -o '"status":"[A-Z]*"' "$DIR/scenario4-response.json" | head -1)
assert "scenario4: status=COMPLETED (got $STATUS) - blank mock method matched the POST request" "$( [ "$STATUS" = '"status":"COMPLETED"' ] && echo true || echo false )"
assert "scenario4: Authorization: Bearer abc present (mock was applied)" "$( grep -q '"Authorization":"Bearer abc"' "$DIR/scenario4-response.json" && echo true || echo false )"
assert "scenario4: no X-APIM-Sandbox-Token anywhere in response" "$( ! grep -qi 'x-apim-sandbox-token' "$DIR/scenario4-response.json" && echo true || echo false )"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

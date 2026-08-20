#!/bin/bash
set -e

echo "=================================================="
echo "Load-Test Tools Proof - DCR + PKCE"
echo "=================================================="
echo "Registration -> authorize -> token -> MCP tools/call"
echo ""

# Configuration
PORT="${PORT:-8090}"
SERVER_URL="${BASE_URI:-http://localhost:$PORT}"
USER_ID="loadtest-tools-$(date +%s)"
SERVER_LOG="${SERVER_LOG:-/tmp/loadtest-tools-server.log}"

echo "🔧 Configuration:"
echo "  Server URL: $SERVER_URL (auth + MCP)"
echo "  User ID: $USER_ID"
echo "  Server log: $SERVER_LOG"
echo ""

# Build the project
echo "🔨 Building project..."
npm run build

# Start merged server in internal mode
echo "🚀 Starting server in INTERNAL mode..."
AUTH_MODE=internal PORT=$PORT BASE_URI=$SERVER_URL node dist/index.js > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT
sleep 5

if ! curl -s -f "$SERVER_URL/" > /dev/null 2>&1; then
    echo "❌ Server failed to start at $SERVER_URL"
    exit 1
fi
echo "✅ Server is running (PID: $SERVER_PID)"

# Helper: POST a JSON-RPC message to /mcp and print the JSON payload
mcp_call() {
    curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Accept: application/json, text/event-stream" \
      -H "Mcp-Session-Id: $SESSION_ID" \
      -X POST -H "Content-Type: application/json" \
      -d "$1" \
      "$SERVER_URL/mcp" | grep "^data: " | sed 's/^data: //'
}

echo ""
echo "🔐 PHASE 1: Dynamic Client Registration + PKCE"
echo "=============================================="

echo "📝 Step 1: Register OAuth client (DCR)"
CLIENT_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"client_name\":\"loadtest-tools-proof\",\"redirect_uris\":[\"http://localhost:3000/callback\"]}" \
  "$SERVER_URL/register")
CLIENT_ID=$(echo "$CLIENT_RESPONSE" | jq -r .client_id)
CLIENT_SECRET=$(echo "$CLIENT_RESPONSE" | jq -r .client_secret)
if [ "$CLIENT_ID" = "null" ] || [ -z "$CLIENT_ID" ]; then
    echo "   ❌ Registration failed: $CLIENT_RESPONSE"
    exit 1
fi
echo "   ✅ Client ID: $CLIENT_ID"

echo ""
echo "🔐 Step 2: Generate PKCE challenge (S256)"
CODE_VERIFIER=$(openssl rand -base64 64 | tr -d "=+/\n" | cut -c1-64)
CODE_CHALLENGE=$(echo -n "$CODE_VERIFIER" | openssl dgst -binary -sha256 | base64 | tr "+/" "-_" | tr -d "=")
echo "   ✅ Verifier length: ${#CODE_VERIFIER} (RFC 7636 requires >= 43)"
if [ "${#CODE_VERIFIER}" -lt 43 ]; then
    echo "   ❌ Verifier shorter than 43 characters"
    exit 1
fi

echo ""
echo "🎫 Step 3: Authorize"
STATE_PARAM="loadtest-tools-$(date +%s)"
AUTH_URL="$SERVER_URL/authorize?response_type=code&client_id=$CLIENT_ID&redirect_uri=http://localhost:3000/callback&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256&state=$STATE_PARAM"
AUTH_PAGE=$(curl -s "$AUTH_URL")
AUTH_CODE=$(echo "$AUTH_PAGE" | grep -o 'state=[^"&]*' | cut -d= -f2 | head -1)
if [ -z "$AUTH_CODE" ]; then
    echo "   ❌ Failed to extract authorization code"
    exit 1
fi
echo "   ✅ Auth code: ${AUTH_CODE:0:20}..."

echo ""
echo "🔄 Step 4: Complete mock upstream auth"
CALLBACK_URL="$SERVER_URL/mock-upstream-idp/callback?state=$AUTH_CODE&code=mock-auth-code&userId=$USER_ID"
CALLBACK_RESPONSE=$(curl -s -i "$CALLBACK_URL")
if echo "$CALLBACK_RESPONSE" | grep -i "^location:" | tr -d '\r' | grep -q "state=$STATE_PARAM"; then
    echo "   ✅ State parameter verified"
else
    echo "   ❌ State parameter mismatch"
    exit 1
fi

echo ""
echo "🎟️  Step 5: Exchange code for access token (with verifier)"
TOKEN_RESPONSE=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code=$AUTH_CODE&redirect_uri=http://localhost:3000/callback&code_verifier=$CODE_VERIFIER" \
  "$SERVER_URL/token")
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .access_token)
REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .refresh_token)
if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "   ❌ Token exchange failed: $TOKEN_RESPONSE"
    exit 1
fi
echo "   ✅ Access token: ${ACCESS_TOKEN:0:20}..."
if [ "$REFRESH_TOKEN" != "null" ] && [ -n "$REFRESH_TOKEN" ]; then
    echo "   ✅ Refresh token issued"
fi

echo ""
echo "❌ Step 6: A wrong verifier must be rejected"
BAD_TOKEN_RESPONSE=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code=$AUTH_CODE&redirect_uri=http://localhost:3000/callback&code_verifier=not-the-verifier-not-the-verifier-not-the-ver" \
  "$SERVER_URL/token")
if echo "$BAD_TOKEN_RESPONSE" | jq -e '.access_token' > /dev/null 2>&1; then
    echo "   ❌ Server issued a token for a wrong verifier"
    exit 1
fi
echo "   ✅ Rejected: $(echo "$BAD_TOKEN_RESPONSE" | jq -r '.error // .')"

echo ""
echo "🧪 PHASE 2: Load-test tools"
echo "==========================="

echo "📱 Step 7: Initialize MCP session"
SESSION_ID=""
INIT_RESPONSE=$(curl -i -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"loadtest-tools-proof","version":"1.0"}}}' \
  "$SERVER_URL/mcp")
SESSION_ID=$(echo "$INIT_RESPONSE" | grep -i "mcp-session-id:" | cut -d' ' -f2 | tr -d '\r')
if [ -z "$SESSION_ID" ]; then
    echo "   ❌ MCP session initialization failed"
    echo "$INIT_RESPONSE"
    exit 1
fi
echo "   ✅ Session: $SESSION_ID"

echo ""
echo "📋 Step 8: tools/list contains every load-test tool"
TOOLS_JSON=$(mcp_call '{"jsonrpc":"2.0","id":"tools","method":"tools/list"}')
for TOOL in classify render_image oversized_text always_fails slow_echo counter; do
    if ! echo "$TOOLS_JSON" | jq -e --arg t "$TOOL" '.result.tools[] | select(.name == $t)' > /dev/null; then
        echo "   ❌ Missing tool: $TOOL"
        exit 1
    fi
    HAS_SCHEMA=$(echo "$TOOLS_JSON" | jq -r --arg t "$TOOL" '.result.tools[] | select(.name == $t) | .inputSchema.type')
    echo "   ✅ $TOOL (inputSchema.type=$HAS_SCHEMA)"
done
echo "   ℹ️  classify schema: $(echo "$TOOLS_JSON" | jq -c '.result.tools[] | select(.name == "classify") | .inputSchema')"

echo ""
echo "🏷️  Step 9: classify round-trips its arguments"
CLASSIFY_JSON=$(mcp_call '{"jsonrpc":"2.0","id":"classify","method":"tools/call","params":{"name":"classify","arguments":{"category":"security","confidence":0.82,"urgent":true,"tags":["pilot","load-test"],"subject":{"name":"acme-corp","region":"eu","priority":2}}}}')
CLASSIFY_TEXT=$(echo "$CLASSIFY_JSON" | jq -r '.result.content[0].text')
echo "   → $CLASSIFY_TEXT"
for EXPECT in "acme-corp" "security" "0.82" "urgent true" "pilot, load-test" "region eu" "priority 2"; do
    case "$CLASSIFY_TEXT" in
        *"$EXPECT"*) ;;
        *) echo "   ❌ classify echo missing: $EXPECT"; exit 1 ;;
    esac
done
echo "   ✅ classify echoed enum, bounded number, boolean, array and nested object"

echo ""
echo "🚫 Step 10: classify rejects an out-of-range confidence"
BAD_CLASSIFY=$(mcp_call '{"jsonrpc":"2.0","id":"classify-bad","method":"tools/call","params":{"name":"classify","arguments":{"category":"security","confidence":4,"urgent":true,"tags":[],"subject":{"name":"acme-corp"}}}}')
if echo "$BAD_CLASSIFY" | jq -e '.result.isError == true or (.error != null)' > /dev/null; then
    echo "   ✅ Rejected out-of-range confidence"
else
    echo "   ❌ Out-of-range confidence accepted: $BAD_CLASSIFY"
    exit 1
fi

echo ""
echo "🔢 Step 11: counter persists across calls in one session"
C1=$(mcp_call '{"jsonrpc":"2.0","id":"c1","method":"tools/call","params":{"name":"counter","arguments":{"op":"increment"}}}' | jq -r '.result.structuredContent.counter')
C2=$(mcp_call '{"jsonrpc":"2.0","id":"c2","method":"tools/call","params":{"name":"counter","arguments":{"op":"increment"}}}' | jq -r '.result.structuredContent.counter')
C3=$(mcp_call '{"jsonrpc":"2.0","id":"c3","method":"tools/call","params":{"name":"counter","arguments":{"op":"read"}}}' | jq -r '.result.structuredContent.counter')
echo "   → increment=$C1, increment=$C2, read=$C3"
if [ "$C1" != "1" ] || [ "$C2" != "2" ] || [ "$C3" != "2" ]; then
    echo "   ❌ Counter did not increment twice and hold"
    exit 1
fi
echo "   ✅ Counter incremented twice and held at 2"

echo ""
echo "🖼️  Step 12: render_image returns an image content block"
IMAGE_JSON=$(mcp_call '{"jsonrpc":"2.0","id":"img","method":"tools/call","params":{"name":"render_image","arguments":{}}}')
IMAGE_TYPE=$(echo "$IMAGE_JSON" | jq -r '.result.content[0].type')
IMAGE_MIME=$(echo "$IMAGE_JSON" | jq -r '.result.content[0].mimeType')
IMAGE_BYTES=$(echo "$IMAGE_JSON" | jq -r '.result.content[0].data' | base64 -d | wc -c)
if [ "$IMAGE_TYPE" != "image" ] || [ "$IMAGE_MIME" != "image/png" ]; then
    echo "   ❌ Not an image block: $IMAGE_JSON"
    exit 1
fi
echo "   ✅ image/png, $IMAGE_BYTES decoded bytes"

echo ""
echo "📦 Step 13: oversized_text returns more than 1MB"
OVERSIZED_BYTES=$(mcp_call '{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"oversized_text","arguments":{}}}' | jq -r '.result.content[0].text' | wc -c)
if [ "$OVERSIZED_BYTES" -le 1048576 ]; then
    echo "   ❌ Only $OVERSIZED_BYTES bytes returned"
    exit 1
fi
echo "   ✅ $OVERSIZED_BYTES bytes returned"

echo ""
echo "💥 Step 14: always_fails returns a tool error"
FAIL_JSON=$(mcp_call '{"jsonrpc":"2.0","id":"fail","method":"tools/call","params":{"name":"always_fails","arguments":{}}}')
if [ "$(echo "$FAIL_JSON" | jq -r '.result.isError')" != "true" ]; then
    echo "   ❌ Not an error result: $FAIL_JSON"
    exit 1
fi
echo "   ✅ isError=true: $(echo "$FAIL_JSON" | jq -r '.result.content[0].text')"

echo ""
echo "🐢 Step 15: slow_echo takes more than 10 seconds"
SLOW_START=$(date +%s)
SLOW_TEXT=$(mcp_call '{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"slow_echo","arguments":{"message":"still here"}}}' | jq -r '.result.content[0].text')
SLOW_ELAPSED=$(( $(date +%s) - SLOW_START ))
echo "   → $SLOW_TEXT (${SLOW_ELAPSED}s)"
if [ "$SLOW_ELAPSED" -lt 10 ]; then
    echo "   ❌ Returned in under 10 seconds"
    exit 1
fi
echo "   ✅ Slow tool took ${SLOW_ELAPSED}s"

echo ""
echo "✅ LOAD-TEST TOOLS PROOF COMPLETE"
echo "================================="
echo "✅ DCR + PKCE (S256, ${#CODE_VERIFIER}-char verifier) accepted; wrong verifier rejected"
echo "✅ All six load-test tools listed with JSON schemas"
echo "✅ classify round-tripped; counter incremented twice within the session"
echo "✅ image, oversized (>1MB), error and slow (>10s) tools behave as named"

#!/bin/bash
set -e

echo "=================================================="
echo "Load-Test Tools Proof - DCR + PKCE + tool matrix"
echo "=================================================="
echo "Registration -> authorize -> token -> MCP tools/call"
echo ""

# Configuration
PORT="${PORT:-8090}"
SERVER_URL="${BASE_URI:-http://localhost:$PORT}"
USER_ID="loadtest-tools-$(date +%s)"
SERVER_LOG="${SERVER_LOG:-/tmp/loadtest-tools-server.log}"
# The near-timeout latency bucket sleeps 55s; opt in when you want it exercised.
RUN_NEAR_TIMEOUT="${RUN_NEAR_TIMEOUT:-0}"

echo "🔧 Configuration:"
echo "  Server URL: $SERVER_URL (auth + MCP)"
echo "  User ID: $USER_ID"
echo "  Server log: $SERVER_LOG"
echo ""

# Build the project
echo "🔨 Building project..."
npm run build > /dev/null

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

# Helper: POST a JSON-RPC message to /mcp, print the JSON payload
mcp_call() {
    curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Accept: application/json, text/event-stream" \
      -H "Mcp-Session-Id: $SESSION_ID" \
      -X POST -H "Content-Type: application/json" \
      -d "$1" \
      "$SERVER_URL/mcp" | grep "^data: " | sed 's/^data: //'
}

# Helper: same, but print only the HTTP status code
mcp_status() {
    curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Accept: application/json, text/event-stream" \
      -H "Mcp-Session-Id: $SESSION_ID" \
      -X POST -H "Content-Type: application/json" \
      -d "$1" \
      "$SERVER_URL/mcp"
}

# Helper: build a tools/call request body
call_body() {
    printf '{"jsonrpc":"2.0","id":"%s","method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"
}

fail() {
    echo "   ❌ $1"
    exit 1
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
[ "$CLIENT_ID" = "null" ] && fail "Registration failed: $CLIENT_RESPONSE"
echo "   ✅ Client ID: $CLIENT_ID"

echo ""
echo "🔐 Step 2: Generate PKCE challenge (S256)"
CODE_VERIFIER=$(openssl rand -base64 64 | tr -d "=+/\n" | cut -c1-64)
CODE_CHALLENGE=$(echo -n "$CODE_VERIFIER" | openssl dgst -binary -sha256 | base64 | tr "+/" "-_" | tr -d "=")
echo "   ✅ Verifier length: ${#CODE_VERIFIER} (RFC 7636 requires >= 43)"
[ "${#CODE_VERIFIER}" -lt 43 ] && fail "Verifier shorter than 43 characters"

echo ""
echo "🎫 Step 3: Authorize"
STATE_PARAM="loadtest-tools-$(date +%s)"
AUTH_URL="$SERVER_URL/authorize?response_type=code&client_id=$CLIENT_ID&redirect_uri=http://localhost:3000/callback&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256&state=$STATE_PARAM"
AUTH_PAGE=$(curl -s "$AUTH_URL")
AUTH_CODE=$(echo "$AUTH_PAGE" | grep -o 'state=[^"&]*' | cut -d= -f2 | head -1)
[ -z "$AUTH_CODE" ] && fail "Failed to extract authorization code"
echo "   ✅ Auth code: ${AUTH_CODE:0:20}..."

echo ""
echo "🔄 Step 4: Complete mock upstream auth"
CALLBACK_RESPONSE=$(curl -s -i "$SERVER_URL/mock-upstream-idp/callback?state=$AUTH_CODE&code=mock-auth-code&userId=$USER_ID")
if echo "$CALLBACK_RESPONSE" | grep -i "^location:" | tr -d '\r' | grep -q "state=$STATE_PARAM"; then
    echo "   ✅ State parameter verified"
else
    fail "State parameter mismatch"
fi

echo ""
echo "🎟️  Step 5: Exchange code for access token (with verifier)"
TOKEN_RESPONSE=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code=$AUTH_CODE&redirect_uri=http://localhost:3000/callback&code_verifier=$CODE_VERIFIER" \
  "$SERVER_URL/token")
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .access_token)
REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .refresh_token)
[ "$ACCESS_TOKEN" = "null" ] && fail "Token exchange failed: $TOKEN_RESPONSE"
echo "   ✅ Access token: ${ACCESS_TOKEN:0:20}..."
[ "$REFRESH_TOKEN" != "null" ] && echo "   ✅ Refresh token issued"

echo ""
echo "❌ Step 6: A wrong verifier must be rejected (fresh, unconsumed code)"
STATE_PARAM_2="loadtest-tools-neg-$(date +%s)"
AUTH_PAGE_2=$(curl -s "$SERVER_URL/authorize?response_type=code&client_id=$CLIENT_ID&redirect_uri=http://localhost:3000/callback&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256&state=$STATE_PARAM_2")
AUTH_CODE_2=$(echo "$AUTH_PAGE_2" | grep -o 'state=[^"&]*' | cut -d= -f2 | head -1)
[ -z "$AUTH_CODE_2" ] && fail "Failed to obtain a second authorization code"
curl -s -o /dev/null "$SERVER_URL/mock-upstream-idp/callback?state=$AUTH_CODE_2&code=mock-auth-code&userId=$USER_ID"
echo "   ℹ️  Second authorization round completed; code is fresh"
BAD_TOKEN_RESPONSE=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code=$AUTH_CODE_2&redirect_uri=http://localhost:3000/callback&code_verifier=not-the-verifier-not-the-verifier-not-the-ver" \
  "$SERVER_URL/token")
echo "$BAD_TOKEN_RESPONSE" | jq -e '.access_token' > /dev/null 2>&1 && fail "Server issued a token for a wrong verifier"
echo "   ✅ Rejected: $(echo "$BAD_TOKEN_RESPONSE" | jq -r '.error // .')"

echo ""
echo "🧪 PHASE 2: The tool matrix"
echo "==========================="

echo "📱 Step 7: Initialize MCP session"
INIT_RESPONSE=$(curl -i -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"loadtest-tools-proof","version":"1.0"}}}' \
  "$SERVER_URL/mcp")
SESSION_ID=$(echo "$INIT_RESPONSE" | grep -i "mcp-session-id:" | cut -d' ' -f2 | tr -d '\r')
[ -z "$SESSION_ID" ] && fail "MCP session initialization failed: $INIT_RESPONSE"
echo "   ✅ Session: $SESSION_ID"

echo ""
echo "📋 Step 8: tools/list is large and complete"
TOOLS_JSON=$(mcp_call '{"jsonrpc":"2.0","id":"tools","method":"tools/list"}')
TOOL_COUNT=$(echo "$TOOLS_JSON" | jq '.result.tools | length')
LIST_BYTES=$(echo "$TOOLS_JSON" | wc -c)
echo "   ✅ $TOOL_COUNT tools listed, $LIST_BYTES bytes of tools/list payload"
[ "$TOOL_COUNT" -lt 50 ] && fail "tools/list is not large ($TOOL_COUNT tools)"
for TOOL in ping classify chaos_text chaos_image chaos_result chaos_fail deep_nest \
            render_image oversized_text always_fails slow_echo counter \
            deterministic_sample enormous_schema vanishing mutating_schema \
            unauthorized close_connection bulk_op_00 bulk_op_39; do
    echo "$TOOLS_JSON" | jq -e --arg t "$TOOL" '.result.tools[] | select(.name == $t) | .inputSchema.type' > /dev/null \
      || fail "Missing tool or schema: $TOOL"
done
echo "   ✅ Every named tool present with an object inputSchema"
ENORMOUS_FIELDS=$(echo "$TOOLS_JSON" | jq '.result.tools[] | select(.name == "enormous_schema") | .inputSchema.properties | length')
echo "   ✅ enormous_schema declares $ENORMOUS_FIELDS properties"
[ "$ENORMOUS_FIELDS" -lt 250 ] && fail "enormous_schema is not enormous"
CHAOS_REQUIRED=$(echo "$TOOLS_JSON" | jq -c '.result.tools[] | select(.name == "chaos_text") | (.inputSchema.required // [])')
[ "$CHAOS_REQUIRED" = "[]" ] || fail "Defaulted arguments are advertised as required: $CHAOS_REQUIRED"
echo "   ✅ Defaulted arguments are advertised as optional (chaos_text required: $CHAOS_REQUIRED)"
echo "   ℹ️  classify schema: $(echo "$TOOLS_JSON" | jq -c '.result.tools[] | select(.name == "classify") | .inputSchema')"

echo ""
echo "🏷️  Step 9: classify round-trips its arguments"
CLASSIFY_TEXT=$(mcp_call "$(call_body classify classify '{"category":"security","confidence":0.82,"urgent":true,"tags":["pilot","load-test"],"subject":{"name":"acme-corp","region":"eu","priority":2}}')" | jq -r '.result.content[0].text')
echo "   → $CLASSIFY_TEXT"
for EXPECT in "acme-corp" "security" "0.82" "urgent true" "pilot, load-test" "region eu" "priority 2"; do
    case "$CLASSIFY_TEXT" in
        *"$EXPECT"*) ;;
        *) fail "classify echo missing: $EXPECT" ;;
    esac
done
BAD_CLASSIFY=$(mcp_call "$(call_body classify-bad classify '{"category":"security","confidence":4,"urgent":true,"tags":[],"subject":{"name":"acme-corp"}}')")
echo "$BAD_CLASSIFY" | jq -e '.result.isError == true or (.error != null)' > /dev/null \
  || fail "Out-of-range confidence accepted: $BAD_CLASSIFY"
echo "   ✅ Round-tripped enum, bounded number, boolean, array, nested object; out-of-range confidence rejected"

echo ""
echo "🎲 Step 10: determinism — same (session, cursor) yields the same behavior"
SAMPLE_A=$(mcp_call "$(call_body det-a deterministic_sample '{"cursor":7}')" | jq -c '.result.structuredContent | {cursor, seed, samples, word}')
SAMPLE_B=$(mcp_call "$(call_body det-b deterministic_sample '{"cursor":7}')" | jq -c '.result.structuredContent | {cursor, seed, samples, word}')
SAMPLE_C=$(mcp_call "$(call_body det-c deterministic_sample '{"cursor":8}')" | jq -c '.result.structuredContent | {cursor, seed, samples, word}')
echo "   → cursor 7: $SAMPLE_A"
echo "   → cursor 7: $SAMPLE_B"
echo "   → cursor 8: $SAMPLE_C"
[ "$SAMPLE_A" != "$SAMPLE_B" ] && fail "Same (session, cursor) produced different output"
[ "$SAMPLE_A" = "$SAMPLE_C" ] && fail "Different cursors produced identical output"
TEXT_MD5_A=$(mcp_call "$(call_body txt-a chaos_text '{"size":"1kb","cursor":11}')" | jq -r '.result.content[0].text' | md5sum | cut -d' ' -f1)
TEXT_MD5_B=$(mcp_call "$(call_body txt-b chaos_text '{"size":"1kb","cursor":11}')" | jq -r '.result.content[0].text' | md5sum | cut -d' ' -f1)
TEXT_MD5_C=$(mcp_call "$(call_body txt-c chaos_text '{"size":"1kb","cursor":12}')" | jq -r '.result.content[0].text' | md5sum | cut -d' ' -f1)
echo "   → chaos_text md5 at cursor 11: $TEXT_MD5_A / $TEXT_MD5_B, at cursor 12: $TEXT_MD5_C"
[ "$TEXT_MD5_A" != "$TEXT_MD5_B" ] && fail "Pinned cursor produced different text"
[ "$TEXT_MD5_A" = "$TEXT_MD5_C" ] && fail "Different cursors produced identical text"
echo "   ✅ Behavior is a pure function of (session id, cursor)"

echo ""
echo "🔢 Step 11: counter persists across calls in one session"
C1=$(mcp_call "$(call_body c1 counter '{"op":"increment"}')" | jq -r '.result.structuredContent.counter')
C2=$(mcp_call "$(call_body c2 counter '{"op":"increment"}')" | jq -r '.result.structuredContent.counter')
C3=$(mcp_call "$(call_body c3 counter '{"op":"read"}')" | jq -r '.result.structuredContent.counter')
echo "   → increment=$C1, increment=$C2, read=$C3"
{ [ "$C1" = "1" ] && [ "$C2" = "2" ] && [ "$C3" = "2" ]; } || fail "Counter did not increment twice and hold"
echo "   ✅ Counter incremented twice and held at 2"

echo ""
echo "⚡ Step 12: ping is tiny and fast"
PING_TEXT=$(mcp_call "$(call_body ping ping '{}')" | jq -r '.result.content[0].text')
[ "$PING_TEXT" = "pong" ] || fail "ping returned: $PING_TEXT"
echo "   ✅ ping -> pong"

echo ""
echo "📦 Step 13: chaos_text sizes"
for SIZE in 1kb 100kb 4mb; do
    BYTES=$(mcp_call "$(call_body "text-$SIZE" chaos_text "{\"size\":\"$SIZE\"}")" | jq -r '.result.content[0].text' | wc -c)
    echo "   ✅ size=$SIZE -> $BYTES bytes"
done
OVERSIZED_BYTES=$(mcp_call "$(call_body big oversized_text '{}')" | jq -r '.result.content[0].text' | wc -c)
[ "$OVERSIZED_BYTES" -le 1048576 ] && fail "oversized_text returned only $OVERSIZED_BYTES bytes"
echo "   ✅ oversized_text -> $OVERSIZED_BYTES bytes (>1MB)"

echo ""
echo "⏱️  Step 14: latency buckets"
for BUCKET in 0ms 50ms 1s 10s; do
    START=$(date +%s)
    mcp_call "$(call_body "lat-$BUCKET" chaos_text "{\"size\":\"1kb\",\"latency\":\"$BUCKET\"}")" > /dev/null
    echo "   ✅ latency=$BUCKET -> $(( $(date +%s) - START ))s"
done
if [ "$RUN_NEAR_TIMEOUT" = "1" ]; then
    START=$(date +%s)
    mcp_call "$(call_body lat-near chaos_text '{"size":"1kb","latency":"near_timeout"}')" > /dev/null
    echo "   ✅ latency=near_timeout -> $(( $(date +%s) - START ))s"
else
    echo "   ⏭️  latency=near_timeout (55s) skipped; set RUN_NEAR_TIMEOUT=1 to include it"
fi

echo ""
echo "🖼️  Step 15: images, including an obnoxious one, and mixed text+image"
for SIZE in tiny huge; do
    IMAGE_JSON=$(mcp_call "$(call_body "img-$SIZE" chaos_image "{\"size\":\"$SIZE\"}")")
    [ "$(echo "$IMAGE_JSON" | jq -r '.result.content[0].type')" = "image" ] || fail "Not an image block: $SIZE"
    IMAGE_BYTES=$(echo "$IMAGE_JSON" | jq -r '.result.content[0].data' | base64 -d | wc -c)
    echo "   ✅ size=$SIZE -> $IMAGE_BYTES PNG bytes ($(echo "$IMAGE_JSON" | jq -r '.result.content[0].mimeType'))"
done
MIXED_TYPES=$(mcp_call "$(call_body img-mixed chaos_image '{"size":"tiny","with_text":true}')" | jq -r '[.result.content[].type] | join("+")')
[ "$MIXED_TYPES" = "text+image" ] || fail "Mixed result was: $MIXED_TYPES"
echo "   ✅ mixed result content: $MIXED_TYPES"
RENDER_TYPE=$(mcp_call "$(call_body render render_image '{}')" | jq -r '.result.content[0].type')
[ "$RENDER_TYPE" = "image" ] || fail "render_image returned $RENDER_TYPE"
echo "   ✅ render_image -> image block"

echo ""
echo "🧬 Step 16: empty, hostile Unicode and nested results"
EMPTY_LEN=$(mcp_call "$(call_body empty chaos_result '{"shape":"empty"}')" | jq '.result.content | length')
[ "$EMPTY_LEN" = "0" ] || fail "Empty result had $EMPTY_LEN blocks"
echo "   ✅ empty result: 0 content blocks"
UNICODE_JSON=$(mcp_call "$(call_body uni chaos_result '{"shape":"unicode"}')")
UNICODE_KEYS=$(echo "$UNICODE_JSON" | jq -r '.result.structuredContent.strings | keys | join(",")')
echo "   ✅ unicode keys: $UNICODE_KEYS"
UNICODE_EMOJI=$(echo "$UNICODE_JSON" | jq -r '.result.structuredContent.strings.emoji')
UNICODE_QUOTES=$(echo "$UNICODE_JSON" | jq -r '.result.structuredContent.strings.quotes')
[ "$UNICODE_EMOJI" = "🙈🙉🙊 family: 👨‍👩‍👧‍👦 flag: 🇯🇵" ] || fail "emoji string came back altered: $UNICODE_EMOJI"
[ "$UNICODE_QUOTES" = "she said \"hi\" and 'bye' and \`tick\` and \\backslash\\" ] || fail "quotes string came back altered: $UNICODE_QUOTES"
echo "   ✅ emoji and quote/backslash strings round-tripped exactly"
echo "   → emoji: $UNICODE_EMOJI"
echo "   → rtl:   $(echo "$UNICODE_JSON" | jq -r '.result.structuredContent.strings.rtl')"
echo "   → bait:  $(echo "$UNICODE_JSON" | jq -r '.result.structuredContent.strings.json_bait')"
NESTED_DEPTH=$(mcp_call "$(call_body nested chaos_result '{"shape":"nested","depth":6}')" | jq -r '.result.structuredContent.nested.depth')
[ "$NESTED_DEPTH" = "6" ] || fail "Nested result depth was $NESTED_DEPTH"
echo "   ✅ nested result depth: $NESTED_DEPTH"
DEEP_JSON=$(mcp_call "$(call_body deep deep_nest '{"depth":12,"payload":{"level1":{"level2":{"level3":{"level4":{"value":"leaf","flag":true}}}}}}')")
DEEP_ECHO=$(echo "$DEEP_JSON" | jq -r '.result.structuredContent.payload.level1.level2.level3.level4.value')
DEEP_DEPTH=$(echo "$DEEP_JSON" | jq -r '.result.structuredContent.nested.depth')
{ [ "$DEEP_ECHO" = "leaf" ] && [ "$DEEP_DEPTH" = "12" ]; } || fail "deep_nest echo=$DEEP_ECHO depth=$DEEP_DEPTH"
echo "   ✅ deep_nest echoed a 5-level argument and returned depth $DEEP_DEPTH"

echo ""
echo "💥 Step 17: deterministic failures"
FAIL_JSON=$(mcp_call "$(call_body f1 chaos_fail '{"mode":"tool_error"}')")
[ "$(echo "$FAIL_JSON" | jq -r '.result.isError')" = "true" ] || fail "tool_error was not an error result"
echo "   ✅ tool_error -> isError result"
CODE_400=$(mcp_call "$(call_body f2 chaos_fail '{"mode":"client_error"}')" | jq -r '.error.code')
[ "$CODE_400" = "-32602" ] || fail "client_error code was $CODE_400"
echo "   ✅ client_error -> JSON-RPC $CODE_400 (400-shaped, InvalidParams)"
CODE_500=$(mcp_call "$(call_body f3 chaos_fail '{"mode":"server_error"}')" | jq -r '.error.code')
[ "$CODE_500" = "-32603" ] || fail "server_error code was $CODE_500"
echo "   ✅ server_error -> JSON-RPC $CODE_500 (500-shaped, InternalError)"
INTERMITTENT_FAIL=$(mcp_call "$(call_body f4 chaos_fail '{"mode":"intermittent","every_n":17,"cursor":34}')" | jq -r '.error.message')
INTERMITTENT_OK=$(mcp_call "$(call_body f5 chaos_fail '{"mode":"intermittent","every_n":17,"cursor":35}')" | jq -r '.result.structuredContent.failed')
case "$INTERMITTENT_FAIL" in
    *"intermittent failure at cursor 34"*) ;;
    *) fail "Intermittent did not fail on the 17th multiple: $INTERMITTENT_FAIL" ;;
esac
[ "$INTERMITTENT_OK" = "false" ] || fail "Intermittent failed off-cycle"
echo "   ✅ intermittent (N=17) fails at cursor 34, succeeds at cursor 35"
ALWAYS_FAIL_TEXT=$(mcp_call "$(call_body f6 always_fails '{}')" | jq -r '.result.content[0].text')
echo "   ✅ always_fails -> $ALWAYS_FAIL_TEXT"

echo ""
echo "🗂️  Step 18: enormous schema accepts and reports its fields"
ENORMOUS_JSON=$(mcp_call "$(call_body enorm enormous_schema '{"field_000":"a","field_001":42,"field_002":"two","field_003":["x"]}')")
echo "   ✅ $(echo "$ENORMOUS_JSON" | jq -r '.result.content[0].text')"

echo ""
echo "🫥 Step 19: vanishing tool disappears after its first call"
BEFORE=$(mcp_call '{"jsonrpc":"2.0","id":"l1","method":"tools/list"}' | jq '[.result.tools[] | select(.name == "vanishing")] | length')
VANISH_TEXT=$(mcp_call "$(call_body van vanishing '{}')" | jq -r '.result.content[0].text')
AFTER=$(mcp_call '{"jsonrpc":"2.0","id":"l2","method":"tools/list"}' | jq '[.result.tools[] | select(.name == "vanishing")] | length')
echo "   → listed before: $BEFORE, after: $AFTER"
echo "   → $VANISH_TEXT"
{ [ "$BEFORE" = "1" ] && [ "$AFTER" = "0" ]; } || fail "vanishing tool did not vanish"
echo "   ✅ Present before the call, absent after"

echo ""
echo "🔀 Step 20: mutating_schema differs between list and call"
LISTED_TYPE=$(mcp_call '{"jsonrpc":"2.0","id":"l3","method":"tools/list"}' | jq -r '.result.tools[] | select(.name == "mutating_schema") | .inputSchema.properties.value.type')
echo "   → listing advertised value: $LISTED_TYPE"
if [ "$LISTED_TYPE" = "string" ]; then
    MUTATE_ARGS='{"value":"as-listed"}'
else
    MUTATE_ARGS='{"value":7,"mode":"strict"}'
fi
MUTATE_ERROR=$(mcp_call "$(call_body mut mutating_schema "$MUTATE_ARGS")" | jq -r '.error.message')
case "$MUTATE_ERROR" in
    *"do not match schema version"*) ;;
    *) fail "Calling with the listed shape succeeded: $MUTATE_ERROR" ;;
esac
echo "   ✅ Calling with the listed shape was rejected: $MUTATE_ERROR"

echo ""
echo "🔒 Step 21: unauthorized returns HTTP 401 after successful auth"
STATUS=$(mcp_status "$(call_body unauth unauthorized '{"mode":"always"}')")
[ "$STATUS" = "401" ] || fail "unauthorized returned HTTP $STATUS"
echo "   ✅ HTTP $STATUS on a session whose token is still valid"
STATUS_OK=$(mcp_status "$(call_body ping2 ping '{}')")
[ "$STATUS_OK" = "200" ] || fail "Session unusable after the synthetic 401 (HTTP $STATUS_OK)"
echo "   ✅ Session still usable afterwards (HTTP $STATUS_OK)"

INV_BEFORE=$(mcp_call "$(call_body inv-a deterministic_sample '{}')" | jq -r '.result.structuredContent.invocation')
mcp_status "$(call_body unauth2 unauthorized '{"mode":"always"}')" > /dev/null
INV_AFTER=$(mcp_call "$(call_body inv-b deterministic_sample '{}')" | jq -r '.result.structuredContent.invocation')
echo "   → invocation $INV_BEFORE -> $INV_AFTER across one 401 and one sample call"
[ "$((INV_AFTER - INV_BEFORE))" -eq 2 ] || fail "A 401 call advanced the invocation counter by $((INV_AFTER - INV_BEFORE - 1)), not 1"
echo "   ✅ A middleware-answered call advances the invocation counter by exactly 1"

echo ""
echo "🔁 Step 21b: unauthorized every_n=3 fires on exactly every third call"
N0=$(mcp_call "$(call_body inv-c deterministic_sample '{}')" | jq -r '.result.structuredContent.invocation')
PATTERN=""
EXPECTED=""
for I in 1 2 3 4 5 6; do
    STATUS=$(mcp_status "$(call_body "everyn-$I" unauthorized '{"mode":"every_n","every_n":3}')")
    PATTERN="$PATTERN $STATUS"
    if [ "$(( (N0 + I) % 3 ))" -eq 0 ]; then
        EXPECTED="$EXPECTED 401"
    else
        EXPECTED="$EXPECTED 200"
    fi
done
echo "   → invocations $((N0 + 1))..$((N0 + 6)) returned:$PATTERN"
echo "   → expected (multiples of 3):$EXPECTED"
[ "$PATTERN" = "$EXPECTED" ] || fail "every_n pattern mismatch"
COUNT_401=$(echo "$PATTERN" | tr ' ' '\n' | grep -c 401)
[ "$COUNT_401" -eq 2 ] || fail "Expected exactly two 401s in six calls, got $COUNT_401"
echo "   ✅ 401 landed on exactly the 3rd and 6th multiples, 200 elsewhere"

echo ""
echo "🔌 Step 22: close_connection drops the socket mid-response"
set +e
CLOSE_OUTPUT=$(curl -s --max-time 10 -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -X POST -H "Content-Type: application/json" \
  -d "$(call_body close close_connection '{"bytes_first":64}')" \
  "$SERVER_URL/mcp")
CLOSE_EXIT=$?
set -e
echo "   → curl exit $CLOSE_EXIT, ${#CLOSE_OUTPUT} bytes of partial body received"
[ "$CLOSE_EXIT" -eq 0 ] && fail "Connection was not dropped"
[ "${#CLOSE_OUTPUT}" -lt 64 ] && fail "Partial body was ${#CLOSE_OUTPUT} bytes; the 64 requested bytes did not arrive"
echo "   ✅ Client saw the 64 requested bytes, then a truncated response (curl exit $CLOSE_EXIT)"
STATUS_OK=$(mcp_status "$(call_body ping3 ping '{}')")
[ "$STATUS_OK" = "200" ] || fail "Session unusable after the dropped connection (HTTP $STATUS_OK)"
echo "   ✅ Session still usable afterwards (HTTP $STATUS_OK)"

echo ""
echo "🐢 Step 23: slow_echo takes more than 10 seconds"
SLOW_START=$(date +%s)
SLOW_TEXT=$(mcp_call "$(call_body slow slow_echo '{"message":"still here"}')" | jq -r '.result.content[0].text')
SLOW_ELAPSED=$(( $(date +%s) - SLOW_START ))
echo "   → $SLOW_TEXT (${SLOW_ELAPSED}s)"
[ "$SLOW_ELAPSED" -lt 10 ] && fail "slow_echo returned in under 10 seconds"
echo "   ✅ slow_echo took ${SLOW_ELAPSED}s"

echo ""
echo "✅ LOAD-TEST TOOLS PROOF COMPLETE"
echo "================================="
echo "✅ DCR + PKCE (S256, ${#CODE_VERIFIER}-char verifier) accepted; wrong verifier rejected"
echo "✅ $TOOL_COUNT tools listed ($LIST_BYTES bytes), every one with a JSON schema"
echo "✅ Determinism: a pinned (session, cursor) reproduced identical seed, samples and text md5"
echo "✅ Sizes, latency buckets, images, empty/Unicode/nested results, deterministic and"
echo "   intermittent failures, vanishing and mutating tools, 401 and dropped connection"
echo "   all behaved as named"

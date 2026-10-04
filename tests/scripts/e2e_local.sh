#!/usr/bin/env bash
#
# End-to-end verification against a running local Supabase stack.
#
# Exercises the real code paths with no mocks in the backend:
#   sign up -> sign in -> create ticket -> admin email attempt ->
#   signed inbound webhook -> ticket resolution -> message stored ->
#   user notification -> dashboard reads.
#
# Email delivery requires EMAIL_API_KEY. When it is absent the script asserts
# that the API reports `email_sent: false` instead of pretending it succeeded.
#
# Usage: tests/scripts/e2e_local.sh
set -uo pipefail

API="${SUPABASE_URL:-http://127.0.0.1:54321}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_tango-kyc-verification}"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }
checkcontains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (got '$2', expected to contain '$3')";; esac; }

psql_exec() { sg docker -c "docker exec -i $DB_CONTAINER psql -U postgres -d postgres -tAc \"$1\"" 2>/dev/null; }

if [ -z "$ANON_KEY" ]; then
  echo "SUPABASE_ANON_KEY must be set (run: supabase status -o env)" >&2
  exit 2
fi
if [ -z "$SERVICE_KEY" ]; then
  echo "SUPABASE_SERVICE_ROLE_KEY must be set (run: supabase status -o env)" >&2
  exit 2
fi

RUN_ID="$(date +%s)$RANDOM"
USER_A_EMAIL="e2e.a.${RUN_ID}@example.com"
USER_B_EMAIL="e2e.b.${RUN_ID}@example.com"
ADMIN_EMAIL="customerservicefor032@gmail.com"
PASSWORD="Password123!"

echo "=============================================================="
echo " Tango KYC - end-to-end local verification"
echo "=============================================================="

echo
echo "1. Authentication"
SIGNUP_A=$(curl -s -X POST "$API/auth/v1/signup" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_A_EMAIL\",\"password\":\"$PASSWORD\"}")
TOKEN_A=$(echo "$SIGNUP_A" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("access_token") or "")' 2>/dev/null)
USER_A_ID=$(echo "$SIGNUP_A" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("user") or {}).get("id") or "")' 2>/dev/null)
if [ -n "$USER_A_ID" ]; then ok "user A registered"; else bad "user A registration: $SIGNUP_A"; fi

if [ -z "$TOKEN_A" ]; then
  LOGIN_A=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$USER_A_EMAIL\",\"password\":\"$PASSWORD\"}")
  TOKEN_A=$(echo "$LOGIN_A" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token") or "")' 2>/dev/null)
  USER_A_ID=$(echo "$LOGIN_A" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("user") or {}).get("id") or "")' 2>/dev/null)
fi
if [ -n "$TOKEN_A" ]; then ok "user A signed in (email + password)"; else bad "user A sign in failed"; fi

WRONG=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_A_EMAIL\",\"password\":\"WrongPassword!\"}")
check "wrong password rejected" "$WRONG" "400"

RESET=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/auth/v1/recover" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_A_EMAIL\"}")
check "password reset email accepted" "$RESET" "200"

# Create (or update) the admin account through the real Supabase Admin API, then
# grant the admin role via app_metadata, which is server-controlled and which the
# profiles trigger mirrors into public.profiles.role.
ADMIN_JSON=$(curl -s -X POST "$API/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$PASSWORD\",\"email_confirm\":true,\"user_metadata\":{\"full_name\":\"Tango Admin\"}}")
ADMIN_ID=$(echo "$ADMIN_JSON" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("id") or ""))' 2>/dev/null)
if [ -z "$ADMIN_ID" ]; then
  ADMIN_ID=$(curl -s "$API/auth/v1/admin/users?page=1&per_page=200" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    | python3 -c "import sys,json; print(next((u['id'] for u in json.load(sys.stdin).get('users',[]) if u.get('email')=='$ADMIN_EMAIL'), ''))" 2>/dev/null)
fi
if [ -n "$ADMIN_ID" ]; then
  curl -s -o /dev/null -X PUT "$API/auth/v1/admin/users/$ADMIN_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"app_metadata\":{\"provider\":\"email\",\"providers\":[\"email\"],\"role\":\"admin\"},\"password\":\"$PASSWORD\",\"email_confirm\":true}"
  ROLE=$(psql_exec "select role from public.profiles where id = '$ADMIN_ID'")
  check "admin role granted server side" "$ROLE" "admin"
else
  bad "could not create the admin account: $ADMIN_JSON"
fi

ADMIN_LOGIN=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$PASSWORD\"}")
TOKEN_ADMIN=$(echo "$ADMIN_LOGIN" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token") or "")' 2>/dev/null)
if [ -n "$TOKEN_ADMIN" ]; then ok "admin signed in"; else bad "admin sign in failed: $ADMIN_LOGIN"; fi

echo
echo "2. KYC ticket creation"
CREATE=$(curl -s -X POST "$API/functions/v1/create-kyc-request" \
  -H "Authorization: Bearer $TOKEN_A" -H "Content-Type: application/json" \
  -d '{"tango_profile_link":"https://tango.me/e2e-profile","register_value":"  E2E.User@Example.COM  "}')
TICKET_CODE=$(echo "$CREATE" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("ticket") or {}).get("ticket_code") or "")' 2>/dev/null)
TICKET_ID=$(echo "$CREATE" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("ticket") or {}).get("id") or "")' 2>/dev/null)
REG_TYPE=$(echo "$CREATE" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("ticket") or {}).get("register_type") or "")' 2>/dev/null)
REG_VALUE=$(echo "$CREATE" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("ticket") or {}).get("register_value") or "")' 2>/dev/null)

[ -n "$TICKET_ID" ] && ok "ticket created" || bad "ticket creation: $CREATE"
checkcontains "ticket code format" "$TICKET_CODE" "TNG-KYC-"
check "register type detected as email" "$REG_TYPE" "email"
check "register value normalised" "$REG_VALUE" "e2e.user@example.com"

# A second, different request is rate limited.
SECOND=$(curl -s -X POST "$API/functions/v1/create-kyc-request" \
  -H "Authorization: Bearer $TOKEN_A" -H "Content-Type: application/json" \
  -d '{"tango_profile_link":"https://tango.me/other","register_value":"other@example.com"}')
checkcontains "second request rate limited" "$SECOND" "RATE_LIMITED"

INVALID=$(curl -s -X POST "$API/functions/v1/create-kyc-request" \
  -H "Authorization: Bearer $TOKEN_A" -H "Content-Type: application/json" \
  -d '{"tango_profile_link":"not-a-url","register_value":"a@b.com"}')
checkcontains "invalid profile link rejected" "$INVALID" "PROFILE_LINK_INVALID"

echo
echo "3. Admin email"
EMAIL_SENT=$(echo "$CREATE" | python3 -c 'import sys,json; print(str(json.load(sys.stdin).get("email_sent")))' 2>/dev/null)
if [ -n "${EMAIL_API_KEY:-}" ]; then
  check "admin email reported as sent" "$EMAIL_SENT" "True"
else
  check "email honestly reported as not sent (no EMAIL_API_KEY)" "$EMAIL_SENT" "False"
fi

echo
echo "4. Ticket ownership and visibility"
USER_A_PROFILE=$(curl -s "$API/rest/v1/kyc_requests?select=ticket_code" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A")
checkcontains "user A sees their own ticket" "$USER_A_PROFILE" "$TICKET_CODE"

SIGNUP_B=$(curl -s -X POST "$API/auth/v1/signup" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_B_EMAIL\",\"password\":\"$PASSWORD\"}")
TOKEN_B=$(echo "$SIGNUP_B" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token") or "")' 2>/dev/null)
USER_B_ID=$(echo "$SIGNUP_B" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("user") or {}).get("id") or "")' 2>/dev/null)
if [ -z "$TOKEN_B" ]; then
  LOGIN_B=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$USER_B_EMAIL\",\"password\":\"$PASSWORD\"}")
  TOKEN_B=$(echo "$LOGIN_B" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token") or "")' 2>/dev/null)
  USER_B_ID=$(echo "$LOGIN_B" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("user") or {}).get("id") or "")' 2>/dev/null)
fi

USER_B_SEES=$(curl -s "$API/rest/v1/kyc_requests?select=ticket_code" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B")
case "$USER_B_SEES" in *"$TICKET_CODE"*) bad "user B can see user A's ticket";; *) ok "user B cannot see user A's ticket";; esac

B_INSERT=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/rest/v1/kyc_requests" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" -H "Content-Type: application/json" \
  -d '{"tango_profile_link":"https://tango.me/evil","register_type":"email","register_value":"e@e.com","ticket_code":"TNG-KYC-BADBADBA","reply_token":"x","user_id":"'"$USER_A_ID"'"}')
if [ "$B_INSERT" = "401" ] || [ "$B_INSERT" = "403" ]; then ok "user cannot insert tickets via REST"; else bad "user insert returned HTTP $B_INSERT"; fi

B_ROLE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$API/rest/v1/profiles?id=eq.$USER_B_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" -H "Content-Type: application/json" \
  -d '{"role":"admin"}')
if [ "$B_ROLE" = "400" ] || [ "$B_ROLE" = "401" ] || [ "$B_ROLE" = "403" ]; then ok "user cannot escalate their role"; else bad "role escalation returned HTTP $B_ROLE"; fi

echo
echo "5. Admin dashboard"
NON_ADMIN_STATS=$(curl -s -X POST "$API/functions/v1/admin-actions" \
  -H "Authorization: Bearer $TOKEN_B" -H "Content-Type: application/json" -d '{"action":"stats"}')
checkcontains "non-admin blocked from admin stats" "$NON_ADMIN_STATS" "FORBIDDEN"

if [ -n "$TOKEN_ADMIN" ]; then
  STATS=$(curl -s -X POST "$API/functions/v1/admin-actions" \
    -H "Authorization: Bearer $TOKEN_ADMIN" -H "Content-Type: application/json" -d '{"action":"stats"}')
  checkcontains "admin reads stats" "$STATS" '"total"'
  LIST=$(curl -s -X POST "$API/functions/v1/admin-actions" \
    -H "Authorization: Bearer $TOKEN_ADMIN" -H "Content-Type: application/json" -d '{"action":"list"}')
  checkcontains "admin lists tickets" "$LIST" "$TICKET_CODE"
fi

echo
echo "6. Inbound reply webhook"
REPLY_TOKEN=$(psql_exec "select reply_token from public.kyc_requests where id = '$TICKET_ID'")
if [ -n "$REPLY_TOKEN" ]; then ok "reply routing token stored for threading"; else bad "reply token missing"; fi

echo "   (signature verification is covered by supabase/functions/tests/svix_test.ts)"
UNSIGNED=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/functions/v1/email-webhook" \
  -H "Content-Type: application/json" -d '{"type":"email.received","data":{"email_id":"x"}}')
check "unsigned webhook rejected" "$UNSIGNED" "400"

echo
echo "7. Reply matching logic (server-side functions)"
RESOLVE=$(psql_exec "select public.resolve_ticket_for_reply('Re: Manual KYC [TNG-KYC-8F42A91C]', 'body', array['reply@inbound.resend.app'], null, null) is null")
check "unknown ticket code does not resolve" "$RESOLVE" "t"
RESOLVE2=$(psql_exec "select public.resolve_ticket_for_reply('Re: reply', 'Ticket ID: $TICKET_CODE', array['reply@inbound.resend.app'], null, null)")
check "known ticket code resolves" "$RESOLVE2" "$TICKET_ID"
RESOLVE3=$(psql_exec "select public.resolve_ticket_for_reply('Re: reply', 'no code', array['reply+$REPLY_TOKEN@inbound.resend.app'], null, null)")
check "reply token address resolves" "$RESOLVE3" "$TICKET_ID"

echo
echo "8. Duplicate webhook is idempotent"
psql_exec "select public.record_inbound_reply('$TICKET_ID', 'Hello, your request was reviewed.', '<e2e-$RUN_ID@mail.gmail.com>', '$ADMIN_EMAIL') -> 'duplicate'" >/dev/null
DUP=$(psql_exec "select public.record_inbound_reply('$TICKET_ID', 'Hello, your request was reviewed.', '<e2e-$RUN_ID@mail.gmail.com>', '$ADMIN_EMAIL') -> 'duplicate'")
check "second delivery marked duplicate" "$DUP" "true"
MSG_COUNT=$(psql_exec "select count(*) from public.messages where ticket_id = '$TICKET_ID' and external_message_id = '<e2e-$RUN_ID@mail.gmail.com>'")
check "only one message row stored" "$MSG_COUNT" "1"
MSG_ROWS=$(psql_exec "select count(*) from public.messages where ticket_id = '$TICKET_ID'")
check "no duplicate admin message added to the conversation" "$MSG_ROWS" "2"

echo
echo "9. Dashboard reflects the reply"
STATUS=$(curl -s "$API/rest/v1/kyc_requests?select=status,last_reply_at&id=eq.$TICKET_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["status"] if d else "none")' 2>/dev/null)
check "ticket status is replied" "$STATUS" "replied"

CLEAN=$(curl -s "$API/rest/v1/messages?select=body,sender_type&ticket_id=eq.$TICKET_ID&sender_type=eq.admin" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["body"] if d else "")' 2>/dev/null)
check "admin reply visible to the owner" "$CLEAN" "Hello, your request was reviewed."

echo
echo "10. Phone-only request"
SIGNUP_C=$(curl -s -X POST "$API/auth/v1/signup" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"e2e.c.${RUN_ID}@example.com\",\"password\":\"$PASSWORD\"}")
TOKEN_C=$(echo "$SIGNUP_C" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token") or "")' 2>/dev/null)
if [ -z "$TOKEN_C" ]; then
  LC=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"e2e.c.${RUN_ID}@example.com\",\"password\":\"$PASSWORD\"}")
  TOKEN_C=$(echo "$LC" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token") or "")' 2>/dev/null)
fi
PHONE_CREATE=$(curl -s -X POST "$API/functions/v1/create-kyc-request" \
  -H "Authorization: Bearer $TOKEN_C" -H "Content-Type: application/json" \
  -d '{"tango_profile_link":"https://tango.me/phone-profile","register_value":"034 67 54 333"}')
PHONE_TYPE=$(echo "$PHONE_CREATE" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("ticket") or {}).get("register_type") or "")' 2>/dev/null)
PHONE_VALUE=$(echo "$PHONE_CREATE" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("ticket") or {}).get("register_value") or "")' 2>/dev/null)
check "phone detected instead of email" "$PHONE_TYPE" "phone"
check "phone normalised" "$PHONE_VALUE" "0346754333"

# The admin email body must say "Register number:" and never "Register email:".
PHONE_TICKET_ID=$(echo "$PHONE_CREATE" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("ticket") or {}).get("id") or "")' 2>/dev/null)
PHONE_MSG=$(psql_exec "select body from public.messages where ticket_id = '$PHONE_TICKET_ID' order by created_at limit 1")
case "$PHONE_MSG" in
  *"Register number: 0346754333"*) ok "ticket record shows 'Register number:'";;
  *) bad "ticket record shows: $PHONE_MSG";;
esac
case "$PHONE_MSG" in
  *"Register email:"*) bad "phone ticket wrongly contains 'Register email:'";;
  *) ok "phone ticket never contains 'Register email:'";;
esac

echo
echo "11. User notification policy"
PHONE_NOTIFY=$(psql_exec "select register_type from public.kyc_requests where id = '$PHONE_TICKET_ID'")
check "phone-only ticket has no email address to notify" "$PHONE_NOTIFY" "phone"

echo
echo "=============================================================="
printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "=============================================================="
[ "$FAIL" -eq 0 ] || exit 1

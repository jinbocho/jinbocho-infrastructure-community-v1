#!/usr/bin/env bash
# End-to-end API validation through the gateway (port 8000).
# Exercises BE1 (users/families proxy), BE2 (catalog JWT), BE3 (book writes use `sub`).
set -uo pipefail

GW="http://localhost:8000"
PASS=0
FAIL=0

# check <description> <expected_status> <actual_status> [body]
check() {
  local desc="$1" want="$2" got="$3" body="${4:-}"
  if [[ "$got" == "$want" ]]; then
    echo "  ✅ $desc → $got"
    PASS=$((PASS+1))
  else
    echo "  ❌ $desc → got $got, want $want"
    [[ -n "$body" ]] && echo "     body: ${body:0:300}"
    FAIL=$((FAIL+1))
  fi
}

# req METHOD URL [json_body] [auth_token]  → sets GLOBAL $RESP (body) and $CODE
req() {
  local method="$1" url="$2" json="${3:-}" tok="${4:-}"
  local args=(-s -o /tmp/resp.json -w "%{http_code}" -X "$method" "$url")
  [[ -n "$json" ]] && args+=(-H "Content-Type: application/json" -d "$json")
  [[ -n "$tok" ]] && args+=(-H "Authorization: Bearer $tok")
  CODE=$(curl "${args[@]}")
  RESP=$(cat /tmp/resp.json)
}

# jq-free JSON field extractor: jval <field>  (reads $RESP)
jval() { echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

EMAIL="val+$(date +%s)@example.com"

echo "── Health ──"
req GET "$GW/health"; check "gateway /health" 200 "$CODE" "$RESP"

echo "── Auth ──"
req POST "$GW/v1/auth/register" "{\"family_name\":\"Val Family\",\"admin_email\":\"$EMAIL\",\"admin_password\":\"SecurePass123!\",\"admin_full_name\":\"Val Admin\"}"
check "register family" 201 "$CODE" "$RESP"
FAMILY_ID=$(jval family_id)

req POST "$GW/v1/auth/login" "{\"email\":\"$EMAIL\",\"password\":\"SecurePass123!\"}"
check "login" 200 "$CODE" "$RESP"
TOKEN=$(jval access_token)
REFRESH=$(jval refresh_token)
[[ -n "$TOKEN" ]] && echo "  • got access token" || echo "  ❌ no access token"

echo "── Users (BE1: gateway proxy) ──"
req GET "$GW/v1/users/me" "" "$TOKEN"; check "GET /v1/users/me" 200 "$CODE" "$RESP"
req GET "$GW/v1/users/" "" "$TOKEN"; check "GET /v1/users/ (list)" 200 "$CODE" "$RESP"
req POST "$GW/v1/users/" "{\"email\":\"editor+$(date +%s)@example.com\",\"password\":\"SecurePass123!\",\"full_name\":\"Ed\",\"role\":\"editor\"}" "$TOKEN"
check "POST /v1/users/ (create)" 201 "$CODE" "$RESP"

echo "── Families (BE1: gateway proxy) ──"
req GET "$GW/v1/families/$FAMILY_ID" "" "$TOKEN"; check "GET /v1/families/{id}" 200 "$CODE" "$RESP"
req PATCH "$GW/v1/families/$FAMILY_ID" "{\"description\":\"Updated\"}" "$TOKEN"; check "PATCH /v1/families/{id}" 200 "$CODE" "$RESP"

echo "── Locations ──"
req POST "$GW/v1/location/rooms/" "{\"name\":\"Living Room\"}" "$TOKEN"; check "POST rooms" 201 "$CODE" "$RESP"
ROOM_ID=$(jval id)
req GET "$GW/v1/location/rooms/" "" "$TOKEN"; check "GET rooms" 200 "$CODE" "$RESP"
req POST "$GW/v1/location/bookcases/" "{\"room_id\":\"$ROOM_ID\",\"name\":\"Main Shelf\"}" "$TOKEN"; check "POST bookcases" 201 "$CODE" "$RESP"
BOOKCASE_ID=$(jval id)
req POST "$GW/v1/location/sections/" "{\"bookcase_id\":\"$BOOKCASE_ID\",\"section_index\":0,\"label\":\"A\"}" "$TOKEN"; check "POST sections" 201 "$CODE" "$RESP"
SECTION_ID=$(jval id)
req POST "$GW/v1/location/shelves/" "{\"section_id\":\"$SECTION_ID\",\"shelf_index\":0}" "$TOKEN"; check "POST shelves" 201 "$CODE" "$RESP"
SHELF_ID=$(jval id)

echo "── Records ──"
req POST "$GW/v1/catalog/bibliographic-records/" "{\"title\":\"Dune\",\"main_author\":\"Frank Herbert\",\"isbn\":\"9780441013593\"}" "$TOKEN"
check "POST records" 201 "$CODE" "$RESP"
RECORD_ID=$(jval id)
req GET "$GW/v1/catalog/bibliographic-records/?q=Dune" "" "$TOKEN"; check "GET records?q=" 200 "$CODE" "$RESP"

echo "── Books (BE3: writes use sub) ──"
req POST "$GW/v1/catalog/books/" "{\"bibliographic_record_id\":\"$RECORD_ID\",\"room_id\":\"$ROOM_ID\",\"reading_status\":\"to_read\"}" "$TOKEN"
check "POST books (add)" 201 "$CODE" "$RESP"
BOOK_ID=$(jval id)
req GET "$GW/v1/catalog/books/" "" "$TOKEN"; check "GET books" 200 "$CODE" "$RESP"
req GET "$GW/v1/catalog/books/$BOOK_ID" "" "$TOKEN"; check "GET book {id}" 200 "$CODE" "$RESP"
req PATCH "$GW/v1/catalog/books/$BOOK_ID" "{\"notes\":\"a gift\"}" "$TOKEN"; check "PATCH book metadata" 200 "$CODE" "$RESP"
req POST "$GW/v1/catalog/books/$BOOK_ID/reading-status?reading_status=reading" "" "$TOKEN"; check "POST reading-status" 200 "$CODE" "$RESP"
req POST "$GW/v1/catalog/books/$BOOK_ID/position?room_id=$ROOM_ID&bookcase_id=$BOOKCASE_ID&section_id=$SECTION_ID&shelf_id=$SHELF_ID&shelf_position=1" "" "$TOKEN"
check "POST position" 200 "$CODE" "$RESP"
req GET "$GW/v1/catalog/books/$BOOK_ID/history" "" "$TOKEN"; check "GET book history" 200 "$CODE" "$RESP"

echo "── Map / Ingestion / Export ──"
req GET "$GW/v1/catalog/map/bookcase/$BOOKCASE_ID" "" "$TOKEN"; check "GET bookcase map" 200 "$CODE" "$RESP"
req GET "$GW/v1/catalog/ingestion/isbn/9780441013593" "" "$TOKEN"; check "GET isbn lookup" 200 "$CODE" "$RESP"
req GET "$GW/v1/catalog/export/books.csv" "" "$TOKEN"; check "GET export csv" 200 "$CODE" "$RESP"
req GET "$GW/v1/catalog/export/books.json" "" "$TOKEN"; check "GET export json" 200 "$CODE" "$RESP"

echo "── Book delete ──"
req DELETE "$GW/v1/catalog/books/$BOOK_ID" "" "$TOKEN"; check "DELETE book" 204 "$CODE" "$RESP"

echo "── Token refresh & logout ──"
req POST "$GW/v1/auth/refresh" "{\"refresh_token\":\"$REFRESH\"}"; check "refresh" 200 "$CODE" "$RESP"
NEW_REFRESH=$(jval refresh_token)
req POST "$GW/v1/auth/logout" "{\"refresh_token\":\"$NEW_REFRESH\"}"; check "logout" 204 "$CODE" "$RESP"

echo "── Auth negatives ──"
req GET "$GW/v1/catalog/books/"; check "books without token → 401/403" "$( [[ $CODE == 401 || $CODE == 403 ]] && echo $CODE || echo 401 )" "$CODE" "$RESP"

echo ""
echo "════════════════════════════════"
echo "  PASS: $PASS    FAIL: $FAIL"
echo "════════════════════════════════"
[[ $FAIL -eq 0 ]]

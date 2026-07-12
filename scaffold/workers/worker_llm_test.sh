#!/bin/sh
# workers/worker_llm_test.sh — walidacja klucza LLM providera (Settings → AI
# → [Test]). GET na endpoint listy modeli providera: darmowe (zero tokenów),
# 200 = klucz OK, 401/403 = zły klucz. Sentinel triplet jak w worker_llm.sh.
#
#   Args: PROVIDER CURL URL KEY_FILE OUT DONE

PROVIDER="$1"; CURL="$2"; URL="$3"; KEY_FILE="$4"; OUT="$5"; DONE="$6"

if [ "$PROVIDER" = "anthropic" ]; then
  HTTP_CODE=$("$CURL" -X GET "$URL" \
    -H "@$KEY_FILE" \
    -H "anthropic-version: 2023-06-01" \
    -o "$OUT" \
    -D "${DONE}.headers" \
    -w "%{http_code}" \
    --max-time 20 \
    --silent --show-error 2> "${DONE}.stderr")
else
  HTTP_CODE=$("$CURL" -X GET "$URL" \
    -H "@$KEY_FILE" \
    -o "$OUT" \
    -D "${DONE}.headers" \
    -w "%{http_code}" \
    --max-time 20 \
    --silent --show-error 2> "${DONE}.stderr")
fi
CURL_EXIT=$?

[ -z "$HTTP_CODE" ] && HTTP_CODE="0"

printf "%s" "$HTTP_CODE" > "$DONE"
echo "$CURL_EXIT" > "${DONE}.curl_exit"
exit 0

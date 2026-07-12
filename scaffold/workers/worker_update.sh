#!/bin/sh
# workers/worker_update.sh — POSIX async wrapper dla update-check.
# GET GitHub Releases API (publiczny endpoint, ZERO API key — nie dotykamy
# .reasonate_key). GitHub wymaga User-Agent (403 bez niego).
# Sentinel triplet + .headers jak w worker_voice_op.sh.
#
#   Args: CURL URL OUT DONE

CURL="$1"; URL="$2"; OUT="$3"; DONE="$4"

HTTP_CODE=$("$CURL" -X GET "$URL" \
  -H "User-Agent: Reasonate" \
  -H "Accept: application/vnd.github+json" \
  -o "$OUT" \
  -D "${DONE}.headers" \
  -w "%{http_code}" \
  --max-time 15 \
  --silent --show-error 2> "${DONE}.stderr")
CURL_EXIT=$?

[ -z "$HTTP_CODE" ] && HTTP_CODE="0"

printf "%s" "$HTTP_CODE" > "$DONE"
echo "$CURL_EXIT" > "${DONE}.curl_exit"
exit 0

#!/bin/sh
# workers/worker_llm.sh — POSIX async wrapper dla LLM providers (NS-B Dubbing).
#
# Pattern mirror worker_voice_op.sh dialogue case (POST JSON body, JSON response).
# Wszystkie 4 providery używają tego samego protokołu transport (POST z JSON body
# + JSON response), różnią się TYLKO formatem headera auth — który jest w
# key_file ('x-api-key: ...' / 'Authorization: Bearer ...' / 'x-goog-api-key: ...').
# Anthropic dodaje extra header 'anthropic-version: 2023-06-01' inline w workerze.
#
# Args:
#   $1  PROVIDER  — anthropic | openai | gemini | deepseek | grok | mistral
#   $2  CURL      — absolute path do curla
#   $3  URL       — pełny endpoint URL (per-provider; Lua side builds)
#   $4  KEY_FILE  — chmod-600 plik z header line ('<name>: <value>')
#   $5  BODY      — request body file (JSON)
#   $6  OUT       — response body output file (JSON)
#   $7  DONE      — sentinel file (zawiera http_code po success/failure)
#
# Po zakończeniu zapisuje atomic sentinel z http_code. Lua side (llm.poll)
# sprawdza istnienie w defer loop. Body i out files cleanowane przez Lua side
# po poll completion (worker nie wie kiedy bezpiecznie).

PROVIDER="$1"
CURL="$2"
URL="$3"
KEY_FILE="$4"
BODY="$5"
OUT="$6"
DONE="$7"

# Anthropic wymaga extra header 'anthropic-version' obok x-api-key. Pozostali
# providery (OpenAI/Gemini/DeepSeek/Grok/Mistral) mają tylko jeden auth header.
case "$PROVIDER" in
  anthropic)
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      --data-binary "@$BODY" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 120 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  openai|gemini|deepseek|grok|mistral)
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      --data-binary "@$BODY" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 120 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  *)
    # Unknown provider — caller bug. Exit 1 → Lua side wyloguje stale handle.
    exit 1
    ;;
esac

[ -z "$HTTP_CODE" ] && HTTP_CODE="0"
printf "%s" "$HTTP_CODE" > "$DONE"
echo "$CURL_EXIT" > "${DONE}.curl_exit"
exit 0

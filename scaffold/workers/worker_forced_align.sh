#!/bin/sh
# workers/worker_forced_align.sh — POSIX async wrapper dla ElevenLabs
# Forced Alignment (NS-B Dubbing).
#
# POST /v1/forced-alignment (multipart). Fields:
#   file=@<audio_path>     — audio file (mp3/wav/flac, <1GB)
#   text=<@text_file>      — text do alignment, READ Z FILE (PM7+ fix)
# Response: JSON {characters[], words[{text,start,end,loss}], loss}
#
# PM7+ change: text is passed via FILE not inline argv. Curl `<@<path>` syntax
# reads file content into form field — bypasses ALL shell escaping issues
# (nested quotes, em dashes, smart quotes, backticks, $vars). Earlier inline
# `-F "text=$TEXT"` would hang for segments z nested double quotes
# (dialogue translation common case).
#
# Args:
#   $1  CURL      — absolute path do curla
#   $2  URL       — endpoint URL (https://api.elevenlabs.io/v1/forced-alignment)
#   $3  KEY_FILE  — chmod-600 plik z 'xi-api-key: <key>' header
#   $4  AUDIO     — ścieżka audio (multipart -F file=@...)
#   $5  TEXT_FILE — ścieżka pliku z tekstem (multipart -F text=<@...)
#   $6  OUT       — JSON response output file
#   $7  DONE      — sentinel file z http_code

CURL="$1"
URL="$2"
KEY_FILE="$3"
AUDIO="$4"
TEXT_FILE="$5"
OUT="$6"
DONE="$7"

HTTP_CODE=$("$CURL" -X POST "$URL" \
  -H "@$KEY_FILE" \
  -F "file=@\"$AUDIO\"" \
  -F "text=<$TEXT_FILE" \
  -o "$OUT" \
  -D "${DONE}.headers" \
  -w "%{http_code}" \
  --max-time 180 \
  --silent --show-error 2> "${DONE}.stderr")
CURL_EXIT=$?

[ -z "$HTTP_CODE" ] && HTTP_CODE="0"
printf "%s" "$HTTP_CODE" > "$DONE"
echo "$CURL_EXIT" > "${DONE}.curl_exit"
exit 0

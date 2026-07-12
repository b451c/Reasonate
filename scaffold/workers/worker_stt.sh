#!/bin/sh
# workers/worker_stt.sh — POSIX async wrapper dla ElevenLabs Scribe STT.
#
# Wywoływany przez reaper.ExecProcess(cmd, -1) jako fire-and-forget.
# Po zakończeniu pisze atomic sentinel z http_code — transcript_editor poll'uje
# istnienie sentinela w defer loop.
#
# Pozycyjne args:
#   $1  curl_path        — absolute path do curla
#   $2  url              — pełny URL /v1/speech-to-text
#   $3  key_file         — plik z headerem "xi-api-key: <KEY>" (curl -H @file)
#   $4  audio_path       — ścieżka source audio (-F file=@…)
#   $5  model_id         — np. "scribe_v2"
#   $6  language_code    — np. "pl" (pusty string = auto-detect)
#   $7  diarize          — "true" lub "false"
#   $8  timestamps_gran  — "word" / "phoneme" / "none"
#   $9  output_path      — gdzie zapisać JSON response
#   $10 done_sentinel    — sygnał końca; zawiera http_code w środku
#   $11 extras_file      — OPCJONALNY (M5-6): dodatkowe pola formularza,
#                          JEDNO per linia w formacie name=value (np.
#                          keyterms=Reasonate ×N, diarization_threshold=0.25).
#                          Lua side kasuje plik w poll.

CURL="$1"
URL="$2"
KEY_FILE="$3"
AUDIO="$4"
MODEL="$5"
LANG="$6"
DIARIZE="$7"
TIMES="$8"
OUT="$9"
DONE="${10}"
EXTRAS="${11}"

# M5-6: argumenty budowane dynamicznie (set --) — pola warunkowe
# (language_code) i extras dokładane tylko gdy obecne; koniec duplikacji.
set -- -X POST "$URL" \
  -H "@$KEY_FILE" \
  -F "file=@\"$AUDIO\"" \
  -F "model_id=$MODEL"
[ -n "$LANG" ] && set -- "$@" -F "language_code=$LANG"
set -- "$@" -F "diarize=$DIARIZE" -F "timestamps_granularity=$TIMES"
if [ -n "$EXTRAS" ] && [ -f "$EXTRAS" ]; then
  while IFS= read -r extra_line; do
    [ -n "$extra_line" ] && set -- "$@" -F "$extra_line"
  done < "$EXTRAS"
fi

HTTP_CODE=$("$CURL" "$@" \
  -o "$OUT" \
  -D "${DONE}.headers" \
  -w "%{http_code}" \
  --max-time 600 \
  --silent --show-error 2> "${DONE}.stderr")

CURL_EXIT=$?
[ -z "$HTTP_CODE" ] && HTTP_CODE="0"

printf "%s" "$HTTP_CODE" > "$DONE"
echo "$CURL_EXIT" > "${DONE}.curl_exit"
exit 0

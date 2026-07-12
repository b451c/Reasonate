#!/bin/sh
# workers/worker.sh — POSIX wrapper dla async curl call do ElevenLabs STS.
#
# Wywoływany przez reaper.ExecProcess(cmd, -1) jako fire-and-forget.
# Po zakończeniu pisze atomic sentinel file z http_code w środku — defer
# loop w job_manager.lua poll-uje istnienie tego pliku.
#
# Pozycyjne args:
#   $1  curl_path        — absolutna ścieżka do curla (z ExtState.curl_path)
#   $2  url              — pełny URL z output_format query
#   $3  key_file         — plik z headerem "xi-api-key: <KEY>" (curl -H @file)
#   $4  audio_path       — ścieżka source audio do wysłania
#   $5  model_id         — np. eleven_multilingual_sts_v2
#   $6  settings_json    — JSON {stability, similarity_boost, style, use_speaker_boost}
#   $7  seed             — int 0..4294967295
#   $8  remove_bg        — "true" / "false"
#   $9  output_path      — gdzie zapisać wynikowe mp3
#   $10 done_sentinel    — sygnał końca; zawiera http_code w środku
#
# UWAGA: ${10} w shellu wymaga braces (inaczej parser czyta jako $1 + "0").

CURL="$1"
URL="$2"
KEY_FILE="$3"
AUDIO="$4"
MODEL="$5"
SETTINGS_FILE="$6"   # 2026-07-12: PLIK z JSON-em (nie inline — PS -File zjada cudzysłowy)
SEED="$7"
REMBG="$8"
OUT="$9"
DONE="${10}"

# Curl: body do $OUT (-o), http_code na stdout (-w "%{http_code}").
# --max-time 420 (M6-8): 300 było ciasne dla itemów pod limitem STS 290 s
# (upload + processing + download > 300 przy wolnym łączu).
# --silent --show-error: cisza poza errorami; stderr → .stderr file
HTTP_CODE=$("$CURL" -X POST "$URL" \
  -H "@$KEY_FILE" \
  -F "audio=@\"$AUDIO\"" \
  -F "model_id=$MODEL" \
  -F "voice_settings=<$SETTINGS_FILE" \
  -F "seed=$SEED" \
  -F "remove_background_noise=$REMBG" \
  -o "$OUT.part" \
  -D "${DONE}.headers" \
  -w "%{http_code}" \
  --max-time 420 \
  --silent --show-error 2> "${DONE}.stderr")

CURL_EXIT=$?

# Pusty http_code (curl umarł zanim cokolwiek się stało) → traktuj jak 0
if [ -z "$HTTP_CODE" ]; then
  HTTP_CODE="0"
fi

# Settings file zużyty przez curl — sprzątamy (pisany per spawn przez Lua).
rm -f "$SETTINGS_FILE"

# M1-2 (audit 2026-07): $OUT = deterministyczny cache path (reasonate_cache/
# <key>.mp3). Curl pisze do $OUT.part; publish przez mv TYLKO po 2xx i PRZED
# sentinelem — przerwany download (kill REAPER mid-flight) nie zostawia
# częściowego pliku pod finalną ścieżką (serwowanego potem jako cache-hit).
# Non-2xx: .part zostaje z ciałem błędu — job_manager poll czyta i usuwa.
case "$HTTP_CODE" in
  2*) mv -f "$OUT.part" "$OUT" ;;
esac

# Atomic done sentinel — defer loop poll-uje istnienie tego pliku.
# Pisanie krótkiego stringa do lokalnego FS jest praktycznie atomic.
printf "%s" "$HTTP_CODE" > "$DONE"

# Diagnostyka opcjonalna
echo "$CURL_EXIT" > "${DONE}.curl_exit"

exit 0

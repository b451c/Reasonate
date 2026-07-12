#!/bin/sh
# workers/worker_voice_op.sh — POSIX async wrapper dla ElevenLabs voice management.
#
# Wywoływany przez reaper.ExecProcess(cmd, -1) jako fire-and-forget. Pisze
# atomic sentinel z http_code; voice_admin.poll(handle) sprawdza istnienie
# sentinela w defer loop Reasonate (~30 Hz).
#
# Pierwszy arg = op. Pozostałe per-op specyficzne.
#
#   train       CURL URL KEY_FILE NAME SAMPLE OUT DONE
#   delete      CURL URL KEY_FILE OUT DONE
#   rename      CURL URL KEY_FILE NAME OUT DONE
#   refresh     CURL URL KEY_FILE OUT DONE
#   quota       CURL URL KEY_FILE OUT DONE             # GET /v1/user/subscription
#   tts         CURL URL KEY_FILE BODY_JSON OUT DONE   # binary mp3 → OUT
#   tts_ts      CURL URL KEY_FILE BODY_JSON OUT DONE   # M5-1: with-timestamps, JSON response → OUT
#   dialogue    CURL URL KEY_FILE BODY_JSON OUT DONE   # NS-2c: multi-speaker JSON → binary mp3 OUT
#   shared_list CURL URL KEY_FILE OUT DONE             # GET /v1/shared-voices
#   add_shared  CURL URL KEY_FILE BODY_JSON OUT DONE   # POST add shared (JSON)
#   isolate     CURL URL KEY_FILE AUDIO OUT DONE       # multipart audio → binary mp3 OUT
#   similar_voices CURL URL KEY_FILE AUDIO OUT DONE SIMILARITY TOP_K  # NS-B: POST /v1/similar-voices
#   sfx         CURL URL KEY_FILE BODY_JSON OUT DONE   # NS-SFX: binary mp3 → OUT
#   music       CURL URL KEY_FILE BODY_JSON OUT DONE   # NS-MUSIC: POST /v1/music → binary mp3 OUT

OP="$1"

case "$OP" in
  train)
    CURL="$2"; URL="$3"; KEY_FILE="$4"; NAME="$5"; SAMPLE="$6"; OUT="$7"; DONE="$8"
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -F "name=$NAME" \
      -F "files=@\"$SAMPLE\"" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 180 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  delete)
    CURL="$2"; URL="$3"; KEY_FILE="$4"; OUT="$5"; DONE="$6"
    HTTP_CODE=$("$CURL" -X DELETE "$URL" \
      -H "@$KEY_FILE" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 30 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  rename)
    CURL="$2"; URL="$3"; KEY_FILE="$4"; NAME="$5"; OUT="$6"; DONE="$7"
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -F "name=$NAME" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 30 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  refresh)
    CURL="$2"; URL="$3"; KEY_FILE="$4"; OUT="$5"; DONE="$6"
    HTTP_CODE=$("$CURL" -X GET "$URL" \
      -H "@$KEY_FILE" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 60 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  quota)
    # GET /v1/user/subscription. Small JSON response z character_count /
    # character_limit / tier / next_character_count_reset_unix.
    CURL="$2"; URL="$3"; KEY_FILE="$4"; OUT="$5"; DONE="$6"
    HTTP_CODE=$("$CURL" -X GET "$URL" \
      -H "@$KEY_FILE" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 30 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  tts)
    # POST JSON body, response is binary mp3. Body file deletowany
    # przez Lua side po poll completion (worker nie wie kiedy bezpiecznie).
    # M1-2 (audit 2026-07): $OUT = deterministyczny cache path → curl pisze
    # do $OUT.part, mv na finalną ścieżkę TYLKO po 2xx (wspólny tail niżej).
    # Bez tego przerwany download zostawiał częściowy plik >1024 B, który
    # każdy przyszły run serwował jako cache-hit (zatruty cache na zawsze).
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
    ATOMIC_OUT=1
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      -H "Accept: audio/mpeg" \
      --data-binary "@$BODY" \
      -o "$OUT.part" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 120 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  tts_ts)
    # M5-1 (audit 2026-07): /v1/text-to-speech/{id}/with-timestamps —
    # response to JSON {audio_base64, alignment{...}}, NIE binarne mp3.
    # OUT = zwykły tmp path (Lua poll dekoduje base64 → cache atomic).
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data-binary "@$BODY" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 120 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  dialogue)
    # NS-2c: POST /v1/text-to-dialogue. JSON body z `inputs` array
    # ({text, voice_id}) + settings.stability + seed. Binary mp3 response.
    # Max-time wyższe niż tts (180s) bo multi-voice generation jest cięższa
    # po stronie ElevenLabs niż pojedynczy głos.
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
    ATOMIC_OUT=1
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      -H "Accept: audio/mpeg" \
      --data-binary "@$BODY" \
      -o "$OUT.part" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 180 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  sfx)
    # NS-SFX: POST /v1/sound-generation?output_format=… JSON body
    # {text, duration_seconds?, prompt_influence?, loop?, model_id}.
    # Binary mp3 response (-o $OUT = deterministic cache path, mirror tts).
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
    ATOMIC_OUT=1
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      -H "Accept: audio/mpeg" \
      --data-binary "@$BODY" \
      -o "$OUT.part" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 120 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  music)
    # NS-MUSIC: POST /v1/music?output_format=… JSON body
    # {prompt, music_length_ms?, force_instrumental?, model_id}.
    # Binary mp3 response, mirror sfx. --max-time 300: dłuższe utwory generują
    # się dłużej; MUSI zostać < async_op.HANDLE_STALE_TIMEOUT (630 od M6-8).
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
    ATOMIC_OUT=1
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      -H "Accept: audio/mpeg" \
      --data-binary "@$BODY" \
      -o "$OUT.part" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 300 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  shared_list)
    # GET /v1/shared-voices?<filters>. URL pre-built by Lua side z query params.
    CURL="$2"; URL="$3"; KEY_FILE="$4"; OUT="$5"; DONE="$6"
    HTTP_CODE=$("$CURL" -X GET "$URL" \
      -H "@$KEY_FILE" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 60 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  add_shared)
    # POST /v1/voices/add/{public_owner_id}/{voice_id}. JSON body z polem
    # new_name (Lua side pisze body file, worker tylko --data-binary).
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      --data-binary "@$BODY" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 60 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  isolate)
    # POST /v1/audio-isolation. Multipart audio file in, binary mp3 out.
    # Pattern identyczny do train (IVC) — single file field, binary response.
    # M1-2: $OUT = deterministyczny cache path (isolated_<hash>.mp3) → atomic.
    CURL="$2"; URL="$3"; KEY_FILE="$4"; AUDIO="$5"; OUT="$6"; DONE="$7"
    ATOMIC_OUT=1
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Accept: audio/mpeg" \
      -F "audio=@\"$AUDIO\"" \
      -o "$OUT.part" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 180 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  similar_voices)
    # NS-B Dubbing: POST /v1/similar-voices. Multipart audio reference in,
    # JSON response with candidates list. Pole nazywa się 'audio_file' (NIE
    # 'file') — verified per audit official docs 2026-05.
    # Optional form fields: similarity_threshold (0..2, lower=closer),
    # top_k (1..100). Passed jako positional args $7+ gdy non-empty.
    CURL="$2"; URL="$3"; KEY_FILE="$4"; AUDIO="$5"; OUT="$6"; DONE="$7"
    SIMILARITY="$8"; TOP_K="$9"
    # Build curl args conditionally — optional form fields tylko gdy non-empty.
    if [ -n "$SIMILARITY" ] && [ -n "$TOP_K" ]; then
      HTTP_CODE=$("$CURL" -X POST "$URL" \
        -H "@$KEY_FILE" \
        -F "audio_file=@\"$AUDIO\"" \
        -F "similarity_threshold=$SIMILARITY" \
        -F "top_k=$TOP_K" \
        -o "$OUT" -w "%{http_code}" --max-time 60 \
        --silent --show-error 2> "${DONE}.stderr")
    elif [ -n "$SIMILARITY" ]; then
      HTTP_CODE=$("$CURL" -X POST "$URL" \
        -H "@$KEY_FILE" \
        -F "audio_file=@\"$AUDIO\"" \
        -F "similarity_threshold=$SIMILARITY" \
        -o "$OUT" -w "%{http_code}" --max-time 60 \
        --silent --show-error 2> "${DONE}.stderr")
    elif [ -n "$TOP_K" ]; then
      HTTP_CODE=$("$CURL" -X POST "$URL" \
        -H "@$KEY_FILE" \
        -F "audio_file=@\"$AUDIO\"" \
        -F "top_k=$TOP_K" \
        -o "$OUT" -w "%{http_code}" --max-time 60 \
        --silent --show-error 2> "${DONE}.stderr")
    else
      HTTP_CODE=$("$CURL" -X POST "$URL" \
        -H "@$KEY_FILE" \
        -F "audio_file=@\"$AUDIO\"" \
        -o "$OUT" -w "%{http_code}" --max-time 60 \
        --silent --show-error 2> "${DONE}.stderr")
    fi
    CURL_EXIT=$?
    ;;
  voice_design_previews)
    # NS-B M4.1 Voice Design step 1: POST /v1/text-to-voice/create-previews.
    # JSON body z voice_description + text (sample) + model_id. Response:
    # { previews: [{ audio_base64, generated_voice_id, ... }, ...] }.
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
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
  voice_design_create)
    # NS-B M4.1 Voice Design step 2: POST /v1/text-to-voice/create-voice-from-preview.
    # JSON body z voice_name + voice_description + generated_voice_id +
    # played_not_selected_voice_ids? Response: { voice_id, name, ... }.
    CURL="$2"; URL="$3"; KEY_FILE="$4"; BODY="$5"; OUT="$6"; DONE="$7"
    HTTP_CODE=$("$CURL" -X POST "$URL" \
      -H "@$KEY_FILE" \
      -H "Content-Type: application/json" \
      --data-binary "@$BODY" \
      -o "$OUT" \
      -D "${DONE}.headers" \
      -w "%{http_code}" \
      --max-time 60 \
      --silent --show-error 2> "${DONE}.stderr")
    CURL_EXIT=$?
    ;;
  *)
    # Unknown op — caller bug. Nie znamy DONE path (varies per op),
    # więc nie możemy bezpiecznie zapisać sentinela. Exit 1 → Lua side
    # ostatecznie wyloguje stale handle (timeout user-side).
    exit 1
    ;;
esac

[ -z "$HTTP_CODE" ] && HTTP_CODE="0"

# M1-2 (audit 2026-07): atomic publish do cache. mv PRZED sentinelem —
# Lua poll widzi sentinel dopiero gdy finalny plik już istnieje. Non-2xx:
# .part zostaje (ciało błędu JSON) — Lua poll czyta i usuwa $OUT.part.
if [ -n "$ATOMIC_OUT" ]; then
  case "$HTTP_CODE" in
    2*) mv -f "$OUT.part" "$OUT" ;;
  esac
fi

printf "%s" "$HTTP_CODE" > "$DONE"
echo "$CURL_EXIT" > "${DONE}.curl_exit"
exit 0

# ElevenLabs — gotowe komendy curl

Copy-paste-able recepty. Zmienna `$KEY` to twoje xi-api-key.

## 1. Test API key (subscription info)

```bash
curl https://api.elevenlabs.io/v1/user/subscription \
  -H "xi-api-key: $KEY"
```

Response (przykład):
```json
{
  "tier": "creator",
  "character_count": 23456,
  "character_limit": 100000,
  "status": "active",
  "next_character_count_reset_unix": 1730000000
}
```

W kodzie agenta: użyj tego do testu po wpisaniu klucza w settings.

## 2. Lista voice'ów

```bash
curl https://api.elevenlabs.io/v2/voices \
  -H "xi-api-key: $KEY"
```

Z paginacją i filtrami:
```bash
curl "https://api.elevenlabs.io/v2/voices?page_size=100&search=narration&category=premade" \
  -H "xi-api-key: $KEY"
```

Pola które ci się przydają per voice:
- `voice_id` — używasz w STS
- `name` — pokaż w UI
- `category` — `premade` / `cloned` / `generated` / `professional`
- `labels` — `{accent, age, gender, descriptive, use_case}`
- `preview_url` — link do mp3 sample (5s)
- `description` — wolny tekst od creatora

## 3. Lista modeli (sprawdź `can_do_voice_conversion`)

```bash
curl https://api.elevenlabs.io/v1/models \
  -H "xi-api-key: $KEY"
```

Filtruj wynik po `can_do_voice_conversion === true` w kodzie. Dla nas:
- `eleven_multilingual_sts_v2` — **używaj tego dla polskiego**
- `eleven_english_sts_v2` — tylko EN

## 4. STS — najprostsze (default settings)

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-speech/JBFqnCBsd6RMkjVDRZzb" \
  -H "xi-api-key: $KEY" \
  -F "audio=@/path/to/source.wav" \
  -F "model_id=eleven_multilingual_sts_v2" \
  -o /path/to/output.mp3 \
  --max-time 300
```

## 5. STS — pełna kontrola

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-speech/JBFqnCBsd6RMkjVDRZzb?output_format=mp3_44100_192" \
  -H "xi-api-key: $KEY" \
  -F "audio=@/path/to/source.wav" \
  -F "model_id=eleven_multilingual_sts_v2" \
  -F 'voice_settings={"stability":0.5,"similarity_boost":0.75,"style":0.0,"use_speaker_boost":true}' \
  -F "seed=42" \
  -F "remove_background_noise=false" \
  -o /path/to/output.mp3 \
  -w "HTTP %{http_code} | %{time_total}s | %{size_download} bytes\n" \
  --max-time 300
```

`-w` pisze metadane do stdout — przydatne do logowania.

## 6. STS — voice_settings z pliku (uniknij escape JSON)

Zapisz JSON do pliku `settings.json`:
```json
{"stability":0.5,"similarity_boost":0.75,"style":0.0,"use_speaker_boost":true}
```

Wyślij:
```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-speech/$VOICE_ID" \
  -H "xi-api-key: $KEY" \
  -F "audio=@source.wav" \
  -F "model_id=eleven_multilingual_sts_v2" \
  -F "voice_settings=<settings.json" \
  -o output.mp3
```

Notatka: prefix `<` w `-F` mówi curl-owi: czytaj wartość pola z pliku.

## 7. STS — header z pliku (klucz API poza command line)

```bash
echo "xi-api-key: $KEY" > /tmp/auth.txt
chmod 600 /tmp/auth.txt

curl -X POST "https://api.elevenlabs.io/v1/speech-to-speech/$VOICE_ID" \
  -H @/tmp/auth.txt \
  -F "audio=@source.wav" \
  -F "model_id=eleven_multilingual_sts_v2" \
  -o output.mp3

rm /tmp/auth.txt  # cleanup
```

API key nie ląduje w `ps`/`history`. Polecam dla produkcji.

## 8. Dodatkowe formaty wyjścia

| Tier | output_format wartości |
|------|------------------------|
| Free | `mp3_44100_64`, `mp3_44100_128` |
| Starter | + `mp3_44100_192` |
| Creator | + `mp3_44100_192`, `pcm_*`, `ulaw_8000` |
| Pro+ | wszystkie powyższe + lossless |

Jeśli wyślesz format poza tierem dostaniesz `403 Forbidden`. Sprawdź subskrypcję na starcie.

## 9. Voice preview download

Każdy voice ma `preview_url` w response z `/v2/voices`. Pobierz:

```bash
curl -L -o /tmp/preview_$VOICE_ID.mp3 "$PREVIEW_URL"
```

Otwórz w default playerze:
- Linux: `xdg-open /tmp/preview.mp3`
- macOS: `open /tmp/preview.mp3`
- Windows: `start /tmp/preview.mp3` (z cmd) lub `Invoke-Item` (PowerShell)

W naszej wtyczce: w voice picker kliknięcie 🔊 download + open w default app.

## 10. Error responses do złapania

```json
// 401 invalid key
{"detail": {"status": "invalid_api_key", "message": "Invalid API key"}}

// 401 quota
{"detail": {"status": "quota_exceeded", "message": "..."}}

// 422 validation
{"detail": [{"loc": [...], "msg": "...", "type": "..."}]}

// 429 rate limit
{"detail": {"status": "too_many_requests", "message": "..."}}

// 403 voice access
{"detail": {"status": "voice_not_found", "message": "..."}}
```

W kodzie agenta — parsuj `detail.status` (jeśli `detail` jest obiektem, nie listą).
Dla 422 `detail` jest LISTĄ błędów walidacji.

## 11. Headers w response — co warto logować

```
character-cost: 1234         # ile kredytów wzięło
request-id: abc123...        # do supportu
xi-api-key-history-id: ...   # ID w panelu użytkownika
```

## 12. Curl quick health check (do diagnozy)

```bash
curl -v https://api.elevenlabs.io/v1/user/subscription \
  -H "xi-api-key: $KEY" 2>&1 | head -50
```

`-v` pokazuje TLS handshake, headers, body. Jak coś nie działa — odpal i wklej do logu.

## 13. Phase 11: Scribe v2 Speech-to-Text

```bash
curl https://api.elevenlabs.io/v1/speech-to-text \
  -H "xi-api-key: $KEY" \
  -F "model_id=scribe_v2" \
  -F "language_code=pl" \
  -F "diarize=false" \
  -F "timestamps_granularity=word" \
  -F "file=@/path/to/recording.wav" \
  -o transcript.json
```

Response (per-word timestamps):
```json
{
  "text": "Marzena nie ukrywała swojego zaskoczenia",
  "words": [
    { "text": "Marzena",   "start": 0.66, "end": 1.18, "logprob": -0.0001 },
    { "text": " ",         "start": 1.18, "end": 1.48, "logprob": -9.4e-06 },
    { "text": "nie",       "start": 1.48, "end": 1.60, "logprob": -9.4e-06 },
    ...
  ],
  "language_code": "pol",
  "language_probability": 1.0
}
```

**WAŻNE**: response zawiera **whitespace tokeny** (puste `text` lub spacje)
jako osobne entries między słowami. UI musi filtrować — patrz
`scaffold/modules/transcript.lua` `is_word_token()`.

Cost: ~$0.40/hour audio (Creator tier). Cache aggressively.

## 14. Phase 11: Eleven multilingual TTS (replacement phrase generation)

```bash
curl "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID?output_format=mp3_44100_128" \
  -H "xi-api-key: $KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: audio/mpeg" \
  --data-binary @body.json \
  -o phrase.mp3
```

`body.json`:
```json
{
  "text": "psa",
  "model_id": "eleven_multilingual_v2",
  "voice_settings": {
    "stability": 0.5,
    "similarity_boost": 0.75,
    "style": 0.0,
    "use_speaker_boost": true
  },
  "previous_text": "Poszedłem dzisiaj na spacer i spotkałem mojego ulubionego",
  "next_text": ""
}
```

**Kluczowe**:
- `text` = TYLKO co generujemy (np. zaznaczone słowo do podmiany)
- `previous_text` / `next_text` = soft context dla AI prosody continuity. **Model NIE generuje** tego tekstu — tylko `text`. Free up to ~5000 chars context.
- `model_id` = `eleven_multilingual_v2` (production stable, Polish supported). NIE `eleven_multilingual_v3` (alpha access only, error 400).
- Response = binary mp3.

Cost: ~$0.30/1k chars (Creator tier) — payable per `text` length, context jest free.

Error response (gdy 4xx/5xx) jest pisany do `-o` file jako JSON zamiast mp3. Sprawdź first bytes:
```bash
head -c 200 phrase.mp3
# Jeśli zaczyna się od "{" → to error JSON, nie mp3
```

## 15. Phase 11: IVC voice cloning

```bash
curl https://api.elevenlabs.io/v1/voices/add \
  -H "xi-api-key: $KEY" \
  -F "name=Reasonate_clone_<track_short>" \
  -F "description=Auto-cloned by Reasonate for dialog repair" \
  -F "files=@/path/to/30s_sample.wav" \
  -o voice.json
```

Response:
```json
{ "voice_id": "abc123def456" }
```

**Free na każdym tier**. 32+ languages (Polish supported). Quality moderate
ale wystarczająca dla repair flow. Free tier limit: 10 custom voices total.

## 16. Phase 11: Delete cloned voice (cleanup)

```bash
curl -X DELETE "https://api.elevenlabs.io/v1/voices/$VOICE_ID" \
  -H "xi-api-key: $KEY"
```

Reasonate: `voice_clone.delete_clone(voice_id)`. Future ROADMAP: UI w Settings
do delete unused clones.

## 17. Big Session #3: Rename voice (POST /v1/voices/{id}/edit)

```bash
curl -X POST "https://api.elevenlabs.io/v1/voices/$VOICE_ID/edit" \
  -H "xi-api-key: $KEY" \
  -F "name=Postać A"
```

Multipart form data, `name` field required. Można dodać `description`,
`labels`, `files` (sample dla IVC re-train) ale dla samego rename — wystarczy
`name`. Response: `{"status": "ok"}`.

Reasonate: `voice_clone.rename_voice(voice_id, new_name)` (sync) +
`voice_admin.spawn_rename(voice_id, new_name)` (async). Voice Manager używa
async path.

## 18. Big Session #4: List shared voices (GET /v1/shared-voices)

```bash
curl "https://api.elevenlabs.io/v1/shared-voices?\
page_size=30&page=0&search=narrator&\
gender=male&age=middle_aged&language=pl&\
category=professional&use_cases=narrative_story&\
featured=true&include_custom_rates=false&include_live_moderated=false" \
  -H "xi-api-key: $KEY"
```

Query params (all optional — empty omit):
- `page_size` (1-100, default 30) · `page` (0-based)
- `search` (full-text)
- `sort` — sort criteria
- `gender` (male/female/neutral)
- `age` (young/middle_aged/old)
- `language` (ISO code: pl/en/de/...)
- `accent` (locale: standard/american/italian/...)
- `category` (professional/famous/high_quality)
- `use_cases` (narrative_story/conversational/characters_animation/social_media/entertainment_tv/advertisement/informative_educational/video_games/meditation)
- `descriptives` (array — wolny tag)
- `featured` (bool)
- `include_custom_rates` (bool, default false)
- `include_live_moderated` (bool, default false)
- `reader_app_enabled` (bool)
- `owner_id` (filter by public_owner_id)

Response: `{voices: [...], has_more, total_count, last_sort_id}`. Per-voice:
`{public_owner_id, voice_id, name, category, gender, age, accent, language,
preview_url, description, free_users_allowed, rate, fiat_rate, ...}`.

Reasonate: `voice_admin.spawn_list_shared(filters)` async. UI: `gui/voice_library.lua`
8 filtrów + auto-apply + 300ms debounce search + Clear filters + pagination.

## 19. Big Session #4: Add shared voice (POST /v1/voices/add/{owner_id}/{voice_id})

```bash
curl -X POST "https://api.elevenlabs.io/v1/voices/add/$PUBLIC_OWNER_ID/$VOICE_ID" \
  -H "xi-api-key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"new_name": "Imported Voice"}'
```

JSON body, NOT multipart (różni się od `/v1/voices/add` IVC create). Required:
`new_name`. Response: `{"voice_id": "<new_voice_id_in_user_account>"}` —
voice_id zostaje TEN SAM jak shared, dodaje się tylko do user collection.

Reasonate: `voice_admin.spawn_add_shared(public_owner_id, voice_id, new_name)`
async. UI: voice_library.lua [Add] button. Po success: `voice_admin.spawn_refresh`
chain żeby user voices update się w voice_picker.

## 20. Big Session #4: Async TTS (POST /v1/text-to-speech/{voice_id})

Patrz #11/#12 dla sync. Async wersja — Lua side pisze body file:

```bash
echo '{"text":"Cześć","model_id":"eleven_multilingual_v2","voice_settings":{"stability":0.5,"similarity_boost":0.75}}' > /tmp/tts_body.json

curl -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID?output_format=mp3_44100_128" \
  -H "xi-api-key: $KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: audio/mpeg" \
  --data-binary "@/tmp/tts_body.json" \
  -o /tmp/output.mp3 \
  -w "%{http_code}" \
  --silent --show-error
```

Reasonate: `voice_admin.spawn_tts(opts)` z cache hit fast path (synthetic done
handle gdy mp3 already exists w cache). Worker: `worker_voice_op.sh tts ...`.
Body file deleted w `voice_admin.poll` po http_code resolved (success or error).

## 21. NS-C: Voice Isolator (POST /v1/audio-isolation)

Pre-process audio (usuwa szum/pogłos/muzykę) → czystszy głos do S2S / STT / IVC.

```bash
curl -X POST "https://api.elevenlabs.io/v1/audio-isolation" \
  -H "xi-api-key: $KEY" \
  -H "Accept: audio/mpeg" \
  -F "audio=@/path/to/noisy.wav" \
  -o /tmp/cleaned.mp3 \
  -w "%{http_code}" \
  --max-time 180 \
  --silent --show-error
```

**OpenAPI schema** (verified 2026-05-11 z `api.elevenlabs.io/openapi.json`):
- Endpoint: `POST /v1/audio-isolation`
- Content-Type: `multipart/form-data`
- Request body: `Body_Audio_Isolation_v1_audio_isolation_post` — jedno required pole
  `audio` (binary, format=binary, description "Audio file to isolate")
- Brak `model_id` / quality params — single model, single response format
- Response: `audio/mpeg` (binary mp3)
- Tier availability: dostępny "across plans" wg pricing comparison (Free/Starter/Creator/Pro)

**Stream variant** (`/v1/audio-isolation/stream`) — same schema, streamed audio. Nie używamy w Reasonate (full mp3 → splice/import wymaga complete file).

**History endpoints** (`/v1/audio-isolation/history`, `/v1/audio-isolation/history/{id}` DELETE) — dla browsing past isolations w ElevenLabs dashboard. Nie integrowane w Reasonate (cache lokalny).

Reasonate: `voice_isolator.spawn_isolate(audio_path)` z cache hit fast path (cache key = `hash(audio_path + '|' + file_size)`, cache path `reasonate_tmp/isolated_<8hex>.mp3`). Worker: `worker_voice_op.sh isolate $CURL $URL $KEY_FILE $AUDIO $OUT $DONE`. 4 punkty wpięcia: `job_manager` pre-isolate phase (Convert), `transcript_editor` pre-STT spawn (Repair), IVC training reuse cleaned audio (cache hit, free), `audition_strip` standalone "Clean voice" button.

**Cache key invalidation**: `cache.compute_key` honoruje `params.isolate_audio` (append `'|iso'` suffix) — toggle flag wymusza fresh API call (correct: różny input audio = różny AI output).

**Pricing**: nieujawnione publicznie w docs (2026-05-11). Verify w live test gdy budżet zaszacowany.

**Minimum duration constraint** (discovered live 2026-05-11, NOT in OpenAPI schema): Audio musi mieć **≥ 4.6 sekund**. Krótsze itemy zwracają:
```json
HTTP 400
{"detail": "Audio duration is 3.15 seconds, which is below the minimum of 4.6 seconds."}
```
Reasonate: `voice_isolator.M.MIN_DURATION_SECS = 4.6` + `spawn_isolate(path, {duration_secs=N})` pre-flight check. Sub-threshold items zwracają synthetic `status='skipped'` przed API call; caller fall-through-uje na raw audio. Zob. `KNOWN-ISSUES.md` "Voice Isolator wymaga MIN 4.6s audio".

## 22. NS-2c: Text-to-Dialogue (POST /v1/text-to-dialogue)

Multi-speaker dialogue generation w jednym requeście — natural conversational
prosody across N voices. v3-only.

```bash
curl -X POST "https://api.elevenlabs.io/v1/text-to-dialogue?output_format=mp3_44100_192" \
  -H "xi-api-key: $KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: audio/mpeg" \
  --data-binary @- <<'JSON' \
{
  "inputs": [
    { "text": "Witaj, jak się dzisiaj masz?", "voice_id": "JBFqnCBsd6RMkjVDRZzb" },
    { "text": "[laughs] Świetnie, dzięki!",   "voice_id": "9BWtsMINqrJLrRacOk9x" },
    { "text": "A co u Ciebie?",                "voice_id": "JBFqnCBsd6RMkjVDRZzb" }
  ],
  "model_id": "eleven_v3",
  "settings": { "stability": 0.5 },
  "seed": 12345
}
JSON
  -o /tmp/dialogue.mp3 \
  -w "%{http_code}" \
  --max-time 180 \
  --silent --show-error
```

**Schema** (verified 2026-05-11 PM5):
- Endpoint: `POST /v1/text-to-dialogue`
- model_id: tylko `eleven_v3` (jedyna obsługiwana wartość)
- `inputs[]`: required array, each {text, voice_id}. **Max 10 unique voice_ids**,
  **~2000 chars total** across `inputs[].text` (soft "for reliable generation";
  over → may truncate lub 422 validation error).
- `settings`: **per-request global** (NIE per-input). Pole: `stability` (float 0-1
  default 0.5). Other voice_settings (similarity_boost, style, speed, use_speaker_boost)
  NIE supported w dialogue endpoint.
- `seed`: int 0-2^32-1 dla deterministic sampling.
- `language_code`: optional ISO 639-1 force language; auto-detect if omitted.
- `apply_text_normalization`: enum `auto`/`on`/`off` (default `auto`).
- `pronunciation_dictionary_locators`: up to 3 dict refs (NS-2c skips dla MVP).

**`voice_id` vs `voice`**: oficjalna ElevenLabs API ref używa `voice_id`. fal.ai
wrapper używa `voice` (ich aliasing) — Reasonate używa canonical `voice_id`.

**Audio tags** (`[laughs]`, `[whispers]`, etc.) działają tak samo co w single v3 TTS
— natural-language instructions w square brackets inline tekstu.

Reasonate: `voice_admin.spawn_dialogue(opts)` → worker `worker_voice_op.sh dialogue
$CURL $URL $KEY_FILE $BODY $OUT $DONE`. Body file JSON encoded `{inputs, model_id,
settings, seed}`, deleted po poll resolve. Cache key `tts.dialogue_cache_key` =
hash(model_id + output_format + inputs sequence + settings + seed) — kolejność
inputs znacząca dla cache (zmiana porządku = inny cache slot, NIE deterministic
same audio).

## 23. NS-2d: Speech-to-Text z diarization (POST /v1/speech-to-text)

Standard Scribe v2 STT z włączonym speaker diarization — words[] response include
`speaker_id` per word ('speaker_0', 'speaker_1', ...).

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
  -H "xi-api-key: $KEY" \
  -F "model_id=scribe_v2" \
  -F "diarize=true" \
  -F "language_code=pl" \
  -F "timestamps_granularity=word" \
  -F "file=@/path/to/dialogue.mp3" \
  -o /tmp/transcript.json \
  -w "%{http_code}" \
  --max-time 120 \
  --silent --show-error
```

**Schema** (verified 2026-05-11 PM7):
- `diarize` (bool) — toggle speaker detection. Default false (regular transcript).
- `num_speakers` (int, optional) — max speaker hint. Default null → auto-detect.
  Max 32 speakers per docs.
- `detect_speaker_roles` (bool, optional) — 'agent'/'customer' labels zamiast
  'speaker_0/1/...'. Adds **+10% surcharge** na base transcription. Reasonate
  NIE używa (chronological mapping wystarcza).
- `use_multi_channel` (bool) — multi-channel input. **NIE kombinuj** z
  `detect_speaker_roles=true` (API rejects).
- File constraint: <3.0GB, min 100ms duration.

**Response z diarization**:
```json
{
  "text": "Hello, world. How are you?",
  "language_code": "en",
  "language_probability": 0.99,
  "words": [
    { "text": "Hello",  "start": 0.20, "end": 0.45, "speaker_id": "speaker_0" },
    { "text": "world",  "start": 0.50, "end": 0.85, "speaker_id": "speaker_0" },
    { "text": ".",      "start": 0.85, "end": 0.90, "speaker_id": "speaker_0" },
    { "text": "How",    "start": 1.50, "end": 1.70, "speaker_id": "speaker_1" },
    { "text": "are",    "start": 1.70, "end": 1.85, "speaker_id": "speaker_1" },
    { "text": "you?",   "start": 1.85, "end": 2.10, "speaker_id": "speaker_1" }
  ]
}
```

**No surcharge** for plain `diarize=true` (only `detect_speaker_roles` adds 10%).

Reasonate (NS-2d): `stt.spawn_diarize(audio_path, opts)` — async, file-based,
NIE cache (diarized response ma inną semantykę niż regular transcript →
`handle.skip_cache=true` flag w `poll_transcribe` bypassuje regular cache write).

NS-2d perform_dialogue_split:
1. Parse `words[]` → group consecutive same-speaker_id → speech regions.
2. Chronological mapping: diarized 'speaker_0' → first encountered unique
   voice_id w naszych inputs[], 'speaker_1' → second, etc.
3. Pre-clip overlapping regions (data overlap z diarization) do mid-overlap.
4. Insert N tracks po master, items per region z padding ±120ms half-gap
   clamped (no overlap między adjacent regions).

## 24. NS-MUSIC: Eleven Music (POST /v1/music)

Generacja muzyki z promptu. Binarne audio w odpowiedzi (mirror
/v1/sound-generation). Verified 2026-06-10 (docs api-reference/music/compose).

```bash
curl -X POST "https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128" \
  -H "xi-api-key: $KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: audio/mpeg" \
  --data-binary '{
    "prompt": "Tense investigative underscore, sparse piano, in D minor, 70 BPM",
    "model_id": "music_v1",
    "music_length_ms": 60000,
    "force_instrumental": true
  }' \
  -o music_out.mp3 \
  --max-time 300
```

Uwagi (verified w oficjalnych docs 2026-06-10):
- `prompt` XOR `composition_plan` — nie wolno obu naraz. `seed` tylko z
  composition_plan.
- `music_length_ms` 3000–600000 (3 s–10 min); pominięte = model decyduje.
- **Model w API tylko `music_v1`** — Music v2 jest web/UI-only ("coming
  soon" dla API). Nie zakładać dostępności v2.
- **Brak parametru loop** — i instrukcja "seamless loop" w prompcie jest
  ignorowana (live-tested). Muzyczne loopy ≤30 s → /v1/sound-generation
  z `loop: true` (oficjalnie wspiera muzyczny materiał).
- **Koszt ≠ stałe credits**: muzyka zużywa "minuty muzyki" planu (kurs per
  tier; SFX dla porównania = stałe 40 credits/s przy podanym duration).
- Bonus: `POST /v1/music/plan` (composition plan z promptu) = 0 kredytów,
  rate-limited; zwraca {positive/negative_global_styles, sections[]}.

Reasonate: `voice_admin.spawn_music(opts)` + worker case `music`
(--max-time 300 — MUSI być < async_op.HANDLE_STALE_TIMEOUT 330 s).


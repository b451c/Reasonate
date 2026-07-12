# Reasonate

AI audio production toolkit for [REAPER](https://www.reaper.fm), built on the
[ElevenLabs](https://elevenlabs.io) API. Replace voices in recorded dialogue,
generate speech and multi-speaker conversations, dub material into other
languages, fix single words in a recorded take, and design sound effects and
music beds — all without leaving your DAW, all non-destructively.

Written in Lua (ReaScript + [ReaImGui](https://github.com/cfillion/reaimgui)).
No external runtime: REAPER's built-in Lua 5.4, `curl`, and your API keys.

> **Status**: v1.0.0 — released via ReaPack and GitHub. Tested live on
> REAPER 7.71 / macOS arm64 (primary platform), REAPER 7.69 / Windows 11
> and REAPER / Ubuntu Linux (aarch64). Community feedback on other
> setups is very welcome.

**User guide**: full illustrated documentation (all five modes, settings
reference, costs, troubleshooting) at
**[b451c.github.io/Reasonate/guide](https://b451c.github.io/Reasonate/guide/)**
(source in [`docs/guide/`](docs/guide/index.html)).

## The five modes

**Voice Replacement** — swap the voice on recorded takes (speech-to-speech).
Per-track voice mapping, async batch conversion with caching and rate-limit
retry, multi-take variants, casts (role → voice presets), per-track recording
with pre-roll, optional Voice Isolator pre-clean. Output lands on a separate
"[AI]" track (folder child of the source); source items are never modified.

**TTS** — a small writing studio inside REAPER. Single-voice text-to-speech
with the full ElevenLabs model lineup (v3 audio-tags palette with search,
multilingual v2, turbo/flash), seeds, per-track defaults, voice presets — plus
a multi-speaker **dialogue** sub-mode (text-to-dialogue endpoint): named cast,
turn-by-turn lines, per-speaker voice settings, optional per-speaker track
split via diarization.

**Dubbing** — translate and re-voice source material in another language while
keeping the original timing. Pipeline: Scribe transcription (with speaker
diarization and silence-aware chunking for long files) → LLM translation with
editable context, glossary and style presets (bring your own key: Anthropic /
OpenAI / Gemini / DeepSeek / xAI Grok / Mistral) → per-speaker voices (clone from source, similar
voices, library pick, or voice design) → TTS with timing fit → forced-alignment
splice onto per-speaker dub tracks. Per-segment regen, variants, inspector,
cost tracking.

**Repair** — Descript-style word-level editing of recorded speech. Click words
in the transcript, type the replacement, get a seamless splice: forced
alignment for cut points, acoustic onset scanning, word-aligned loudness
match, optional tempo match with élastique stretch. Replace / insert / delete.

**SFX & Music** — sound effects (`/v1/sound-generation`) and instrumental
music beds (`/v1/music`) from a text prompt, or proposed by an LLM straight
from your **scene**: select an item, the transcript is analyzed and you get
editable, time-anchored candidates (effects plus an optional music bed) that
insert exactly where the event happens. Results are grouped per generation
with per-take preview, dedicated "SFX" and "Music" tracks, and an AI
"New idea" rephrase per candidate.

Everything is non-destructive: source items are never altered (only metadata
and colors), every insert/convert is wrapped in an undo block, and all
generated audio is cached deterministically (repeating an identical request
is free).

## Requirements

- REAPER ≥ 7.0 (tested on 7.71, macOS arm64)
- [ReaImGui](https://github.com/cfillion/reaimgui) ≥ 0.10.0.4 (via ReaPack)
- `curl` ≥ 7.76 (auto-detected; macOS/Linux system curl is fine)
- [SWS extension](https://www.sws-extension.org) - required for in-app audio
  preview (without it previews open in your system player)
- An [ElevenLabs](https://elevenlabs.io) API key (paid tier recommended;
  Creator covers all features including dubbing and music)
- Optional: an LLM API key (Anthropic / OpenAI / Gemini / DeepSeek / xAI Grok / Mistral) for
  Dubbing translation, TTS Enhance and SFX scene analysis

## Installation

**ReaPack (recommended):**

1. Install REAPER, [ReaPack](https://reapack.com), ReaImGui ≥ 0.10
   (Extensions → ReaPack → Browse packages → "ReaImGui") and the
   [SWS extension](https://www.sws-extension.org).
2. Extensions → ReaPack → Import repositories… → paste:
   `https://raw.githubusercontent.com/b451c/Reasonate/main/index.xml`
3. Browse packages → search "Reasonate" → Install → Apply.
4. Run "Script: reasonate.lua" from the Action List → Settings → paste your
   ElevenLabs API key → Test → Save & fetch voices.

**Manual install:** copy the contents of `scaffold/` to
`<REAPER resource path>/Scripts/Reasonate/`, then Action List →
"New action…" → "Load ReaScript…" → pick `reasonate.lua`. Optionally run
`_phase0_check.lua` once to validate the environment.

## Costs & privacy

Reasonate is a client for third-party AI APIs. Audio and text you process are
sent to ElevenLabs (and, for translation/scene analysis, to the LLM provider
you configure). API usage is billed to **your** accounts by those providers —
character/credit costs are previewed in the UI where possible, and the
deterministic cache makes repeated identical requests free. API keys are
stored in REAPER's ExtState and passed to `curl` via a `chmod 600` header
file — never on a command line and never inside project files.

## Repository structure

```
voice-changer-reaper/
├── LICENSE                  ← MIT (+ third-party notices)
├── README.md                ← this file
├── scaffold/                ← the plugin (copy this into REAPER Scripts)
│   ├── reasonate.lua        ← entry point
│   ├── modules/             ← core (api, cache, async, state, splicers, …)
│   │   ├── modes/           ← voice_replacement / tts / dubbing / repair / sfx
│   │   ├── gui/             ← ImGui views (30 files)
│   │   ├── llm/             ← anthropic / openai / gemini / deepseek / grok / mistral adapters
│   │   └── lib/json.lua     ← vendored rxi/json (MIT)
│   ├── workers/             ← curl wrappers, POSIX .sh + Windows .ps1 (async sentinel pattern)
│   ├── assets/fonts/        ← Inter Regular/SemiBold (SIL OFL 1.1, see OFL.txt)
│   ├── _phase0_check.lua    ← environment validator
│   └── reacast.lua          ← legacy entry-point shim (pre-rename installs)
├── scripts/                 ← quality gate: check.sh (syntax + luacheck +
│                              UI-English scan + headless tests) + git hook
├── tests/                   ← headless unit tests (lua5.4 tests/run.lua)
├── docs/guide/              ← the illustrated user guide (GitHub Pages)
└── reference/               ← API cheat-sheets (ElevenLabs curl, ReaImGui)
```

## Development

- Quality gate: `sh scripts/check.sh` — four gates (Lua syntax, luacheck with
  undefined-globals as errors, English-only UI string scan, headless unit
  tests). Install it as a pre-commit hook with `sh scripts/install_hooks.sh`.
- Tests run without REAPER: `lua5.4 tests/run.lua` (a minimal REAPER stub is
  vendored in `tests/reaper_stub.lua`).
- Code and all UI strings are English; some internal notes in `reference/`
  are in Polish.
- Known limitations and troubleshooting live in the
  [user guide](docs/guide/troubleshooting.html).

## License

[MIT](LICENSE) © 2026 Bartosz Sroczynski (falami.studio / b4s1c).

Bundled third-party components: [Inter](https://github.com/rsms/inter) font
(SIL OFL 1.1 — `scaffold/assets/fonts/OFL.txt`),
[rxi/json.lua](https://github.com/rxi/json.lua) (MIT). Reasonate is an
independent project, not affiliated with or endorsed by Cockos (REAPER) or
ElevenLabs.

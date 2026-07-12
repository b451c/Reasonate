-- modules/tts.lua
-- Phase 11 (Dialog Repair) — Eleven multilingual TTS endpoint.
--
-- POST /v1/text-to-speech/{voice_id}?output_format=mp3_44100_128
-- Body JSON: { text, model_id, voice_settings, previous_text, next_text }
-- Response: binary mp3.
--
-- Sync call (~3-10s typical dla short phrase). Cache mp3 deterministycznie
-- po hashu (voice_id + model_id + text + prev + next + settings) — re-edit
-- z tym samym tekstem trafia w cache, instant.
--
-- Niezmiennik #1 (API key NIGDY w shell command line) — klucz idzie do curla
-- przez `-H @keyfile` (api.ensure_key_file pisze chmod-600 plik raz per
-- session). NIGDY argv.

local api  = require 'modules.api'
local cfg  = require 'modules.config'
local util = require 'modules.util'
local json = require 'modules.lib.json'

local M = {}

-- ElevenLabs production TTS model ID. Spec wcześniej zakładał 'v3' (z research
-- ElevenLabs landing page) ale real API endpoint expects 'eleven_multilingual_v2'
-- jako stable production. v3 jest na razie alpha. v2 supports 32+ languages
-- including Polish na każdym tier.
local DEFAULT_MODEL = 'eleven_multilingual_v2'
local DEFAULT_FORMAT = 'mp3_44100_128'

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

----------------------------------------------------------------------------
-- Cache: trzymamy generated phrase mp3 w reasonate_tmp/tts_<8hex>.mp3.
-- Re-edit tej samej frazy z tym samym voice/settings → cache hit, instant.
----------------------------------------------------------------------------
function M.cache_key(opts)
  -- seed dołączony do klucza (NS-2b TTS mode regen): różne seedy = różne
  -- cache slots = różne wygenerowane audio dla tego samego tekstu. Bez seeda
  -- (nil / 0) zachowanie identyczne jak pre-NS-2b (backward-compat dla
  -- Phase 11 Repair flow, który nie używa seed).
  -- M1-1 (audit 2026-07): voice_settings kanonicznie (nie json.encode —
  -- niedeterministyczna kolejność pól per proces w Lua 5.4) + 'v2|' =
  -- jednorazowa inwalidacja. M4-6: language_code w kluczu (ten sam tekst
  -- z wymuszonym innym językiem = inne audio).
  local s = string.format(
    'tts|v2|%s|%s|%s|%s|%s|%s|%s|%s|%s',
    opts.voice_id     or '',
    opts.model_id     or DEFAULT_MODEL,
    opts.output_format or DEFAULT_FORMAT,
    opts.text         or '',
    opts.prev_text    or '',
    opts.next_text    or '',
    util.canon_voice_settings(opts.voice_settings),
    tostring(opts.seed or 0),
    opts.language_code or '')
  return string.format('%08x', util.simple_hash(s))
end

function M.cache_path_for(opts)
  util.mkdir_p(tmp_dir())
  return tmp_dir() .. path_sep() .. 'tts_' .. M.cache_key(opts) .. '.mp3'
end

----------------------------------------------------------------------------
-- NS-2c: cache key dla /v1/text-to-dialogue. Hashujemy całą sekwencję inputs
-- (kolejność znacząca — naturalna rozmowa zależy od kolejności turns) +
-- settings + seed + output_format. Dwa identyczne wywołania → ten sam mp3.
----------------------------------------------------------------------------
function M.dialogue_cache_key(opts)
  local inputs_repr = {}
  if type(opts.inputs) == 'table' then
    for i, it in ipairs(opts.inputs) do
      inputs_repr[i] = (it.voice_id or '') .. '|' .. (it.text or '')
    end
  end
  -- M1-1 (audit 2026-07): settings kanonicznie zamiast json.encode
  -- (deterministyczny klucz między restartami) + 'v2|' inwalidacja.
  local s = string.format(
    'dialogue|v2|%s|%s|%s|%s|%s',
    opts.model_id      or 'eleven_v3',
    opts.output_format or 'mp3_44100_128',
    table.concat(inputs_repr, '\x1f'),  -- unit separator unlikely w tekście
    util.canon_voice_settings(opts.settings),
    tostring(opts.seed or 0))
  return string.format('%08x', util.simple_hash(s))
end

function M.dialogue_cache_path_for(opts)
  util.mkdir_p(tmp_dir())
  return tmp_dir() .. path_sep() .. 'dialogue_' .. M.dialogue_cache_key(opts) .. '.mp3'
end

-- M.generate_phrase (sync, blokujace GUI 3-15 s) USUNIETE M7
-- (2026-07-11, user OK) - zero callerow od async voice_admin.spawn_tts
-- (Big Session #3). cache_key/cache_path_for/dialogue_* ZOSTAJA -
-- uzywa ich spawn_tts/spawn_dialogue. Git history zachowuje.

return M

-- modules/cast_registry.lua
-- W2 M3 (PHASE-W2 §4): Project Cast Registry — wspólny katalog postaci per
-- projekt REAPER: label + opis (z glossary characters) + głosy per język.
-- Łamie silosy między trybami: Dubbing zasila (M3.1, sync przy flushu stanu),
-- TTS dialog czyta ("Cast from project", M3.3). Repair/VR adaptery = M3.2/M3.4
-- (następne sesje).
--
-- Zasada (plan §4): registry PROPONUJE, nigdy nie nadpisuje cicho — konsumenci
-- aplikują wyłącznie przy jawnych akcjach usera (klik + wybór Replace/Merge).
--
-- Persystencja: mirror dubbing_state 2-tier — ProjExtState pointer
-- 'Reasonate.cast_registry' { registry_guid, version } + plik JSON
-- <resource>/Scripts/Reasonate/cast_registries/<guid>.json. Bez debounce
-- (zapisy tylko przy zdarzeniach: flush dubbingu / jawna akcja konsumenta).
--
-- Klucz łączący materiał (M3 decyzja 2026-06-11, z testem): geometry_key
-- BEZ języka — hash(source_path|item_offs|item_len|playrate). Język to
-- parametr STT (Repair dokleja '|lang=' do SWOJEGO cache key), nie tożsamość
-- materiału: transkrypcje PL i EN tego samego itemu muszą linkować te same
-- postaci. Konsument linków (Match cast) = M3.2.
--
-- Character schema:
--   { id, label, description?,                       -- opis z glossary
--     voices = { [lang or 'default'] = { voice_id, voice_name } },
--     ivc_clone_id?,                                  -- M3.2 (Repair)
--     links = { track_guids = {}, item_diarize = {} },-- M3.2 (Match cast)
--     updated_at, source_mode }
--
-- Czyste core (normalize/upsert/pick/geometry_key) headless-tested.

local util = require 'modules.util'
local json = require 'modules.lib.json'

local M = {}

M.PROJ_EXT_SECTION = 'Reasonate'
M.PROJ_EXT_KEY     = 'cast_registry'
M.STATE_VERSION    = 1

----------------------------------------------------------------------------
-- Pure core
----------------------------------------------------------------------------

-- Fold case dla matchowania labeli: ASCII lower + polskie diakrytyki
-- (Lua :lower() nie tyka multi-byte UTF-8). Labels są krótkie i user-typed
-- ('Anna' vs 'anna' vs 'ANNA' = ta sama postać).
local PL_FOLD = {
  ['Ą'] = 'ą', ['Ć'] = 'ć', ['Ę'] = 'ę', ['Ł'] = 'ł', ['Ń'] = 'ń',
  ['Ó'] = 'ó', ['Ś'] = 'ś', ['Ź'] = 'ź', ['Ż'] = 'ż',
}

function M.normalize_label(label)
  if type(label) ~= 'string' then return '' end
  local out = label:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' '):lower()
  out = out:gsub('[\xC0-\xFF][\x80-\xBF]*', function(ch)
    return PL_FOLD[ch] or ch
  end)
  return out
end

-- Kanoniczny klucz materiału — BEZ języka (patrz nagłówek). Format seedu
-- celowo identyczny ze stt.cache_key(path, render_info bez .language):
-- geometry-stable diarize cache dubbingu linkuje się 1:1.
function M.geometry_key(source_path, item_offs, item_length, playrate)
  if not source_path or source_path == '' then return nil end
  local seed = ('%s|%.6f|%.6f|%.6f'):format(
    source_path,
    tonumber(item_offs)   or 0,
    tonumber(item_length) or 0,
    tonumber(playrate)    or 1)
  return string.format('%08x', util.simple_hash(seed))
end

function M.new_registry(guid)
  return { version = M.STATE_VERSION, registry_guid = guid, characters = {} }
end

function M.characters(reg)
  return (reg and reg.characters) or {}
end

function M.is_empty(reg)
  return not reg or not reg.characters or #reg.characters == 0
end

function M.find_character(reg, label)
  local key = M.normalize_label(label)
  if key == '' then return nil end
  for _, ch in ipairs(M.characters(reg)) do
    if M.normalize_label(ch.label) == key then return ch end
  end
  return nil
end

-- Upsert by normalized label. Merge: voices per-lang overwrite (tylko
-- non-empty voice_id), description nadpisywany tylko gdy podany non-empty
-- (puste pole w producencie nie kasuje opisu z innego trybu). opts.now
-- wstrzykiwany w testach (default os.time).
function M.upsert_character(reg, fields, opts)
  if not reg or type(fields) ~= 'table' then return nil end
  local label = fields.label
  if type(label) ~= 'string' or M.normalize_label(label) == '' then return nil end
  reg.characters = reg.characters or {}
  local ch = M.find_character(reg, label)
  if not ch then
    ch = {
      id     = 'char_' .. string.format('%08x',
                 util.simple_hash(M.normalize_label(label))),
      label  = label,
      voices = {},
      links  = { track_guids = {}, item_diarize = {} },
    }
    reg.characters[#reg.characters + 1] = ch
  end
  ch.voices = ch.voices or {}
  if type(fields.voices) == 'table' then
    for lang, v in pairs(fields.voices) do
      if type(v) == 'table' and type(v.voice_id) == 'string' and v.voice_id ~= '' then
        ch.voices[lang] = { voice_id = v.voice_id, voice_name = v.voice_name or '' }
      end
    end
  end
  if type(fields.description) == 'string' and fields.description ~= '' then
    ch.description = fields.description
  end
  if type(fields.ivc_clone_id) == 'string' and fields.ivc_clone_id ~= '' then
    ch.ivc_clone_id = fields.ivc_clone_id
  end
  if type(fields.source_mode) == 'string' then ch.source_mode = fields.source_mode end
  ch.updated_at = (opts and opts.now) or os.time()
  return ch
end

----------------------------------------------------------------------------
-- M3 cz.2: linki materiał ↔ postać.
-- ch.links.item_diarize = { [geom_key] = { [scribe_id] = true } } — SET
-- sidów per materiał (diarization potrafi rozbić jedną osobę na 2 sidy;
-- plan §4 zapisywał scalar — set jest nadzbiorem, scalar tolerowany przy
-- odczycie). Para (geom_key, scribe_id) jest UNIKALNA w całym rejestrze —
-- link przenosi ją między postaciami (ostatni gest usera wygrywa).
----------------------------------------------------------------------------

local function link_set(ch, geom_key)
  local map = ch and ch.links and ch.links.item_diarize
  return map and map[geom_key]
end

function M.find_by_link(reg, geom_key, scribe_id)
  if not geom_key or not scribe_id then return nil end
  for _, ch in ipairs(M.characters(reg)) do
    local set = link_set(ch, geom_key)
    if type(set) == 'table' and set[scribe_id] then return ch end
    if set == scribe_id then return ch end   -- legacy scalar shape
  end
  return nil
end

-- Wszystkie postaci zlinkowane z materiałem: { [scribe_id] = character }.
function M.characters_for_material(reg, geom_key)
  local out = {}
  if not geom_key then return out end
  for _, ch in ipairs(M.characters(reg)) do
    local set = link_set(ch, geom_key)
    if type(set) == 'table' then
      for sid in pairs(set) do out[sid] = ch end
    elseif type(set) == 'string' then
      out[set] = ch
    end
  end
  return out
end

function M.link_item_speaker(reg, ch, geom_key, scribe_id, opts)
  if not reg or not ch then return false end
  if type(geom_key) ~= 'string' or geom_key == '' then return false end
  if type(scribe_id) ~= 'string' or scribe_id == '' then return false end
  -- Uniqueness: zdejmij parę z każdej INNEJ postaci.
  for _, other in ipairs(M.characters(reg)) do
    if other ~= ch then
      local set = link_set(other, geom_key)
      if type(set) == 'table' then
        set[scribe_id] = nil
        if next(set) == nil then other.links.item_diarize[geom_key] = nil end
      elseif set == scribe_id then
        other.links.item_diarize[geom_key] = nil
      end
    end
  end
  ch.links = ch.links or { track_guids = {}, item_diarize = {} }
  ch.links.item_diarize = ch.links.item_diarize or {}
  local set = ch.links.item_diarize[geom_key]
  if type(set) ~= 'table' then
    -- brak / legacy scalar → świeży set (scalar wchodzi do setu)
    set = type(ch.links.item_diarize[geom_key]) == 'string'
      and { [ch.links.item_diarize[geom_key]] = true } or {}
    ch.links.item_diarize[geom_key] = set
  end
  set[scribe_id] = true
  ch.updated_at = (opts and opts.now) or os.time()
  return true
end

-- Marker obecności postaci w materiale (links.materials[geom_key]=true) —
-- BEZ sidów: numeracja mówców pipeline'u dubbingu jest chunk-lokalna i NIE
-- pokrywa się z diarize itemu w Repair; linkowanie jej sidów do
-- item_diarize zasiałoby błędne etykiety. Konsument: Match cast (priorytet
-- postaci znanych z tego materiału).
function M.link_material(reg, ch, geom_key, opts)
  if not reg or not ch then return false end
  if type(geom_key) ~= 'string' or geom_key == '' then return false end
  ch.links = ch.links or { track_guids = {}, item_diarize = {} }
  ch.links.materials = ch.links.materials or {}
  if ch.links.materials[geom_key] then return false end   -- no-op = no dirty
  ch.links.materials[geom_key] = true
  ch.updated_at = (opts and opts.now) or os.time()
  return true
end

function M.is_material_linked(ch, geom_key)
  if not ch or not geom_key then return false end
  local m = ch.links and ch.links.materials
  if m and m[geom_key] then return true end
  local set = ch.links and ch.links.item_diarize
            and ch.links.item_diarize[geom_key]
  return set ~= nil
end

function M.unlink_item_speaker(reg, geom_key, scribe_id)
  local ch = M.find_by_link(reg, geom_key, scribe_id)
  if not ch then return false end
  local set = link_set(ch, geom_key)
  if type(set) == 'table' then
    set[scribe_id] = nil
    if next(set) == nil then ch.links.item_diarize[geom_key] = nil end
  else
    ch.links.item_diarize[geom_key] = nil
  end
  return true
end

-- Rename z cleanupem (M3 cz.2): registry jest upsert-only per label, więc
-- rename musi RELABELOWAĆ istniejącą postać zamiast płodzić duplikat pod
-- nowym labelem. Kolizja z inną postacią = merge (gest znaczy "to ta sama
-- osoba"): zwycięża postać już istniejąca pod nowym labelem; jej pola
-- wygrywają, puste uzupełniane, voices per-lang dokładane tylko brakujące,
-- linki przenoszone w całości (uniqueness par zachowana). Zwraca ocalałą
-- postać lub nil (pusty label = no-op).
function M.rename_character(reg, ch, new_label, opts)
  if not reg or not ch or type(new_label) ~= 'string' then return nil end
  local key = M.normalize_label(new_label)
  if key == '' then return nil end
  local now = (opts and opts.now) or os.time()
  if M.normalize_label(ch.label) == key then
    ch.label = new_label   -- wariant pisowni (case/diakrytyki)
    ch.updated_at = now
    return ch
  end
  local other = M.find_character(reg, new_label)
  if not other or other == ch then
    ch.label = new_label
    ch.updated_at = now
    return ch
  end
  -- Merge ch → other.
  other.voices = other.voices or {}
  if type(ch.voices) == 'table' then
    for lang, v in pairs(ch.voices) do
      if not other.voices[lang] then other.voices[lang] = v end
    end
  end
  if (other.description == nil or other.description == '')
     and type(ch.description) == 'string' and ch.description ~= '' then
    other.description = ch.description
  end
  if (other.ivc_clone_id == nil or other.ivc_clone_id == '')
     and type(ch.ivc_clone_id) == 'string' and ch.ivc_clone_id ~= '' then
    other.ivc_clone_id = ch.ivc_clone_id
  end
  local src_links = ch.links or {}
  if type(src_links.track_guids) == 'table' then
    other.links = other.links or { track_guids = {}, item_diarize = {} }
    other.links.track_guids = other.links.track_guids or {}
    local seen = {}
    for _, g in ipairs(other.links.track_guids) do seen[g] = true end
    for _, g in ipairs(src_links.track_guids) do
      if not seen[g] then
        other.links.track_guids[#other.links.track_guids + 1] = g
        seen[g] = true
      end
    end
  end
  if type(src_links.item_diarize) == 'table' then
    -- Snapshot par przed przenoszeniem — link_item_speaker mutuje mapy.
    local pairs_to_move = {}
    for gk, set in pairs(src_links.item_diarize) do
      if type(set) == 'table' then
        for sid in pairs(set) do
          pairs_to_move[#pairs_to_move + 1] = { gk, sid }
        end
      elseif type(set) == 'string' then
        pairs_to_move[#pairs_to_move + 1] = { gk, set }
      end
    end
    for _, p in ipairs(pairs_to_move) do
      M.link_item_speaker(reg, other, p[1], p[2], { now = now })
    end
  end
  for i, c in ipairs(reg.characters) do
    if c == ch then table.remove(reg.characters, i) break end
  end
  other.updated_at = now
  return other
end

-- Głos dla konsumenta bez kontekstu języka (TTS dialog): preferred_lang →
-- 'default' → pierwszy język alfabetycznie (stabilny wybór).
function M.pick_voice(ch, preferred_lang)
  if not ch or type(ch.voices) ~= 'table' then return nil end
  local function take(v) return v and v.voice_id, v and v.voice_name end
  if preferred_lang and ch.voices[preferred_lang] then
    return take(ch.voices[preferred_lang])
  end
  if ch.voices.default then return take(ch.voices.default) end
  local langs = {}
  for lang in pairs(ch.voices) do langs[#langs + 1] = lang end
  table.sort(langs)
  if langs[1] then return take(ch.voices[langs[1]]) end
  return nil
end

----------------------------------------------------------------------------
-- Persistence (mirror dubbing_state 2-tier)
----------------------------------------------------------------------------
local function path_sep() return util.path_sep() end

-- T5a (UX-POLISH, user decision 2026-07-11): JSON rejestru żyje OBOK .rpp
-- (<project_dir>/reasonate_projects/cast_registries/) i podróżuje z
-- projektem; unsaved → fallback resource path. Odczyt: primary → fallback
-- (lazy migracja — pierwszy zapis ląduje w primary, backup zostaje).
local SUBDIR = 'cast_registries'

local function registry_file_for_write(guid)
  local primary = util.project_state_dirs(SUBDIR)
  util.mkdir_p(primary)
  return primary .. path_sep() .. guid .. '.json'
end

local function find_registry_file(guid)
  local primary, fallback = util.project_state_dirs(SUBDIR)
  local p = primary .. path_sep() .. guid .. '.json'
  if util.file_exists(p) then return p end
  if fallback then
    local f = fallback .. path_sep() .. guid .. '.json'
    if util.file_exists(f) then return f end
  end
  return nil
end

local function proj_handle()
  return reaper.EnumProjects(-1, '')
end

local function read_pointer()
  local _, raw = reaper.GetProjExtState(proj_handle(), M.PROJ_EXT_SECTION, M.PROJ_EXT_KEY)
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

local function write_pointer(meta)
  local ok, encoded = pcall(json.encode, meta or {})
  if ok then
    reaper.SetProjExtState(proj_handle(), M.PROJ_EXT_SECTION, M.PROJ_EXT_KEY, encoded)
    reaper.MarkProjectDirty(0)
  end
end

local function generate_guid()
  local guid = ''
  if reaper.genGuid then guid = reaper.genGuid('') end
  guid = guid:gsub('[{}%-]', '')
  if guid == '' then guid = string.format('%08x', util.simple_hash(tostring(os.time()))) end
  return 'cast_' .. guid
end

-- load() → registry | nil (brak pointera = projekt bez rejestru — normalne).
function M.load()
  local ptr = read_pointer()
  if not ptr or type(ptr.registry_guid) ~= 'string' or ptr.registry_guid == '' then
    return nil
  end
  local path = find_registry_file(ptr.registry_guid)
  if not path then return nil end
  local raw = util.read_file(path)
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  decoded.registry_guid = ptr.registry_guid
  decoded.characters = decoded.characters or {}
  return decoded
end

function M.load_or_create()
  local reg = M.load()
  if reg then return reg end
  local guid = generate_guid()
  reg = M.new_registry(guid)
  write_pointer({ registry_guid = guid, version = M.STATE_VERSION })
  return reg
end

function M.save(reg)
  if not reg or type(reg.registry_guid) ~= 'string' or reg.registry_guid == '' then
    return false, 'no registry guid'
  end
  local ok, encoded = pcall(json.encode, reg)
  if not ok then return false, 'JSON encode failed' end
  if not util.write_file(registry_file_for_write(reg.registry_guid), encoded) then
    return false, 'write file failed'
  end
  return true
end

----------------------------------------------------------------------------
-- M3.1 producer: Dubbing → registry. Wołane po realnym flushu stanu
-- dubbingu (consume_signals / shutdown) — pokrywa KAŻDĄ ścieżkę mutacji
-- głosów (panel pick/design/clear, clone done, similar apply), bo wszystkie
-- przechodzą przez mark_dirty → flush. Idempotent (upsert by label).
----------------------------------------------------------------------------
-- opts.geom_key (W2 M3 cz.2): kanoniczny klucz materiału źródłowego
-- (mixed_single) — postaci dostają marker links.materials (patrz
-- link_material wyżej). opts.now wstrzykiwany w testach.
function M.sync_from_dubbing(project, opts)
  if not project or type(project.speakers) ~= 'table' then return false end
  -- Opisy postaci z glossary.characters (match by name; speaking_style
  -- pełni rolę opisu postaci w dubbingu).
  local desc_by_label = {}
  local g = project.glossary
  if g and type(g.characters) == 'table' then
    for _, c in ipairs(g.characters) do
      if type(c.name) == 'string' and type(c.speaking_style) == 'string'
         and c.speaking_style ~= '' then
        desc_by_label[M.normalize_label(c.name)] = c.speaking_style
      end
    end
  end
  local reg = M.load_or_create()
  local changed = false
  for _, spk in ipairs(project.speakers) do
    if type(spk.label) == 'string' and spk.label ~= '' then
      local voices = {}
      if type(spk.voices) == 'table' then
        for lang, vid in pairs(spk.voices) do
          if type(vid) == 'string' and vid ~= '' then
            voices[lang] = {
              voice_id   = vid,
              voice_name = (spk.voice_names and spk.voice_names[lang]) or '',
            }
          end
        end
      end
      local ch = M.upsert_character(reg, {
        label        = spk.label,
        voices       = voices,
        description  = desc_by_label[M.normalize_label(spk.label)],
        -- W2 M3 cz.2: klon IVC wytrenowany w dubbingu identyfikuje osobę
        -- (konsumowany przez propozycję głosu w Repair i Match cast).
        ivc_clone_id = spk.ivc_clone_id,
        source_mode  = 'dubbing',
      }, opts)
      if ch and opts and opts.geom_key then
        M.link_material(reg, ch, opts.geom_key, opts)
      end
      changed = true
    end
  end
  if changed then return M.save(reg) end
  return false
end

return M

-- modules/util.lua
-- Małe utility używane w fazach 1-2. Większe rzeczy (json, hash, mkdir,
-- shell escape) dochodzą w fazach 3+.

local M = {}

local DEBUG = false

function M.set_debug(enabled) DEBUG = enabled end

function M.dbg(...)
  if not DEBUG then return end
  local parts = {}
  for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
  reaper.ShowConsoleMsg('[Reasonate] ' .. table.concat(parts, '  ') .. '\n')
end

function M.now() return reaper.time_precise() end

function M.find(t, predicate)
  for i, v in ipairs(t) do
    if predicate(v) then return v, i end
  end
end

----------------------------------------------------------------------------
-- DJB2 hash (do seed deterministycznego per-item + voice_id; nie crypto)
----------------------------------------------------------------------------
function M.simple_hash(s)
  local h = 5381
  for i = 1, #s do
    h = ((h * 33) + s:byte(i)) % 0x7FFFFFFF
  end
  return h
end

----------------------------------------------------------------------------
-- M1-1 (audit 2026-07): kanoniczna serializacja voice_settings do kluczy
-- cache. NIGDY json.encode do kluczy — rxi-json iteruje pairs(), a Lua 5.4
-- randomizuje hash stringów per proces, więc ta sama tabela daje inną
-- kolejność pól co sesję → niedeterministyczny klucz → pierwszy Convert po
-- każdym restarcie REAPER = płatny cache-miss + osierocony plik.
-- Stała lista pól + stała kolejność + stałe defaulty (mirror
-- reaper_helpers.settings_equal). Nowe pole = dopisz NA KOŃCU i podbij
-- prefiks wersji w kluczach konsumentów (v2| → v3|) — jawna inwalidacja.
----------------------------------------------------------------------------
function M.canon_voice_settings(vs)
  if type(vs) ~= 'table' then return '' end
  return ('stab=%.4f|sim=%.4f|style=%.4f|boost=%s|speed=%.4f'):format(
    tonumber(vs.stability) or 0.5,
    tonumber(vs.similarity_boost) or 0.75,
    tonumber(vs.style) or 0,
    tostring(vs.use_speaker_boost ~= false),
    tonumber(vs.speed) or 1.0)
end

----------------------------------------------------------------------------
-- M3-1 (audit 2026-07): długość tekstu w ZNAKACH, nie bajtach. ElevenLabs
-- liczy znaki; #s liczy bajty (polskie/niemieckie/japońskie znaki = 2-4 B),
-- więc #s tnie limity za wcześnie i zawyża koszty. Fallback #s dla invalid
-- UTF-8 (utf8.len zwraca nil) — lepiej przeszacować niż crashnąć.
----------------------------------------------------------------------------
function M.utf8_len(s)
  if type(s) ~= 'string' then return 0 end
  return utf8.len(s) or #s
end

----------------------------------------------------------------------------
-- HOTFIX 2026-07-11 (live-caught, regresja M5-3): Scribe zwraca language_code
-- w ISO 639-3 ('eng','pol'), a TTS language_code przyjmuje ISO 639-1
-- ('en','pl') — surowe przekazanie = HTTP 400 "Model ... does not support
-- language_code 'eng'". Normalizacja: 2-literowe pass-through (lowercase),
-- 'pt-br' → 'pt' (region strip), 639-3/639-2 przez mapę, nieznane → nil
-- (caller POMIJA pole — bezpieczny default = autodetekcja modelu).
----------------------------------------------------------------------------
local ISO639_3_TO_1 = {
  eng='en', pol='pl', deu='de', ger='de', fra='fr', fre='fr', spa='es',
  ita='it', por='pt', rus='ru', jpn='ja', kor='ko', zho='zh', chi='zh',
  nld='nl', dut='nl', ukr='uk', ces='cs', cze='cs', slk='sk', slo='sk',
  ron='ro', rum='ro', hun='hu', tur='tr', ara='ar', hin='hi', swe='sv',
  nor='no', nob='no', dan='da', fin='fi', ell='el', gre='el', heb='he',
  vie='vi', tha='th', ind='id', msa='ms', may='ms', fil='fil', tgl='tl',
  hrv='hr', srp='sr', bul='bg', cat='ca', slv='sl', lit='lt', lav='lv',
  est='et', fas='fa', per='fa', urd='ur', ben='bn', tam='ta', tel='te',
  glg='gl', isl='is', ice='is', mkd='mk', mac='mk', bos='bs', sqi='sq',
  alb='sq', kaz='kk', aze='az', kat='ka', geo='ka', hye='hy', arm='hy',
  afr='af', swa='sw', nno='no',
}

function M.iso639_1(code)
  if type(code) ~= 'string' then return nil end
  code = code:lower():gsub('^%s+', ''):gsub('%s+$', '')
  if code == '' then return nil end
  -- Region subtag ('pt-br', 'en_US') → język bazowy.
  local base = code:match('^(%a+)[-_]') or code
  if #base == 2 then return base end
  if ISO639_3_TO_1[base] then return ISO639_3_TO_1[base] end
  if base == 'fil' then return 'fil' end   -- ElevenLabs używa 3-literowego 'fil'
  return nil
end

----------------------------------------------------------------------------
-- Windows port (2026-07-11): każdy worker .sh ma odpowiednik .ps1
-- (PowerShell zamiast .bat — sensowne cytowanie argumentów; DEVIATIONS).
-- worker_script: podmiana rozszerzenia na Windows. exec_worker: spawn
-- fire-and-forget; na Windows prefiks powershell.exe (cmd zaczyna się od
-- escapowanej ścieżki skryptu, więc sam prefiks wystarczy).
----------------------------------------------------------------------------
function M.worker_script(sh_path)
  if reaper.GetOS():find('Win') then
    return (sh_path:gsub('%.sh$', '.ps1'))
  end
  return sh_path
end

----------------------------------------------------------------------------
-- exec_hidden (2026-07-12, iteracja 2 po user-caught kaskadzie na VM):
-- na Windows odpala DOWOLNY command line całkowicie bez okna konsoli —
-- przez wscript.exe (host GUI) + workers/run_hidden.vbs. Sam
-- "-WindowStyle Hidden" NIE wystarcza: konhost tworzy widoczne okno i
-- dopiero PS je chowa → błysk per spawn (kaskada przy pompach ×3).
-- Command line idzie przez PLIK tmp (zero re-quotowania JSON/spacji);
-- VBS kasuje plik po odczycie.
----------------------------------------------------------------------------
function M.exec_hidden(cmd)
  if not reaper.GetOS():find('Win') then
    reaper.ExecProcess(cmd, -1)
    return
  end
  local _, this_path = reaper.get_action_context()
  local script_dir = this_path and this_path:match('(.+)[/\\]') or ''
  local vbs = script_dir .. '\\workers\\run_hidden.vbs'
  local tmp = reaper.GetResourcePath() .. '\\Scripts\\reasonate_tmp'
  M.mkdir_p(tmp)
  local cmdfile = ('%s\\spawn_%x_%x.cmdline'):format(tmp, os.time(), math.random(0, 0xFFFFFF))
  if not M.write_file(cmdfile, cmd) then
    -- Fallback: stara ścieżka (błysk, ale działa).
    reaper.ExecProcess(cmd, -2)
    return
  end
  reaper.ExecProcess(('wscript.exe //B //Nologo "%s" "%s"'):format(vbs, cmdfile), -2)
end

function M.exec_worker(cmd)
  if reaper.GetOS():find('Win') then
    cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' .. cmd
  end
  M.exec_hidden(cmd)
end

----------------------------------------------------------------------------
-- Format helpers
----------------------------------------------------------------------------
function M.format_duration(seconds)
  local s = math.floor(seconds + 0.5)
  if s < 60 then return string.format('%ds', s) end
  if s < 3600 then return string.format('%dm %02ds', math.floor(s / 60), s % 60) end
  return string.format('%dh %dm', math.floor(s / 3600), math.floor((s % 3600) / 60))
end

----------------------------------------------------------------------------
-- Filesystem
----------------------------------------------------------------------------
function M.mkdir_p(path)
  -- Natywne API zamiast os.execute (2026-07-12, user-caught na VM):
  -- os.execute spawnował cmd.exe Z OKNEM KONSOLI per wywołanie, a
  -- cache.cache_dir() woła mkdir_p per FRAME (header pokazuje rozmiar
  -- cache) → na Windowsie storm okienek kradnących focus (mac: cichy
  -- fork per frame — też źle). RecursiveCreateDirectory = zero shell,
  -- zero okien, istniejący katalog to tani no-op (Lua: verified MCP).
  if path and path ~= '' then
    reaper.RecursiveCreateDirectory(path, 0)
  end
end

function M.path_sep()
  return reaper.GetOS():find('Win') and '\\' or '/'
end

function M.file_exists(path)
  local f = io.open(path, 'rb')
  if f then f:close(); return true end
  return false
end

function M.file_size(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local sz = f:seek('end')
  f:close()
  return sz
end

function M.read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local content = f:read('*all')
  f:close()
  return content
end

function M.write_file(path, content)
  local f = io.open(path, 'wb')
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

----------------------------------------------------------------------------
-- Shell escape (POSIX wraps in single quotes; Windows wraps in double)
----------------------------------------------------------------------------
function M.shell_escape(s)
  s = tostring(s)
  if reaper.GetOS():find('Win') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

----------------------------------------------------------------------------
-- T5a (UX-POLISH, user decision 2026-07-11): katalogi na per-projektowe
-- JSON-y (dubbing_projects / cast_registries). Zapisany projekt → obok
-- .rpp (<project_dir>/reasonate_projects/<subdir>) — stan PODRÓŻUJE z
-- projektem (jak reasonate_cache). Unsaved → fallback resource path (jak
-- do 2026-07-11). Zwraca (primary, fallback|nil): zapis idzie do primary;
-- odczyt próbuje primary → fallback (lazy migracja = następny zapis
-- ląduje w primary; plik w fallbacku zostaje jako backup, nie kasujemy).
----------------------------------------------------------------------------
function M.project_state_dirs(subdir)
  local sep = M.path_sep()
  local fallback = reaper.GetResourcePath() .. sep .. 'Scripts'
      .. sep .. 'Reasonate' .. sep .. subdir
  local _, proj_path = reaper.EnumProjects(-1)
  if proj_path and proj_path ~= '' then
    local pd = proj_path:match('(.+)[/\\]')
    if pd then
      return pd .. sep .. 'reasonate_projects' .. sep .. subdir, fallback
    end
  end
  return fallback, nil
end

----------------------------------------------------------------------------
-- T4 (UX-POLISH): otwórz URL w domyślnej przeglądarce. CF_ShellExecute
-- (SWS) gdy jest; fallback = systemowy opener przez ExecProcess (absolutne
-- ścieżki — macOS GUI nie dziedziczy PATH, wzorzec preview.lua).
----------------------------------------------------------------------------
function M.open_url(url)
  if not url or url == '' then return false end
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(url)
    return true
  end
  local os_str = reaper.GetOS()
  local cmd
  if os_str:find('Win') then
    cmd = 'cmd /c start "" ' .. M.shell_escape(url)
  elseif os_str:find('OSX') or os_str:find('macOS') then
    cmd = '/usr/bin/open ' .. M.shell_escape(url)
  else
    cmd = 'xdg-open ' .. M.shell_escape(url)
  end
  reaper.ExecProcess(cmd, -1)
  return true
end

----------------------------------------------------------------------------
-- Soft word-wrap dla ImGui InputTextMultiline (brak natywnego wrapu —
-- KNOWN-ISSUES PM11). Wstawia '\n' co ~max_chars na granicy słowa; istniejące
-- newlines zachowane (paragraph breaks). Para z normalize_whitespace —
-- widget dostaje wrapped view, stan/commit trzyma czysty single-line.
-- Konsumenci: gui/dubbing_panel (inline edit), gui/tts_dialogue_panel (lines).
----------------------------------------------------------------------------
function M.soft_wrap_text(text, max_chars)
  if not text or text == '' then return '' end
  max_chars = max_chars or 70
  local out = {}
  for paragraph in (text .. '\n'):gmatch('([^\n]*)\n') do
    local line = ''
    for word in paragraph:gmatch('%S+') do
      if #line == 0 then
        line = word
      elseif #line + 1 + #word > max_chars then
        table.insert(out, line)
        line = word
      else
        line = line .. ' ' .. word
      end
    end
    if line ~= '' then table.insert(out, line) end
  end
  return table.concat(out, '\n')
end

-- Collapse wszystkie \n / \t / multi-space → single space + trim. Commit-side
-- odpowiednik soft_wrap_text (czysty single-line w stanie / cache keys).
function M.normalize_whitespace(text)
  if not text then return '' end
  text = text:gsub('%s+', ' ')
  text = text:gsub('^%s+', ''):gsub('%s+$', '')
  return text
end

----------------------------------------------------------------------------
-- Pure-Lua base64 decode — cross-platform (used dla NS-B M4.1 Voice Design
-- preview audio). Returns decoded binary string or nil + err.
-- Strict mode: ignores whitespace + newlines (URL-safe variants NOT supported
-- — ElevenLabs returns standard base64 z + and /).
----------------------------------------------------------------------------
----------------------------------------------------------------------------
-- M4-2 (audit 2026-07): wyciągnij kompletny JSON z odpowiedzi LLM.
-- Providery bez twardego JSON mode (DeepSeek, Mistral) i fallbacki strict
-- potrafią owinąć wynik w ```json fences```, dopisać preambułę ("Here is…")
-- albo uciąć na max_tokens. Zwraca zbalansowany fragment JSON lub nil
-- (ucięty/brak JSON) — caller robi czytelny błąd zamiast crasha w decode.
----------------------------------------------------------------------------
function M.extract_json(s)
  if type(s) ~= 'string' or s == '' then return nil end
  local fenced = s:match('```[jJ][sS][oO][nN]%s*(.-)%s*```')
              or s:match('```%s*([%[{].-)%s*```')
  if fenced then s = fenced end
  local first = s:find('[%[{]')
  if not first then return nil end
  s = s:sub(first)
  -- Balans klamer z pominięciem stringów — trailing proza ucięta, brak
  -- domknięcia (truncation) = nil.
  local depth, in_str, esc = 0, false, false
  for i = 1, #s do
    local c = s:sub(i, i)
    if in_str then
      if esc then esc = false
      elseif c == '\\' then esc = true
      elseif c == '"' then in_str = false end
    else
      if c == '"' then in_str = true
      elseif c == '{' or c == '[' then depth = depth + 1
      elseif c == '}' or c == ']' then
        depth = depth - 1
        if depth == 0 then return s:sub(1, i) end
      end
    end
  end
  return nil
end

local B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64_LOOKUP = nil
local function ensure_b64_lookup()
  if B64_LOOKUP then return end
  B64_LOOKUP = {}
  for i = 1, #B64_CHARS do
    B64_LOOKUP[B64_CHARS:sub(i, i)] = i - 1
  end
end

function M.base64_decode(s)
  if not s or s == '' then return nil, 'empty input' end
  ensure_b64_lookup()
  -- Strip whitespace
  s = s:gsub('[%s\r\n]', '')
  -- Strip padding
  local s_clean = s:gsub('=+$', '')
  local out = {}
  local buf, bits = 0, 0
  for i = 1, #s_clean do
    local c = s_clean:sub(i, i)
    local v = B64_LOOKUP[c]
    if not v then return nil, 'invalid base64 char at pos ' .. i end
    buf = buf * 64 + v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local byte = math.floor(buf / (2 ^ bits))
      buf = buf - byte * (2 ^ bits)
      out[#out + 1] = string.char(byte)
    end
  end
  return table.concat(out)
end

-- REAPER native EnumerateFiles — działa na GUI bez PATH issues, cross-platform
function M.list_dir(path)
  local files = {}
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(path, i)
    if not f then break end
    files[#files + 1] = f
    i = i + 1
  end
  return files
end

return M

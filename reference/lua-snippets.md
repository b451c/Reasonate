# Lua snippets — reusable patterns

Małe utility funkcje którymi się obkleisz cały skrypt. Wrzuć do `modules/util.lua`.

## File system

```lua
local M = {}

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

function M.append_file(path, content)
  local f = io.open(path, 'ab')
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

function M.mkdir_p(path)
  if reaper.GetOS():find('Win') then
    os.execute('mkdir "' .. path .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. path .. '"')
  end
end

function M.rm_f(path)
  os.remove(path)
end

function M.list_dir(path)
  local files = {}
  local cmd = reaper.GetOS():find('Win')
    and ('dir /B "' .. path .. '"')
    or  ('ls -1 "' .. path .. '"')
  local p = io.popen(cmd)
  if p then
    for line in p:lines() do
      files[#files + 1] = line
    end
    p:close()
  end
  return files
end
```

## Path manipulation

```lua
function M.path_sep()
  return reaper.GetOS():find('Win') and '\\' or '/'
end

function M.path_join(...)
  local sep = M.path_sep()
  return table.concat({...}, sep):gsub(sep .. sep, sep)
end

function M.path_dir(path)
  return path:match('(.+)[/\\]') or '.'
end

function M.path_base(path)
  return path:match('([^/\\]+)$') or path
end

function M.path_ext(path)
  return path:match('%.([^.]+)$')
end

function M.path_stem(path)
  local base = M.path_base(path)
  return base:match('(.+)%.[^.]+$') or base
end
```

## JSON (minimal, zero-dep)

Jeśli nie chcesz pełnej biblioteki, ten minimal działa dla naszych prostych przypadków (encode/decode flat objects/arrays z string/number/bool/nil):

```lua
-- BARDZO uproszczony JSON. Do produkcji weź dkjson albo json.lua.
local function escape_str(s)
  return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
end

function M.json_encode(v, level)
  level = level or 0
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then return tostring(v) end
  if t == 'string' then return '"' .. escape_str(v) .. '"' end
  if t == 'table' then
    -- array vs object
    local is_array = true
    local n = 0
    for k, _ in pairs(v) do
      n = n + 1
      if type(k) ~= 'number' then is_array = false; break end
    end
    if is_array and n > 0 then
      local parts = {}
      for _, vv in ipairs(v) do parts[#parts+1] = M.json_encode(vv, level+1) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, vv in pairs(v) do
        parts[#parts+1] = '"' .. escape_str(tostring(k)) .. '":' .. M.json_encode(vv, level+1)
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  error('Cannot encode type: ' .. t)
end

-- Decoder polecam wziąć z https://github.com/rxi/json.lua
-- albo dkjson z LuaRocks. Implementacja od zera nie jest tego warta.
```

**Lepiej**: pobierz `rxi/json.lua` (single file, MIT, ~250 lines) i wrzuć do `modules/lib/json.lua`.

## String utilities

```lua
function M.shell_escape_unix(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.shell_escape_win(s)
  -- cmd.exe: " escapuje się przez ""
  return '"' .. s:gsub('"', '""') .. '"'
end

function M.shell_escape(s)
  if reaper.GetOS():find('Win') then
    return M.shell_escape_win(s)
  end
  return M.shell_escape_unix(s)
end

function M.split(s, sep)
  sep = sep or '\n'
  local parts = {}
  for p in (s .. sep):gmatch('(.-)' .. sep:gsub('[%-%.]', '%%%0')) do
    parts[#parts + 1] = p
  end
  return parts
end

function M.trim(s)
  return s:gsub('^%s+', ''):gsub('%s+$', '')
end

function M.startswith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.endswith(s, suffix)
  return suffix == '' or s:sub(-#suffix) == suffix
end
```

## UUID-ish (do job IDs, sentinel filenames)

```lua
function M.uuid_short()
  -- 16 hex chars, time-based + random
  math.randomseed(os.time() + math.floor(reaper.time_precise() * 1e6))
  local t = os.time()
  return string.format('%08x%08x', t, math.random(0, 0xFFFFFFFF))
end
```

Wystarczające do nazwy temp file. Nie crypto.

## Hash do cache key (bez SHA)

```lua
function M.simple_hash(s)
  -- DJB2 hash. Nie crypto, ale dobre do cache key.
  local h = 5381
  for i = 1, #s do
    h = ((h * 33) + s:byte(i)) % 0x7FFFFFFF
  end
  return string.format('%08x', h)
end

function M.cache_key(source_path, voice_id, model_id, seed, settings_json)
  local input = string.format('%s|%d|%s|%s|%d|%s',
    source_path,
    M.file_size(source_path) or 0,
    voice_id,
    model_id,
    seed or 0,
    settings_json or '')
  return M.simple_hash(input)
end
```

Uwaga: `simple_hash` da Ci 32-bit klucz, kolizje są ~1 na 4 mld przy losowych input-ach. W praktyce dla projektu z 1000 itemami szansa kolizji znikoma, ale jeśli chcesz spokoju — weź `rxi/json.lua` i wrzuć do hasha cały tekst joba przez DJB2.

## Tabele

```lua
function M.table_size(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function M.table_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys+1] = k end
  return keys
end

function M.table_values(t)
  local vals = {}
  for _, v in pairs(t) do vals[#vals+1] = v end
  return vals
end

function M.shallow_copy(t)
  local n = {}
  for k, v in pairs(t) do n[k] = v end
  return n
end

function M.find(t, predicate)
  for _, v in ipairs(t) do
    if predicate(v) then return v end
  end
end

function M.filter(t, predicate)
  local r = {}
  for _, v in ipairs(t) do
    if predicate(v) then r[#r+1] = v end
  end
  return r
end

function M.map(t, fn)
  local r = {}
  for i, v in ipairs(t) do r[i] = fn(v) end
  return r
end
```

## Time

```lua
function M.now() return reaper.time_precise() end

function M.format_duration(seconds)
  local s = math.floor(seconds)
  if s < 60 then return string.format('%ds', s) end
  if s < 3600 then return string.format('%dm %02ds', s/60, s%60) end
  return string.format('%dh %dm', s/3600, (s%3600)/60)
end

function M.eta(elapsed, fraction)
  if fraction <= 0 or fraction >= 1 then return nil end
  local total = elapsed / fraction
  return total - elapsed
end
```

## Debug / logging

```lua
local DEBUG = false

function M.dbg(...)
  if not DEBUG then return end
  local parts = {}
  for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
  reaper.ShowConsoleMsg(table.concat(parts, '  ') .. '\n')
end

function M.set_debug(enabled)
  DEBUG = enabled
end

-- Bardziej rozbudowany logger z poziomami
local Log = {entries = {}, max_entries = 200}

function Log.add(level, msg)
  table.insert(Log.entries, 1, {
    level = level,
    msg = msg,
    time = os.time(),
    time_pretty = os.date('%H:%M:%S')
  })
  while #Log.entries > Log.max_entries do
    table.remove(Log.entries)
  end
end

function Log.info(msg) Log.add('info', msg) end
function Log.warn(msg) Log.add('warn', msg) end
function Log.error(msg) Log.add('error', msg) end

M.log = Log
```

## Defer-aware sleep (dla retry backoff)

```lua
-- Lua os.time() ma rozdzielczość 1s, używaj reaper.time_precise()
-- Wzorzec retry-after-N-seconds w defer loop:

local function tick()
  local now = reaper.time_precise()
  for id, job in pairs(jobs_to_retry) do
    if job.retry_at and now >= job.retry_at then
      job_manager.spawn(job)
      jobs_to_retry[id] = nil
    end
  end
end
```

Nigdy nie używaj `os.execute('sleep N')` — blokuje cały REAPER.

## ImGui balanced helpers

```lua
function M.with_color(ctx, col, value, fn)
  reaper.ImGui_PushStyleColor(ctx, col, value)
  local ok, err = pcall(fn)
  reaper.ImGui_PopStyleColor(ctx)
  if not ok then error(err) end
end

function M.with_font(ctx, font, size, fn)
  reaper.ImGui_PushFont(ctx, font, size)
  local ok, err = pcall(fn)
  reaper.ImGui_PopFont(ctx)
  if not ok then error(err) end
end

function M.with_id(ctx, id, fn)
  reaper.ImGui_PushID(ctx, id)
  local ok, err = pcall(fn)
  reaper.ImGui_PopID(ctx)
  if not ok then error(err) end
end

function M.with_disabled(ctx, disabled, fn)
  reaper.ImGui_BeginDisabled(ctx, disabled)
  local ok, err = pcall(fn)
  reaper.ImGui_EndDisabled(ctx)
  if not ok then error(err) end
end
```

Te helpery gwarantują że Push ma swój Pop nawet jak Lua rzuci wyjątkiem. Bardzo defensywne, polecam.

```lua
return M
```

## Pitch shifter resolve po nazwie (I_PITCHMODE)

Sloty pitch shifterów REAPER bywają wersjo-zależne — nigdy nie hardcode'uj
samej liczby. Resolve w runtime po nazwie; pakowanie per SDK:
`I_PITCHMODE = (mode << 16) | submode`, `-1` = project default.

```lua
-- élastique Soloist:Speech (formant-preserving — najlepszy dla mowy).
-- Ostatni match wygrywa: enum ma 2.2.8 ORAZ 3.3.3 (nowsza dalej w liście).
-- Lua: boolean retval, string str = reaper.EnumPitchShiftModes(int mode)
--      (MCP index błędnie twierdzi "brak Lua" — patrz KNOWN-ISSUES durable).
local function resolve_speech_pitchmode()
  if not (reaper.EnumPitchShiftModes and reaper.EnumPitchShiftSubModes) then
    return 0xB0002  -- fallback: élastique 3.3.3 Soloist : Speech (REAPER 7.x)
  end
  local result, mode = -1, 0
  while true do
    local ok, name = reaper.EnumPitchShiftModes(mode)
    if not ok then break end
    -- name == nil = mode "currently unsupported" (scan idzie dalej);
    -- 'lastique' omija é w nazwie
    if name and name:find('lastique') and name:find('Soloist') then
      local sub = 0
      while true do
        local sub_name = reaper.EnumPitchShiftSubModes(mode, sub)
        if not sub_name then break end
        if sub_name:find('Speech') then result = (mode << 16) | sub; break end
        sub = sub + 1
      end
    end
    mode = mode + 1
  end
  return result  -- -1 gdy brak matcha = zostaw project default
end

-- Użycie (per take, razem z B_PPITCH=1):
-- reaper.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', 1)
-- local pm = resolve_speech_pitchmode()
-- if pm ~= -1 then reaper.SetMediaItemTakeInfo_Value(take, 'I_PITCHMODE', pm) end
```

Wersja produkcyjna (z cache per session + injectable enums dla testów):
`dubbing_splicer.resolve_speech_pitchmode` (W2 M2, 2026-06-11).

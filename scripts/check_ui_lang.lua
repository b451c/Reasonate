-- scripts/check_ui_lang.lua — bramka "UI English-only".
--
-- Skanuje pliki .lua i raportuje polskie diakrytyki WYŁĄCZNIE wewnątrz
-- literałów stringowych (komentarze -- i --[[ ]] są legalnie polskie per
-- CLAUDE.md). Zastępuje grep z handover.md Krok 2, który łapał komentarze
-- inline i wymagał ręcznego przeglądu — to jest wersja zero-false-positive
-- nadająca się na exit-code gate.
--
-- Użycie: lua5.4 scripts/check_ui_lang.lua <plik.lua> [<plik2.lua> ...]
-- Exit 0 = czysto; 1 = znaleziono diakrytyki w stringach (wypisane file:line).

local DIACRITICS = {
  'ą','ć','ę','ł','ń','ó','ś','ż','ź',
  'Ą','Ć','Ę','Ł','Ń','Ó','Ś','Ż','Ź',
}

local function has_diacritic(s)
  for _, d in ipairs(DIACRITICS) do
    if s:find(d, 1, true) then return d end
  end
  return nil
end

-- Mini-lexer: wyciąga literały stringowe (', ", [[ ]] z poziomami [=[)
-- pomijając komentarze. Zwraca listę {line=N, text=...}.
local function extract_strings(src)
  local out = {}
  local i, n, line = 1, #src, 1
  local function peek(off) return src:sub(i + (off or 0), i + (off or 0)) end

  -- Pomocnik: long bracket [[...]] / [=[...]=] — zwraca poziom lub nil.
  local function long_open_at(pos)
    if src:sub(pos, pos) ~= '[' then return nil end
    local j = pos + 1
    local eq = 0
    while src:sub(j, j) == '=' do eq = eq + 1; j = j + 1 end
    if src:sub(j, j) == '[' then return eq, j end
    return nil
  end

  while i <= n do
    local c = src:sub(i, i)
    if c == '\n' then
      line = line + 1
      i = i + 1
    elseif c == '-' and peek(1) == '-' then
      -- Komentarz: -- lub --[[ ]]
      local lvl, openend = long_open_at(i + 2)
      if lvl then
        -- block comment — skip do ]=*]
        local close = ']' .. string.rep('=', lvl) .. ']'
        local s_, e_ = src:find(close, openend + 1, true)
        local segment = src:sub(i, e_ or n)
        for _ in segment:gmatch('\n') do line = line + 1 end
        i = (e_ or n) + 1
      else
        local nl = src:find('\n', i, true)
        i = nl or (n + 1)
      end
    elseif c == "'" or c == '"' then
      local quote = c
      local start_line = line
      local j = i + 1
      local buf = {}
      while j <= n do
        local cj = src:sub(j, j)
        if cj == '\\' then
          buf[#buf + 1] = src:sub(j, j + 1)
          j = j + 2
        elseif cj == quote then
          break
        elseif cj == '\n' then
          -- niedomknięty string (syntax error) — przerwij bezpiecznie
          line = line + 1
          break
        else
          buf[#buf + 1] = cj
          j = j + 1
        end
      end
      out[#out + 1] = { line = start_line, text = table.concat(buf) }
      i = j + 1
    else
      local lvl, openend = long_open_at(i)
      if lvl then
        local start_line = line
        local close = ']' .. string.rep('=', lvl) .. ']'
        local s_, e_ = src:find(close, openend + 1, true)
        local content = src:sub(openend + 1, (s_ or n + 1) - 1)
        for _ in content:gmatch('\n') do line = line + 1 end
        out[#out + 1] = { line = start_line, text = content }
        i = (e_ or n) + 1
      else
        i = i + 1
      end
    end
  end
  return out
end

local violations = 0
for fi = 1, #arg do
  local path = arg[fi]
  local f = io.open(path, 'rb')
  if f then
    local src = f:read('*all') or ''
    f:close()
    for _, lit in ipairs(extract_strings(src)) do
      local d = has_diacritic(lit.text)
      if d then
        violations = violations + 1
        local preview = lit.text:gsub('%s+', ' '):sub(1, 70)
        io.write(('%s:%d: polish char %q in string: %s\n')
          :format(path, lit.line, d, preview))
      end
    end
  else
    io.write(('WARN: cannot open %s\n'):format(path))
  end
end

os.exit(violations == 0 and 0 or 1)

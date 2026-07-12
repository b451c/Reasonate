-- modules/dialogue_script.lua
--
-- W3 (2026-06-11, user request): parser skryptu dialogowego z pliku .txt/.md
-- — "żeby nie trzeba było wpisywać ręcznie". Format per linia:
--
--   Anna: Jak było w podróży?
--   Marek: Długo... za długo.
--
-- Tolerowane ozdobniki markdown: nagłówki (# ...) i linie --- są POMIJANE,
-- bullet/quote (-, *, >) i bold/italic/code wokół imienia (**Anna:**) są
-- zdejmowane. Linia bez prefiksu "Name:" = kontynuacja poprzedniej kwestii
-- (doklejana spacją). Moduł PURE (zero reaper) — headless-tested.
-- Konsument: modes/tts.import_dialogue_script (mapowanie na mówców + linie).

local M = {}

-- parse(raw) → lines|nil, err
-- lines = array { speaker = 'Name', text = 'kwestia' } (kolejność pliku).
function M.parse(raw)
  if type(raw) ~= 'string' or raw == '' then
    return nil, 'empty file'
  end
  raw = raw:gsub('^\239\187\191', '')            -- UTF-8 BOM
  raw = raw:gsub('\r\n', '\n'):gsub('\r', '\n')  -- CRLF / CR → LF

  local out = {}
  for line in (raw .. '\n'):gmatch('([^\n]*)\n') do
    local t = line:gsub('^%s+', ''):gsub('%s+$', '')
    local skip = (t == '') or t:match('^#') or t:match('^%-%-%-+$')
    if not skip then
      t = t:gsub('^[%-%*>]+%s+', '')             -- md bullet / quote prefix
      local name, rest = t:match('^([^:]+):%s*(.*)$')
      if name then
        name = name:gsub('[%*_`]', ''):gsub('^%s+', ''):gsub('%s+$', '')
      end
      if name and #name > 0 and #name <= 40 and not name:find('[%[%]]') then
        rest = (rest or ''):gsub('^[%*_`]+%s*', '')
        out[#out + 1] = { speaker = name, text = rest }
      elseif #out > 0 then
        -- Kontynuacja poprzedniej kwestii (wieloliniowa kwestia w pliku).
        if out[#out].text == '' then
          out[#out].text = t
        else
          out[#out].text = out[#out].text .. ' ' .. t
        end
      end
      -- Linia bez "Name:" PRZED pierwszą kwestią — ignorowana (didaskalia).
    end
  end

  if #out == 0 then
    return nil, 'no "Name: line text" entries found'
  end
  return out
end

return M

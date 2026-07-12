-- modules/llm/anthropic.lua
-- NS-B Dubbing: Anthropic Messages API adapter.
--
-- Endpoint: POST https://api.anthropic.com/v1/messages
-- Forced JSON via tool_use: tool_choice={type='tool', name='emit_translation'}
--   -- model MUSI wywołać dokładnie ten tool, parser czyta input dict
-- Prompt caching: cache_control={type='ephemeral'} na system block + tools
--   → 90% off reads, 5min TTL default. Min 2048 tok dla Sonnet (verified audit).

local M = {}

M.ENDPOINT    = 'https://api.anthropic.com/v1/messages'
M.API_VERSION = '2023-06-01'  -- verified 2026-05 still current

function M.endpoint_url(_model)
  return M.ENDPOINT  -- single endpoint, model w body field
end

function M.key_header(api_key)
  return 'x-api-key: ' .. api_key
end

-- W2 s6 fix (2026-06-11, verified oficjalna referencja Claude API): sampling
-- params (temperature/top_p/top_k) są USUNIĘTE na Opus 4.7/4.8 oraz
-- Fable/Mythos — wysłanie = HTTP 400 "Unsupported parameter". Sonnet 4.6 /
-- Haiku 4.5 / Opus ≤4.6 akceptują. Pre-fix opcja "Opus 4.7 (premium)"
-- w Settings była martwa (każde wywołanie 400).
local function sampling_supported(model)
  local m = model or ''
  if m:find('^claude%-opus%-4%-7') or m:find('^claude%-opus%-4%-8') then return false end
  if m:find('^claude%-fable') or m:find('^claude%-mythos') then return false end
  return true
end

-- Task (name/description/schema) przychodzi w opts.task z llm.lua
-- (NS-SFX generalizacja 2026-06-10; definicja translate = llm.TASK_TRANSLATE).
function M.build_body(opts)
  local task = opts.task
  local model = opts.model or 'claude-sonnet-4-6'
  local body = {
    model       = model,
    max_tokens  = opts.max_tokens or 2048,
    tools = {
      {
        name         = task.name,
        description  = task.description,
        input_schema = task.schema,
      },
    },
    tool_choice = { type = 'tool', name = task.name },
    messages = {
      { role = 'user', content = opts.user_prompt or '' },
    },
  }
  if sampling_supported(model) then
    body.temperature = opts.temperature or 0.7
  end
  -- System prompt jako block array → umożliwia cache_control on it.
  if opts.system_prompt and opts.system_prompt ~= '' then
    body.system = {
      { type = 'text', text = opts.system_prompt },
    }
    if opts.cache_control then
      -- Cache breakpoint na system + tools (jeden cache_control pokrywa preceding content).
      body.system[1].cache_control = { type = 'ephemeral' }
      body.tools[1].cache_control  = { type = 'ephemeral' }
    end
  end
  return body
end

-- Response shape: { content:[{type:'tool_use', name:..., input:{...}}], usage:{...}, ... }
-- Zwraca surowe { data = tool_input, usage } — walidacja per task w llm.poll.
function M.parse_success(decoded)
  if type(decoded) ~= 'table' or type(decoded.content) ~= 'table' then
    return nil, 'Anthropic response missing content[]'
  end
  local tool_input
  for _, block in ipairs(decoded.content) do
    if type(block) == 'table' and block.type == 'tool_use' and block.input then
      tool_input = block.input
      break
    end
  end
  if not tool_input then
    return nil, 'Anthropic response missing tool_use block (model did not call the tool)'
  end
  return { data = tool_input, usage = decoded.usage or {} }
end

function M.format_error(http_code, decoded_or_body)
  local detail = ''
  if type(decoded_or_body) == 'table' and type(decoded_or_body.error) == 'table' then
    local e = decoded_or_body.error
    detail = (e.type or '') .. ': ' .. (e.message or '?')
  elseif type(decoded_or_body) == 'string' then
    detail = decoded_or_body:sub(1, 200)
  end
  return string.format('HTTP %d (Anthropic)%s', http_code, detail ~= '' and (': ' .. detail) or '')
end

return M

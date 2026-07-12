-- modules/llm/openai.lua
-- NS-B Dubbing: OpenAI Chat Completions adapter.
--
-- Endpoint: POST https://api.openai.com/v1/chat/completions
-- Forced JSON via response_format.json_schema z strict:true (grammar-level enforcement).
-- GPT-5.2+ używa CFG token masking — model LITERALNIE nie może wyemitować
-- innego niż schema-conforming JSON.
--
-- Schema constraints (verified per audit):
--   - additionalProperties: false MANDATORY
--   - required[] lists ALL keys w properties
--   - NIE wspierane: anyOf, oneOf, allOf, $ref, pattern, >100 properties

local M = {}

M.ENDPOINT = 'https://api.openai.com/v1/chat/completions'

function M.endpoint_url(_model)
  return M.ENDPOINT
end

function M.key_header(api_key)
  return 'Authorization: Bearer ' .. api_key
end

-- Task przychodzi w opts.task (NS-SFX generalizacja 2026-06-10). Preferowany
-- task.openai_schema (strict wymaga required-all + additionalProperties:false
-- REKURENCYJNIE — autor taska podaje jawnie); fallback: canonical task.schema
-- ze strict=false (best-effort).
function M.build_body(opts)
  local task = opts.task
  local json_schema = task.openai_schema
    or { name = task.name, strict = false, schema = task.schema }
  local messages = {}
  if opts.system_prompt and opts.system_prompt ~= '' then
    messages[#messages + 1] = { role = 'system', content = opts.system_prompt }
  end
  messages[#messages + 1] = { role = 'user', content = opts.user_prompt or '' }
  return {
    model           = opts.model or 'gpt-5.4-mini',
    messages        = messages,
    max_completion_tokens = opts.max_tokens or 2048,
    -- W2 s6 fix (2026-06-11): temperature POMIJANE — warianty GPT-5.x
    -- z włączonym rozumowaniem odrzucają parametr ("Unsupported parameter:
    -- 'temperature'"); wsparcie zależy od modelu/reasoning_effort, więc
    -- jedyna bezpieczna opcja to default. Sterowanie stylem = prompt.
    response_format = {
      type        = 'json_schema',
      json_schema = json_schema,
    },
  }
end

-- Response shape: { choices:[{message:{content:'JSON string', refusal:null}}], usage:{...} }
function M.parse_success(decoded)
  if type(decoded) ~= 'table' or type(decoded.choices) ~= 'table' or not decoded.choices[1] then
    return nil, 'OpenAI response missing choices[]'
  end
  local msg = decoded.choices[1].message
  if type(msg) ~= 'table' then
    return nil, 'OpenAI response missing message'
  end
  if msg.refusal and msg.refusal ~= '' then
    return nil, 'OpenAI refused: ' .. tostring(msg.refusal)
  end
  if type(msg.content) ~= 'string' or msg.content == '' then
    return nil, 'OpenAI message.content empty'
  end
  -- M4-2: strict schema zwykle daje czysty JSON, ale warianty reasoning
  -- potrafią dopisać prozę lub uciąć na max_tokens — guard przed decode.
  local cleaned = require('modules.util').extract_json(msg.content)
  if not cleaned then
    return nil, 'OpenAI: no complete JSON in response (truncated or non-JSON output)'
  end
  local json = require 'modules.lib.json'
  local ok, parsed = pcall(json.decode, cleaned)
  if not ok or type(parsed) ~= 'table' then
    return nil, 'OpenAI JSON parse failed lub schema mismatch'
  end
  -- Surowe { data, usage } — walidacja per task w llm.poll.
  return { data = parsed, usage = decoded.usage or {} }
end

function M.format_error(http_code, decoded_or_body)
  local detail = ''
  if type(decoded_or_body) == 'table' and type(decoded_or_body.error) == 'table' then
    local e = decoded_or_body.error
    detail = (e.code or e.type or '') .. ': ' .. (e.message or '?')
  elseif type(decoded_or_body) == 'string' then
    detail = decoded_or_body:sub(1, 200)
  end
  return string.format('HTTP %d (OpenAI)%s', http_code, detail ~= '' and (': ' .. detail) or '')
end

return M

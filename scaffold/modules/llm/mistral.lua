-- modules/llm/mistral.lua
-- W2 s6 (2026-06-11): Mistral adapter — Chat Completions (OpenAI-like).
--
-- Endpoint: POST https://api.mistral.ai/v1/chat/completions
-- Forced JSON via response_format = { type='json_schema',
--   json_schema={ name, schema } } — DOKŁADNIE shape z oficjalnego przykładu
-- (verified docs.mistral.ai → custom structured outputs, 2026-06-11; bez
-- pola 'strict' — nie wysyłamy pól spoza dokumentacji).
-- Response shape = OpenAI (choices[].message.content z JSON stringiem).
-- temperature wspierane (oficjalny przykład używa temperature=0) → wysyłamy.
-- Selling point: dane przetwarzane w UE (RODO dla materiałów klienckich).

local M = {}

M.ENDPOINT = 'https://api.mistral.ai/v1/chat/completions'

function M.endpoint_url(_model)
  return M.ENDPOINT
end

function M.key_header(api_key)
  return 'Authorization: Bearer ' .. api_key
end

-- Canonical task.schema idzie prosto w json_schema.schema (Mistral przyjmuje
-- standardowy JSON Schema; bez wymogu required-all jak OpenAI strict).
function M.build_body(opts)
  local task = opts.task
  local messages = {}
  if opts.system_prompt and opts.system_prompt ~= '' then
    messages[#messages + 1] = { role = 'system', content = opts.system_prompt }
  end
  messages[#messages + 1] = { role = 'user', content = opts.user_prompt or '' }
  return {
    model       = opts.model or 'mistral-medium-latest',
    messages    = messages,
    max_tokens  = opts.max_tokens or 2048,
    temperature = opts.temperature or 0.7,
    response_format = {
      type        = 'json_schema',
      json_schema = {
        name   = task.name,
        schema = task.schema,
      },
    },
  }
end

-- Response shape: OpenAI-compatible.
function M.parse_success(decoded)
  if type(decoded) ~= 'table' or type(decoded.choices) ~= 'table' or not decoded.choices[1] then
    return nil, 'Mistral response missing choices[]'
  end
  local msg = decoded.choices[1].message
  if type(msg) ~= 'table' or type(msg.content) ~= 'string' or msg.content == '' then
    return nil, 'Mistral message.content empty'
  end
  -- M4-2: json_schema Mistrala jest bez strict — fences/truncation możliwe.
  local cleaned = require('modules.util').extract_json(msg.content)
  if not cleaned then
    return nil, 'Mistral: no complete JSON in response (truncated or non-JSON output)'
  end
  local json = require 'modules.lib.json'
  local ok, parsed = pcall(json.decode, cleaned)
  if not ok or type(parsed) ~= 'table' then
    return nil, 'Mistral JSON parse failed lub schema mismatch'
  end
  -- Surowe { data, usage } — walidacja per task w llm.poll.
  return { data = parsed, usage = decoded.usage or {} }
end

function M.format_error(http_code, decoded_or_body)
  local detail = ''
  if type(decoded_or_body) == 'table' then
    -- Mistral: {message, type} top-level LUB {detail:[...]} dla 422.
    if type(decoded_or_body.message) == 'string' then
      detail = (decoded_or_body.type or '') .. ': ' .. decoded_or_body.message
    elseif type(decoded_or_body.error) == 'table' then
      local e = decoded_or_body.error
      detail = (e.code or e.type or '') .. ': ' .. (e.message or '?')
    elseif decoded_or_body.detail ~= nil then
      local json = require 'modules.lib.json'
      local okj, enc = pcall(json.encode, decoded_or_body.detail)
      detail = okj and enc:sub(1, 200) or 'validation error'
    end
  elseif type(decoded_or_body) == 'string' then
    detail = decoded_or_body:sub(1, 200)
  end
  return string.format('HTTP %d (Mistral)%s', http_code, detail ~= '' and (': ' .. detail) or '')
end

return M

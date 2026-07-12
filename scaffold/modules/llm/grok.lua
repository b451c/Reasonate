-- modules/llm/grok.lua
-- W2 s6 (2026-06-11): xAI Grok adapter — OpenAI-compatible Chat Completions.
--
-- Endpoint: POST https://api.x.ai/v1/chat/completions
-- Forced JSON via response_format.json_schema (strict:true) — wspierane na
-- rodzinie Grok 4 (verified docs.x.ai → model-capabilities → structured
-- outputs, 2026-06-11). additionalProperties u xAI defaultuje do false —
-- task.openai_schema (required-all + additionalProperties:false) pasuje 1:1.
-- Response shape = OpenAI (choices[].message.content z JSON stringiem).
-- Sampling: temperature POMIJANE (mirror openai.lua — warianty reasoning
-- odrzucają parametr; default jest bezpieczny na wszystkich).

local M = {}

M.ENDPOINT = 'https://api.x.ai/v1/chat/completions'

function M.endpoint_url(_model)
  return M.ENDPOINT
end

function M.key_header(api_key)
  return 'Authorization: Bearer ' .. api_key
end

-- Preferowany task.openai_schema (strict-ready); fallback canonical
-- task.schema ze strict=false (best-effort) — mirror openai.lua.
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
    model      = opts.model or 'grok-4.3',
    messages   = messages,
    -- xAI używa klasycznego max_tokens (nie max_completion_tokens jak OpenAI).
    max_tokens = opts.max_tokens or 2048,
    response_format = {
      type        = 'json_schema',
      json_schema = json_schema,
    },
  }
end

-- Response shape: OpenAI-compatible.
function M.parse_success(decoded)
  if type(decoded) ~= 'table' or type(decoded.choices) ~= 'table' or not decoded.choices[1] then
    return nil, 'Grok response missing choices[]'
  end
  local msg = decoded.choices[1].message
  if type(msg) ~= 'table' or type(msg.content) ~= 'string' or msg.content == '' then
    return nil, 'Grok message.content empty'
  end
  -- M4-2: fences/preambuła/truncation guard (wspólny wzorzec adapterów).
  local cleaned = require('modules.util').extract_json(msg.content)
  if not cleaned then
    return nil, 'Grok: no complete JSON in response (truncated or non-JSON output)'
  end
  local json = require 'modules.lib.json'
  local ok, parsed = pcall(json.decode, cleaned)
  if not ok or type(parsed) ~= 'table' then
    return nil, 'Grok JSON parse failed lub schema mismatch'
  end
  -- Surowe { data, usage } — walidacja per task w llm.poll.
  return { data = parsed, usage = decoded.usage or {} }
end

function M.format_error(http_code, decoded_or_body)
  local detail = ''
  if type(decoded_or_body) == 'table' then
    -- xAI zwraca błędy jako {error: "string"} LUB {error: {message, code}}.
    local e = decoded_or_body.error
    if type(e) == 'table' then
      detail = (e.code or e.type or '') .. ': ' .. (e.message or '?')
    elseif type(e) == 'string' then
      detail = e:sub(1, 200)
    end
  elseif type(decoded_or_body) == 'string' then
    detail = decoded_or_body:sub(1, 200)
  end
  return string.format('HTTP %d (Grok)%s', http_code, detail ~= '' and (': ' .. detail) or '')
end

return M

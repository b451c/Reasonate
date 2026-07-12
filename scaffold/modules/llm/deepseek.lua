-- modules/llm/deepseek.lua
-- NS-B Dubbing: DeepSeek API adapter (OpenAI-compatible format).
--
-- Endpoint: POST https://api.deepseek.com/chat/completions
-- JSON output: response_format={type='json_object'} + schema embedded w system prompt.
-- DeepSeek NIE wspiera json_schema strict (per audit) — best-effort enforcement only.
--
-- Polish translation quality: untested (per audit). Default opt-in tylko gdy user
-- ma DeepSeek key i nie ma innych. Bezpieczniej Claude/Gemini dla Polish drama.

local M = {}

M.ENDPOINT = 'https://api.deepseek.com/chat/completions'

function M.endpoint_url(_model)
  return M.ENDPOINT
end

function M.key_header(api_key)
  return 'Authorization: Bearer ' .. api_key
end

-- Schema instructions appended do system prompt (DeepSeek nie ma strict
-- json_schema mode). Tekst instrukcji przychodzi per task
-- (opts.task.deepseek_instruction — NS-SFX generalizacja 2026-06-10);
-- fallback generyczny gdy task go nie definiuje.
local GENERIC_INSTRUCTION = [[


OUTPUT FORMAT:
Return ONLY a single JSON object matching the requested schema. No markdown fence, no preamble, no commentary.]]

function M.build_body(opts)
  local sys = (opts.system_prompt or '')
    .. (opts.task.deepseek_instruction or GENERIC_INSTRUCTION)
  local messages = {
    { role = 'system', content = sys },
    { role = 'user',   content = opts.user_prompt or '' },
  }
  return {
    model           = opts.model or 'deepseek-v4-flash',
    messages        = messages,
    max_tokens      = opts.max_tokens or 2048,
    temperature     = opts.temperature or 0.7,
    response_format = { type = 'json_object' },  -- best-effort, NOT strict
  }
end

-- Response shape — OpenAI-compatible (same as OpenAI adapter).
function M.parse_success(decoded)
  if type(decoded) ~= 'table' or type(decoded.choices) ~= 'table' or not decoded.choices[1] then
    return nil, 'DeepSeek response missing choices[]'
  end
  local msg = decoded.choices[1].message
  if type(msg) ~= 'table' or type(msg.content) ~= 'string' or msg.content == '' then
    return nil, 'DeepSeek message.content empty'
  end
  -- M4-2: fences/preambuła/truncation — wyciągnij kompletny JSON zamiast
  -- padać w decode (json_object jest best-effort, nie strict).
  local cleaned = require('modules.util').extract_json(msg.content)
  if not cleaned then
    return nil, 'DeepSeek: no complete JSON in response (truncated or non-JSON output)'
  end
  local json = require 'modules.lib.json'
  local ok, parsed = pcall(json.decode, cleaned)
  if not ok or type(parsed) ~= 'table' then
    return nil, 'DeepSeek JSON parse failed (no strict schema enforcement, may return malformed JSON)'
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
  return string.format('HTTP %d (DeepSeek)%s', http_code, detail ~= '' and (': ' .. detail) or '')
end

return M

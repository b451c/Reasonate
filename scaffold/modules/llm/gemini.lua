-- modules/llm/gemini.lua
-- NS-B Dubbing: Google Gemini API adapter (v1beta).
--
-- Endpoint: POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
--   UWAGA: ":generateContent" jest częścią URL path (colon-method), nie segment after slash.
-- Forced JSON via generationConfig.responseSchema + responseMimeType='application/json'.
-- Auth: header 'x-goog-api-key' (preferred 2026 over URL query param — verified audit).

local M = {}

local BASE = 'https://generativelanguage.googleapis.com/v1beta/models/'

function M.endpoint_url(model)
  return BASE .. (model or 'gemini-2.5-flash') .. ':generateContent'
end

function M.key_header(api_key)
  return 'x-goog-api-key: ' .. api_key
end

-- Gemini responseSchema accepts OpenAPI-flavored JSON schema subset (verified
-- audit; lowercase types OK). Task przychodzi w opts.task — canonical
-- task.schema idzie prosto w responseSchema (NS-SFX generalizacja 2026-06-10).
function M.build_body(opts)
  local body = {
    contents = {
      { role = 'user', parts = { { text = opts.user_prompt or '' } } },
    },
    generationConfig = {
      temperature       = opts.temperature or 0.7,
      maxOutputTokens   = opts.max_tokens or 2048,
      responseMimeType  = 'application/json',
      responseSchema    = opts.task.schema,
    },
  }
  -- System instruction top-level (Gemini 2026 stable pattern, NIE jako role w contents[]).
  if opts.system_prompt and opts.system_prompt ~= '' then
    body.systemInstruction = {
      parts = { { text = opts.system_prompt } },
    }
  end
  return body
end

-- Response shape:
--   { candidates:[{ content:{ parts:[{text:'JSON string'}] }, finishReason }], usageMetadata }
function M.parse_success(decoded)
  if type(decoded) ~= 'table' or type(decoded.candidates) ~= 'table' or not decoded.candidates[1] then
    return nil, 'Gemini response missing candidates[]'
  end
  local cand = decoded.candidates[1]
  if cand.finishReason and cand.finishReason ~= 'STOP' and cand.finishReason ~= 'MAX_TOKENS' then
    return nil, 'Gemini blocked: ' .. tostring(cand.finishReason)
  end
  if type(cand.content) ~= 'table' or type(cand.content.parts) ~= 'table' or not cand.content.parts[1] then
    return nil, 'Gemini candidate missing content.parts[]'
  end
  local text = cand.content.parts[1].text
  if type(text) ~= 'string' or text == '' then
    return nil, 'Gemini content.parts[0].text empty'
  end
  -- M4-2: MAX_TOKENS przepuszczamy wyżej (finishReason) — ucięty JSON
  -- kończy się tu czytelnym błędem zamiast crasha w decode.
  local cleaned = require('modules.util').extract_json(text)
  if not cleaned then
    return nil, 'Gemini: no complete JSON in response (truncated or non-JSON output)'
  end
  local json = require 'modules.lib.json'
  local ok, parsed = pcall(json.decode, cleaned)
  if not ok or type(parsed) ~= 'table' then
    return nil, 'Gemini JSON parse failed lub schema mismatch'
  end
  -- Surowe { data, usage } — walidacja per task w llm.poll.
  return { data = parsed, usage = decoded.usageMetadata or {} }
end

function M.format_error(http_code, decoded_or_body)
  local detail = ''
  if type(decoded_or_body) == 'table' and type(decoded_or_body.error) == 'table' then
    local e = decoded_or_body.error
    detail = (e.status or tostring(e.code or '')) .. ': ' .. (e.message or '?')
  elseif type(decoded_or_body) == 'string' then
    detail = decoded_or_body:sub(1, 200)
  end
  return string.format('HTTP %d (Gemini)%s', http_code, detail ~= '' and (': ' .. detail) or '')
end

return M

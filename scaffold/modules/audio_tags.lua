-- modules/audio_tags.lua
--
-- NS-2b (M2): curated audio tags dla ElevenLabs Eleven v3.
--
-- Klik w palette (modes/tts.lua) → wstawia [tag] do tekstu. Pełna lista 100+
-- w docs ElevenLabs + community; tutaj wybór ~70 najbardziej użytecznych
-- w produkcji VO/dubbingu, podzielonych na 7 kategorii.
--
-- Wszystkie user-facing strings (kategoria + tooltip) PO ANGIELSKU per
-- memory `feedback_ui_english_only.md` — plugin targets global market.
-- Tag sam jest English (ElevenLabs model rozumie tylko English keywords).
--
-- v3-only feature; inne modele (Multilingual v2 / Turbo / Flash) ignorują
-- audio tagi (pozostawiają je w tekście jako literalne wyrazy).

local M = {}

M.CATEGORIES = {
  {
    name = 'Emotions',
    expanded_default = false,
    tags = {
      { tag = 'happy',         tooltip = 'Happy, cheerful tone.' },
      { tag = 'sad',           tooltip = 'Sad, downcast.' },
      { tag = 'angry',         tooltip = 'Angry, agitated.' },
      { tag = 'excited',       tooltip = 'Excited, enthusiastic.' },
      { tag = 'nervous',       tooltip = 'Nervous, uncertain.' },
      { tag = 'curious',       tooltip = 'Curious, inquisitive.' },
      { tag = 'sarcastic',     tooltip = 'Sarcastic.' },
      { tag = 'confident',     tooltip = 'Confident.' },
      { tag = 'hesitant',      tooltip = 'Hesitant, wavering.' },
      { tag = 'regretful',     tooltip = 'Regretful.' },
      { tag = 'mischievous',   tooltip = 'Mischievous, playful.' },
      { tag = 'calm',          tooltip = 'Calm, composed.' },
      { tag = 'melancholic',   tooltip = 'Melancholic, reflective.' },
      { tag = 'fearful',       tooltip = 'Fearful.' },
      { tag = 'tender',        tooltip = 'Tender, gentle.' },
      { tag = 'playful',       tooltip = 'Playful, jocular.' },
    },
  },
  {
    name = 'Delivery',
    expanded_default = false,
    tags = {
      { tag = 'whispers',            tooltip = 'Whispering.' },
      { tag = 'shouts',              tooltip = 'Shouting.' },
      { tag = 'softly',              tooltip = 'Softly, gently.' },
      { tag = 'singing',             tooltip = 'Singing.' },
      { tag = 'robotic',             tooltip = 'Robotic voice.' },
      { tag = 'storytelling tone',   tooltip = 'Storytelling / narration tone.' },
      { tag = 'documentary style',   tooltip = 'Documentary style.' },
      { tag = 'conversational tone', tooltip = 'Conversational tone.' },
      { tag = 'dramatic',            tooltip = 'Dramatic delivery.' },
      { tag = 'monotone',            tooltip = 'Monotone, no emotion.' },
    },
  },
  {
    name = 'Non-verbal',
    expanded_default = false,
    tags = {
      { tag = 'laughs',        tooltip = 'Laughter.' },
      { tag = 'chuckles',      tooltip = 'Soft, short laugh.' },
      { tag = 'giggles',       tooltip = 'Giggle.' },
      { tag = 'sighs',         tooltip = 'Sigh.' },
      { tag = 'coughs',        tooltip = 'Cough.' },
      { tag = 'gasps',         tooltip = 'Gasp of surprise.' },
      { tag = 'snorts',        tooltip = 'Snort.' },
      { tag = 'crying',        tooltip = 'Crying.' },
      { tag = 'clears throat', tooltip = 'Throat clearing.' },
      { tag = 'yawning',       tooltip = 'Yawning.' },
      { tag = 'nervous laugh', tooltip = 'Nervous laugh.' },
      { tag = 'evil laugh',    tooltip = 'Evil laugh.' },
    },
  },
  {
    name = 'SFX',
    expanded_default = false,
    experimental_note = 'Experimental — hit-or-miss. Try Variants ×3 with Stability = Creative for reliable output. Add narrative context around the tag (e.g. "The crowd erupted [applause]") for best results.',
    tags = {
      { tag = 'applause',        tooltip = 'Applause.' },
      { tag = 'gunshot',         tooltip = 'Gunshot.' },
      { tag = 'explosion',       tooltip = 'Explosion.' },
      { tag = 'footsteps',       tooltip = 'Footsteps.' },
      { tag = 'leaves rustling', tooltip = 'Leaves rustling.' },
      { tag = 'wind chimes',     tooltip = 'Wind chimes.' },
      { tag = 'thunderstorm',    tooltip = 'Thunderstorm.' },
      { tag = 'telephone rings', tooltip = 'Telephone ringing.' },
    },
  },
  {
    name = 'Accent',
    expanded_default = false,
    tags = {
      { tag = 'strong British accent',  tooltip = 'Strong British accent.' },
      { tag = 'strong American accent', tooltip = 'Strong American accent.' },
      { tag = 'strong French accent',   tooltip = 'Strong French accent.' },
      { tag = 'strong Italian accent',  tooltip = 'Strong Italian accent.' },
      { tag = 'strong German accent',   tooltip = 'Strong German accent.' },
      { tag = 'strong Spanish accent',  tooltip = 'Strong Spanish accent.' },
      { tag = 'Polish accent',          tooltip = 'Polish accent.' },
    },
  },
  {
    name = 'Body state',
    expanded_default = false,
    experimental_note = 'May be inconsistent. Best with expressive voices + Variants ×3.',
    tags = {
      { tag = 'breathing heavily', tooltip = 'Breathing heavily.' },
      { tag = 'shivering',         tooltip = 'Shivering (cold / fear).' },
      { tag = 'panting',           tooltip = 'Panting.' },
      { tag = 'trembling voice',   tooltip = 'Trembling voice.' },
    },
  },
  {
    name = 'Narrative',
    expanded_default = false,
    tags = {
      { tag = 'dramatic pause',  tooltip = 'Dramatic pause.' },
      { tag = 'inner monologue', tooltip = 'Inner monologue.' },
      { tag = 'flashback tone',  tooltip = 'Flashback tone.' },
    },
  },
}

----------------------------------------------------------------------------
-- Insert tag at end of current text. ImGui InputTextMultiline w ReaImGui Lua
-- API nie udostępnia kursora — append-end z space prefix gdy non-empty jest
-- najprostszy reliable approach. User może później manually drag tag w żądane
-- miejsce w textarea (REAPER InputText pozwala na edit po kliknięciu).
----------------------------------------------------------------------------
function M.insert_tag(current_text, tag)
  local txt = current_text or ''
  local prefix = ''
  if txt ~= '' then
    local last = txt:sub(-1)
    if last ~= ' ' and last ~= '\n' and last ~= '\t' then
      prefix = ' '
    end
  end
  return txt .. prefix .. '[' .. tag .. '] '
end

----------------------------------------------------------------------------
-- W3 UI/UX (2026-06-10): case-insensitive search po nazwie tagu + tooltipie.
-- Palette pokazuje płaską listę trafień zamiast rozwijania kategorii ręcznie.
-- Returns: array of { tag, tooltip, cat } (pusty dla pustego query).
----------------------------------------------------------------------------
function M.search(query)
  local q = (query or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
  local out = {}
  if q == '' then return out end
  for _, cat in ipairs(M.CATEGORIES) do
    for _, t in ipairs(cat.tags) do
      local hay = (t.tag .. ' ' .. (t.tooltip or '')):lower()
      if hay:find(q, 1, true) then
        out[#out + 1] = { tag = t.tag, tooltip = t.tooltip, cat = cat.name }
      end
    end
  end
  return out
end

return M

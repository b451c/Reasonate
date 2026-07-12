-- modules/repair_splicer.lua
--
-- NS-F: precision splice engine for Repair mode (Descript-like word editing).
--
-- KEY DIFFERENCES vs splice.lua (Phase 11 legacy):
--   1. lead_sil / trail_sil pobierane Z forced_align result (deterministic
--      milisecond precision), NIE z threshold-based peak scan.
--      → eliminuje BUG #2 "cut beginning/end of replacement word"
--      (threshold -38dB myli soft phonemes "s/f/k/p/m/n" z ciszą).
--   2. F_overlap = lead_sil (NIE capped at 30ms).
--      → eliminuje BUG #1 "fragment poprzedniego słowa" (capping
--      powodował że pozostałe 30-70ms overlap'u grało na pełnej głośności).
--   3. Fallback graceful gdy forced_align unavailable:
--      → 20ms anti-click crossfade (AD8) zamiast lead_sil detection.
--
-- Layout invariant (Phase 11 5c preserved):
--   new_item: D_STARTOFFS=0, D_LENGTH=phrase_len, D_POSITION=t_left - lead_sil
--   Full TTS source preserved → user może drag krawędzi w REAPER manual.
--
-- Niezmienniki:
--   #2 source NIGDY modyfikowany audio (SplitMediaItem tworzy references,
--      nie modyfikuje pliku na dysku)
--   #3 main thread (defer)
--   #4 Undo block

local cfg = require 'modules.config'

local M = {}

local PEXT_NAMESPACE = 'P_EXT:Reasonate.'
local MIN_FADE       = 0.008      -- 8ms anti-click safety floor
local DEFAULT_FALLBACK_CROSSFADE = 0.020   -- 20ms fallback gdy alignment unavailable
local RMS_VOICED_THRESHOLD       = 0.012   -- ~-38dB linear; below = silence (skip w RMS measure)
local RMS_SOURCE_LOOKBACK_SECS   = 1.0     -- mierzymy ostatnie 1.0s voiced przed audio_start
-- Asymmetric clamps (2026-05-16): boost capped tightly bo TTS phrase-wide RMS
-- jest biased low przez inter-word pauses → over-boost ("za głośno" reports
-- correlate z gain ≥+3dB w live data). Attenuate zostaje pełne — TTS-louder
-- cases bezpieczniej tłumić niż wzmocnić. Trade-off documented w DEVIATIONS.
local VOLUME_BOOST_CLAMP_DB      = 2.0     -- max +dB boost przy LEGACY phrase-wide
                                           -- measurement (apples-to-gruszki bias →
                                           -- ciasny bezpiecznik; patrz DEVIATIONS)
local VOLUME_BOOST_CLAMP_ALIGNED_DB = 8.0  -- max +dB boost przy word-aligned
                                           -- measurement (W1.1 2026-06-10, user OK:
                                           -- pomiar 1:1 tych samych słów → wiarygodny,
                                           -- clamp +2 głodził głośne źródła "za cicho" ×2)
local VOLUME_ATTEN_CLAMP_DB      = 12.0    -- max -dB attenuate (TTS louder than source)

-- Diagnostic flag — dane przy "wstawia za głośne" / "za cicho" reportach.
-- Console line per edit z src_db / tts_db / applied gain. M0-3 (audit
-- 2026-07): config-gated (Settings → General → "Diagnostic logging",
-- default OFF); odczyt per edit — zero kosztu w hot loop.
local function VOLUME_DEBUG() return cfg.get_debug_logging() end

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
local function set_pext(item, key, value)
  reaper.GetSetMediaItemInfo_String(item, PEXT_NAMESPACE .. key,
    tostring(value or ''), true)
end

local function set_iv(item, key, value)
  reaper.SetMediaItemInfo_Value(item, key, value)
end

local function get_iv(item, key)
  return reaper.GetMediaItemInfo_Value(item, key)
end

local function item_guid(item)
  local _, g = reaper.GetSetMediaItemInfo_String(item, 'GUID', '', false)
  return g
end

-- M5-9c (user decision 2026-07-11): opcjonalny ripple na WSZYSTKICH trackach
-- (default OFF = tylko track źródłowy). Items z pozycją > threshold na innych
-- trackach przesuwane o shift — muzyka/SFX pod dialogiem trzymają synchron.
local function ripple_other_tracks(src_track, threshold_pos, shift)
  if not cfg.get_repair_ripple_all_tracks() then return end
  if math.abs(shift) < 0.001 then return end
  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    if tr and tr ~= src_track then
      for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, i)
        local p = get_iv(it, 'D_POSITION')
        if p > threshold_pos - 0.001 then
          set_iv(it, 'D_POSITION', p + shift)
        end
      end
    end
  end
end

----------------------------------------------------------------------------
-- RMS volume measurement w voiced regions (M1.5).
--
-- Per PCM_Source_GetPeaks layout: bufor ma `numsamples*nch` MAX values potem
-- `numsamples*nch` MIN values (per KNOWN-ISSUES.md "PCM_Source_GetPeaks buffer
-- layout — interleaved MAX, then MIN, then EXTRA"). Indexing 1-based.
--
-- Algorytm: scan window, dla każdego sample frame compute frame_max (max
-- abs(max), abs(min) across channels). Gdy > threshold → voiced, include w
-- RMS. Sumuj kwadraty samples, dziel przez count, sqrt → RMS linear.
-- Convert do dB: 20*log10(rms).
--
-- 2026-05-16 (B fix attempt #1 reverted): tried median(sq) zamiast mean(sq)
-- — wrong hypothesis. Median underestimuje perceived loudness dla skewed-low
-- distributions (TTS phrase = dużo soft frames + few peaks → median pulled
-- DOWN). RMS poprawnie weight'uje peaks przez kwadratowy emphasis.
-- Mean retained. Alternative fix path dla "za głośno" reports = asymmetric
-- clamp lub TTS measurement nad change-word only (root cause TBD).
--
-- Zwraca: rms_db (number) lub nil gdy żadnych voiced samples lub peak API fail.
----------------------------------------------------------------------------
local function measure_rms_voiced(pcm_src, start_sec, end_sec, threshold)
  if not pcm_src then return nil end
  threshold = threshold or RMS_VOICED_THRESHOLD
  local nch = reaper.GetMediaSourceNumChannels and reaper.GetMediaSourceNumChannels(pcm_src) or 1
  if nch <= 0 then nch = 1 end
  local len = reaper.GetMediaSourceLength(pcm_src) or 0
  start_sec = math.max(0, start_sec or 0)
  end_sec   = math.min(len, end_sec or len)
  if end_sec <= start_sec then return nil end

  local peakrate = 1000   -- 1ms resolution
  local n = math.floor((end_sec - start_sec) * peakrate)
  if n <= 0 then return nil end

  local buf = reaper.new_array(n * nch * 2)
  buf.clear()
  local rv = reaper.PCM_Source_GetPeaks(pcm_src, peakrate, start_sec, nch, n, 0, buf)
  if not rv or rv == 0 then return nil end

  local max_off = 0
  local min_off = n * nch
  local sum_sq = 0
  local cnt = 0
  for i = 0, n - 1 do
    local frame_max = 0
    for c = 0, nch - 1 do
      local mx = math.abs(buf[1 + max_off + i * nch + c] or 0)
      local mn = math.abs(buf[1 + min_off + i * nch + c] or 0)
      if mx > frame_max then frame_max = mx end
      if mn > frame_max then frame_max = mn end
    end
    if frame_max > threshold then
      sum_sq = sum_sq + frame_max * frame_max
      cnt = cnt + 1
    end
  end
  if cnt == 0 then return nil end
  local rms_linear = math.sqrt(sum_sq / cnt)
  if rms_linear <= 0 then return nil end
  return 20 * math.log(rms_linear, 10)
end

----------------------------------------------------------------------------
-- ensure_peaks(pcm_src) — synchronicznie dobudowuje peakfile gdy brakuje.
--
-- I4 fix (2026-06-10, live-evidence "znowu"→"nowu"): PCM_Source_BuildPeaks
-- (src, 0) tylko ROZPOCZYNA budowę (PeaksBuild_Begin per SDK); bez pompowania
-- mode=1 peaki nie powstają w tej samej klatce → GetPeaks zwraca 0 →
-- akustyczny dobór cięcia ślepy na świeży TTS mp3 (logi `tts rms=n/a`) ORAZ
-- na source będący wcześniejszą wklejką (`src rms=n/a`) → cięcie pauzy weszło
-- w spóźniony (forced_align) onset /z/. TTS ma sekundy audio — pętla kończy
-- się w pojedynczych iteracjach; cap broni klatkę przy długim pliku (wtedy
-- scany gracefully fallbackują jak dotąd).
----------------------------------------------------------------------------
local function ensure_peaks(pcm_src)
  if not pcm_src or not reaper.PCM_Source_BuildPeaks then return end
  if reaper.PCM_Source_BuildPeaks(pcm_src, 0) == 0 then return end
  for _ = 1, 500 do
    if reaper.PCM_Source_BuildPeaks(pcm_src, 1) == 0 then break end
  end
  reaper.PCM_Source_BuildPeaks(pcm_src, 2)
end

----------------------------------------------------------------------------
-- find_quietest_window(pcm_src, t_start, t_end, window_secs) → center_t, rms
--
-- Acoustic onset detection: scan PCM peaks (1ms resolution) w [t_start, t_end],
-- znajdź sliding window of window_secs z minimum sum-of-squares energy.
-- Returns center time of that window + linear RMS level.
--
-- Use cases:
--   1. Pause-mode refinement w find_pause_blend_point — picks precise cut time
--      within silence gap (replaces bias factor midpoint).
--   2. Hard-stop letter candidate scoring — measure RMS w crossfade window
--      around proposed cut, pick acoustically quietest candidate (replaces
--      "always furthest" heuristic, eliminuje konflikt między testami).
--
-- Returns nil gdy: pcm_src missing, range narrower niż window+5ms slack,
-- peaks API fail. Caller falls back to prior heuristic.
----------------------------------------------------------------------------
local function find_quietest_window(pcm_src, t_start, t_end, window_secs)
  if not pcm_src then return nil end
  window_secs = window_secs or 0.030
  local len = reaper.GetMediaSourceLength(pcm_src) or 0
  t_start = math.max(0, t_start or 0)
  t_end   = math.min(len, t_end or len)
  if t_end - t_start < window_secs + 0.005 then return nil end

  local nch = reaper.GetMediaSourceNumChannels(pcm_src) or 1
  if nch <= 0 then nch = 1 end
  local peakrate = 1000
  local n = math.floor((t_end - t_start) * peakrate)
  if n <= 0 then return nil end

  local buf = reaper.new_array(n * nch * 2)
  buf.clear()
  local rv = reaper.PCM_Source_GetPeaks(pcm_src, peakrate, t_start, nch, n, 0, buf)
  if not rv or rv == 0 then return nil end

  -- Build per-frame max(abs) envelope from interleaved MAX,MIN peaks
  local max_off = 0
  local min_off = n * nch
  local env = {}
  for i = 0, n - 1 do
    local frame_max = 0
    for c = 0, nch - 1 do
      local mx = math.abs(buf[1 + max_off + i * nch + c] or 0)
      local mn = math.abs(buf[1 + min_off + i * nch + c] or 0)
      if mx > frame_max then frame_max = mx end
      if mn > frame_max then frame_max = mn end
    end
    env[i + 1] = frame_max
  end

  local window_samples = math.floor(window_secs * peakrate)
  if window_samples <= 0 or window_samples > n then return nil end

  -- Rolling sum-of-squares; O(n) total
  local running_sum = 0
  for i = 1, window_samples do
    running_sum = running_sum + env[i] * env[i]
  end
  local best_sum = running_sum
  local best_start = 1
  for i = window_samples + 1, n do
    running_sum = running_sum
      + env[i] * env[i]
      - env[i - window_samples] * env[i - window_samples]
    if running_sum < best_sum then
      best_sum = running_sum
      best_start = i - window_samples + 1
    end
  end

  local center_t = t_start + (best_start + window_samples / 2 - 1) / peakrate
  local rms_linear = math.sqrt(best_sum / window_samples)
  return center_t, rms_linear
end

----------------------------------------------------------------------------
-- measure_rms_linear(pcm_src, t_start, t_end) → rms_linear or nil
--
-- Quick fixed-window RMS measurement (no sliding, no voicing threshold).
-- Returns linear RMS over [t_start, t_end] z PCM_Source_GetPeaks (1ms resolution).
-- Use case: hard-stop letter candidate scoring — measure RMS at proposed
-- splice point dla każdego candidate, compare to pick acoustically quietest.
--
-- Differs from measure_rms_voiced: no -38dB voicing threshold (we want raw
-- amplitude AT cut point), returns linear (small numbers easier dla ratio
-- comparison niż dB).
-- Differs from find_quietest_window: fixed range, no sliding scan (caller
-- specifies exact window of interest).
--
-- Returns nil gdy: pcm_src missing, peaks API fail (np. peakfile not yet
-- built dla fresh TTS mp3 — common edge case na first edit cycle).
----------------------------------------------------------------------------
local function measure_rms_linear(pcm_src, t_start, t_end)
  if not pcm_src then return nil end
  local len = reaper.GetMediaSourceLength(pcm_src) or 0
  t_start = math.max(0, t_start or 0)
  t_end   = math.min(len, t_end or len)
  if t_end <= t_start then return nil end

  local nch = reaper.GetMediaSourceNumChannels(pcm_src) or 1
  if nch <= 0 then nch = 1 end
  local peakrate = 1000
  local n = math.floor((t_end - t_start) * peakrate)
  if n <= 0 then return nil end

  local buf = reaper.new_array(n * nch * 2)
  buf.clear()
  local rv = reaper.PCM_Source_GetPeaks(pcm_src, peakrate, t_start, nch, n, 0, buf)
  if not rv or rv == 0 then return nil end

  local max_off = 0
  local min_off = n * nch
  local sum_sq = 0
  for i = 0, n - 1 do
    local frame_max = 0
    for c = 0, nch - 1 do
      local mx = math.abs(buf[1 + max_off + i * nch + c] or 0)
      local mn = math.abs(buf[1 + min_off + i * nch + c] or 0)
      if mx > frame_max then frame_max = mx end
      if mn > frame_max then frame_max = mn end
    end
    sum_sq = sum_sq + frame_max * frame_max
  end
  return math.sqrt(sum_sq / n)
end

----------------------------------------------------------------------------
-- Compute volume offset (dB) source → TTS dla loudness matching.
--
-- Source measurement: ostatnie RMS_SOURCE_LOOKBACK_SECS przed audio_start
-- w source media. Tylko voiced (skip silence) — chcemy dopasować TTS do
-- average voice level, nie do silence-padded RMS.
--
-- TTS measurement: voiced region (po lead_sil, przed trail_sil).
--
-- Returns: gain_db (asymmetric clamp: +VOLUME_BOOST_CLAMP_DB / -VOLUME_ATTEN_CLAMP_DB)
-- lub nil gdy measurement failed (caller fallback do 1.0 = no adjustment).
----------------------------------------------------------------------------
local function compute_volume_gain_db(source_pcm_src, audio_start_sec,
                                       tts_pcm_src, lead_sil, trail_sil, phrase_len)
  -- Source RMS: lookback od audio_start
  local src_start = math.max(0, audio_start_sec - RMS_SOURCE_LOOKBACK_SECS)
  local src_end   = audio_start_sec
  local source_rms_db = measure_rms_voiced(source_pcm_src, src_start, src_end)
  if not source_rms_db then
    -- Fallback: try wider window jeśli zero voiced samples (e.g., start of recording)
    src_start = math.max(0, audio_start_sec - 3.0)
    source_rms_db = measure_rms_voiced(source_pcm_src, src_start, src_end)
  end

  -- TTS RMS: voiced region between lead_sil i trail_sil
  local tts_start = lead_sil or 0
  local tts_end   = math.max(tts_start + 0.05, phrase_len - (trail_sil or 0))
  local tts_rms_db = measure_rms_voiced(tts_pcm_src, tts_start, tts_end)

  if not source_rms_db or not tts_rms_db then return nil end

  local gain_db = source_rms_db - tts_rms_db
  -- Asymmetric clamps: boost +2dB max, attenuate -12dB max
  if gain_db >  VOLUME_BOOST_CLAMP_DB then gain_db =  VOLUME_BOOST_CLAMP_DB end
  if gain_db < -VOLUME_ATTEN_CLAMP_DB then gain_db = -VOLUME_ATTEN_CLAMP_DB end
  return gain_db, source_rms_db, tts_rms_db
end

----------------------------------------------------------------------------
-- Extract lead_sil / trail_sil z forced_align result.
-- forced_align response: { words: [{text, start, end, loss}], characters: [...] }
-- lead_sil  = words[1].start            (czas do pierwszego słowa)
-- trail_sil = audio_len - words[N].end  (czas po ostatnim słowie)
----------------------------------------------------------------------------
local function lead_trail_from_alignment(alignment, audio_len)
  if not alignment or type(alignment.words) ~= 'table' then return nil, nil end
  local words = alignment.words
  if #words == 0 then return nil, nil end
  local first = words[1]
  local last  = words[#words]
  local lead  = first.start
  local trail = nil
  if last['end'] and audio_len then
    trail = audio_len - last['end']
  end
  if lead and lead < 0 then lead = 0 end
  if trail and trail < 0 then trail = 0 end
  return lead, trail
end

----------------------------------------------------------------------------
-- M.splice_phrase(source_item, phrase_audio_path, audio_start_sec, audio_end_sec,
--                 alignment, opts)
--
-- Parameters:
--   source_item       — REAPER MediaItem (source containing target audio)
--   phrase_audio_path — path do wygenerowanego TTS mp3
--   audio_start_sec   — pozycja w SOURCE MEDIA (sec from file start) — początek
--                       zaznaczenia do podmiany
--   audio_end_sec     — pozycja w SOURCE MEDIA — koniec zaznaczenia
--   alignment         — forced_align result z TTS audio (lub nil = fallback)
--                       { words: [{text, start, end, loss}], characters: [...] }
--   opts:
--     fallback_crossfade_secs (default 0.020) — fade length gdy alignment nil
--     repair_metadata = { phrase_text, voice_id, voice_source, seed, from_text }
--     shift_downstream (default false)
--     stretch_playrate (0 < r ≤ 1, default 1) — I9-narrow élastique slow-down
--
-- Returns: { ok, new_item, left_item, right_item, phrase_len, gap_len,
--            shifted_secs, lead_silence_secs, trail_silence_secs,
--            left_overlap_secs, right_overlap_secs, alignment_used, err }
----------------------------------------------------------------------------
function M.splice_phrase(source_item, phrase_audio_path, audio_start_sec, audio_end_sec, alignment, opts)
  opts = opts or {}
  if not source_item then return { ok = false, err = 'nil source_item' } end
  if not phrase_audio_path or phrase_audio_path == '' then
    return { ok = false, err = 'empty phrase_audio_path' }
  end
  if not audio_start_sec or not audio_end_sec or audio_end_sec <= audio_start_sec then
    return { ok = false, err = 'invalid audio_start/end' }
  end

  -- Read item geometry
  local item_pos  = get_iv(source_item, 'D_POSITION')
  local item_len  = get_iv(source_item, 'D_LENGTH')
  local take = reaper.GetActiveTake(source_item)
  if not take or reaper.TakeIsMIDI(take) then
    return { ok = false, err = 'item has no audio take' }
  end
  local playrate  = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if playrate <= 0 then playrate = 1.0 end
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')

  local item_audio_lo = item_offs
  local item_audio_hi = item_offs + item_len * playrate

  if audio_start_sec < item_audio_lo - 0.001 or audio_end_sec > item_audio_hi + 0.001 then
    return { ok = false, err = ('phrase boundary [%.3f..%.3f] outside item audio range [%.3f..%.3f]'):format(
      audio_start_sec, audio_end_sec, item_audio_lo, item_audio_hi) }
  end

  -- Map source-audio time → timeline time
  local t_left  = item_pos + (audio_start_sec - item_offs) / playrate
  local t_right = item_pos + (audio_end_sec   - item_offs) / playrate

  if t_right - t_left < 0.005 then
    return { ok = false, err = 'phrase span too short (<5ms)' }
  end

  local track = reaper.GetMediaItemTrack(source_item)
  if not track then return { ok = false, err = 'item has no track' } end

  -- Load TTS audio
  local phrase_src = reaper.PCM_Source_CreateFromFile(phrase_audio_path)
  if not phrase_src then
    return { ok = false, err = 'PCM_Source_CreateFromFile failed: ' .. phrase_audio_path }
  end
  local phrase_len = reaper.GetMediaSourceLength(phrase_src)
  if not phrase_len or phrase_len <= 0 then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'phrase audio has zero length' }
  end

  -- I4 fix: peaki gotowe synchronicznie (volume match czyta GetPeaks z TTS).
  ensure_peaks(phrase_src)

  -- ====== KEY DIFFERENCE vs splice.lua: lead_sil/trail_sil z forced_align ======
  --
  -- Forced alignment daje DETERMINISTYCZNE word boundaries z dokładnością ms.
  -- Threshold-based peak scan (legacy splice.lua) myli soft phonemes (s/f/k/p/m/n)
  -- z ciszą i wycina je przez fade → cut beginning/end of replacement.
  -- Forced align nie ma tego problemu.
  --
  -- Fallback: gdy alignment unavailable (forced_align failed or skipped),
  -- użyj 20ms anti-click crossfade (AD8) zamiast lead/trail detection.

  local lead_sil, trail_sil = lead_trail_from_alignment(alignment, phrase_len)
  local fallback_xf = opts.fallback_crossfade_secs or DEFAULT_FALLBACK_CROSSFADE
  local alignment_used = (lead_sil ~= nil and trail_sil ~= nil)

  if not alignment_used then
    lead_sil  = fallback_xf
    trail_sil = fallback_xf
  end

  -- Sanity clamps
  lead_sil  = math.max(0, math.min(lead_sil  or 0, phrase_len * 0.5))
  trail_sil = math.max(0, math.min(trail_sil or 0, phrase_len * 0.5))

  -- I9-narrow (W1, USER-APPROVED — DEVIATIONS 2026-06-10): łagodny élastique
  -- stretch wklejki gdy tempo clamp-floor nie domknął tempa (r < 1 → TTS gra
  -- wolniej, pitch preserved). Wielkości TTS w domenie TIMELINE = source / r;
  -- przy r=1 (brak flagi) wszystkie wzory redukują się do dotychczasowych.
  local stretch_r = tonumber(opts.stretch_playrate) or 1.0
  if stretch_r <= 0 or stretch_r > 1.0 then stretch_r = 1.0 end
  local lead_tl   = lead_sil   / stretch_r
  local trail_tl  = trail_sil  / stretch_r
  local phrase_tl = phrase_len / stretch_r

  local source_guid = item_guid(source_item)

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- 1. Split source at t_left → source_item ends at t_left, returns middle
  local middle = nil
  local left_item = source_item
  if t_left > item_pos + 0.001 then
    middle = reaper.SplitMediaItem(source_item, t_left)
  else
    left_item = nil
    middle = source_item
  end

  if not middle then
    reaper.Undo_EndBlock('Reasonate: Repair splice (failed)', -1)
    reaper.PreventUIRefresh(-1)
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'SplitMediaItem failed at t_left' }
  end

  -- 2. Split middle at t_right → returns right_item
  local right_item = nil
  local item_end = item_pos + item_len
  if t_right < item_end - 0.001 then
    right_item = reaper.SplitMediaItem(middle, t_right)
    if not right_item then
      reaper.Undo_EndBlock('Reasonate: Repair splice (failed)', -1)
      reaper.PreventUIRefresh(-1)
      if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
      return { ok = false, err = 'SplitMediaItem failed at t_right' }
    end
  end

  -- 3. Delete middle slice
  reaper.DeleteTrackMediaItem(track, middle)

  -- 4. Create new item z TTS audio.
  -- Full-source layout: D_STARTOFFS=0, D_LENGTH=phrase_len, D_POSITION=t_left-lead_sil.
  -- Speech onset (gdzie zaczyna się voiced content) trafia DOKŁADNIE w t_left.
  -- User może w REAPER pociągnąć left/right edge — full source visible pod itemem.

  local new_item = reaper.AddMediaItemToTrack(track)
  if not new_item then
    reaper.Undo_EndBlock('Reasonate: Repair splice (failed)', -1)
    reaper.PreventUIRefresh(-1)
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'AddMediaItemToTrack failed' }
  end
  local new_take = reaper.AddTakeToMediaItem(new_item)
  reaper.SetMediaItemTake_Source(new_take, phrase_src)

  local new_pos       = t_left - lead_tl
  local new_startoffs = 0
  local new_len       = phrase_tl
  local effective_speech_len = phrase_tl - lead_tl - trail_tl
  if effective_speech_len < 0.001 then effective_speech_len = phrase_tl end

  set_iv(new_item, 'D_POSITION', new_pos)
  set_iv(new_item, 'D_LENGTH',   new_len)
  reaper.SetMediaItemTakeInfo_Value(new_take, 'D_STARTOFFS', new_startoffs)
  reaper.SetMediaItemTakeInfo_Value(new_take, 'D_PLAYRATE',  stretch_r)
  if stretch_r ~= 1.0 then
    -- Preserve pitch przy zmianie playback rate — essential dla mowy
    -- (élastique wg project default; wzorzec dubbing_splicer).
    reaper.SetMediaItemTakeInfo_Value(new_take, 'B_PPITCH', 1)
  end

  -- ====== KEY DIFFERENCE: F_overlap = lead_sil (NOT capped) ======
  --
  -- Legacy splice.lua: F_overlap = max(MIN_FADE, min(crossfade_ms, lead_sil)).
  -- Gdy lead_sil > crossfade_ms (e.g. 60ms > 30ms): overlap region 60ms, ale
  -- fade tylko 30ms → pierwsze 30ms left_itemu na pełnej głośności =
  -- "fragment poprzedniego słowa".
  --
  -- NS-F fix: F_overlap = lead_sil (full overlap region crossfaded). Plus
  -- MIN_FADE = 8ms anti-click safety floor. Bug #1 eliminated.

  -- (Domena timeline — przy stretchu lead/trail na timelinie rosną o 1/r.)
  local F_overlap       = math.max(MIN_FADE, lead_tl)
  local F_right_overlap = math.max(MIN_FADE, trail_tl)

  -- 5. Length adapt right_item — shift gdy TTS speech end != original gap end.
  -- M2 v2 extension: support negative shift (TTS shorter than original gap; e.g.
  -- Delete via context regen → TTS = "<ctx_before> <ctx_after>" jest krótsze niż
  -- "<ctx_before> <deleted> <ctx_after>"). shift_downstream przesuwa items LEFT lub
  -- RIGHT w zależności od znaku, żeby downstream timeline kontynuował bez gap'a.
  local gap_len = t_right - t_left
  local shifted_secs = 0
  if right_item then
    local right_pos = get_iv(right_item, 'D_POSITION')
    local new_speech_end = t_left + effective_speech_len
    local shift = new_speech_end - t_right
    if math.abs(shift) > 0.001 then
      shifted_secs = shift
      set_iv(right_item, 'D_POSITION', right_pos + shift)
      if opts.shift_downstream then
        local n = reaper.CountTrackMediaItems(track)
        for i = 0, n - 1 do
          local it = reaper.GetTrackMediaItem(track, i)
          if it ~= right_item and it ~= new_item and it ~= left_item then
            local p = get_iv(it, 'D_POSITION')
            if p > right_pos - 0.001 then
              set_iv(it, 'D_POSITION', p + shift)
            end
          end
        end
        ripple_other_tracks(track, right_pos, shift)
      end
    end
  end

  -- 6. Crossfades — overlap regions covered FULL by fade (no gap).
  -- Left side: left_item D_FADEOUTLEN = F_overlap, new_item D_FADEINLEN = F_overlap.
  -- Right side: new_item D_FADEOUTLEN = F_right_overlap, right_item D_FADEINLEN = F_right_overlap.
  if left_item then
    set_iv(left_item, 'D_FADEOUTLEN', F_overlap)
    set_iv(new_item,  'D_FADEINLEN',  F_overlap)
  end
  if right_item then
    set_iv(new_item,   'D_FADEOUTLEN', F_right_overlap)
    set_iv(right_item, 'D_FADEINLEN',  F_right_overlap)
  end

  -- ====== M1.5: RMS volume match (TTS → source level) ======
  --
  -- ElevenLabs TTS jest LUFS-normalized w izolacji. Po splice może wybijać
  -- się głośnością z reszty nagrania (zwłaszcza gdy oryginał ma mocny
  -- compression/dynamics post-mixing). Auto-match w voiced regions z
  -- ±12 dB clamp eliminuje skok głośności bez ryzyka extreme adjustments.
  -- Toggle: cfg.get_repair_auto_volume_match() (default ON).

  local volume_gain_db = 0
  local volume_match_applied = false
  if cfg.get_repair_auto_volume_match() then
    -- Source PCM z active take of source_item (before split nadal valid).
    -- M0-4 (audit 2026-07): left_item or RIGHT_item — nigdy new_item. Przy
    -- splice od 1. słowa (left_item==nil) new_item = take TTS, a TTS nie
    -- jest MIDI, więc fallback niżej był NIEOSIĄGALNY → pomiar "źródła"
    -- na pliku TTS w złej domenie czasu → match cicho nie działał.
    local src_item = left_item or right_item
    local src_take = src_item and reaper.GetActiveTake(src_item) or nil
    -- Drugi stopień: left MIDI/brak take → spróbuj right_item.
    -- Oba nil (selekcja = cały item) → src_take nil → skip matchingu.
    if not src_take or reaper.TakeIsMIDI(src_take) then
      src_take = right_item and reaper.GetActiveTake(right_item) or nil
    end
    if src_take and not reaper.TakeIsMIDI(src_take) then
      local source_pcm = reaper.GetMediaItemTake_Source(src_take)
      if source_pcm then
        local gain_db, src_db, tts_db = compute_volume_gain_db(
          source_pcm, audio_start_sec, phrase_src, lead_sil, trail_sil, phrase_len)
        if VOLUME_DEBUG() then
          reaper.ShowConsoleMsg(('[Reasonate] VOL/phrase src=%s tts=%s gain=%s lookback=%.1fs (mean RMS voiced)\n')
            :format(src_db and ('%.2fdB'):format(src_db) or 'nil',
                    tts_db and ('%.2fdB'):format(tts_db) or 'nil',
                    gain_db and ('%+.2fdB'):format(gain_db) or 'nil',
                    RMS_SOURCE_LOOKBACK_SECS))
        end
        if gain_db then
          volume_gain_db = gain_db
          local linear_gain = 10 ^ (gain_db / 20)
          reaper.SetMediaItemTakeInfo_Value(new_take, 'D_VOL', linear_gain)
          volume_match_applied = true
          set_pext(new_item, 'repair_volume_offset_db', ('%.2f'):format(gain_db))
          set_pext(new_item, 'repair_source_rms_db',    ('%.2f'):format(src_db or 0))
          set_pext(new_item, 'repair_tts_rms_db',       ('%.2f'):format(tts_db or 0))
        end
      end
    end
  end

  -- 7. P_EXT na new_item — repair output marker + metadata
  set_pext(new_item, 'is_repair_output',    '1')
  set_pext(new_item, 'converted',           '1')   -- backward compat z status coloring
  set_pext(new_item, 'repair_mode',         opts.repair_mode or 'replace')
  set_pext(new_item, 'repair_source_item_guid', source_guid or '')
  set_pext(new_item, 'repair_audio_start',  tostring(audio_start_sec))
  set_pext(new_item, 'repair_audio_end',    tostring(audio_end_sec))
  set_pext(new_item, 'repair_created_at',   tostring(os.time()))
  set_pext(new_item, 'repair_alignment_used', alignment_used and '1' or '0')
  set_pext(new_item, 'repair_lead_sil_secs',  ('%.4f'):format(lead_sil))
  set_pext(new_item, 'repair_trail_sil_secs', ('%.4f'):format(trail_sil))
  if stretch_r ~= 1.0 then
    set_pext(new_item, 'repair_stretch_playrate', ('%.4f'):format(stretch_r))
  end
  local meta = opts.repair_metadata or {}
  set_pext(new_item, 'repair_phrase_text',  meta.phrase_text or '')
  set_pext(new_item, 'repair_from_text',    meta.from_text or '')
  set_pext(new_item, 'voice_id',            meta.voice_id    or '')
  set_pext(new_item, 'voice_source',        meta.voice_source or '')
  set_pext(new_item, 'repair_seed',         tostring(meta.seed or 0))

  -- Take name dla audition cycle readability
  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
    ('Repair: %s'):format((meta.phrase_text or 'edit'):sub(1, 40)), true)

  -- 8. Build peaks + force visual refresh wszystkich 3 itemów
  if reaper.PCM_Source_BuildPeaks then
    reaper.PCM_Source_BuildPeaks(phrase_src, 0)
  end
  if left_item  then reaper.UpdateItemInProject(left_item)  end
                       reaper.UpdateItemInProject(new_item)
  if right_item then reaper.UpdateItemInProject(right_item) end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: Repair splice', -1)
  reaper.PreventUIRefresh(-1)

  -- Build peaks dla visible items (background async)
  reaper.Main_OnCommand(40047, 0)   -- "Peaks: Build any missing peaks"

  return {
    ok                   = true,
    new_item             = new_item,
    left_item            = left_item,
    right_item           = right_item,
    phrase_len           = phrase_len,
    gap_len              = gap_len,
    shifted_secs         = shifted_secs,
    lead_silence_secs    = lead_sil,
    trail_silence_secs   = trail_sil,
    left_overlap_secs    = F_overlap,
    right_overlap_secs   = F_right_overlap,
    effective_speech_len = effective_speech_len,
    alignment_used       = alignment_used,
    stretch_playrate     = (stretch_r ~= 1.0) and stretch_r or nil,
    volume_gain_db       = volume_gain_db,
    volume_match_applied = volume_match_applied,
  }
end

----------------------------------------------------------------------------
-- ===== NS-F M2 v3: letter-aligned crossfade splice =====
--
-- Rationale: M2 v2 splice_phrase replaces FULL extended span (context_before
-- + change + context_after) z TTS audio. To zastępuje też oryginalne context
-- words → user słyszy TTS-rendition w głosie klona dla "is a" i "demo of",
-- nawet jeśli te słowa są identyczne semantycznie. User reported: "wkleja sie
-- cala sentecnja".
--
-- Fix v3: blend WEWNĄTRZ immediate context word (closest do zmiany) na
-- konkretnej literze (auto-pick: sonorant preferred). Outer context (dalsze
-- słowa) zostają oryginalne. Innymi słowy:
--   - TTS prompt: wide ("is a SHORT demo of") — dla prosody continuity
--   - TTS audio used: NARROW (od litery w "a" do litery w "demo")
--   - Original audio: kept dla "this is" + first half of "a" + second half
--                     of "demo" + "of for REAPER..."
--   - Crossfade: na konkretnej literze w obu źródłach (te same fonemy w tym
--                samym głosie clone → blend imperceptible)
--
-- Wymaga: TTS alignment AND source alignment (oba z `/v1/forced-alignment` /
-- Scribe characters[]). Bez któregokolwiek → caller route do splice_phrase.

local BLEND_CROSSFADE_SECS = 0.040   -- 40ms default crossfade na blend letter
local MIN_BLEND_LETTER_DUR = 0.030   -- min 30ms letter duration żeby blend miał sens
local MIN_PAUSE_SPLIT_SECS = 0.016   -- 16ms = 2× MIN_FADE — minimum gap dla
                                     -- pause-mode żeby F crossfade fitował bez
                                     -- overrun gap edges. Below 16ms: MIN_FADE
                                     -- 8ms clamp powoduje że F/2 lead-in/out
                                     -- wchodzi w prev/next word audio (=
                                     -- crossfade catches voice content =
                                     -- artifact, e.g., "demo of my voice/audio"
                                     -- 1ms TTS gap reported live test).
                                     -- Below threshold: fall through to letter
                                     -- mode (fricative/sibilant scan w ctx).
local ACOUSTIC_SCAN_WINDOW_SECS = 0.030  -- 30ms PCM window dla acoustic onset
                                         -- detection (find_quietest_window).
                                         -- Mniejsza niż BLEND_CROSSFADE_SECS
                                         -- (40ms) bo zostawia margin na F/2
                                         -- lead-in/out po obu stronach.
-- M0-3 (audit 2026-07): config-gated (Settings → General → "Diagnostic
-- logging", default OFF); odczyt per edit (event-driven), nie per frame.
local function PAUSE_SPLIT_DEBUG() return cfg.get_debug_logging() end

local SONORANT_LETTERS = { m=1, n=1, l=1, r=1, w=1, v=1, z=1, y=1 }
local SIBILANT_LETTERS = { s=1 }    -- "s" unvoiced sibilant — peak noise blend
local FRICATIVE_LETTERS = { f=1, h=1 }  -- unvoiced fricatives — noise blend (jak sibilant
                                        -- ale less peak energy). User feedback: "f" w "for"
                                        -- = correct splice point per intuition (2026-05-15).
local VOWEL_LETTERS    = { a=1, e=1, i=1, o=1, u=1 }
local STOP_LETTERS     = { p=1, b=1, t=1, d=1, k=1, g=1,
                           c=1, x=1, j=1, q=1 }   -- f, h removed (są fricatives)

----------------------------------------------------------------------------
-- normalize_text(s) — lowercase + trim + strip ASCII punctuation. Used dla
-- word text matching cross-API (Scribe vs forced_align mogą różnie traktować
-- comma/period attachment).
----------------------------------------------------------------------------
local function normalize_text(s)
  if not s then return '' end
  s = tostring(s):lower():gsub('^%s+', ''):gsub('%s+$', '')
  s = s:gsub('[%p]', '')   -- strip wszystkie ASCII punct
  return s
end

----------------------------------------------------------------------------
-- count_words(text) — count whitespace-separated tokens (po normalizacji).
-- Empty text → 0. Used dla TTS word position math gdy inserted_text może być
-- multi-word (e.g., "very fast" → 2 words).
----------------------------------------------------------------------------
local function count_words(text)
  if not text or text == '' then return 0 end
  local n = 0
  for _ in tostring(text):gmatch('%S+') do n = n + 1 end
  return n
end

----------------------------------------------------------------------------
-- tts_nth_nonspace(words, n) → idx, word
-- TTS prompt forced_align zwraca whitespace tokens jako osobne entries w words[]
-- (np. ["is", " ", "a", " ", "short"]). Pozycja "n-tego prompt-word" wymaga
-- skipping whitespace. Findujemy n-te słowo z non-empty non-whitespace text.
-- Module-level dla reuse w pause-viability detection w splice_phrase_blended
-- (was originally local inside find_pause_blend_point).
----------------------------------------------------------------------------
local function tts_nth_nonspace(words, n)
  if not words or not n or n < 1 then return nil end
  local count = 0
  for i, w in ipairs(words) do
    if w.text and w.text:match('%S') then
      count = count + 1
      if count == n then return i, w end
    end
  end
  return nil
end

----------------------------------------------------------------------------
-- measure_ctx_rms_aligned(source_pcm, words_tbl, ctx, phrase_src,
--                         tts_alignment, inserted_n) → src_db, tts_db | nil
--
-- W1.1 (2026-06-10, user OK): word-aligned volume measurement. Porównuje
-- voiced RMS TYCH SAMYCH słów kontekstu w source i w TTS render (1:1 — ten
-- sam tekst, ten sam klon głosu) zamiast "1s źródła przed cięciem vs średnia
-- całej frazy TTS". Live-test pokazał, że stary pomiar + clamp +2dB głodzi
-- głośne źródła (potrzebne +8dB → wstawka ~6dB za cicha, user-confirmed ×2).
--
-- Source side: bloki context_before/after z words_tbl (source-file time).
-- TTS side: first n_before + last n_after non-space tokens z tts_alignment
-- (TTS-file time). Tokenization guard ±1 (mirror compute_tts_observed_pace);
-- mismatch / brak pomiaru → nil → caller fallback do legacy measurement
-- z ciasnym clampem. Per-side blok liczony TYLKO gdy zmierzone OBA końce
-- (source i TTS) — bez asymetrycznych porównań.
----------------------------------------------------------------------------
local function measure_ctx_rms_aligned(source_pcm, words_tbl, ctx, phrase_src,
                                       tts_alignment, inserted_n)
  if not (source_pcm and words_tbl and ctx and phrase_src and tts_alignment) then
    return nil
  end
  if type(tts_alignment.words) ~= 'table' then return nil end

  local n_before = math.max(0, (ctx.context_before_hi or 0) - (ctx.context_before_lo or 1) + 1)
  local n_after  = math.max(0, (ctx.context_after_hi  or 0) - (ctx.context_after_lo  or 1) + 1)
  if n_before == 0 and n_after == 0 then return nil end

  local toks = {}
  for _, w in ipairs(tts_alignment.words) do
    if w.text and w.text:match('%S') then toks[#toks + 1] = w end
  end
  local expected = n_before + (inserted_n or 0) + n_after
  if math.abs(#toks - expected) > 1 then return nil end
  if n_before > #toks or n_after > #toks then return nil end

  local function wfield(e, k)
    if not e then return nil end
    local v = e[k]
    if v ~= nil then return tonumber(v) end
    if e.word then return tonumber(e.word[k]) end
    return nil
  end

  local src_vals, tts_vals = {}, {}

  if n_before > 0 then
    local s0 = wfield(words_tbl[ctx.context_before_lo], 'start')
    local s1 = wfield(words_tbl[ctx.context_before_hi], 'end')
    local t0 = tonumber(toks[1].start)
    local t1 = tonumber(toks[n_before]['end'])
    if s0 and s1 and s1 > s0 and t0 and t1 and t1 > t0 then
      local s_db = measure_rms_voiced(source_pcm, s0, s1)
      local t_db = measure_rms_voiced(phrase_src, t0, t1)
      if s_db and t_db then
        src_vals[#src_vals + 1] = s_db
        tts_vals[#tts_vals + 1] = t_db
      end
    end
  end

  if n_after > 0 then
    local s0 = wfield(words_tbl[ctx.context_after_lo], 'start')
    local s1 = wfield(words_tbl[ctx.context_after_hi], 'end')
    local t0 = tonumber(toks[#toks - n_after + 1].start)
    local t1 = tonumber(toks[#toks]['end'])
    if s0 and s1 and s1 > s0 and t0 and t1 and t1 > t0 then
      local s_db = measure_rms_voiced(source_pcm, s0, s1)
      local t_db = measure_rms_voiced(phrase_src, t0, t1)
      if s_db and t_db then
        src_vals[#src_vals + 1] = s_db
        tts_vals[#tts_vals + 1] = t_db
      end
    end
  end

  if #src_vals == 0 then return nil end
  local s_sum, t_sum = 0, 0
  for i = 1, #src_vals do
    s_sum = s_sum + src_vals[i]
    t_sum = t_sum + tts_vals[i]
  end
  return s_sum / #src_vals, t_sum / #tts_vals
end

----------------------------------------------------------------------------
-- get_word_chars(alignment, word_idx) → chars[] z alignment.characters
-- które padają w obrębie alignment.words[word_idx] start/end (10ms tolerancja).
-- Returns nil gdy word/timing missing.
----------------------------------------------------------------------------
local function get_word_chars(alignment, word_idx)
  if not alignment or type(alignment.words) ~= 'table' then return nil end
  if type(alignment.characters) ~= 'table' then return nil end
  local w = alignment.words[word_idx]
  if not w or not w.start or not w['end'] then return nil end
  local lo = w.start - 0.010
  local hi = w['end']  + 0.010
  local out = {}
  for _, ch in ipairs(alignment.characters) do
    local cs = tonumber(ch.start)
    local ce = tonumber(ch['end'])
    if cs and ce and cs >= lo and ce <= hi then
      out[#out + 1] = ch
    end
  end
  return out
end

----------------------------------------------------------------------------
-- auto_pick_blend_letter(chars) → idx_in_chars (1-based) + char_table OR nil
--
-- Score per char:
--   - Sonorant cons (m, n, l, r, w, v, z, y): 100
--   - Vowel (a, e, i, o, u):                   50
--   - Stop/fricative (p, b, t, d, k, g, s, f): 10
--   - Other (z lookup default):                30
--   - Whitespace/punctuation:                  skip
--   - Char duration < MIN_BLEND_LETTER_DUR:    skip (too short to blend)
--   - Position bonus: peak at middle of word (1 - |pos - 0.5| * 2) * 30
----------------------------------------------------------------------------
local function auto_pick_blend_letter(chars)
  if not chars or #chars == 0 then return nil end
  local n = #chars
  local best_idx, best_score = nil, -math.huge
  for i = 1, n do
    local ch = chars[i]
    local text_raw = ch.text or ''
    if text_raw ~= '' and not text_raw:match('^%s+$') and not text_raw:match('^%p+$') then
      local text_lower = text_raw:lower()
      -- Multi-char Unicode (np. diakrytyki) — skip (heuristic fragile)
      if #text_lower == 1 then
        local cs = tonumber(ch.start) or 0
        local ce = tonumber(ch['end']) or 0
        local dur = ce - cs
        -- Per-class MIN_DUR: sibilanty/fricatives są NOISE → crossfade w noise
        -- jest forgiving, krótka dur OK. Pitched letters (vowels/sonorants/stops)
        -- wymagają więcej czasu na smooth crossfade.
        local is_noise_letter = SIBILANT_LETTERS[text_lower] or FRICATIVE_LETTERS[text_lower]
        local min_dur = is_noise_letter and 0.010 or MIN_BLEND_LETTER_DUR
        if dur >= min_dur then
          local base
          local no_pos_bonus = false
          -- Scoring per user feedback (2026-05-15): sonoranty audible (pitch
          -- carries → clone-vs-source mismatch słyszalny). Sibilanty/fricatives
          -- noise-only = perfect blend. Vowels mid (pitch ale sustained).
          if SIBILANT_LETTERS[text_lower] then
            base = 130              -- s — peak noise, always wins
            no_pos_bonus = true     -- /s/ at edge = natural word boundary cut (user pref)
          elseif FRICATIVE_LETTERS[text_lower] then base = 90        -- f, h — noise blend
          elseif VOWEL_LETTERS[text_lower] then base = 50
          elseif SONORANT_LETTERS[text_lower] then base = 30         -- DEMOTED — pitch wobble
          elseif STOP_LETTERS[text_lower]   then base = 10
          else base = 30 end
          -- Position bonus (peak middle, edges penalized) — except sibilants
          local pos_bonus = 0
          if not no_pos_bonus then
            local pos_fraction = (n > 1) and ((i - 1) / (n - 1)) or 0.5
            pos_bonus = 30 * (1 - math.abs(pos_fraction - 0.5) * 2)
          end
          local score = base + pos_bonus
          if score > best_score then
            best_score = score
            best_idx = i
          end
        end
      end
    end
  end
  if not best_idx then return nil end
  return best_idx, chars[best_idx]
end

----------------------------------------------------------------------------
-- find_aligned_word_by_time(alignment, expected_start, expected_text, tol)
--
-- Disambiguates duplicate words w transcrypcie używając source-time proximity.
-- E.g., transkrypt zawierający dwa "in" — text-only search łapie FIRST →
-- może być przed selection range → degenerate splice. Time-based lookup
-- preferuje match closest do expected_start.
--
-- Strategy:
--   1. Try position-based at expected_idx (jeśli supplied): use if text matches
--      AND timing matches w obrębie 0.3s.
--   2. Else: collect all candidates with text match, pick closest by time.
--   3. Tol default 2.0s — generous bo Scribe vs forced_align mogą mieć
--      cumulative drift na długich transcryptach.
--
-- Returns: word_idx + word_table, OR nil.
----------------------------------------------------------------------------
local function find_aligned_word_by_time(alignment, expected_start, expected_text,
                                          preferred_idx, tol)
  if not alignment or type(alignment.words) ~= 'table' then return nil end
  tol = tol or 2.0
  local norm_expected = normalize_text(expected_text)

  -- Position-based first: gdy expected idx ma text match + timing within tight
  -- window, accept od razu (najszybsze + zazwyczaj poprawne). Live-fix
  -- (2026-06-10): preferred_idx to indeks words_tbl (bez spacji), a
  -- alignment.words zawiera tokeny whitespace — mapowanie przez nth-nonspace;
  -- surowy indeks trafiał w spację (zawsze miss) albo przypadkowy token.
  if preferred_idx then
    local raw_idx, w = tts_nth_nonspace(alignment.words, preferred_idx)
    if w then
      local ws = tonumber(w.start)
      if ws and normalize_text(w.text) == norm_expected and expected_start then
        if math.abs(ws - expected_start) <= 0.3 then
          return raw_idx, w
        end
      end
    end
  end

  -- Time-based: collect text-match candidates, pick closest do expected_start.
  if not expected_start then
    -- Brak source-time anchor — fallback do pierwszego text match
    for i, w in ipairs(alignment.words) do
      if normalize_text(w.text) == norm_expected then return i, w end
    end
    return nil
  end

  local best_idx, best_w, best_diff = nil, nil, math.huge
  for i, w in ipairs(alignment.words) do
    if normalize_text(w.text) == norm_expected then
      local ws = tonumber(w.start)
      if ws then
        local diff = math.abs(ws - expected_start)
        if diff < best_diff and diff <= tol then
          best_diff = diff
          best_idx = i
          best_w = w
        end
      end
    end
  end
  return best_idx, best_w
end

----------------------------------------------------------------------------
-- find_pause_blend_point(src_align, tts_align, words_tbl,
--                         src_idx_a, src_idx_b, tts_idx_a, tts_idx_b,
--                         min_gap_secs)
--
-- Detect pause (silence gap) między source_words[src_idx_a].end a
-- source_words[src_idx_b].start, ORAZ między TTS odpowiednikami. Jeśli oba
-- gapy ≥ min_gap_secs → splice w MIDPOINT obu pauz (cięcie w ciszy =
-- niesłyszalne, classic audio editing pattern).
--
-- Source word indices resolved via find_aligned_word_by_time (handle duplicate
-- words w transcrypcie). TTS indices to positions w TTS prompt (predictable
-- order, no disambiguation needed).
--
-- Returns same shape jak compute_blend_point + kind='pause' + src_gap/tts_gap.
-- Returns nil gdy któraś pauza < min_gap_secs lub words missing.
----------------------------------------------------------------------------
local function find_pause_blend_point(src_align, tts_align, words_tbl,
                                       src_idx_a, src_idx_b,
                                       tts_idx_a, tts_idx_b, min_gap_secs,
                                       bias_factor, pcm_opts)
  -- bias_factor: 0..1, fraction od src_a side gdzie cut land. Default 0.5
  -- (midpoint pauzy). Niższy = closer to src_a (away from src_b side), wyższy =
  -- closer to src_b. Used jako fallback gdy acoustic refinement nie zadziała
  -- (pcm_opts nil, gap za krótki dla window, lub peaks API fail).
  -- pcm_opts (optional): { source_pcm, tts_pcm, window_secs } — gdy obecne,
  -- acoustic onset detection refinuje src_t/tts_t do faktycznie najcichszego
  -- momentu w pauzie zamiast biased midpoint.
  bias_factor = bias_factor or 0.5
  if not src_align or not tts_align or not words_tbl then return nil end
  if type(src_align.words) ~= 'table' or type(tts_align.words) ~= 'table' then
    return nil
  end
  if not src_idx_a or not src_idx_b or src_idx_a < 1 or src_idx_b < 1 then
    return nil
  end
  if not tts_idx_a or not tts_idx_b or tts_idx_a < 1 or tts_idx_b < 1 then
    return nil
  end

  -- Resolve source words via time-anchored lookup (duplicate-word safe)
  local wt_a = words_tbl[src_idx_a]
  local wt_b = words_tbl[src_idx_b]
  if not wt_a or not wt_b then
    if PAUSE_SPLIT_DEBUG() then
      reaper.ShowConsoleMsg(('[Repair pause-splice] EARLY-FAIL words_tbl[%d]=%s words_tbl[%d]=%s\n'):format(
        src_idx_a, tostring(wt_a), src_idx_b, tostring(wt_b)))
    end
    return nil
  end
  local _, src_a = find_aligned_word_by_time(src_align,
    tonumber(wt_a.start), wt_a.text, src_idx_a, 2.0)
  local _, src_b = find_aligned_word_by_time(src_align,
    tonumber(wt_b.start), wt_b.text, src_idx_b, 2.0)
  if not src_a or not src_b then
    if PAUSE_SPLIT_DEBUG() then
      reaper.ShowConsoleMsg(('[Repair pause-splice] EARLY-FAIL src lookup: "%s"→%s "%s"→%s\n'):format(
        wt_a.text or '?', tostring(src_a and 'found' or 'nil'),
        wt_b.text or '?', tostring(src_b and 'found' or 'nil')))
    end
    return nil
  end

  -- tts_nth_nonspace lifted do module-level (search above)
  local _, tts_a = tts_nth_nonspace(tts_align.words, tts_idx_a)
  local _, tts_b = tts_nth_nonspace(tts_align.words, tts_idx_b)
  if not tts_a or not tts_b then
    if PAUSE_SPLIT_DEBUG() then
      reaper.ShowConsoleMsg(('[Repair pause-splice] EARLY-FAIL tts non-space lookup: pos=%d→%s pos=%d→%s (total=%d)\n'):format(
        tts_idx_a, tostring(tts_a and tts_a.text or 'nil'),
        tts_idx_b, tostring(tts_b and tts_b.text or 'nil'),
        #tts_align.words))
    end
    return nil
  end

  local src_a_end   = tonumber(src_a['end'])
  local src_b_start = tonumber(src_b.start)
  local tts_a_end   = tonumber(tts_a['end'])
  local tts_b_start = tonumber(tts_b.start)
  if not src_a_end or not src_b_start or not tts_a_end or not tts_b_start then
    return nil
  end

  local src_gap = src_b_start - src_a_end
  local tts_gap = tts_b_start - tts_a_end

  if PAUSE_SPLIT_DEBUG() then
    reaper.ShowConsoleMsg(('[Repair pause-splice] src="%s"→"%s" gap=%.1fms · ' ..
      'tts="%s"→"%s" gap=%.1fms · threshold=%.1fms · bias=%.2f · %s\n'):format(
        src_a.text or '?', src_b.text or '?', src_gap * 1000,
        tts_a.text or '?', tts_b.text or '?', tts_gap * 1000,
        min_gap_secs * 1000, bias_factor,
        (src_gap >= min_gap_secs and tts_gap >= min_gap_secs)
          and 'PAUSE-mode' or 'fallback LETTER'))
  end

  if src_gap < min_gap_secs or tts_gap < min_gap_secs then return nil end

  -- Default: biased midpoint pauzy. F-cap (splice_phrase_blended) uses
  -- src_dur/tts_dur jako gap widths — capping ensures F/2 nie overrun gap.
  local src_t_final = src_a_end + src_gap * bias_factor
  local tts_t_final = tts_a_end + tts_gap * bias_factor

  -- Acoustic refinement: gdy PCM sources provided, scan dla locally quietest
  -- 30ms window w pauzie. Margin = min(src_gap, tts_gap)*0.25 preserves F-cap
  -- invariant (F ≤ min_gap*0.5 → F/2 ≤ min_gap*0.25), więc refined src_t
  -- nigdy nie powoduje crossfade overrun gap edges.
  -- Acoustic refinement: gdy PCM provided, scan dla locally quietest 30ms window.
  -- IMPORTANT: search range restricted to FIRST HALF of gap (closer to prev-word
  -- end) gdy pcm_opts.search_first_half_only=true. Avoids forced_align imprecision
  -- on next-word onset: sibilants (/sh/ /s/ /h/ /f/) reported 50-100ms late by
  -- alignment vs acoustic reality → "quietest moment" w second half could land
  -- INSIDE actual sibilant ramp-up → cut placed in /sh/ → audible artifact w
  -- crossfade (e.g., double-sh "sz short" reported 2026-05-16 EVENING calm→quiet).
  --
  -- Margin = min_gap*0.25 preserves F-cap invariant (F/2 ≤ min_gap*0.25).
  local acoustic_src, acoustic_tts = false, false
  local refined_src_rms, refined_tts_rms = nil, nil
  if pcm_opts then
    local W = pcm_opts.window_secs or ACOUSTIC_SCAN_WINDOW_SECS
    local min_gap = math.min(src_gap, tts_gap)
    local margin = min_gap * 0.25
    local first_half_only = pcm_opts.search_first_half_only

    if pcm_opts.source_pcm then
      local lo = src_a_end + margin
      local hi = first_half_only
        and (src_a_end + src_gap * 0.5)
        or  (src_b_start - margin)
      if hi - lo >= W + 0.005 then
        local t, rms = find_quietest_window(pcm_opts.source_pcm, lo, hi, W)
        if t then
          src_t_final = t
          refined_src_rms = rms
          acoustic_src = true
        end
      end
    end
    if pcm_opts.tts_pcm then
      local lo = tts_a_end + margin
      local hi = first_half_only
        and (tts_a_end + tts_gap * 0.5)
        or  (tts_b_start - margin)
      if hi - lo >= W + 0.005 then
        local t, rms = find_quietest_window(pcm_opts.tts_pcm, lo, hi, W)
        if t then
          tts_t_final = t
          refined_tts_rms = rms
          acoustic_tts = true
        end
      end
    end
    if PAUSE_SPLIT_DEBUG() and (acoustic_src or acoustic_tts) then
      reaper.ShowConsoleMsg(('[Repair acoustic] PAUSE refined src=%s (rms=%s) tts=%s (rms=%s) · min_gap=%.1fms margin=%.1fms first_half=%s\n'):format(
        acoustic_src and ('%.3fs (was %.3fs)'):format(src_t_final, src_a_end + src_gap * bias_factor) or 'biased',
        refined_src_rms and ('%.4f'):format(refined_src_rms) or 'n/a',
        acoustic_tts and ('%.3fs (was %.3fs)'):format(tts_t_final, tts_a_end + tts_gap * bias_factor) or 'biased',
        refined_tts_rms and ('%.4f'):format(refined_tts_rms) or 'n/a',
        min_gap * 1000, margin * 1000,
        first_half_only and 'YES' or 'no'))
    end
  end

  return {
    src_t    = src_t_final,
    tts_t    = tts_t_final,
    letter   = '',                              -- nie aplikowalne dla pause
    src_dur  = src_gap,
    tts_dur  = tts_gap,
    src_word = '',
    tts_word = '',
    kind     = 'pause',
    src_gap  = src_gap,
    tts_gap  = tts_gap,
    bias     = bias_factor,
    acoustic_src = acoustic_src,
    acoustic_tts = acoustic_tts,
  }
end

----------------------------------------------------------------------------
-- compute_blend_point(src_align, tts_align, src_word_idx, tts_word_idx,
--                     expected_text, expected_source_start)
--
-- Picks blend letter w danym context word (immediate-to-change). Returns
--   { src_t, tts_t, letter, dur_src, dur_tts } OR nil + reason.
--
-- src_word_idx          — preferred index w source alignment.words[] (s.words_tbl idx)
-- tts_word_idx          — preferred index w TTS alignment.words[]
-- expected_text         — text słowa
-- expected_source_start — source-time start słowa (z s.words_tbl[idx].start) —
--                          ground truth dla disambiguation duplikatów.
----------------------------------------------------------------------------
local function compute_blend_point(src_align, tts_align, src_word_idx,
                                    tts_word_idx, expected_text, expected_source_start)
  if not src_align or not tts_align then return nil, 'missing alignment' end
  if type(src_align.words) ~= 'table' or type(tts_align.words) ~= 'table' then
    return nil, 'alignment.words missing'
  end

  local norm_expected = normalize_text(expected_text)

  -- Find source word: time-based disambiguation (critical dla duplikatów typu
  -- "in" występujące wiele razy w transcrypcie).
  local resolved_src_idx, src_word = find_aligned_word_by_time(src_align,
    expected_source_start, expected_text, src_word_idx, 2.0)
  if not src_word then
    return nil, 'source word "' .. tostring(expected_text) ..
      '" not found near source-time ' .. tostring(expected_source_start)
  end
  src_word_idx = resolved_src_idx

  -- Find TTS word: position-first preferred (TTS prompt constructed by us z
  -- predictable structure), text-search fallback. TTS-time is unknown ahead so
  -- nie possible time-based disambig — ale TTS prompts typically nie duplicate
  -- context words (chyba że user wpisze "in" jako insert AND ma "in" w
  -- context — rare edge case).
  -- Live-fix (2026-06-10): tts_word_idx to pozycja prompt-word (non-space
  -- ordinal) — surowy alignment.words[idx] trafiał w token spacji dla idx>1.
  local tts_raw_idx, tts_word = tts_nth_nonspace(tts_align.words, tts_word_idx)
  if not tts_word or (norm_expected ~= '' and normalize_text(tts_word.text) ~= norm_expected) then
    local resolved_tts_idx, found_w = find_aligned_word_by_time(tts_align,
      nil, expected_text, tts_word_idx, math.huge)
    if not found_w then
      return nil, 'TTS word "' .. tostring(expected_text) .. '" not found in alignment'
    end
    tts_word_idx = resolved_tts_idx
    tts_word = found_w
  else
    tts_word_idx = tts_raw_idx
  end

  local src_chars = get_word_chars(src_align, src_word_idx)
  local tts_chars = get_word_chars(tts_align, tts_word_idx)
  if not src_chars or #src_chars == 0 then return nil, 'no source chars in word' end
  if not tts_chars or #tts_chars == 0 then return nil, 'no TTS chars in word' end

  -- Pick best letter — auto_pick na SOURCE chars first (źródłem prawdy timing)
  local src_pick_idx, src_pick_ch = auto_pick_blend_letter(src_chars)
  if not src_pick_idx then return nil, 'no acceptable letter in source word' end
  local letter = (src_pick_ch.text or ''):lower()

  -- Find same letter in TTS chars — match by lowercase + try same position first
  local tts_pick_ch = nil
  -- Try same character index w TTS (chars[] może mieć identyczną długość bo to ten
  -- sam word text, ale ordering chars może się różnić jeśli alignment grupuje
  -- różnie — defensive position-first, fallback search by text).
  if tts_chars[src_pick_idx] then
    local tch = tts_chars[src_pick_idx]
    if (tch.text or ''):lower() == letter then
      tts_pick_ch = tch
    end
  end
  if not tts_pick_ch then
    for _, tch in ipairs(tts_chars) do
      if (tch.text or ''):lower() == letter then
        tts_pick_ch = tch
        break
      end
    end
  end
  if not tts_pick_ch then
    return nil, 'letter "' .. letter .. '" not found in TTS word'
  end

  local src_start_t = tonumber(src_pick_ch.start)
  local src_end_t   = tonumber(src_pick_ch['end']) or src_start_t
  local tts_start_t = tonumber(tts_pick_ch.start)
  local tts_end_t   = tonumber(tts_pick_ch['end']) or tts_start_t
  if not src_start_t or not tts_start_t then return nil, 'letter timing missing' end

  local src_dur = src_end_t - src_start_t
  local tts_dur = tts_end_t - tts_start_t

  -- Letter MIDPOINT as blend anchor (was letter start, 2026-05-16 EVENING).
  -- Rationale: forced_align places letter .start at /o/-/f/ transition region
  -- (gradual sibilant attack ~5-10ms), so TTS audio at "/f/_start" still has
  -- residual /o/ amplitude. User report: green TTS at item start shows /o/
  -- vowel peaks instead of clean /f/ noise.
  -- Midpoint = past transition, into pure fricative noise. F/2 lead-in/out
  -- still stays within letter (cap_factor 0.8 ensures F/2 ≤ dur*0.4 < dur/2).
  local src_t = (src_start_t + src_end_t) / 2
  local tts_t = (tts_start_t + tts_end_t) / 2

  return {
    src_t      = src_t,
    tts_t      = tts_t,
    letter     = letter,
    src_dur    = src_dur,
    tts_dur    = tts_dur,
    src_word   = src_word.text,
    tts_word   = tts_word.text,
    kind       = 'letter',
  }
end

----------------------------------------------------------------------------
-- M.splice_phrase_blended(source_item, phrase_audio_path, ctx, tts_alignment,
--                          source_alignment, words_tbl, opts)
--
-- M2 v3 letter-aligned crossfade splice.
--
-- Parameters:
--   source_item       — REAPER MediaItem (containing original audio)
--   phrase_audio_path — TTS mp3 path
--   ctx               — compute_context_range() result (audio_start/end,
--                       context_before_lo/hi, context_after_lo/hi,
--                       change_first_idx/last_idx, inserted_text, tts_text)
--   tts_alignment     — forced_align result na TTS audio
--                       { words[], characters[] }
--   source_alignment  — forced_align result na ORIGINAL source audio
--                       { words[], characters[] } — indeksy słów matchują
--                       s.words_tbl po refine_words_with_alignment
--   words_tbl         — s.words_tbl (dla lookup tekstu context words)
--   opts:
--     crossfade_secs (default 0.040)
--     shift_downstream (default false)
--     repair_metadata (per splice_phrase)
--     repair_mode
--     stretch_playrate (0 < r ≤ 1, default 1) — I9-narrow élastique slow-down
--
-- Returns: { ok, new_item, left_item, right_item, ... } LUB
--          { ok=false, err, fallback_recommended=true } gdy blend point
--          niemożliwy (caller fallback do splice_phrase).
----------------------------------------------------------------------------
function M.splice_phrase_blended(source_item, phrase_audio_path, ctx,
                                  tts_alignment, source_alignment, words_tbl, opts)
  opts = opts or {}
  if not source_item then return { ok = false, err = 'nil source_item' } end
  if not phrase_audio_path or phrase_audio_path == '' then
    return { ok = false, err = 'empty phrase_audio_path' }
  end
  if not ctx then return { ok = false, err = 'nil ctx' } end
  if not tts_alignment or type(tts_alignment.words) ~= 'table' then
    return { ok = false, err = 'tts_alignment missing', fallback_recommended = true }
  end
  if not source_alignment or type(source_alignment.words) ~= 'table' then
    return { ok = false, err = 'source_alignment missing', fallback_recommended = true }
  end
  if not words_tbl then return { ok = false, err = 'words_tbl missing',
    fallback_recommended = true } end

  local F = tonumber(opts.crossfade_secs) or BLEND_CROSSFADE_SECS
  if F <= 0 then F = BLEND_CROSSFADE_SECS end

  -- I9-narrow (W1, USER-APPROVED — DEVIATIONS 2026-06-10): jak w splice_phrase
  -- — TTS item dostaje D_PLAYRATE = r (<1, pitch preserved); wielkości TTS
  -- przeliczane source→timeline przez /r. Blend pointy (letter positions)
  -- żyją w domenach SOURCE obu stron — wybór cięcia niezależny od stretchu.
  -- r=1 (brak flagi) → wzory identyczne jak dotąd.
  local stretch_r = tonumber(opts.stretch_playrate) or 1.0
  if stretch_r <= 0 or stretch_r > 1.0 then stretch_r = 1.0 end

  -- 1. Determine immediate context word indices + TTS word positions
  local left_ctx_n   = ctx.context_before_hi - ctx.context_before_lo + 1
  local right_ctx_n  = ctx.context_after_hi  - ctx.context_after_lo  + 1
  local has_left_ctx  = left_ctx_n  > 0
  local has_right_ctx = right_ctx_n > 0
  local inserted_n   = count_words(ctx.inserted_text)

  -- Edge case: brak obu context blocks (zmiana zaczyna i kończy się na końcach
  -- transcryptu) — fallback do hard-cut splice_phrase
  if not has_left_ctx and not has_right_ctx then
    return { ok = false, err = 'no context blocks (both sides empty)',
             fallback_recommended = true }
  end

  -- 1.5. Acquire PCM sources + item geometry early — used przez acoustic
  --      onset detection w blend point picking AND geometry math poniżej.
  local item_pos  = get_iv(source_item, 'D_POSITION')
  local item_len  = get_iv(source_item, 'D_LENGTH')
  local item_end  = item_pos + item_len
  local take = reaper.GetActiveTake(source_item)
  if not take or reaper.TakeIsMIDI(take) then
    return { ok = false, err = 'item has no audio take' }
  end
  local playrate  = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if playrate <= 0 then playrate = 1.0 end
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local source_pcm = reaper.GetMediaItemTake_Source(take)

  local phrase_src = reaper.PCM_Source_CreateFromFile(phrase_audio_path)
  if not phrase_src then
    return { ok = false, err = 'PCM_Source_CreateFromFile failed: ' .. phrase_audio_path }
  end
  local phrase_len = reaper.GetMediaSourceLength(phrase_src)
  if not phrase_len or phrase_len <= 0 then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'phrase audio has zero length' }
  end
  -- I4 fix: peaki MUSZĄ istnieć PRZED blend-point scoring (nie tylko zacząć
  -- się budować). Source też — sąsiedni item bywa wcześniejszą wklejką TTS.
  ensure_peaks(phrase_src)
  ensure_peaks(source_pcm)
  local pcm_opts = { source_pcm = source_pcm, tts_pcm = phrase_src }
  -- For outer pauses (between context and change word, or change and ctx_after):
  -- restrict acoustic refinement do first-half-of-gap. Avoids placing cut close
  -- to next-word onset, gdzie forced_align imprecision na sibilants /sh/ /s/
  -- może powodować "double-sh" artifact (refined cut lands w actual ramp-up
  -- before alignment reports start). Inner-left pause (between two ctx words)
  -- uses default symmetric search.
  local pcm_opts_first_half = {
    source_pcm = source_pcm,
    tts_pcm = phrase_src,
    search_first_half_only = true,
  }

  -- 2. Compute blend points — PAUSE-PREFER, LETTER-FALLBACK
  --    Pause splice (cięcie w ciszy) jest niesłyszalne — preferowane gdy
  --    pause width ≥ MIN_PAUSE_SPLIT_SECS w OBYDWU alignmentach (source + TTS).
  --    Acoustic refinement (find_quietest_window) precyzyjnie wybiera moment
  --    cięcia w pauzie. Inaczej fallback do letter-aligned (existing M2 v3 logic).
  local left_blend, right_blend = nil, nil
  local left_err,  right_err   = nil, nil

  if has_left_ctx then
    -- Detect HARD STOP onset (k/q/c/g/p/b/t/d) na BOTH:
    --   (a) source change word (np. "quick" → /k/)
    --   (b) TTS inserted text (np. "ProTools" → /p/)
    -- Whichever side has hard-stop: forced_align imprecyzja na .start może
    -- catch transient. Workaround: letter-mode na sibilant/fricative w left
    -- ctx (clean noise-blend, no transient imprecyzja).
    local change_word = words_tbl[ctx.change_first_idx]
    local source_first = change_word and (change_word.text or ''):lower():sub(1,1) or ''
    local inserted_trimmed = (ctx.inserted_text or ''):gsub('^%s+', '')
    local inserted_first = inserted_trimmed:lower():sub(1,1)
    local HARD_STOPS = { k=true, q=true, c=true, g=true, p=true, b=true, t=true, d=true }
    local is_hard_stop = HARD_STOPS[source_first] or HARD_STOPS[inserted_first]

    -- Detect pause-unviable: TTS gap między last ctx word i first change word
    -- ZA WĄSKI dla F crossfade. Below ~F threshold (40ms), pause-mode forces
    -- F=MIN_FADE=8ms ale F/2 lead-in wchodzi w prev word content = crossfade
    -- catches voice = artifact. Trigger letter scan (same logic jak hard-stop)
    -- — szuka fricative/sibilant w ctx dla noise-blend zamiast voiced cut.
    --
    -- Przykład: "demo of my voice" → audio. TTS gap "my"→"audio" = 1ms (forced
    -- align rendered nearly continuous). User intuicja: /f/ w "of" lepsze
    -- (fricative noise blend) niż voiced cut na boundary my|voice. (Live test
    -- 2026-05-16 EVENING)
    local pause_unviable = false
    do
      local _, tts_last_ctx = tts_nth_nonspace(tts_alignment.words, left_ctx_n)
      local _, tts_first_change = tts_nth_nonspace(tts_alignment.words, left_ctx_n + 1)
      if tts_last_ctx and tts_first_change then
        local tts_gap = (tonumber(tts_first_change.start) or 0)
                      - (tonumber(tts_last_ctx['end']) or 0)
        if tts_gap < BLEND_CROSSFADE_SECS then
          pause_unviable = true
        end
      end
    end

    -- Priority 1: scan WSZYSTKIE left ctx words backward, pick sibilant/fricative
    -- letter. ALWAYS runs — letter cut on fricative w ctx jest architekturalnie
    -- SAFER niż LEFT pause-mode, bo:
    --   - LEFT pause cuts between ctx_end i CHANGE word start
    --   - Source has change_word onset (e.g. /v/ w "voice"), TTS has inserted
    --     word onset (e.g. /s/ w "sound") — DIFFERENT phonemes
    --   - Crossfade F/2 lead-out catches the differing onsets → audible mismatch
    --   - Letter cut na fricative w ctx: source + TTS clone voice mają IDENTYCZNY
    --     phoneme w ctx word → noise blend imperceptible
    -- Pause-mode kept jako fallback gdy NO fricative/sibilant w ctx (rare).
    -- is_hard_stop / pause_unviable zachowane dla diagnostic only.
    -- User confirmed 2026-05-16 EVENING voice→sound case: prefer /f/ w "of"
    -- nad pause cut "my|voice/sound" even gdy pause "wide".
    do
      -- Scan all left ctx words, collect sibilant/fricative candidates,
      -- pick LONGEST (more crossfade material = cleaner blend, user preference
      -- 2026-05-15: "/s/ w 'this' lepsze bo dluzsze niz /s/ w 'is'").
      local candidates = {}
      for src_word_idx = ctx.context_before_hi, ctx.context_before_lo, -1 do
        local tts_word_idx = left_ctx_n - (ctx.context_before_hi - src_word_idx)
        if tts_word_idx >= 1 then
          local wt = words_tbl[src_word_idx]
          local expected_text = wt and wt.text or ''
          local expected_src_start = wt and tonumber(wt.start) or nil
          local letter_blend, lb_err = compute_blend_point(source_alignment, tts_alignment,
            src_word_idx, tts_word_idx, expected_text, expected_src_start)
          if PAUSE_SPLIT_DEBUG() then
            reaper.ShowConsoleMsg(('[Repair blend] LEFT hard-stop scan "%s" (idx=%d, tts=%d) → letter=%s%s\n'):format(
              expected_text, src_word_idx, tts_word_idx,
              letter_blend and ('"' .. (letter_blend.letter or '?') .. '"') or 'nil',
              lb_err and (' err="' .. tostring(lb_err) .. '"') or ''))
          end
          if letter_blend and letter_blend.letter then
            local L = letter_blend.letter
            if SIBILANT_LETTERS[L] or FRICATIVE_LETTERS[L] then
              local src_dur = letter_blend.src_dur or 0
              local tts_dur = letter_blend.tts_dur or 0
              -- W1.1 guard (2026-06-10, live-test edit 9): zdegenerowany
              -- 0ms letter (forced_align char timing) przechodził do
              -- kandydatów → crossfade 0ms = ryzyko kliku. Bottleneck
              -- min(src,tts) musi unieść noise-class fade (≥10ms) —
              -- mirror per-class MIN_DUR z auto_pick_blend_letter.
              if math.min(src_dur, tts_dur) >= 0.010 then
                candidates[#candidates + 1] = {
                  blend         = letter_blend,
                  min_dur       = math.min(src_dur, tts_dur),  -- bottleneck
                  word          = expected_text,
                  src_word_idx  = src_word_idx,
                }
              end
            end
          end
        end
      end
      -- ACOUSTIC scoring (2026-05-16 acoustic onset detection — Priority A):
      -- Measure RMS przy proposed splice point dla każdego candidate, pick
      -- najcichszego. Eliminuje konflikt heurystyki "furthest vs longest"
      -- między testami quick→short (chce furthest) i calm→quiet (chce
      -- najdłuższego /s/ w "is" bo natural pre-pause). RMS w faktycznym audio
      -- mówi która opcja jest empirycznie quietest = blend imperceptible.
      -- Fallback do furthest-first gdy ANY candidate brakuje RMS data (np.
      -- letter za blisko brzegu audio dla F-window).
      if #candidates > 0 then
        -- Score candidates via measure_rms_linear (fixed window — measure
        -- RMS at proposed cut point exactly, no sliding scan). Use W=40ms
        -- (matches actual crossfade region after F-cap).
        --
        -- TTS RMS often unavailable on first edit cycle (fresh mp3 lacks
        -- peakfile, PCM_Source_BuildPeaks async, GetPeaks returns 0).
        -- Source RMS reliable bo source recording already has .reapeaks
        -- from import. Score with whatever we have: combined_rms = max(src,
        -- tts) gdy oba available (louder side dominates seam) else src
        -- alone (TTS clones source phonemes — source RMS is a good proxy
        -- dla blend quality at same phonetic position).
        local W = BLEND_CROSSFADE_SECS  -- 40ms = actual crossfade region
        local any_scored = false
        for _, c in ipairs(candidates) do
          local src_t = c.blend.src_t
          local tts_t = c.blend.tts_t
          if src_t then
            local src_rms = measure_rms_linear(source_pcm,
              src_t - W / 2, src_t + W / 2)
            local tts_rms = tts_t and measure_rms_linear(phrase_src,
              tts_t - W / 2, tts_t + W / 2) or nil
            if src_rms then
              c.src_rms = src_rms
              c.tts_rms = tts_rms
              c.combined_rms = tts_rms and math.max(src_rms, tts_rms) or src_rms
              any_scored = true
            end
          end
        end

        -- Sort: candidates z RMS scores first (ascending), then unscored
        -- candidates by src_word_idx (legacy furthest-first). Partition keeps
        -- comparator transitive (Lua table.sort requires this).
        if any_scored then
          table.sort(candidates, function(a, b)
            if a.combined_rms and b.combined_rms then
              return a.combined_rms < b.combined_rms
            elseif a.combined_rms then
              return true   -- scored beats unscored
            elseif b.combined_rms then
              return false
            else
              return a.src_word_idx < b.src_word_idx
            end
          end)
        else
          table.sort(candidates, function(a, b)
            return a.src_word_idx < b.src_word_idx
          end)
        end
        local best = candidates[1]
        left_blend = best.blend

        local has_tts_rms = false
        for _, c in ipairs(candidates) do
          if c.tts_rms then has_tts_rms = true; break end
        end
        local mode_str
        if best.combined_rms then
          mode_str = has_tts_rms and 'acoustic-src+tts' or 'acoustic-src-only'
        else
          mode_str = 'furthest-fallback'
        end

        if PAUSE_SPLIT_DEBUG() then
          local options = {}
          for _, c in ipairs(candidates) do
            options[#options + 1] = ('"%s"=%.1fms%s'):format(
              c.word, c.min_dur * 1000,
              c.combined_rms and (' rms=%.4f%s'):format(
                c.combined_rms,
                c.tts_rms and (' (s=%.4f t=%.4f)'):format(c.src_rms, c.tts_rms)
                          or (' (s=%.4f t=n/a)'):format(c.src_rms))
                or ' rms=n/a')
          end
          local trigger = is_hard_stop and 'hard-stop'
                       or pause_unviable and 'pause-unviable'
                       or 'always-priority'
          reaper.ShowConsoleMsg(('[Repair blend] LEFT letter scan (%s · src="%s" ins="%s") → letter "%s" w "%s" (mode=%s · candidates: %s)\n'):format(
            trigger, source_first, inserted_first, best.blend.letter, best.word,
            mode_str, table.concat(options, ', ')))
        end
      end
    end

    -- Priority 2: OUTER LEFT pause (gdy non-hard-stop, lub hard-stop bez sibilant/fricative)
    if not left_blend and ctx.change_first_idx and inserted_n > 0
       and ctx.context_before_hi
       and ctx.change_first_idx > ctx.context_before_hi then
      local left_bias = is_hard_stop and 0.25 or 0.35
      left_blend = find_pause_blend_point(source_alignment, tts_alignment, words_tbl,
        ctx.context_before_hi, ctx.change_first_idx,
        left_ctx_n, left_ctx_n + 1,
        MIN_PAUSE_SPLIT_SECS, left_bias, pcm_opts_first_half)
    end
    -- Priority 2: INNER LEFT pause — między ctx_before_hi-1 a ctx_before_hi
    -- (wewnątrz left ctx block). Fallback gdy OUTER nie ma pauzy (np. user
    -- mówi szybko "a quick" prawie jak jedno słowo).
    if not left_blend and left_ctx_n >= 2 and ctx.context_before_hi and ctx.context_before_hi >= 2 then
      left_blend = find_pause_blend_point(source_alignment, tts_alignment, words_tbl,
        ctx.context_before_hi - 1, ctx.context_before_hi,
        left_ctx_n - 1, left_ctx_n,
        MIN_PAUSE_SPLIT_SECS, nil, pcm_opts)
    end
    -- Fallback letter-aligned dla immediate ctx word
    if not left_blend then
      local src_word_idx = ctx.context_before_hi
      local tts_word_idx = left_ctx_n              -- left ctx fills positions 1..left_ctx_n w TTS
      local wt = words_tbl[src_word_idx]
      local expected_text = wt and wt.text or ''
      local expected_src_start = wt and tonumber(wt.start) or nil
      left_blend, left_err = compute_blend_point(source_alignment, tts_alignment,
        src_word_idx, tts_word_idx, expected_text, expected_src_start)
      -- Drugi fallback: scan PRECEDING ctx word (np. immediate "a" fail 1-letter,
      -- spróbuj "is" — last sibilant "s" da clean blend point).
      if not left_blend and left_ctx_n >= 2 then
        local prev_src_idx = ctx.context_before_hi - 1
        local prev_tts_idx = left_ctx_n - 1
        local prev_wt = words_tbl[prev_src_idx]
        local prev_text = prev_wt and prev_wt.text or ''
        local prev_start = prev_wt and tonumber(prev_wt.start) or nil
        local fallback_blend, fallback_err = compute_blend_point(
          source_alignment, tts_alignment,
          prev_src_idx, prev_tts_idx, prev_text, prev_start)
        if fallback_blend then
          left_blend = fallback_blend
          left_err = nil
          if PAUSE_SPLIT_DEBUG() then
            reaper.ShowConsoleMsg(('[Repair blend] LEFT letter fallback → preceding word "%s" (letter "%s")\n'):format(
              prev_text, fallback_blend.letter or '?'))
          end
        else
          left_err = ('immediate: %s | preceding "%s": %s'):format(
            tostring(left_err), prev_text, tostring(fallback_err))
        end
      end
    end
  end

  if has_right_ctx then
    -- Try pause-splice: gap między (last word before right ctx) a context_after_lo.
    -- W source: ctx.context_after_lo - 1 (= change_last_idx dla Replace/Delete, lub
    -- ctx.context_before_hi dla Insert — contiguous selection assumption).
    -- W TTS: tts_idx_a = left_ctx_n + inserted_n (last word w TTS przed right ctx),
    -- tts_idx_b = + 1.
    local pause_src_a = ctx.context_after_lo and (ctx.context_after_lo - 1) or 0
    local pause_tts_a = left_ctx_n + inserted_n
    if ctx.context_after_lo and pause_src_a >= 1 and pause_tts_a >= 1 then
      -- Right pause: bias 0.25 (closer to change-word end, away from next-word
      -- onset). Refinement restricted to first half via pcm_opts_first_half.
      -- Both safety mechanisms prevent /sh/ /s/ etc. ramp-up bleeding into
      -- crossfade region (cf. double-sh artifact "sz short" reported live test).
      right_blend = find_pause_blend_point(source_alignment, tts_alignment, words_tbl,
        pause_src_a, ctx.context_after_lo,
        pause_tts_a, pause_tts_a + 1,
        MIN_PAUSE_SPLIT_SECS, 0.25, pcm_opts_first_half)
    end
    -- Fallback letter-aligned dla immediate ctx word
    if not right_blend then
      local src_word_idx = ctx.context_after_lo
      -- TTS right ctx starts po left ctx + inserted words (Delete: inserted_n=0)
      local tts_word_idx = left_ctx_n + inserted_n + 1
      local wt = words_tbl[src_word_idx]
      local expected_text = wt and wt.text or ''
      local expected_src_start = wt and tonumber(wt.start) or nil
      right_blend, right_err = compute_blend_point(source_alignment, tts_alignment,
        src_word_idx, tts_word_idx, expected_text, expected_src_start)
      -- Drugi fallback: scan NEXT ctx word (jeśli istnieje w ctx block).
      if not right_blend and right_ctx_n >= 2 and ctx.context_after_hi then
        local next_src_idx = ctx.context_after_lo + 1
        local next_tts_idx = left_ctx_n + inserted_n + 2
        local next_wt = words_tbl[next_src_idx]
        local next_text = next_wt and next_wt.text or ''
        local next_start = next_wt and tonumber(next_wt.start) or nil
        local fallback_blend, fallback_err = compute_blend_point(
          source_alignment, tts_alignment,
          next_src_idx, next_tts_idx, next_text, next_start)
        if fallback_blend then
          right_blend = fallback_blend
          right_err = nil
          if PAUSE_SPLIT_DEBUG() then
            reaper.ShowConsoleMsg(('[Repair blend] RIGHT letter fallback → following word "%s" (letter "%s")\n'):format(
              next_text, fallback_blend.letter or '?'))
          end
        else
          right_err = ('immediate: %s | following "%s": %s'):format(
            tostring(right_err), next_text, tostring(fallback_err))
        end
      end
    end
  end

  if PAUSE_SPLIT_DEBUG() then
    reaper.ShowConsoleMsg(('[Repair blend FINAL] LEFT kind=%s err=%s · RIGHT kind=%s err=%s · ' ..
      'ctx: before_lo=%s before_hi=%s change=%s..%s after_lo=%s after_hi=%s · ' ..
      'left_ctx_n=%d right_ctx_n=%d inserted_n=%d\n'):format(
        tostring(left_blend  and left_blend.kind  or 'nil'),
        tostring(left_err  or 'none'),
        tostring(right_blend and right_blend.kind or 'nil'),
        tostring(right_err or 'none'),
        tostring(ctx.context_before_lo), tostring(ctx.context_before_hi),
        tostring(ctx.change_first_idx),  tostring(ctx.change_last_idx),
        tostring(ctx.context_after_lo),  tostring(ctx.context_after_hi),
        left_ctx_n, right_ctx_n, inserted_n))
  end

  -- 3. If both blend points failed → fallback
  if not left_blend and not right_blend then
    return { ok = false,
             err = 'blend points failed (left: ' .. tostring(left_err) ..
                   ', right: ' .. tostring(right_err) .. ')',
             fallback_recommended = true }
  end

  -- 4. (moved to section 1.5 — PCM sources + geometry loaded early dla
  --     acoustic onset detection w blend point picking)

  -- 5. Map source-time blend points → project time
  --    src_blend_proj = item_pos + (src_t - item_offs) / playrate
  local function src_to_proj(t) return item_pos + (t - item_offs) / playrate end

  -- Left side: gdy blend, użyj letter time. Gdy no blend (no left ctx), użyj
  -- ctx.audio_start jako hard cut (no overlap).
  local left_src_t  -- source-time blend point (left side)
  local left_tts_t  -- TTS source-time blend point
  if left_blend then
    left_src_t = left_blend.src_t
    left_tts_t = left_blend.tts_t
  else
    -- No left ctx → hard start: use audio_start (start of change word)
    left_src_t = ctx.audio_start
    left_tts_t = 0     -- TTS starts at 0 (no left fade-in skip)
  end
  local left_blend_proj = src_to_proj(left_src_t)

  -- Right side
  local right_src_t
  local right_tts_t
  if right_blend then
    right_src_t = right_blend.src_t
    right_tts_t = right_blend.tts_t
  else
    right_src_t = ctx.audio_end
    right_tts_t = phrase_len
  end
  local right_blend_proj = src_to_proj(right_src_t)

  -- 6. Sanity: order
  if right_src_t <= left_src_t + 0.005 then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'right blend not after left (degenerate range)' }
  end
  if right_tts_t <= left_tts_t + 0.005 then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'TTS right blend not after left (alignment issue?)' }
  end

  -- 7. Scale F:
  --    Letter mode: cap = letter_dur * 0.8 (90's-style safety).
  --    Pause mode: cap = pause_gap * 0.5 (50% — leaves 25% margin each side
  --    od reported word boundaries, kompensuje forced_align imprecision
  --    na transient onsets /k/ /dʒ/ /ʃ/ etc.).
  local F_left  = F
  local F_right = F
  local function cap_factor(blend)
    return (blend and blend.kind == 'pause') and 0.5 or 0.8
  end
  if left_blend then
    local factor = cap_factor(left_blend)
    local cap = math.min(left_blend.src_dur, left_blend.tts_dur) * factor
    if cap > 0 and cap < F_left then F_left = math.max(0.008, cap) end
  end
  if right_blend then
    local factor = cap_factor(right_blend)
    local cap = math.min(right_blend.src_dur, right_blend.tts_dur) * factor
    if cap > 0 and cap < F_right then F_right = math.max(0.008, cap) end
  end

  -- 7b. Symmetric crossfade dla obu modów: F/2 lead-in/out na każdą stronę.
  --
  -- Letter mode: blend point = letter MIDPOINT (compute_blend_point change).
  -- F/2 each side stays within letter (cap_factor 0.8 → F/2 ≤ dur*0.4 < dur/2).
  -- Crossfade entirely w noise region letter, no pre-letter content w lead-in.
  -- Visible X-fade w timeline (source fade-out crosses TTS fade-in).
  --
  -- Pause mode: blend point = silence position (bias OR PCM-refined).
  -- F/2 each side stays w pause (margin = min_gap*0.25 in find_pause_blend_point).
  --
  -- Earlier 2026-05-16 EVENING tried asymmetric for letter (Option B: tts_lead=0,
  -- src_lead=F). Eliminated /o/ tail z TTS bo TTS startuje AT letter start.
  -- Reverted po user feedback: tts_d_startoffs at letter start STILL has /o/
  -- residue (forced_align imprecision on transition). Midpoint anchor fixes
  -- ROOT CAUSE — TTS audio at midpoint - F/2 is past transition. Plus visible
  -- X-fade preferred over hard-cut visual.
  local function lead_secs(_blend, F_eff)
    return F_eff / 2, F_eff / 2
  end
  local left_tts_lead,  left_src_lead  = lead_secs(left_blend, F_left)
  local right_tts_lead, right_src_lead = lead_secs(right_blend, F_right)

  -- 8. Compute TTS placement.
  --    TTS source time `left_tts_t` powinien grać dokładnie w project time
  --    `left_blend_proj`. Overlap region F_left zaczyna się left_tts_lead wcześniej.
  local tts_d_pos       = left_blend_proj - left_tts_lead
  -- Lead F/2 to wielkość TIMELINE — source skonsumowany w leadzie = lead × r.
  local tts_d_startoffs = left_tts_t - left_tts_lead * stretch_r
  if tts_d_startoffs < 0 then
    -- Edge: TTS audio za krótkie żeby pomieścić left_tts_lead. Clamp + dostosuj
    -- pos żeby letter wciąż landował na left_blend_proj. (delta = source secs;
    -- na timeline /r.)
    local delta = -tts_d_startoffs
    tts_d_startoffs = 0
    tts_d_pos = tts_d_pos + delta / stretch_r
    F_left = math.max(0.008, F_left - 2 * delta / stretch_r)
    left_tts_lead, left_src_lead = lead_secs(left_blend, F_left)
  end
  local tts_d_length = (right_tts_t - left_tts_t) / stretch_r + left_tts_lead + right_tts_lead
  if tts_d_startoffs + tts_d_length * stretch_r > phrase_len then
    tts_d_length = (phrase_len - tts_d_startoffs) / stretch_r
  end

  -- TTS project end (gdzie TTS faktycznie kończy granie audio)
  local tts_d_end = tts_d_pos + tts_d_length

  -- New right blend project time — gdzie right letter w TTS landuje:
  --   proj_right_letter = tts_d_pos + (right_tts_t - tts_d_startoffs) / stretch_r
  local new_right_blend_proj = tts_d_pos + (right_tts_t - tts_d_startoffs) / stretch_r

  -- Shift downstream by (new_right_blend_proj - right_blend_proj)
  local shifted_secs = new_right_blend_proj - right_blend_proj

  -- 9. Validate splice points within item bounds
  if left_src_t < item_offs - 0.001 or right_src_t > item_offs + item_len * playrate + 0.001 then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = ('blend points [%.3f..%.3f] outside item audio [%.3f..%.3f]'):format(
      left_src_t, right_src_t, item_offs, item_offs + item_len * playrate) }
  end

  local track = reaper.GetMediaItemTrack(source_item)
  if not track then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'item has no track' }
  end

  local source_guid = item_guid(source_item)

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- 10. Split source at LEFT blend point (project time). left_item ends here.
  local middle = nil
  local left_item = source_item
  local left_split_proj = left_blend_proj + left_src_lead   -- F/2 w obu trybach (komentarz mówił "letter: F" — M7 errata)
  -- Clamp do item bounds
  if left_split_proj > item_end - 0.001 then left_split_proj = item_end - 0.001 end
  if left_split_proj < item_pos + 0.001 then
    -- Brak left content → left_item = nil
    left_item = nil
    middle = source_item
  else
    middle = reaper.SplitMediaItem(source_item, left_split_proj)
    if not middle then
      reaper.Undo_EndBlock('Reasonate: Repair blended splice (failed)', -1)
      reaper.PreventUIRefresh(-1)
      if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
      return { ok = false, err = 'SplitMediaItem failed at left blend' }
    end
  end

  -- 11. Split middle at RIGHT blend point. right_item starts here.
  -- pause mode: F/2 lead-in (right_item starts F_right/2 wcześniej, audio = silence)
  -- letter mode: F lead-in (right_item starts F_right wcześniej, audio = letter)
  local right_item = nil
  local right_split_proj = right_blend_proj - right_src_lead
  if right_split_proj < item_pos + 0.001 then right_split_proj = item_pos + 0.001 end
  if right_split_proj < item_end - 0.001 then
    right_item = reaper.SplitMediaItem(middle, right_split_proj)
    if not right_item then
      reaper.Undo_EndBlock('Reasonate: Repair blended splice (failed)', -1)
      reaper.PreventUIRefresh(-1)
      if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
      return { ok = false, err = 'SplitMediaItem failed at right blend' }
    end
  end

  -- 12. Delete middle slice
  reaper.DeleteTrackMediaItem(track, middle)

  -- 13. Create new TTS item
  local new_item = reaper.AddMediaItemToTrack(track)
  if not new_item then
    reaper.Undo_EndBlock('Reasonate: Repair blended splice (failed)', -1)
    reaper.PreventUIRefresh(-1)
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'AddMediaItemToTrack failed' }
  end
  local new_take = reaper.AddTakeToMediaItem(new_item)
  reaper.SetMediaItemTake_Source(new_take, phrase_src)

  set_iv(new_item, 'D_POSITION', tts_d_pos)
  set_iv(new_item, 'D_LENGTH',   tts_d_length)
  reaper.SetMediaItemTakeInfo_Value(new_take, 'D_STARTOFFS', tts_d_startoffs)
  reaper.SetMediaItemTakeInfo_Value(new_take, 'D_PLAYRATE',  stretch_r)
  if stretch_r ~= 1.0 then
    -- Preserve pitch przy zmianie playback rate — essential dla mowy
    -- (élastique wg project default; wzorzec dubbing_splicer).
    reaper.SetMediaItemTakeInfo_Value(new_take, 'B_PPITCH', 1)
  end

  -- 14. Shift right_item + downstream by shifted_secs (gdy non-zero)
  if right_item and math.abs(shifted_secs) > 0.001 then
    local right_pos = get_iv(right_item, 'D_POSITION')
    set_iv(right_item, 'D_POSITION', right_pos + shifted_secs)
    if opts.shift_downstream then
      local n = reaper.CountTrackMediaItems(track)
      for i = 0, n - 1 do
        local it = reaper.GetTrackMediaItem(track, i)
        if it ~= right_item and it ~= new_item and it ~= left_item then
          local p = get_iv(it, 'D_POSITION')
          if p > right_pos - 0.001 then
            set_iv(it, 'D_POSITION', p + shifted_secs)
          end
        end
      end
      ripple_other_tracks(track, right_pos, shifted_secs)
    end
  end

  -- 15. Crossfades — letter aligned overlaps
  if left_item then
    set_iv(left_item, 'D_FADEOUTLEN', F_left)
    set_iv(new_item,  'D_FADEINLEN',  F_left)
  else
    -- No left context — TTS starts hard (small anti-click)
    set_iv(new_item, 'D_FADEINLEN', 0.008)
  end
  if right_item then
    set_iv(new_item,   'D_FADEOUTLEN', F_right)
    set_iv(right_item, 'D_FADEINLEN',  F_right)
  else
    set_iv(new_item, 'D_FADEOUTLEN', 0.008)
  end

  -- 16. RMS volume match (mirror splice_phrase M1.5)
  local volume_gain_db = 0
  local volume_match_applied = false
  if cfg.get_repair_auto_volume_match() then
    -- M0-4 (audit 2026-07): left or RIGHT (nigdy new_item = take TTS) —
    -- mirror splice_phrase; oba nil → src_take nil → skip matchingu.
    local src_item = left_item or right_item
    local src_take = src_item and reaper.GetActiveTake(src_item) or nil
    if not src_take or reaper.TakeIsMIDI(src_take) then
      src_take = right_item and reaper.GetActiveTake(right_item) or nil
    end
    if src_take and not reaper.TakeIsMIDI(src_take) then
      local source_pcm = reaper.GetMediaItemTake_Source(src_take)
      if source_pcm then
        -- W1.1 (2026-06-10, user OK): preferowany pomiar word-aligned — te
        -- same słowa kontekstu w source i TTS (1:1) → wiarygodny gain →
        -- szerszy boost clamp +8dB. Fallback (tokenization mismatch / brak
        -- pomiaru): legacy "1s przed cięciem vs cała fraza" z ciasnym +2dB.
        local boost_clamp = VOLUME_BOOST_CLAMP_ALIGNED_DB
        local meas_mode   = 'aligned ctx-words'
        local src_db, tts_db = measure_ctx_rms_aligned(
          source_pcm, words_tbl, ctx, phrase_src, tts_alignment, inserted_n)
        if not (src_db and tts_db) then
          boost_clamp = VOLUME_BOOST_CLAMP_DB
          meas_mode   = 'phrase-wide LEFT-only (legacy fallback)'
          -- measure_rms_voiced działa w domenie SOURCE TTS — span konsumowany
          -- przez item = tts_d_length (timeline) × stretch_r.
          local tts_meas_start = tts_d_startoffs + 0.05
          local tts_meas_end   = tts_d_startoffs + tts_d_length * stretch_r - 0.05
          src_db = measure_rms_voiced(source_pcm,
            math.max(0, left_src_t - RMS_SOURCE_LOOKBACK_SECS), left_src_t)
          if not src_db then
            src_db = measure_rms_voiced(source_pcm,
              math.max(0, left_src_t - 3.0), left_src_t)
          end
          tts_db = measure_rms_voiced(phrase_src, tts_meas_start, tts_meas_end)
        end
        local raw_gain_db = (src_db and tts_db) and (src_db - tts_db) or nil
        local clamped_gain_db = raw_gain_db
        if clamped_gain_db then
          -- Asymmetric: boost clamp per measurement mode, attenuate -12dB max
          if clamped_gain_db >  boost_clamp then clamped_gain_db =  boost_clamp end
          if clamped_gain_db < -VOLUME_ATTEN_CLAMP_DB then clamped_gain_db = -VOLUME_ATTEN_CLAMP_DB end
        end
        if VOLUME_DEBUG() then
          reaper.ShowConsoleMsg(('[Reasonate] VOL/blend src=%s tts=%s raw_gain=%s clamped=%s (mode=%s · boost_cap=%+.1fdB)\n')
            :format(src_db and ('%.2fdB'):format(src_db) or 'nil',
                    tts_db and ('%.2fdB'):format(tts_db) or 'nil',
                    raw_gain_db and ('%+.2fdB'):format(raw_gain_db) or 'nil',
                    clamped_gain_db and ('%+.2fdB'):format(clamped_gain_db) or 'nil',
                    meas_mode, boost_clamp))
        end
        if clamped_gain_db then
          volume_gain_db = clamped_gain_db
          local linear_gain = 10 ^ (clamped_gain_db / 20)
          reaper.SetMediaItemTakeInfo_Value(new_take, 'D_VOL', linear_gain)
          volume_match_applied = true
          set_pext(new_item, 'repair_volume_offset_db', ('%.2f'):format(clamped_gain_db))
          set_pext(new_item, 'repair_source_rms_db',    ('%.2f'):format(src_db))
          set_pext(new_item, 'repair_tts_rms_db',       ('%.2f'):format(tts_db))
        end
      end
    end
  end

  -- 17. P_EXT na new_item
  set_pext(new_item, 'is_repair_output',      '1')
  set_pext(new_item, 'converted',             '1')
  set_pext(new_item, 'repair_mode',           opts.repair_mode or 'replace')
  set_pext(new_item, 'repair_source_item_guid', source_guid or '')
  set_pext(new_item, 'repair_audio_start',    tostring(ctx.audio_start))
  set_pext(new_item, 'repair_audio_end',      tostring(ctx.audio_end))
  set_pext(new_item, 'repair_created_at',     tostring(os.time()))
  set_pext(new_item, 'repair_alignment_used', '1')
  set_pext(new_item, 'repair_blended',        '1')
  set_pext(new_item, 'repair_left_blend_kind',  left_blend  and left_blend.kind  or '')
  set_pext(new_item, 'repair_right_blend_kind', right_blend and right_blend.kind or '')
  set_pext(new_item, 'repair_left_blend_letter',  left_blend  and left_blend.letter  or '')
  set_pext(new_item, 'repair_right_blend_letter', right_blend and right_blend.letter or '')
  if left_blend and left_blend.src_gap then
    set_pext(new_item, 'repair_left_pause_secs',  ('%.4f'):format(left_blend.src_gap))
  end
  if right_blend and right_blend.src_gap then
    set_pext(new_item, 'repair_right_pause_secs', ('%.4f'):format(right_blend.src_gap))
  end
  set_pext(new_item, 'repair_left_xfade_secs',  ('%.4f'):format(F_left))
  set_pext(new_item, 'repair_right_xfade_secs', ('%.4f'):format(F_right))
  set_pext(new_item, 'repair_shifted_secs',     ('%.4f'):format(shifted_secs))
  if stretch_r ~= 1.0 then
    set_pext(new_item, 'repair_stretch_playrate', ('%.4f'):format(stretch_r))
  end
  local meta = opts.repair_metadata or {}
  set_pext(new_item, 'repair_phrase_text', meta.phrase_text or '')
  set_pext(new_item, 'repair_from_text',   meta.from_text or '')
  set_pext(new_item, 'voice_id',           meta.voice_id    or '')
  set_pext(new_item, 'voice_source',       meta.voice_source or '')
  set_pext(new_item, 'repair_seed',        tostring(meta.seed or 0))

  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
    ('Repair: %s'):format((meta.phrase_text or 'edit'):sub(1, 40)), true)

  if reaper.PCM_Source_BuildPeaks then
    reaper.PCM_Source_BuildPeaks(phrase_src, 0)
  end
  if left_item  then reaper.UpdateItemInProject(left_item)  end
                       reaper.UpdateItemInProject(new_item)
  if right_item then reaper.UpdateItemInProject(right_item) end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: Repair blended splice', -1)
  reaper.PreventUIRefresh(-1)

  reaper.Main_OnCommand(40047, 0)

  return {
    ok                   = true,
    new_item             = new_item,
    left_item            = left_item,
    right_item           = right_item,
    phrase_len           = phrase_len,
    gap_len              = right_src_t - left_src_t,
    shifted_secs         = shifted_secs,
    left_blend           = left_blend,
    right_blend          = right_blend,
    left_xfade_secs      = F_left,
    right_xfade_secs     = F_right,
    alignment_used       = true,
    blended              = true,
    stretch_playrate     = (stretch_r ~= 1.0) and stretch_r or nil,
    volume_gain_db       = volume_gain_db,
    volume_match_applied = volume_match_applied,
  }
end

return M

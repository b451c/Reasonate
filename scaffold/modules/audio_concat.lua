-- modules/audio_concat.lua
-- NS-G (2026-05-14) — concatenate selected source-time regions z REAPER item
-- do single mono 22.05kHz 16-bit PCM WAV (TARGET_SR; header mówił 44.1 —
-- M7 errata). Used dla speaker-aware IVC clone
-- source selection: user picks N regions w speaker_picker modal, plugin
-- concatuje wybrane fragmenty audio → uploaduje do ElevenLabs IVC training.
--
-- Niezmienniki:
--   #2 source plik NIGDY nie modyfikowany — AudioAccessor read-only
--   #3 main thread only — CreateTakeAudioAccessor wymaga main thread
--
-- Output format dyktowany przez ElevenLabs IVC + smaller upload:
--   - mono (1 channel) — IVC traktuje stereo jako 2× duplikat (no quality
--     benefit, double upload size). Source stereo automatycznie down-mixed
--     przez AudioAccessor gdy request nch=1.
--   - 22.05 kHz — ElevenLabs internally downsamples voice samples. 22kHz daje
--     dobrą speech quality (telephone band+) PRZY 2× mniejszym rozmiarze niż
--     44.1kHz. 11MB IVC limit = ~250s @ 22kHz mono 16-bit (vs ~125s @ 44.1kHz)
--     — wystarczy dla typical 60-180s IVC sample.
--   - 16-bit PCM — standard, lossless dla speech zakres dynamiki

local util = require 'modules.util'

local M = {}

local TARGET_SR  = 22050     -- mono speech band; 2× time budget vs 44.1
local TARGET_NCH = 1
local CHUNK_SECS = 1.0
-- ElevenLabs IVC API limit: 11MB upload. At 22050Hz mono 16-bit = 44100 B/s →
-- max ~250s. Speaker_picker validate_for_ivc używa ~240s jako safe upper bound.
M.MAX_DURATION_SECS = 240

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

----------------------------------------------------------------------------
-- WAV header writer (PCM 16-bit LE mono 44.1kHz).
-- Identyczny pattern jak audio_accessor.lua dla consistency.
----------------------------------------------------------------------------
local function write_wav_header(f, sample_rate, num_channels, num_frames)
  local bits_per_sample  = 16
  local bytes_per_sample = 2
  local block_align = num_channels * bytes_per_sample
  local byte_rate   = sample_rate * block_align
  local data_size   = num_frames * block_align
  local riff_size   = 36 + data_size

  f:write('RIFF')
  f:write(string.pack('<I4', riff_size))
  f:write('WAVE')
  f:write('fmt ')
  f:write(string.pack('<I4', 16))
  f:write(string.pack('<I2', 1))
  f:write(string.pack('<I2', num_channels))
  f:write(string.pack('<I4', sample_rate))
  f:write(string.pack('<I4', byte_rate))
  f:write(string.pack('<I2', block_align))
  f:write(string.pack('<I2', bits_per_sample))
  f:write('data')
  f:write(string.pack('<I4', data_size))
end

----------------------------------------------------------------------------
-- Float [-1, 1] → signed 16-bit PCM LE. Sub-chunked dla Lua stack limit
-- (table.unpack max ~7000 entries).
----------------------------------------------------------------------------
local function pack_chunk_int16(arr, n_total_samples)
  local parts = {}
  local SUBCHUNK = 4096
  local fmt_full = '<' .. string.rep('h', SUBCHUNK)
  local i = 1
  while i <= n_total_samples do
    local remaining = n_total_samples - i + 1
    local n_this = math.min(SUBCHUNK, remaining)
    local ints = {}
    for k = 0, n_this - 1 do
      local s = arr[i + k] or 0
      if s >  1.0 then s =  1.0 end
      if s < -1.0 then s = -1.0 end
      local v = math.floor(s * 32767 + (s >= 0 and 0.5 or -0.5))
      if v >  32767 then v =  32767 end
      if v < -32768 then v = -32768 end
      ints[k + 1] = v
    end
    if n_this == SUBCHUNK then
      parts[#parts + 1] = string.pack(fmt_full, table.unpack(ints))
    else
      local fmt_partial = '<' .. string.rep('h', n_this)
      parts[#parts + 1] = string.pack(fmt_partial, table.unpack(ints))
    end
    i = i + n_this
  end
  return table.concat(parts)
end

----------------------------------------------------------------------------
-- M.cache_path_for(source_item, regions) → path or nil
--
-- Cache key hashuje: source_path + source_size + regions serialized +
-- target_sr + target_nch. Re-concat ten sam item + ten sam zestaw regions
-- = cache hit (zero new render work). Regions w innej kolejności = different
-- hash (deterministic order matters dla user-controlled selection).
----------------------------------------------------------------------------
function M.cache_path_for(source_item, regions)
  if not source_item or not regions or #regions == 0 then return nil end
  local take = reaper.GetActiveTake(source_item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local src_path = reaper.GetMediaSourceFileName(src, '') or ''
  local src_size = util.file_size(src_path) or 0

  local regs_str = {}
  for i, r in ipairs(regions) do
    regs_str[i] = string.format('%.4f-%.4f',
      tonumber(r.start) or 0,
      tonumber(r['end']) or 0)
  end
  -- v3 cache key prefix — bumped 2026-05-14 PM4 po:
  --   v2: source-time → accessor-time conversion fix (wrong fragment rendered)
  --   v3: TARGET_SR 44100 → 22050 (fit IVC 11MB upload limit dla longer samples)
  local key_str = ('v3|%s|%d|%d|%d|%s'):format(
    src_path, src_size, TARGET_SR, TARGET_NCH,
    table.concat(regs_str, ','))
  local hash = string.format('%08x', util.simple_hash(key_str))
  util.mkdir_p(tmp_dir())
  return tmp_dir() .. path_sep() .. 'concat_' .. hash .. '.wav'
end

----------------------------------------------------------------------------
-- M.total_duration(regions) → seconds
-- Pure helper dla validation w speaker_picker.
----------------------------------------------------------------------------
function M.total_duration(regions)
  if not regions then return 0 end
  local total = 0
  for _, r in ipairs(regions) do
    local s = tonumber(r.start) or 0
    local e = tonumber(r['end']) or 0
    if e > s then total = total + (e - s) end
  end
  return total
end

----------------------------------------------------------------------------
-- M.concat_regions(source_item, regions, opts) → path, err
--
-- Renders regions [{start, end}, ...] z source_item via AudioAccessor,
-- concatenated do single mono 44.1kHz WAV. Source-time secs.
--
-- Behaviour:
--   - Cache hit (existing WAV z same hash) → return path bez render
--   - Cache miss → CreateTakeAudioAccessor, iterate regions, write WAV
--   - Empty regions → err
--   - Region out of accessor bounds → clamp (silence dla outside range)
--
-- opts (optional): { force_rebuild=true → skip cache check }
----------------------------------------------------------------------------
function M.concat_regions(source_item, regions, opts)
  opts = opts or {}
  if not source_item then return nil, 'nil source_item' end
  if not regions or #regions == 0 then return nil, 'no regions selected' end

  local take = reaper.GetActiveTake(source_item)
  if not take or reaper.TakeIsMIDI(take) then
    return nil, 'item has no audio take'
  end

  local output_path = M.cache_path_for(source_item, regions)
  if not output_path then return nil, 'cannot compute cache path' end

  -- Cache hit (file present + non-empty)
  if not opts.force_rebuild
    and util.file_exists(output_path)
    and (util.file_size(output_path) or 0) > 100
  then
    return output_path, nil
  end

  -- Compute total_frames z góry (deterministic header)
  local total_frames = 0
  for _, r in ipairs(regions) do
    local s = tonumber(r.start) or 0
    local e = tonumber(r['end']) or 0
    if e > s then
      total_frames = total_frames + math.floor((e - s) * TARGET_SR + 0.5)
    end
  end
  if total_frames <= 0 then return nil, 'zero total duration across regions' end

  -- NS-G fix (2026-05-14 PM4): regions są w SOURCE-TIME (po PM3 timestamp shift
  -- = item_offs added do Scribe word.start). AudioAccessor.GetAudioAccessorSamples
  -- przyjmuje PROJECT-TIME (= D_POSITION + offset). Bez konwersji read mapuje
  -- na wrong audio fragment (np. source 25s → przy item D_POSITION=15 audio
  -- accessor wczytuje source 30s, nie 25s — user słyszy "Hosta" tam gdzie
  -- powinien Karpathy'ego).
  --
  -- Konwersja source-time S → accessor-time A (playrate=1 assumption):
  --   A = accessor_start_time + (S - D_STARTOFFS)
  --
  -- Playrate ≠ 1 (M1 limitation): AudioAccessor zwraca content z embedded
  -- playrate distortion, więc rendered audio dla speeded item = Chipmunks
  -- speech → wrong dla IVC training. Reject z explicit error.
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local playrate  = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  if math.abs(playrate - 1.0) > 0.001 then
    return nil, ('item has playrate=%.3f (≠1.0) — NS-G M1 supports natural-rate items only'):format(playrate)
  end

  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then return nil, 'CreateTakeAudioAccessor failed' end

  local t_acc_start = reaper.GetAudioAccessorStartTime(accessor)
  local t_acc_end   = reaper.GetAudioAccessorEndTime(accessor)

  local function source_to_accessor(source_t)
    return t_acc_start + (source_t - item_offs)
  end

  util.mkdir_p(tmp_dir())
  local f, oerr = io.open(output_path, 'wb')
  if not f then
    reaper.DestroyAudioAccessor(accessor)
    return nil, 'cannot open output: ' .. tostring(oerr)
  end

  write_wav_header(f, TARGET_SR, TARGET_NCH, total_frames)

  local frames_per_chunk = math.floor(TARGET_SR * CHUNK_SECS)
  local buf = reaper.new_array(frames_per_chunk * TARGET_NCH)

  local err_msg = nil
  local frames_written = 0

  for _, r in ipairs(regions) do
    local r_start_src = tonumber(r.start) or 0
    local r_end_src   = tonumber(r['end']) or 0
    if r_end_src > r_start_src then
      -- Convert source-time → accessor-time (playrate=1 → 1:1 mapping plus
      -- offset). source_to_accessor handles item_offs + t_acc_start.
      local r_start_acc = source_to_accessor(r_start_src)
      local r_end_acc   = source_to_accessor(r_end_src)
      local read_start  = math.max(r_start_acc, t_acc_start)
      local read_end    = math.min(r_end_acc, t_acc_end)
      if read_end <= read_start then
        -- Cała region poza accessor → silence fill
        local n_silence = math.floor((r_end_src - r_start_src) * TARGET_SR + 0.5)
        if n_silence > 0 then
          f:write(string.rep('\0\0', n_silence))
          frames_written = frames_written + n_silence
        end
      else
        -- Leading silence (region.start poza item)
        local lead = math.floor((read_start - r_start_acc) * TARGET_SR + 0.5)
        if lead > 0 then
          f:write(string.rep('\0\0', lead))
          frames_written = frames_written + lead
        end

        -- Render in-bounds portion
        local r_frames = math.floor((read_end - read_start) * TARGET_SR + 0.5)
        local fdone = 0
        while fdone < r_frames do
          local fleft = r_frames - fdone
          local fchunk = math.min(frames_per_chunk, fleft)
          local n_samples = fchunk * TARGET_NCH
          local t_chunk = read_start + fdone / TARGET_SR

          buf.clear()
          local rv = reaper.GetAudioAccessorSamples(accessor,
            TARGET_SR, TARGET_NCH, t_chunk, fchunk, buf)
          if rv == -1 then
            err_msg = 'GetAudioAccessorSamples returned -1'
            break
          end

          f:write(pack_chunk_int16(buf, n_samples))
          fdone = fdone + fchunk
          frames_written = frames_written + fchunk
        end
        if err_msg then break end

        -- Trailing silence
        local trail = math.floor((r_end_acc - read_end) * TARGET_SR + 0.5)
        if trail > 0 then
          f:write(string.rep('\0\0', trail))
          frames_written = frames_written + trail
        end
      end
    end
  end

  reaper.DestroyAudioAccessor(accessor)
  f:close()

  if err_msg then
    os.remove(output_path)
    return nil, err_msg
  end

  -- Sanity check — written frames powinny match total_frames. M7: tolerancja
  -- ±1 ramka PER REGION (każdy region zaokrągla niezależnie; przy N regionach
  -- suma driftu legalnie sięga N — stały próg 1 odrzucał poprawne concaty).
  local tol = math.max(1, #regions)
  if math.abs(frames_written - total_frames) > tol then
    os.remove(output_path)
    return nil, ('frame count mismatch: written %d vs header %d')
      :format(frames_written, total_frames)
  end

  return output_path, nil
end

return M

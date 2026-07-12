-- modules/audio_accessor.lua
-- Phase 11.x — non-destructive render of an item's visible region to tmp WAV.
--
-- Goal: enable Convert/STT na trimmed itemach BEZ modyfikacji project state.
-- AudioAccessor (REAPER native API) decoduje samples on-demand z source pliku
-- używając built-in REAPER decoders (mp3/wav/flac/m4a/ogg). Read-only.
--
-- Output: 16-bit PCM WAV w `<resource>/Scripts/reasonate_tmp/render_<8hex>.wav`.
-- Sample rate i channel count = source native (bez resample/mixdown).
--
-- Niezmienniki:
--   #2 source plik nigdy nie modyfikowany — AudioAccessor read-only
--   #3 main thread only — CreateTakeAudioAccessor wymaga main thread
--
-- Używane przez:
--   - audio_render.prepare_audio_for_api (Convert) — gdy item trimmed/fade/playrate
--     ale BEZ FX (FX powodują "take has FX" reject — render via AudioAccessor
--     by zaszył FX w audio, co może zaskoczyć user'a)

local util = require 'modules.util'

local M = {}

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

----------------------------------------------------------------------------
-- WAV header writer (PCM 16-bit little-endian).
-- Standard 44-byte RIFF/WAVE/fmt /data layout.
----------------------------------------------------------------------------
local function write_wav_header(f, sample_rate, num_channels, num_frames)
  local bits_per_sample = 16
  local bytes_per_sample = 2
  local block_align = num_channels * bytes_per_sample
  local byte_rate   = sample_rate * block_align
  local data_size   = num_frames * block_align
  local riff_size   = 36 + data_size

  -- RIFF chunk
  f:write('RIFF')
  f:write(string.pack('<I4', riff_size))
  f:write('WAVE')
  -- fmt subchunk
  f:write('fmt ')
  f:write(string.pack('<I4', 16))                  -- subchunk size
  f:write(string.pack('<I2', 1))                   -- PCM format
  f:write(string.pack('<I2', num_channels))
  f:write(string.pack('<I4', sample_rate))
  f:write(string.pack('<I4', byte_rate))
  f:write(string.pack('<I2', block_align))
  f:write(string.pack('<I2', bits_per_sample))
  -- data subchunk header
  f:write('data')
  f:write(string.pack('<I4', data_size))
end

----------------------------------------------------------------------------
-- Float [-1, 1] → signed 16-bit PCM (clamped, rounded).
-- Pakujemy chunk całością (string.pack z multiple values) dla perf.
-- Lua 5.4 string.pack obsługuje dowolnie długi format string.
----------------------------------------------------------------------------
local function pack_chunk_int16(arr, n_total_samples)
  -- Convert n samples z reaper.array (float doubles) na int16 little-endian bytes.
  -- arr indexing 1-based per reaper.new_array convention.
  local parts = {}
  -- Process w pod-chunkach żeby table.unpack nie przekroczył stack limit
  -- (typowo ~7000). Robimy 4096 samples per pack call.
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
-- M.cache_path_for(item) → string
-- Stable hash z (source_path, source_size, item_offs, item_len, playrate).
-- Re-render itego samego trimu trafia w existing tmp file.
----------------------------------------------------------------------------
function M.cache_path_for(item)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end

  local src_path = reaper.GetMediaSourceFileName(src, '') or ''
  local src_size = util.file_size(src_path) or 0
  local offs     = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local len      = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  local rate     = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  local key_str  = ('%s|%d|%.6f|%.6f|%.6f'):format(src_path, src_size, offs, len, rate)
  local hash     = string.format('%08x', util.simple_hash(key_str))
  util.mkdir_p(tmp_dir())
  return tmp_dir() .. path_sep() .. 'render_' .. hash .. '.wav'
end

----------------------------------------------------------------------------
-- M.render_visible_to_wav(item, output_path) → ok, err
--
-- Decode visible region of item's active take do WAV (16-bit PCM, native SR/ch).
-- Output path: caller-provided. Cache hit przez M.cache_path_for + file_exists
-- check robi caller (np. Convert flow).
--
-- Pre-FX (take FX nie applied). Wszystkie inne aspekty (volume/pan/playrate)
-- zwracane jako effective audio.
----------------------------------------------------------------------------
function M.render_visible_to_wav(item, output_path)
  if not item then return false, 'nil item' end
  if not output_path or output_path == '' then return false, 'empty output_path' end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return false, 'item has no audio take'
  end

  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return false, 'take has no source' end

  local sr  = reaper.GetMediaSourceSampleRate(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if not sr or sr <= 0 then return false, 'invalid source sample rate' end
  if not nch or nch <= 0 then return false, 'invalid source channel count' end

  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then return false, 'CreateTakeAudioAccessor failed' end

  local t_start = reaper.GetAudioAccessorStartTime(accessor)
  local t_end   = reaper.GetAudioAccessorEndTime(accessor)
  local duration = t_end - t_start
  if duration <= 0 then
    reaper.DestroyAudioAccessor(accessor)
    return false, ('zero/negative accessor duration (%.3f..%.3f)'):format(t_start, t_end)
  end

  local total_frames = math.floor(duration * sr + 0.5)
  if total_frames <= 0 then
    reaper.DestroyAudioAccessor(accessor)
    return false, 'zero total frames'
  end

  util.mkdir_p(tmp_dir())
  local f, oerr = io.open(output_path, 'wb')
  if not f then
    reaper.DestroyAudioAccessor(accessor)
    return false, 'cannot open output: ' .. tostring(oerr)
  end

  -- WAV header (deterministyczny — total_frames znamy z góry, accessor zwraca
  -- 0 dla silent regions ale zawsze fills żądaną liczbę samples).
  write_wav_header(f, sr, nch, total_frames)

  -- Read samples w chunkach. 1s @ 48kHz stereo = 96k samples = ~768KB w arr.
  -- Tradeoff: większy chunk = mniej calls ale więcej memory; mniejszy = więcej
  -- accessor calls. 1s jest sensowny default.
  local CHUNK_SECS = 1.0
  local frames_per_chunk = math.min(total_frames, math.floor(sr * CHUNK_SECS))
  local buf = reaper.new_array(frames_per_chunk * nch)

  local frames_done = 0
  local err_msg = nil

  while frames_done < total_frames do
    local frames_left = total_frames - frames_done
    local frames_this = math.min(frames_per_chunk, frames_left)
    local samples_this = frames_this * nch
    local t_chunk = t_start + frames_done / sr

    buf.clear()

    local rv = reaper.GetAudioAccessorSamples(accessor, sr, nch, t_chunk, frames_this, buf)
    if rv == -1 then
      err_msg = 'GetAudioAccessorSamples returned -1 (error)'
      break
    end
    -- rv == 0 → no audio (silence), buffer is zeros, write as-is
    -- rv == 1 → audio present

    local bytes = pack_chunk_int16(buf, samples_this)
    f:write(bytes)
    frames_done = frames_done + frames_this
  end

  reaper.DestroyAudioAccessor(accessor)
  f:close()

  if err_msg then
    os.remove(output_path)
    return false, err_msg
  end

  return true, nil
end

----------------------------------------------------------------------------
-- M.is_renderable(item) → ok, err
-- Czy AudioAccessor da radę zrobić render — looser niż is_simple_item.
-- Akceptuje: trim, offset, fade, playrate (REAPER zaszywa playrate w samples).
-- Odrzuca: take FX (nie chcemy zaszyć FX w audio bez user awareness),
-- MIDI take, brak source path.
----------------------------------------------------------------------------
function M.is_renderable(item)
  if not item then return false, 'nil item' end
  local take = reaper.GetActiveTake(item)
  if not take then return false, 'item has no take' end
  if reaper.TakeIsMIDI(take) then return false, 'MIDI take not supported' end
  if reaper.TakeFX_GetCount(take) > 0 then
    return false, 'take has FX (would bake FX into audio — disable FX or render manually)'
  end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return false, 'take has no source' end
  return true, nil
end

return M

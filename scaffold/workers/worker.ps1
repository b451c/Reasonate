# workers/worker.ps1 - Windows wrapper dla async curl call do ElevenLabs STS.
# Mirror worker.sh 1:1 (args, sentinel triplet+headers, atomic .part publish).
# Spawn z Lua: powershell.exe -NoProfile -ExecutionPolicy Bypass -File worker.ps1 <args>
#
# UWAGA quoting: pola multipart budowane BEZ wewnetrznych cudzyslowow
# ("audio=@$Audio") - spacje w sciezkach OK; przecinek/srednik w sciezce =
# znane ograniczenie curl -F (skrajnie rzadkie na Windows).
# Komentarze bez polskich diakrytykow - PS 5.1 czyta pliki bez BOM jako ANSI.

param(
  [string]$Curl,
  [string]$Url,
  [string]$KeyFile,
  [string]$Audio,
  [string]$Model,
  [string]$SettingsFile,   # 2026-07-12: PLIK z JSON (PS -File zjada cudzyslowy w argv)
  [string]$Seed,
  [string]$RemBg,
  [string]$Out,
  [string]$Done
)

$cargs = @(
  '-X','POST', $Url,
  '-H', "@$KeyFile",
  '-F', "audio=@$Audio",
  '-F', "model_id=$Model",
  '-F', "voice_settings=<$SettingsFile",
  '-F', "seed=$Seed",
  '-F', "remove_background_noise=$RemBg",
  '-o', "$Out.part",
  '-D', "$Done.headers",
  '-w', '%{http_code}',
  '--max-time', '420',
  '--silent', '--show-error',
  '--stderr', "$Done.stderr"
)

$HttpCode = (& $Curl @cargs | Out-String).Trim()
$CurlExit = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($HttpCode)) { $HttpCode = '0' }

# Settings file zuzyty przez curl - sprzatamy (pisany per spawn przez Lua).
Remove-Item -Force -LiteralPath $SettingsFile -ErrorAction SilentlyContinue

# M1-2: atomic publish - mv TYLKO po 2xx, PRZED sentinelem.
if ($HttpCode -match '^2') {
  Move-Item -Force -LiteralPath "$Out.part" -Destination $Out -ErrorAction SilentlyContinue
}

[System.IO.File]::WriteAllText($Done, $HttpCode)
[System.IO.File]::WriteAllText("$Done.curl_exit", "$CurlExit")
exit 0

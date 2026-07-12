# workers/worker_stt.ps1 - Windows wrapper dla ElevenLabs Scribe STT.
# Mirror worker_stt.sh (w tym plik extras M5-6: name=value per linia).
# Spawn: powershell.exe -NoProfile -ExecutionPolicy Bypass -File worker_stt.ps1 <args>

param(
  [string]$Curl,
  [string]$Url,
  [string]$KeyFile,
  [string]$Audio,
  [string]$Model,
  [string]$Lang,
  [string]$Diarize,
  [string]$Times,
  [string]$Out,
  [string]$Done,
  [string]$Extras = ''
)

$cargs = @(
  '-X','POST', $Url,
  '-H', "@$KeyFile",
  '-F', "file=@$Audio",
  '-F', "model_id=$Model"
)
if (-not [string]::IsNullOrEmpty($Lang)) {
  $cargs += @('-F', "language_code=$Lang")
}
$cargs += @('-F', "diarize=$Diarize", '-F', "timestamps_granularity=$Times")
if (-not [string]::IsNullOrEmpty($Extras) -and (Test-Path -LiteralPath $Extras)) {
  foreach ($line in [System.IO.File]::ReadAllLines($Extras)) {
    if (-not [string]::IsNullOrWhiteSpace($line)) { $cargs += @('-F', $line) }
  }
}
$cargs += @(
  '-o', $Out,
  '-D', "$Done.headers",
  '-w', '%{http_code}',
  '--max-time', '600',
  '--silent', '--show-error',
  '--stderr', "$Done.stderr"
)

$HttpCode = (& $Curl @cargs | Out-String).Trim()
$CurlExit = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($HttpCode)) { $HttpCode = '0' }

[System.IO.File]::WriteAllText($Done, $HttpCode)
[System.IO.File]::WriteAllText("$Done.curl_exit", "$CurlExit")
exit 0

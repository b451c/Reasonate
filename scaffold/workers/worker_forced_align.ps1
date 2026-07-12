# workers/worker_forced_align.ps1 - Windows wrapper dla /v1/forced-alignment.
# Mirror worker_forced_align.sh (tekst z PLIKU: -F "text=<sciezka" - omija
# pieklo escapowania cudzyslowow w tlumaczeniach dialogow).

param(
  [string]$Curl,
  [string]$Url,
  [string]$KeyFile,
  [string]$Audio,
  [string]$TextFile,
  [string]$Out,
  [string]$Done
)

$cargs = @(
  '-X','POST', $Url,
  '-H', "@$KeyFile",
  '-F', "file=@$Audio",
  '-F', "text=<$TextFile",
  '-o', $Out,
  '-D', "$Done.headers",
  '-w', '%{http_code}',
  '--max-time', '180',
  '--silent', '--show-error',
  '--stderr', "$Done.stderr"
)

$HttpCode = (& $Curl @cargs | Out-String).Trim()
$CurlExit = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($HttpCode)) { $HttpCode = '0' }

[System.IO.File]::WriteAllText($Done, $HttpCode)
[System.IO.File]::WriteAllText("$Done.curl_exit", "$CurlExit")
exit 0

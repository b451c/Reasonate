# workers/worker_update.ps1 - Windows wrapper dla update-check.
# Mirror worker_update.sh: GET GitHub Releases API, zero API key,
# User-Agent wymagany. Sentinel triplet + .headers.
# Spawn: powershell.exe -NoProfile -ExecutionPolicy Bypass -File worker_update.ps1 <curl> <url> <out> <done>

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Argv
)

$Curl = $Argv[0]; $Url = $Argv[1]; $Out = $Argv[2]; $Done = $Argv[3]

$cargs = @(
  '-X', 'GET', $Url,
  '-H', 'User-Agent: Reasonate',
  '-H', 'Accept: application/vnd.github+json',
  '-o', $Out,
  '-D', "$Done.headers",
  '-w', '%{http_code}',
  '--max-time', '15',
  '--silent', '--show-error',
  '--stderr', "$Done.stderr"
)

$HttpCode = (& $Curl @cargs | Out-String).Trim()
$CurlExit = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($HttpCode)) { $HttpCode = '0' }

[System.IO.File]::WriteAllText($Done, $HttpCode)
[System.IO.File]::WriteAllText("$Done.curl_exit", "$CurlExit")
exit 0

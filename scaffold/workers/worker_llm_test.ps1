# workers/worker_llm_test.ps1 - Windows mirror worker_llm_test.sh.
# GET list-models providera = darmowa walidacja klucza. Sentinel triplet.
# Spawn: powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File worker_llm_test.ps1 <provider> <curl> <url> <keyfile> <out> <done>

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Argv
)

$Provider = $Argv[0]; $Curl = $Argv[1]; $Url = $Argv[2]
$KeyFile = $Argv[3]; $Out = $Argv[4]; $Done = $Argv[5]

$cargs = @('-X', 'GET', $Url, '-H', "@$KeyFile")
if ($Provider -eq 'anthropic') {
  $cargs += @('-H', 'anthropic-version: 2023-06-01')
}
$cargs += @(
  '-o', $Out,
  '-D', "$Done.headers",
  '-w', '%{http_code}',
  '--max-time', '20',
  '--silent', '--show-error',
  '--stderr', "$Done.stderr"
)

$HttpCode = (& $Curl @cargs | Out-String).Trim()
$CurlExit = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($HttpCode)) { $HttpCode = '0' }

[System.IO.File]::WriteAllText($Done, $HttpCode)
[System.IO.File]::WriteAllText("$Done.curl_exit", "$CurlExit")
exit 0

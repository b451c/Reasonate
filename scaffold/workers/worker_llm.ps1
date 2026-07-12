# workers/worker_llm.ps1 - Windows wrapper dla LLM providers (dubbing/enhance/sfx).
# Mirror worker_llm.sh: POST JSON body -> JSON response; auth header w key file;
# anthropic dostaje dodatkowy naglowek anthropic-version.

param(
  [string]$Provider,
  [string]$Curl,
  [string]$Url,
  [string]$KeyFile,
  [string]$Body,
  [string]$Out,
  [string]$Done
)

$known = @('anthropic','openai','gemini','deepseek','grok','mistral')
if ($known -notcontains $Provider) { exit 1 }

$cargs = @('-X','POST', $Url, '-H', "@$KeyFile")
if ($Provider -eq 'anthropic') {
  $cargs += @('-H', 'anthropic-version: 2023-06-01')
}
$cargs += @(
  '-H', 'Content-Type: application/json',
  '--data-binary', "@$Body",
  '-o', $Out,
  '-D', "$Done.headers",
  '-w', '%{http_code}',
  '--max-time', '120',
  '--silent', '--show-error',
  '--stderr', "$Done.stderr"
)

$HttpCode = (& $Curl @cargs | Out-String).Trim()
$CurlExit = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($HttpCode)) { $HttpCode = '0' }

[System.IO.File]::WriteAllText($Done, $HttpCode)
[System.IO.File]::WriteAllText("$Done.curl_exit", "$CurlExit")
exit 0

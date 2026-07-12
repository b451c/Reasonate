# workers/worker_voice_op.ps1 - Windows wrapper dla ElevenLabs voice ops.
# Mirror worker_voice_op.sh: pierwszy arg = op, reszta pozycyjna per op.
# Ops: train delete rename refresh quota tts tts_ts dialogue shared_list
#      add_shared isolate similar_voices sfx music voice_design_previews
#      voice_design_create
# Sentinel triplet + .headers jak w sh; atomic .part publish (M1-2) dla
# ops binarnych (tts/dialogue/sfx/music/isolate).
# Spawn: powershell.exe -NoProfile -ExecutionPolicy Bypass -File worker_voice_op.ps1 <op> <args...>

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Argv
)

$Op = $Argv[0]
$AtomicOut = $false
$Out = ''
$Done = ''
$cargs = @()

switch ($Op) {
  'train' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Name = $Argv[4]; $Sample = $Argv[5]; $Out = $Argv[6]; $Done = $Argv[7]
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-F',"name=$Name",'-F',"files=@$Sample",
      '-o',$Out,'--max-time','180')
  }
  'delete' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Out = $Argv[4]; $Done = $Argv[5]
    $cargs = @('-X','DELETE',$Url,'-H',"@$KeyFile",'-o',$Out,'--max-time','30')
  }
  'rename' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Name = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-F',"name=$Name",'-o',$Out,'--max-time','30')
  }
  'refresh' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Out = $Argv[4]; $Done = $Argv[5]
    $cargs = @('-X','GET',$Url,'-H',"@$KeyFile",'-o',$Out,'--max-time','60')
  }
  'quota' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Out = $Argv[4]; $Done = $Argv[5]
    $cargs = @('-X','GET',$Url,'-H',"@$KeyFile",'-o',$Out,'--max-time','30')
  }
  'tts' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $AtomicOut = $true
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json','-H','Accept: audio/mpeg',
      '--data-binary',"@$Body",'-o',"$Out.part",'--max-time','120')
  }
  'tts_ts' {
    # M5-1: with-timestamps - response JSON, NIE binarne mp3.
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json','-H','Accept: application/json',
      '--data-binary',"@$Body",'-o',$Out,'--max-time','120')
  }
  'dialogue' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $AtomicOut = $true
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json','-H','Accept: audio/mpeg',
      '--data-binary',"@$Body",'-o',"$Out.part",'--max-time','180')
  }
  'sfx' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $AtomicOut = $true
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json','-H','Accept: audio/mpeg',
      '--data-binary',"@$Body",'-o',"$Out.part",'--max-time','120')
  }
  'music' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $AtomicOut = $true
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json','-H','Accept: audio/mpeg',
      '--data-binary',"@$Body",'-o',"$Out.part",'--max-time','300')
  }
  'shared_list' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Out = $Argv[4]; $Done = $Argv[5]
    $cargs = @('-X','GET',$Url,'-H',"@$KeyFile",'-o',$Out,'--max-time','60')
  }
  'add_shared' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json',
      '--data-binary',"@$Body",'-o',$Out,'--max-time','60')
  }
  'isolate' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Audio = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $AtomicOut = $true
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",'-H','Accept: audio/mpeg',
      '-F',"audio=@$Audio",'-o',"$Out.part",'--max-time','180')
  }
  'similar_voices' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Audio = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $Similarity = if ($Argv.Count -gt 7) { $Argv[7] } else { '' }
    $TopK       = if ($Argv.Count -gt 8) { $Argv[8] } else { '' }
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",'-F',"audio_file=@$Audio")
    if (-not [string]::IsNullOrEmpty($Similarity)) {
      $cargs += @('-F',"similarity_threshold=$Similarity")
    }
    if (-not [string]::IsNullOrEmpty($TopK)) {
      $cargs += @('-F',"top_k=$TopK")
    }
    $cargs += @('-o',$Out,'--max-time','60')
  }
  'voice_design_previews' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json',
      '--data-binary',"@$Body",'-o',$Out,'--max-time','120')
  }
  'voice_design_create' {
    $Curl = $Argv[1]; $Url = $Argv[2]; $KeyFile = $Argv[3]
    $Body = $Argv[4]; $Out = $Argv[5]; $Done = $Argv[6]
    $cargs = @('-X','POST',$Url,'-H',"@$KeyFile",
      '-H','Content-Type: application/json',
      '--data-binary',"@$Body",'-o',$Out,'--max-time','60')
  }
  default {
    # Unknown op - caller bug; nie znamy DONE path, brak sentinela.
    exit 1
  }
}

$cargs += @(
  '-D', "$Done.headers",
  '-w', '%{http_code}',
  '--silent', '--show-error',
  '--stderr', "$Done.stderr"
)

$HttpCode = (& $Curl @cargs | Out-String).Trim()
$CurlExit = $LASTEXITCODE
if ([string]::IsNullOrWhiteSpace($HttpCode)) { $HttpCode = '0' }

# M1-2: atomic publish do cache - mv PRZED sentinelem, TYLKO po 2xx.
if ($AtomicOut -and $HttpCode -match '^2') {
  Move-Item -Force -LiteralPath "$Out.part" -Destination $Out -ErrorAction SilentlyContinue
}

[System.IO.File]::WriteAllText($Done, $HttpCode)
[System.IO.File]::WriteAllText("$Done.curl_exit", "$CurlExit")
exit 0

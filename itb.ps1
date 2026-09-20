<#
itb.ps1 -- set up and run ITB, on Windows without WSL.

  .\itb.ps1                 first run: ask, configure, start. Later: just start.
  .\itb.ps1 -Reconfigure    ask everything again (keeps a backup of .env)
  .\itb.ps1 -Check          report what is missing. Changes nothing, starts nothing
  .\itb.ps1 -Logs           start, then follow the API log

It is safe to run repeatedly: it never overwrites .env or license.json without
being told to, and -Check touches nothing at all.

-----------------------------------------------------------------------------
THIS SCRIPT HAS A TWIN: itb.sh, for Linux, macOS and WSL. The two must stay in
step, and nothing checks that automatically -- this repository has no test
harness. If you change one, walk the other through the same numbered sections:

  1 preflight    2 configure    3 licence    4 data directory    5 start

Keep the section numbers and the questions identical. A twin that drifts is
worse than no twin, because the two answers disagree and neither says so.

One difference is deliberate and not drift: section 4. On Windows there is no
`chown` and Docker Desktop maps file ownership itself, so the uid check that
itb.sh performs does not apply and this script says so instead of pretending.
-----------------------------------------------------------------------------
#>

[CmdletBinding()]
param(
  [switch]$Check,
  [switch]$Reconfigure,
  [switch]$Logs
)

$ErrorActionPreference = 'Stop'
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)

$script:Problems = 0
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  ok   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Fail($m) { $script:Problems++; Write-Host "  fail $m" -ForegroundColor Red }
function Die($m)  { Fail $m; exit 1 }

function ReadReply {
  # Read-Host talks to the console host, which ignores a redirected stdin -- and
  # -AsSecureString on a pipe blocks for ever. itb.sh's `read`/`read -rs` handle
  # a terminal and a pipe alike, so handle both here too, and read every answer
  # through the same reader so they cannot disagree about the stream position.
  # Nothing is hidden when the input is piped: there is no terminal to hide from.
  param([string]$prompt, [switch]$Secret)
  if ([Console]::IsInputRedirected) {
    Write-Host "  ${prompt}: " -NoNewline
    $line = [Console]::In.ReadLine()
    Write-Host ''
    if ($null -eq $line) { return '' }
    return $line
  }
  if ($Secret) {
    $secure = Read-Host "  $prompt" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
  return (Read-Host "  $prompt")
}

function Ask($prompt, $default) {
  $suffix = if ($default) { " [$default]" } else { "" }
  $reply = ReadReply "$prompt$suffix"
  if ([string]::IsNullOrWhiteSpace($reply)) { return $default }
  return $reply
}

function AskSecret($prompt) { return (ReadReply $prompt -Secret) }

function Confirm($prompt) {
  $reply = ReadReply "$prompt [y/N]"
  return ($reply -match '^(y|yes)$')
}

function Sha256Of([string]$text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
  } finally { $sha.Dispose() }
}

function RandomHex32 {
  # RandomNumberGenerator::Fill is .NET Core only, so it is absent from Windows
  # PowerShell 5.1 -- which is what `powershell.exe` is on a stock Windows box.
  # Create() has been on both runtimes since forever.
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $bytes = [byte[]]::new(32)
    $rng.GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
  } finally { $rng.Dispose() }
}

function SetEnvValue($file, $key, $value) {
  $lines = Get-Content -LiteralPath $file
  $found = $false
  $out = foreach ($line in $lines) {
    if ($line -match "^$([regex]::Escape($key))=") { $found = $true; "$key=$value" } else { $line }
  }
  if (-not $found) { $out = @($out) + "$key=$value" }
  [IO.File]::WriteAllLines((Resolve-Path -LiteralPath $file), $out, [Text.UTF8Encoding]::new($false))
}

function InvokeCompose {
  # docker compose, with .env as the ONLY source of configuration.
  $saved = @{}
  if (Test-Path -LiteralPath '.env') {
    foreach ($line in Get-Content -LiteralPath '.env') {
      if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=') {
        $k = $Matches[1]
        if (Test-Path -LiteralPath "Env:\$k") {
          $saved[$k] = (Get-Item -LiteralPath "Env:\$k").Value
          Remove-Item -LiteralPath "Env:\$k"
        }
      }
    }
  }
  try { docker compose @args }
  finally { foreach ($k in $saved.Keys) { Set-Item -LiteralPath "Env:\$k" -Value $saved[$k] } }
}

function EnvValue($file, $key) {
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  $line = Select-String -LiteralPath $file -Pattern "^$([regex]::Escape($key))=" | Select-Object -First 1
  if (-not $line) { return $null }
  return ($line.Line -replace "^$([regex]::Escape($key))=", '')
}

# ---------------------------------------------------------------------------
# 1 preflight
# ---------------------------------------------------------------------------
Info 'Checking what is needed'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Die 'docker not found on PATH. Install Docker Desktop, then run this again.'
}
Ok "docker ($((docker --version) -split ',' | Select-Object -First 1))"

docker compose version *> $null
if ($LASTEXITCODE -ne 0) { Die '`docker compose` (v2) not available.' }
Ok "docker compose ($(docker compose version --short))"

docker info *> $null
if ($LASTEXITCODE -ne 0) { Die 'the Docker daemon is not reachable. Start Docker Desktop.' }
Ok 'the Docker daemon answers'

if (-not (Test-Path -LiteralPath '.env.example')) {
  Die 'no .env.example here. Run this from the directory you cloned.'
}

# ---------------------------------------------------------------------------
# 2 configure -- .env
# ---------------------------------------------------------------------------
if ($Check) {
  Info 'Configuration'
  if (Test-Path -LiteralPath '.env') {
    Ok '.env exists'
    foreach ($k in 'ITB_API_TAG', 'ITB_CLIENT_TAG', 'ITB_AUTH_USERS') {
      if (EnvValue '.env' $k) { Ok "$k is set" }
      else { Fail "$k is empty -- the stack will not start" }
    }
    if (EnvValue '.env' 'ITB_CORS_ALLOW_ORIGINS') { Ok 'ITB_CORS_ALLOW_ORIGINS is set' }
    else { Fail 'ITB_CORS_ALLOW_ORIGINS is empty -- the app loads and cannot reach the API' }
  } else {
    Fail 'no .env -- run .\itb.ps1 without -Check to create it'
  }
}
elseif ((-not (Test-Path -LiteralPath '.env')) -or $Reconfigure) {
  if (Test-Path -LiteralPath '.env') {
    Copy-Item '.env' ".env.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Warn 'your .env was copied to .env.bak.* before being rewritten'
  }
  Copy-Item '.env.example' '.env' -Force

  Info 'Configuration -- four answers, then it starts'

  # -- image tags. Both images are public, so their tags can simply be read.
  $suggested = ''
  try {
    $rows = (Invoke-RestMethod -TimeoutSec 15 -Method Get `
      -Uri 'https://hub.docker.com/v2/repositories/banianch/itb-api/tags?page_size=25').results
    $suggested = ($rows | Where-Object { $_.name -match '^v?\d+\.\d+\.\d+$' } |
                  Select-Object -First 1).name
  } catch { $suggested = '' }

  if ($suggested) { Ok "newest released tag on Docker Hub: $suggested" }
  else {
    Warn 'could not read the tag list from Docker Hub -- enter the tag by hand'
    Write-Host '        see https://hub.docker.com/u/banianch'
  }
  $tag = Ask 'Version to run' $suggested
  if (-not $tag) { Die 'no version given. Both images need the same tag.' }
  SetEnvValue '.env' 'ITB_API_TAG' $tag
  SetEnvValue '.env' 'ITB_CLIENT_TAG' $tag

  # -- the account
  Write-Host ''
  Write-Host '  Exactly one account -- a second one makes the API refuse to start.'
  $email = Ask 'Your e-mail address (this is the login)' ''
  if (-not $email) { Die 'no e-mail given.' }
  $pw1 = AskSecret 'Password'
  if (-not $pw1) { Die 'no password given.' }
  if ($pw1.Length -lt 6) { Die 'the password must be at least 6 characters.' }
  $pw2 = AskSecret 'Password again'
  if ($pw1 -ne $pw2) { Die 'the two passwords differ.' }
  SetEnvValue '.env' 'ITB_AUTH_USERS' "$email`:$(Sha256Of $pw1)"
  $pw1 = $null; $pw2 = $null
  Ok 'account configured (the password is stored only as a SHA-256 hash)'

  # -- secrets nobody should have to invent. A failure here must not abort the
  # run half-way through .env, the way itb.sh warns and carries on.
  $jwt = $null; $cred = $null
  try { $jwt = RandomHex32; $cred = RandomHex32 } catch { $jwt = $null; $cred = $null }
  if ($jwt -and $cred) {
    SetEnvValue '.env' 'ITB_JWT_SECRET' $jwt
    SetEnvValue '.env' 'ITB_CREDENTIAL_KEY' $cred
    Ok 'session key and credential key generated'
  } else {
    Warn 'could not generate random keys -- ITB_JWT_SECRET stays empty, so a restart logs you out'
  }

  # -- the port
  Write-Host ''
  $port = Ask 'HTTP port' '80'
  SetEnvValue '.env' 'ITB_HTTP_PORT' $port
  if ($port -ne '80') {
    SetEnvValue '.env' 'ITB_API_URL' "http://api.itb.localhost:$port"
    SetEnvValue '.env' 'ITB_CORS_ALLOW_ORIGINS' "http://itb.localhost:$port"
    Ok "port $port -- the browser URL and the allowed origin were adjusted with it"
  }

  Ok '.env written'
}
else {
  Ok '.env exists (use -Reconfigure to answer the questions again)'

  # Compose marks these three as required. An empty one surfaces only as an
  # interpolation error during `pull`, which this script then reports as a bad
  # image tag -- so say what is actually wrong, before it gets that far.
  $missing = @('ITB_API_TAG', 'ITB_CLIENT_TAG', 'ITB_AUTH_USERS') |
             Where-Object { -not (EnvValue '.env' $_) }
  if ($missing) {
    Fail "$($missing -join ', ') empty in .env -- the stack cannot start"
    Write-Host '        Fill it in by hand, or run .\itb.ps1 -Reconfigure to be asked again.'
    exit 1
  }
  if (-not (EnvValue '.env' 'ITB_CORS_ALLOW_ORIGINS')) {
    Warn 'ITB_CORS_ALLOW_ORIGINS is empty -- the app loads and cannot reach the API'
  }
}

# ---------------------------------------------------------------------------
# 3 licence -- the one thing this script cannot produce
# ---------------------------------------------------------------------------
Info 'Licence'
$lic = EnvValue '.env' 'ITB_LICENSE_FILE'
if (-not $lic) { $lic = './license.json' }

if (Test-Path -LiteralPath $lic) {
  $raw = Get-Content -LiteralPath $lic -Raw
  $obj = $null
  try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null }
  if ($obj -and $obj.licType) {
    $expired = $false
    if ($obj.validTo) {
      $expired = ([datetime]::Parse($obj.validTo) -lt (Get-Date).Date)
    }
    if ($expired) {
      Fail "the licence expired on $($obj.validTo) -- the API will not start. Get a new one at https://itb.banian.ch/license/"
    } else {
      Ok "licence found (type $($obj.licType), valid to $($obj.validTo))"
    }
  } else {
    Warn "$lic does not look like a licence (no licType field)"
  }
} else {
  Fail "no licence at $lic"
  Write-Host @'
        The API does not start without one. It is free of charge:
        Get your license at: https://itb.banian.ch/license/
        and save the file you get back as .\license.json
'@
  if (-not $Check) { exit 1 }
}

# ---------------------------------------------------------------------------
# 4 data directory
# ---------------------------------------------------------------------------
Info 'Data directory'
$dataDir = EnvValue '.env' 'ITB_DATA_DIR'
if (-not $dataDir) { $dataDir = './data' }

if (Test-Path -LiteralPath $dataDir) {
  Ok "$dataDir exists"
} elseif ($Check) {
  Fail "$dataDir does not exist"
} else {
  New-Item -ItemType Directory -Path $dataDir | Out-Null
  Ok "$dataDir created"
}

# ---------------------------------------------------------------------------
# 5 start
# ---------------------------------------------------------------------------
if ($Check) {
  if ($script:Problems -gt 0) {
    Info "$($script:Problems) problem(s) found -- nothing was changed and nothing was started"
    exit 1
  }
  Info 'Everything needed is in place -- nothing was changed and nothing was started'
  exit 0
}

Info 'Starting'
InvokeCompose pull
if ($LASTEXITCODE -ne 0) {
  Fail 'could not pull the images.'
  Write-Host '        If the tag does not exist, the tags are listed at'
  Write-Host '        https://hub.docker.com/u/banianch -- then .\itb.ps1 -Reconfigure'
  exit 1
}
InvokeCompose up -d
if ($LASTEXITCODE -ne 0) { Die 'docker compose up failed.' }

$port = EnvValue '.env' 'ITB_HTTP_PORT'
if (-not $port) { $port = '80' }
if ($port -eq '80') { $base = 'http://itb.localhost'; $api = 'http://api.itb.localhost' }
else { $base = "http://itb.localhost:$port"; $api = "http://api.itb.localhost:$port" }

Write-Host ''
Info 'ITB is starting'
Write-Host ('    {0,-34} the modeller' -f $base)
Write-Host ('    {0,-34} the user guide' -f "$base/user-docs/")
Write-Host ('    {0,-34} the API reference' -f "$api/docs")
Write-Host ''
Write-Host '  The API verifies the licence before it serves anything, so give it a few'
Write-Host '  seconds. If it does not come up:'
Write-Host '      docker compose logs itb-api'
Write-Host ''

if ($Logs) { InvokeCompose logs -f itb-api }

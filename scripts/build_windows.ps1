param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Love,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Version,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Output
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$Love = [IO.Path]::GetFullPath($Love)
$Output = [IO.Path]::GetFullPath($Output)
if ($Love -eq $Output) { throw "build_windows: output must differ from payload" }
if (-not (Test-Path -LiteralPath $Love -PathType Leaf)) { throw "build_windows: payload does not exist" }

$identity = @'
from pathlib import Path
import hashlib
import re
import sys
import zipfile
sys.path.insert(0, str(Path("scripts").resolve()))
from pack_love import validate_identity
payload, wanted = Path(sys.argv[1]), sys.argv[2]
if wanted == "dev":
    raise SystemExit("build_windows: release version must be a complete semantic version")
with zipfile.ZipFile(payload) as archive:
    identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
    version = re.search(r'version\s*=\s*"([^"]+)"', identity)
    commit = re.search(r'commit\s*=\s*"([0-9a-f]{40})"', identity)
    if version is None or commit is None or version.group(1) != wanted:
        raise SystemExit("build_windows: payload identity does not match --version")
    validate_identity(version.group(1), commit.group(1))
    if archive.testzip() is not None:
        raise SystemExit("build_windows: payload CRC verification failed")
print(commit.group(1))
print(hashlib.sha256(payload.read_bytes()).hexdigest())
'@ | python3 - $Love $Version
if ($LASTEXITCODE -ne 0) { throw "build_windows: payload validation failed" }
$payloadCommit, $payloadSha = $identity

$pins = Get-Content -Raw -LiteralPath (Join-Path $repo "scripts/packaging/pins.json") | ConvertFrom-Json
$runtimePin = $pins.love_desktop.windows
$cache = if ($env:PORTEMON_BUILD_CACHE) { $env:PORTEMON_BUILD_CACHE } else { Join-Path $repo ".agents/tmp/portemon-release/cache" }
New-Item -ItemType Directory -Force -Path $cache, (Split-Path -Parent $Output) | Out-Null
$runtime = Join-Path $cache $runtimePin.file
if (-not (Test-Path -LiteralPath $runtime)) {
  Invoke-WebRequest -Uri $runtimePin.url -OutFile $runtime
}
if ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtimePin.archive.value) {
  throw "build_windows: official runtime checksum mismatch"
}
if ((Get-Item -LiteralPath $runtime).Length -ne $runtimePin.bytes) {
  throw "build_windows: official runtime size differs from its pin"
}

$stage = Join-Path (Split-Path -Parent $Output) (".portemon-windows-" + [Guid]::NewGuid().ToString("N"))
$temporaryOutput = "$Output.tmp.zip"
$backup = "$Output.previous"
$promoted = $false
New-Item -ItemType Directory -Path $stage | Out-Null
try {
  Expand-Archive -LiteralPath $runtime -DestinationPath (Join-Path $stage "runtime")
  $engine = Join-Path $stage "runtime/love-11.5-win64"
  $product = Join-Path $stage "Portemon Nitro"
  New-Item -ItemType Directory -Path $product | Out-Null
  foreach ($name in @("love.dll", "lua51.dll", "SDL2.dll", "OpenAL32.dll", "mpg123.dll", "msvcp120.dll", "msvcr120.dll", "license.txt")) {
    $source = Join-Path $engine $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "build_windows: official runtime omitted $name" }
    Copy-Item -LiteralPath $source -Destination $product
  }
  $executable = Join-Path $product "Portemon Nitro.exe"
  Copy-Item -LiteralPath (Join-Path $engine "love.exe") -Destination $executable
  $executableStream = [IO.File]::Open($executable, [IO.FileMode]::Append, [IO.FileAccess]::Write)
  $payloadStream = [IO.File]::OpenRead($Love)
  try {
    $payloadStream.CopyTo($executableStream)
    $executableStream.Flush()
  } finally {
    $payloadStream.Dispose()
    $executableStream.Dispose()
  }

  $nfd = Join-Path $stage "nfd"
  python3 (Join-Path $repo "scripts/packaging/build_nfd.py") --platform windows --arch x64 --output $nfd
  if ($LASTEXITCODE -ne 0) { throw "build_windows: NFDe build failed" }
  $native = Join-Path $product "app/native/windows/x64"
  New-Item -ItemType Directory -Force -Path $native | Out-Null
  Copy-Item -LiteralPath (Join-Path $nfd "nfd.dll") -Destination $native
  Copy-Item -LiteralPath (Join-Path $nfd "LICENSE") -Destination $native
  Copy-Item -LiteralPath (Join-Path $repo "LICENSE") -Destination $product

  $headers = & dumpbin /headers $executable 2>&1
  if ($LASTEXITCODE -ne 0 -or ($headers -join "`n") -notmatch "x64") { throw "build_windows: fused executable is not x64" }
  $verify = @'
from pathlib import Path
import hashlib
import sys
executable, payload, wanted = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
data = executable.read_bytes()
if not data.endswith(payload.read_bytes()):
    raise SystemExit("build_windows: fused payload bytes differ")
if hashlib.sha256(data[data.rfind(b"PK\x03\x04"):]).hexdigest() != wanted:
    raise SystemExit("build_windows: fused payload digest differs")
'@ | python3 - $executable $Love $payloadSha
  if ($LASTEXITCODE -ne 0) { throw "build_windows: fused payload verification failed" }

  Compress-Archive -LiteralPath $product -DestinationPath $temporaryOutput -CompressionLevel Optimal
  $archiveCheck = @'
from pathlib import Path
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    if archive.testzip() is not None or sum(name.endswith(".exe") for name in names) != 1:
        raise SystemExit("build_windows: ZIP verification failed")
'@ | python3 - $temporaryOutput
  if ($LASTEXITCODE -ne 0) { throw "build_windows: ZIP verification failed" }

  $smokeRoot = Join-Path $stage "smoke"
  $smokeInstall = Join-Path $smokeRoot "read-only-install"
  $smokeCwd = Join-Path $smokeRoot "unrelated-cwd"
  $smokeEnvironment = python3 (Join-Path $repo "scripts/packaging/smoke_environment.py") --platform windows --root $smokeRoot | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $null -eq $smokeEnvironment) { throw "build_windows: smoke environment validation failed" }
  New-Item -ItemType Directory -Force -Path $smokeInstall, $smokeCwd, $smokeEnvironment.APPDATA, $smokeEnvironment.LOCALAPPDATA, $smokeEnvironment.USERPROFILE, $smokeEnvironment.PORTEMON_SAVE_DIR | Out-Null
  Expand-Archive -LiteralPath $temporaryOutput -DestinationPath $smokeInstall
  $smokeExe = Join-Path $smokeInstall "Portemon Nitro/Portemon Nitro.exe"
  $smokeOut = Join-Path $smokeRoot "stdout.log"
  $smokeErr = Join-Path $smokeRoot "stderr.log"
  $smokeVariableNames = @("APPDATA", "LOCALAPPDATA", "USERPROFILE", "PORTEMON_SAVE_DIR", "ALSOFT_DRIVERS")
  $previousEnvironment = @{}
  foreach ($name in $smokeVariableNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
  }
  $smoke = $null
  try {
    foreach ($name in $smokeVariableNames) {
      Set-Item -Path "Env:$name" -Value $smokeEnvironment.$name
    }
    $smoke = Start-Process -FilePath $smokeExe -WorkingDirectory $smokeCwd -PassThru -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr
    Start-Sleep -Seconds 5
    if ($smoke.HasExited) { throw "build_windows: packaged application exited during startup" }
    $diagnostics = (Get-Content -LiteralPath $smokeOut -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $smokeErr -ErrorAction SilentlyContinue)
    if (($diagnostics -join "`n") -match "(?i)Error:|stack traceback|boot\.lua") { throw "build_windows: packaged application reported a boot error" }
  } finally {
    try {
      if ($null -ne $smoke) {
        if (-not $smoke.HasExited) { Stop-Process -Id $smoke.Id -Force }
        $smoke.WaitForExit()
      }
    } finally {
      foreach ($name in $smokeVariableNames) {
        Set-Item -Path "Env:$name" -Value $previousEnvironment[$name]
      }
    }
  }

  if (Test-Path -LiteralPath $Output) { Move-Item -LiteralPath $Output -Destination $backup }
  try {
    Move-Item -LiteralPath $temporaryOutput -Destination $Output
    $promoted = $true
  } catch {
    if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $Output)) { Move-Item -LiteralPath $backup -Destination $Output }
    throw
  }
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
  Write-Output "build_windows: wrote $Output (payload $payloadSha, commit $payloadCommit)"
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $promoted) { Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue }
}

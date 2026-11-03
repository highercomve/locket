# Install Locket on Windows from a GitHub release, for this user (no admin):
#
#   irm https://raw.githubusercontent.com/highercomve/locket/main/scripts/install.ps1 | iex
#
#   %LOCALAPPDATA%\locket\bin\locket.exe   the command line, put on your PATH
#   %LOCALAPPDATA%\Programs\Locket         the desktop app (its own installer,
#                                          run silently; Start menu entry)
#
# Every file is checked against the release's SHA256SUMS before it is used.
# The vault is never touched. Settings, as environment variables (for
# `irm | iex`) or as parameters when the script is saved and run:
#
#   $env:LOCKET_VERSION = '0.2.0'   -Version 0.2.0   a release (default: the latest)
#   $env:LOCKET_BIN_DIR = 'DIR'     -BinDir DIR      where locket.exe goes
#   $env:LOCKET_NO_APP = '1'        -NoApp           only the command line
#
# Windows PowerShell 5.1 and PowerShell 7 both work. Locket is built for
# x86_64; Windows on Arm runs it under emulation.
[CmdletBinding()]
param(
    [string]$Version = $env:LOCKET_VERSION,
    [string]$BinDir = $env:LOCKET_BIN_DIR,
    [switch]$NoApp = [bool]$env:LOCKET_NO_APP
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest's progress bar makes downloads many times slower on 5.1.
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 may default to TLS 1.0, which GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo = 'highercomve/locket'
if (-not $BinDir) { $BinDir = Join-Path $env:LOCALAPPDATA 'locket\bin' }

function Fail([string]$message) {
    Write-Host "error: $message" -ForegroundColor Red
    # `exit` would close the window of an `irm | iex` session: throw instead.
    throw $message
}

if ($Version) {
    $Version = $Version.TrimStart('v')
} else {
    try {
        $release = Invoke-RestMethod -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' } "https://api.github.com/repos/$repo/releases/latest"
    } catch {
        Fail "could not find the latest release: $($_.Exception.Message)"
    }
    $Version = ([string]$release.tag_name).TrimStart('v')
}
if ($Version -notmatch '^[0-9A-Za-z.-]+$') { Fail "not a version: $Version" }
$base = "https://github.com/$repo/releases/download/v$Version"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("locket-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    Write-Host "Locket $Version for Windows"
    $sumsPath = Join-Path $tmp 'SHA256SUMS'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sumsPath
    } catch {
        Fail "no release v$Version (or no SHA256SUMS in it)"
    }
    $sums = @{}
    foreach ($line in Get-Content $sumsPath) {
        if ($line -match '^([0-9a-fA-F]{64}) [ *]?(.+)$') { $sums[$Matches[2]] = $Matches[1].ToLower() }
    }

    # Download a release file into $tmp, check it against SHA256SUMS, return its path.
    function Get-Asset([string]$name) {
        if (-not $sums.ContainsKey($name)) { Fail "$name is not in the v$Version release" }
        $path = Join-Path $tmp $name
        Write-Host "Downloading $name"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $path
        } catch {
            Fail "could not download ${name}: $($_.Exception.Message)"
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
        if ($hash -ne $sums[$name]) { Fail "$name does not match its SHA-256 in SHA256SUMS" }
        return $path
    }

    # The command line.
    $cli = Get-Asset "locket-$Version-x86_64-windows.exe"
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $dest = Join-Path $BinDir 'locket.exe'
    try {
        Move-Item -Force -LiteralPath $cli -Destination $dest
    } catch {
        Fail "could not replace ${dest} (is locket running?): $($_.Exception.Message)"
    }
    Write-Host "Installed the command line to $dest"

    # On the user's PATH, for new terminals and for this one.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if ($parts -notcontains $BinDir) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $BinDir) -join ';'), 'User')
        Write-Host "Added $BinDir to your PATH (new terminals see it)"
    }
    if (@($env:Path -split ';') -notcontains $BinDir) { $env:Path = "$env:Path;$BinDir" }

    # The app: its own per-user installer, run silently.
    if (-not $NoApp) {
        $setup = Get-Asset "Locket-$Version-setup.exe"
        Write-Host "Installing the app"
        $p = Start-Process -FilePath $setup -ArgumentList '/S' -PassThru -Wait
        if ($p.ExitCode -ne 0) { Fail "the app's installer exited with $($p.ExitCode)" }
        Write-Host "Installed the app (Start menu: Locket)"
    }

    Write-Host "Done. 'locket update' updates the command line; the app updates itself."
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Waired one-liner installer for Windows.

.DESCRIPTION
    End-user-facing entry point. Designed to be hosted on the public
    waired-install mirror and run via:

        iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 | iex

    The script:
        1. Re-launches itself elevated when not already Administrator
           (UAC prompt).
        2. Downloads `waired-windows-amd64.zip` + `.sha256` from the
           public mirror, verifies the hash.
        3. Stops any existing `waired-agent` service.
        4. Extracts the zip to %ProgramFiles%\Waired\.
        5. Hands off to `waired-agent.exe install`, which registers the
           Windows Service, the Event Log source, and applies the
           restrictive DACL on the state directory. SCM register logic
           is NOT duplicated here.
        6. Prints next-step instructions that mirror the Linux
           install.sh "Next steps" block.

    The Linux counterpart is packaging/install/install.sh -- keep this
    script's UX (env vars, --dry-run, --help) parallel to it.

    For developers building from a repo checkout, see
    scripts/install/waired-agent-windows.ps1 instead -- that script takes
    a pre-built local exe and skips the download path.

.PARAMETER DryRun
    Print every privileged command without running it.

.PARAMETER Help
    Print help and exit.

.EXAMPLE
    iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 | iex

.EXAMPLE
    # Pin to a specific tag
    $env:WAIRED_VERSION = 'v1.2.3'
    iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 | iex

.EXAMPLE
    # Headless server: skip tray
    $env:WAIRED_NO_TRAY = '1'
    iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Help,
    # Internal: non-empty when re-invoked elevated by Phase 1 after the
    # download has already happened. Skips re-download and goes straight
    # to the privileged install steps. Not documented in -Help -- callers
    # never set this directly.
    [string]$StagedZipPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# -------------------------------------------------------------------
# Configuration (overridable via environment, mirrors install.sh)
# -------------------------------------------------------------------

# Public mirror that hosts install.ps1 itself plus the per-tag Windows
# release assets (zip + sha256 + Setup.exe). The main `gen16k/waired`
# repository is private; releases there are not publicly downloadable.
# Each `v*` tag mirrors its Windows assets here via release.yml.
$BaseUrl    = if ($env:WAIRED_INSTALL_BASE_URL) { $env:WAIRED_INSTALL_BASE_URL } `
              else { 'https://github.com/gen16k/waired-install/releases' }
$Version    = if ($env:WAIRED_VERSION) { $env:WAIRED_VERSION } else { 'latest' }
$NoTray     = [bool]$env:WAIRED_NO_TRAY
$StateDir   = $env:WAIRED_STATE_DIR

$InstallDir  = Join-Path $env:ProgramFiles 'Waired'
$ServiceName = 'waired-agent'
$ZipName     = 'waired-windows-amd64.zip'
$ShaName     = "$ZipName.sha256"

# -------------------------------------------------------------------
# common_* helpers (mirror install.sh naming)
# -------------------------------------------------------------------

function Common-Log  { param([string]$Msg) Write-Host "[waired] $Msg" -ForegroundColor Cyan }
function Common-Warn { param([string]$Msg) Write-Host "[waired] $Msg" -ForegroundColor Yellow }
function Common-Die  {
    param([string]$Msg)
    Write-Host "[waired] $Msg" -ForegroundColor Red
    exit 1
}

# Either run the script-block or, in dry-run mode, print a description.
function Common-Run {
    param(
        [string]$Description,
        [scriptblock]$Action
    )
    if ($DryRun) {
        Write-Host "[dry-run] $Description" -ForegroundColor DarkGray
        return
    }
    & $Action
}

function Show-Help {
@'
install.ps1 -- install Waired for Windows.

Usage:
  iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 | iex

  # Or, with options:
  $script = iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1
  Invoke-Expression "& { $($script.Content) } -DryRun"

Switches:
  -DryRun   Print every privileged command without executing it.
  -Help     Print this help.

Environment variables:
  WAIRED_VERSION           Pin a specific release tag (e.g. v1.2.3). Default: latest.
  WAIRED_NO_TRAY           If set, skip waired-tray.exe.
  WAIRED_STATE_DIR         Override on-disk state location. Default: %ProgramData%\waired.
  WAIRED_INSTALL_BASE_URL  Override the mirror base URL (tests / staging).

Diagnostics:
  Get-Service waired-agent
  Get-WinEvent -ProviderName waired-agent -LogName Application -MaxEvents 20

Uninstall:
  - Settings -> Apps -> Waired -> Uninstall (when the GUI installer was used)
  - or: & "C:\Program Files\Waired\waired-agent.exe" uninstall
'@ | Write-Host
}

# -------------------------------------------------------------------
# detect_* -- OS / arch validation
# -------------------------------------------------------------------

function Detect-Platform {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -ne 'AMD64') {
        Common-Die "unsupported CPU architecture: $arch. Waired ships windows/amd64 today."
    }
    $os = [Environment]::OSVersion
    # Windows 10 1809 (build 17763) is the minimum for the path /
    # service / DACL APIs the agent relies on.
    if ($os.Version.Build -lt 17763) {
        Common-Die "Windows 10 1809 (build 17763) or newer is required. Detected build $($os.Version.Build)."
    }
    Common-Log "Detected Windows $($os.Version) ($arch)"
}

# -------------------------------------------------------------------
# Self-elevation
# -------------------------------------------------------------------

function Test-Admin {
    $id   = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prin = New-Object Security.Principal.WindowsPrincipal($id)
    return $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-invoke this script elevated, AFTER the un-elevated download +
# checksum-verify have already finished. The staged zip path is passed
# along so the elevated child does not re-download (one UAC prompt
# total, no double-fetch). Two cases for re-invocation source:
#   (a) Running from a .ps1 on disk (`powershell -File install.ps1`):
#       $PSCommandPath gives the absolute script path; re-launch
#       powershell.exe -File against it with -StagedZipPath.
#   (b) Sourced via `iwr | iex`: $PSCommandPath is null. Re-fetch the
#       script body from the same mirror URL and pass -StagedZipPath
#       to it via Invoke-Expression's scriptblock-wrapping trick.
#
# We deliberately do NOT use sudo.exe: it ships only on Windows 11
# 24H2+ Pro builds and is not present on the majority of supported
# targets. Start-Process -Verb RunAs is universal back to Windows 10
# 1809.
function Invoke-SelfElevate {
    param([string]$ZipPath)

    Common-Log "Privileged step ahead -- requesting UAC..."

    # WAIRED_NO_TRAY / WAIRED_STATE_DIR are read from $env in the
    # elevated child too -- Start-Process inherits the parent's
    # environment block. Only the staged zip path and -DryRun need
    # explicit forwarding.
    $passthroughArgs = @('-StagedZipPath', $ZipPath)
    if ($DryRun) { $passthroughArgs += '-DryRun' }

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($PSCommandPath) {
        $psArgs += @('-File', $PSCommandPath) + $passthroughArgs
    } else {
        $url = if ($Version -eq 'latest') {
            "$BaseUrl/latest/download/install.ps1"
        } else {
            "$BaseUrl/download/$Version/install.ps1"
        }
        # iex strips param() bindings, so wrap the fetched script in a
        # call-operator block that DOES bind named parameters.
        $passthroughLiteral = ($passthroughArgs | ForEach-Object {
            if ($_ -match '^-') { $_ } else { "'" + ($_ -replace "'", "''") + "'" }
        }) -join ' '
        $bootstrap = "`$src = iwr -useb '$url'; Invoke-Expression `"& { `$(`$src.Content) } $passthroughLiteral`""
        $psArgs += @('-Command', $bootstrap)
    }

    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList $psArgs -Verb RunAs -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        Common-Die "elevated installer exited code $($proc.ExitCode)"
    }
}

# -------------------------------------------------------------------
# Asset download + verification
# -------------------------------------------------------------------

function Resolve-ReleaseBase {
    if ($Version -eq 'latest') {
        return "$BaseUrl/latest/download"
    }
    return "$BaseUrl/download/$Version"
}

function Get-AssetWithChecksum {
    param([string]$WorkDir)

    $releaseBase = Resolve-ReleaseBase
    $zipPath = Join-Path $WorkDir $ZipName
    $shaPath = Join-Path $WorkDir $ShaName

    Common-Log "Downloading $ZipName from $releaseBase"
    Common-Run "Invoke-WebRequest $releaseBase/$ZipName -> $zipPath" {
        Invoke-WebRequest -Uri "$releaseBase/$ZipName" -OutFile $zipPath -UseBasicParsing
    }
    Common-Log "Downloading $ShaName"
    Common-Run "Invoke-WebRequest $releaseBase/$ShaName -> $shaPath" {
        Invoke-WebRequest -Uri "$releaseBase/$ShaName" -OutFile $shaPath -UseBasicParsing
    }

    if ($DryRun) { return $zipPath }

    # Expect a line of the shape "<hex>  waired-windows-amd64.zip"
    $expectedLine = (Get-Content -LiteralPath $shaPath -First 1).Trim()
    if (-not $expectedLine) {
        Common-Die "checksum file is empty: $shaPath"
    }
    $expected = ($expectedLine -split '\s+')[0].ToLowerInvariant()
    $actual   = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        Common-Die "SHA-256 mismatch for ${ZipName}: expected $expected, got $actual"
    }
    Common-Log "Checksum OK ($actual)"
    return $zipPath
}

# -------------------------------------------------------------------
# Service install
# -------------------------------------------------------------------

function Stop-ExistingService {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { return }

    Common-Log "Existing $ServiceName found (Status: $($svc.Status)); removing before re-install"
    if ($svc.Status -ne 'Stopped') {
        Common-Run "Stop-Service $ServiceName" {
            try { Stop-Service -Name $ServiceName -Force -ErrorAction Stop } catch {
                Common-Warn "Stop-Service failed: $($_.Exception.Message); falling back to sc.exe delete"
            }
        }
    }
    Common-Run "sc.exe delete $ServiceName" {
        $null = & sc.exe delete $ServiceName
        if ($LASTEXITCODE -ne 0) {
            Common-Die "sc.exe delete $ServiceName exited with code $LASTEXITCODE"
        }
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { return }
            Start-Sleep -Milliseconds 200
        }
        Common-Die "service still present 10s after sc.exe delete"
    }
}

function Extract-Zip {
    param([string]$ZipPath)

    Common-Run "Expand-Archive $ZipPath -> $InstallDir" {
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $InstallDir -Force
    }
}

# Remove waired-tray.exe after extraction when WAIRED_NO_TRAY is set.
function Remove-TrayIfRequested {
    if (-not $NoTray) { return }
    $tray = Join-Path $InstallDir 'waired-tray.exe'
    Common-Log "WAIRED_NO_TRAY set -- skipping tray binary"
    Common-Run "Remove-Item $tray" {
        if (Test-Path -LiteralPath $tray) {
            Remove-Item -LiteralPath $tray -Force
        }
    }
}

function Invoke-AgentInstall {
    $exe = Join-Path $InstallDir 'waired-agent.exe'
    # NOTE: do NOT name this `$args` -- that is a PowerShell automatic
    # variable holding the un-bound positional arguments of the enclosing
    # scope. The Common-Run scriptblock below is evaluated via `& $Action`
    # inside Common-Run's own scope, where `$args` resolves to
    # Common-Run's (empty) automatic, NOT to this function's assignment.
    # The result was `& $exe @args` = `& $exe` (no args), so
    # waired-agent.exe was invoked WITHOUT the `install` subcommand,
    # fell through to the foreground daemon path, and exited with
    # `no identity at <user APPDATA>` -- which looked like an install
    # failure but was really an automatic-variable scoping bug. The
    # developer-facing scripts/install/waired-agent-windows.ps1 already
    # uses `$installArgs` for exactly this reason; match it.
    $installArgs = @('install')
    if ($StateDir) { $installArgs += "-state-dir=$StateDir" }
    Common-Log "Running: $exe $($installArgs -join ' ')"
    Common-Run "& $exe $($installArgs -join ' ')" {
        & $exe @installArgs
        if ($LASTEXITCODE -ne 0) {
            Common-Die "waired-agent install exited with code $LASTEXITCODE"
        }
    }
}

function Show-NextSteps {
    $cpHint = if ($StateDir) { $StateDir } else { Join-Path $env:ProgramData 'waired' }
    Write-Host ''
    Write-Host 'Waired installed.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host '  1. Enroll this device against your Control Plane:'
    Write-Host "       & `"$InstallDir\waired.exe`" init --control `"https://your-cp.example.com`""
    Write-Host '     (or right-click the waired-tray icon once it is running and pick "Log in...")'
    Write-Host '  2. Start the daemon:'
    Write-Host "       Start-Service $ServiceName"
    Write-Host ''
    if (-not $NoTray) {
        Write-Host 'Tray:'
        Write-Host "  Launch `"$InstallDir\waired-tray.exe`" once from File Explorer or the Start menu."
        Write-Host '  On first launch it registers itself in HKCU\...\Run so it auto-starts at each logon.'
        Write-Host ''
    }
    Write-Host "State / identity:  $cpHint"
    Write-Host 'Diagnostics:       Get-WinEvent -ProviderName waired-agent -LogName Application -MaxEvents 20'
    Write-Host "Uninstall:         & `"$InstallDir\waired-agent.exe`" uninstall"
    Write-Host ''
}

# -------------------------------------------------------------------
# main
# -------------------------------------------------------------------

if ($Help) {
    Show-Help
    return
}

Detect-Platform

# Two phases. Both run the same script, distinguished by whether
# -StagedZipPath was passed:
#
#   Phase 1 (un-elevated): runs the download + sha256 verify in the
#     calling user's context. No UAC prompt yet. If anything fails
#     (no network, bad mirror, hash mismatch) the user wastes zero
#     UAC clicks. On success, re-invokes self via Start-Process
#     -Verb RunAs with -StagedZipPath pointing at the verified zip.
#
#   Phase 2 (elevated): launched by Phase 1 through UAC. Reads the
#     already-verified zip from the path passed by the parent, stops
#     any old service, extracts to %ProgramFiles%\Waired, and runs
#     `waired-agent.exe install`. Does NOT re-download.
#
# This is the "defer elevation until actually needed" pattern: the
# UAC dialog appears once, immediately before the first privileged
# operation, with the script body unchanged across the boundary.

if (-not $StagedZipPath) {
    # ---- Phase 1: un-elevated ----
    if (Test-Admin) {
        Common-Warn "already running elevated; doing download + install in one go (UAC was unnecessary)"
    }
    $workDir = Join-Path $env:TEMP "waired-install-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $stagedZip = $null
    try {
        $stagedZip = Get-AssetWithChecksum -WorkDir $workDir
        if (Test-Admin) {
            # Already elevated -> skip the self-re-exec and just run
            # Phase 2 inline so we don't pop a no-op UAC dialog.
            Stop-ExistingService
            Extract-Zip -ZipPath $stagedZip
            Remove-TrayIfRequested
            Invoke-AgentInstall
            Show-NextSteps
        } else {
            Invoke-SelfElevate -ZipPath $stagedZip
        }
    } finally {
        # Only the un-elevated parent owns the workdir lifecycle. The
        # elevated child reads the zip and exits; the parent then
        # cleans up. If the elevated child crashes, the workdir leaks
        # under %TEMP% and the next install gets a fresh GUID dir --
        # acceptable.
        Common-Run "Remove-Item -Recurse $workDir" {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return
}

# ---- Phase 2: elevated ----
if (-not (Test-Admin)) {
    Common-Die "internal error: -StagedZipPath set but not running elevated"
}
if (-not (Test-Path -LiteralPath $StagedZipPath)) {
    Common-Die "staged zip not found at $StagedZipPath (parent installer may have crashed)"
}
Common-Log "elevated phase: installing from $StagedZipPath"
Stop-ExistingService
Extract-Zip -ZipPath $StagedZipPath
Remove-TrayIfRequested
Invoke-AgentInstall
Show-NextSteps

<#
.SYNOPSIS
Starts the OpenCodex web gateway on Windows.

.DESCRIPTION
Builds the gateway (or the full project when needed), resolves the Codex Desktop
app.asar path, sets the required environment variables, and runs `pnpm run web:dev`.

.EXAMPLE
.\scripts\start-web.ps1

.EXAMPLE
.\scripts\start-web.ps1 -Port 3738 -Debug

.EXAMPLE
.\scripts\start-web.ps1 -SkipBuild -CodexDesktopAppPath "C:\Program Files\WindowsApps\OpenAI.Codex_26.519.5221.0_x64__2p2nqsd0c76g0\app\resources\app.asar"

.EXAMPLE
.\scripts\start-web.ps1 -NoStart
#>

param(
  [Alias("Host")]
  [string]$ListenHost = "0.0.0.0",

  [int]$Port = 3737,

  [string]$CodexDesktopAppPath,

  [switch]$SkipBuild,

  [switch]$BuildAll,

  [switch]$Debug,

  [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found in PATH."
  }
}

function Resolve-AppAsarPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

  if ((Test-Path -LiteralPath $resolvedPath -PathType Leaf) -and ([System.IO.Path]::GetFileName($resolvedPath) -eq "app.asar")) {
    return $resolvedPath
  }

  if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
    $candidates = @(
      (Join-Path $resolvedPath "resources\app.asar"),
      (Join-Path $resolvedPath "app\resources\app.asar")
    )

    foreach ($candidate in $candidates) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).ProviderPath
      }
    }
  }

  throw "Could not resolve app.asar from '$Path'. Provide the app.asar file, the app folder, or the package root."
}

function Find-AppAsarPath {
  if ($env:CODEX_DESKTOP_APP_PATH) {
    try {
      return Resolve-AppAsarPath -Path $env:CODEX_DESKTOP_APP_PATH
    } catch {
      Write-Warning "Ignoring invalid CODEX_DESKTOP_APP_PATH: $($env:CODEX_DESKTOP_APP_PATH)"
    }
  }

  $searchRoots = @()
  $windowsAppsRoot = "C:\Program Files\WindowsApps"
  if (Test-Path -LiteralPath $windowsAppsRoot -PathType Container) {
    $searchRoots += Get-ChildItem -LiteralPath $windowsAppsRoot -Filter "OpenAI.Codex_*__2p2nqsd0c76g0" -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending
  }

  $localProgramsRoot = Join-Path $env:LOCALAPPDATA "Programs"
  if (Test-Path -LiteralPath $localProgramsRoot -PathType Container) {
    $searchRoots += Get-ChildItem -LiteralPath $localProgramsRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "*Codex*" } |
      Sort-Object LastWriteTime -Descending
  }

  foreach ($root in $searchRoots) {
    $candidates = @(
      (Join-Path $root.FullName "resources\app.asar"),
      (Join-Path $root.FullName "app\resources\app.asar")
    )

    foreach ($candidate in $candidates) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).ProviderPath
      }
    }
  }

  return $null
}

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Description,

    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string[]]$Arguments = @()
  )

  Write-Host $Description
  & $FilePath @Arguments

  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE."
  }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..")).ProviderPath

Require-Command -Name "node"
Require-Command -Name "pnpm"

Push-Location $repoRoot
try {
  $resolvedAppAsar = if ($CodexDesktopAppPath) {
    Resolve-AppAsarPath -Path $CodexDesktopAppPath
  } else {
    Find-AppAsarPath
  }

  if ($resolvedAppAsar) {
    $env:CODEX_DESKTOP_APP_PATH = $resolvedAppAsar
  } else {
    Write-Warning "Could not auto-detect Codex Desktop app.asar. Continuing with the repository's built-in auto-scan logic."
  }

  $env:HOST = $ListenHost
  $env:PORT = [string]$Port

  if ($Debug) {
    $env:CODEX_WEB_DEBUG = "1"
  }

  $vendorDistDir = Join-Path $repoRoot "vendor\electron-to-web\dist"
  $gatewayServerFile = Join-Path $repoRoot "gateway\dist\server.js"

  if ($SkipBuild) {
    Write-Host "Skipping build because -SkipBuild was specified."
    if (-not (Test-Path -LiteralPath $gatewayServerFile -PathType Leaf)) {
      Write-Warning "gateway\dist\server.js was not found. If startup fails, rerun without -SkipBuild."
    }
  } elseif ($BuildAll -or -not (Test-Path -LiteralPath $vendorDistDir -PathType Container)) {
    Invoke-CheckedCommand -Description "Running full build..." -FilePath "pnpm" -Arguments @("run", "build")
  } else {
    Invoke-CheckedCommand -Description "Running gateway build..." -FilePath "pnpm" -Arguments @("run", "build:gateway")
  }

  Write-Host ""
  Write-Host "OpenCodex web gateway configuration:"
  Write-Host "  Repo root: $repoRoot"
  Write-Host "  HOST: $($env:HOST)"
  Write-Host "  PORT: $($env:PORT)"
  if ($resolvedAppAsar) {
    Write-Host "  CODEX_DESKTOP_APP_PATH: $resolvedAppAsar"
  }
  if ($Debug) {
    Write-Host "  CODEX_WEB_DEBUG: 1"
  }
  Write-Host ""

  if ($NoStart) {
    Write-Host "NoStart mode enabled. Startup command was not executed."
    return
  }

  Invoke-CheckedCommand -Description "Starting web gateway..." -FilePath "pnpm" -Arguments @("run", "web:dev")
} finally {
  Pop-Location
}

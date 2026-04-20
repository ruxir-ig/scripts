[CmdletBinding()]
param(
    [switch]$ReinstallNode,
    [switch]$ReinstallCodex,
    [switch]$ReinstallOpenCode
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$FallbackNodeLtsVersion = "v24.15.0"
$NodeInstallDir = Join-Path $env:LOCALAPPDATA "Programs\nodejs"
$NpmGlobalPrefix = Join-Path $env:APPDATA "npm"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Message)
    Write-Host " -> $Message" -ForegroundColor DarkGray
}

function Get-NormalizedPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue.Trim())

    try {
        return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    } catch {
        return $expanded.TrimEnd('\')
    }
}

function Get-UniquePathEntries {
    param([string[]]$Entries)

    $seen = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $Entries) {
        $normalized = Get-NormalizedPath $entry
        if (-not $normalized) {
            continue
        }

        if ($seen.Add($normalized)) {
            [void]$result.Add($normalized)
        }
    }

    return $result
}

function Refresh-SessionPath {
    $machineEntries = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine") -split ";"
    )
    $userEntries = @(
        [Environment]::GetEnvironmentVariable("Path", "User") -split ";"
    )
    $currentEntries = @(
        $env:Path -split ";"
    )

    $merged = Get-UniquePathEntries ($currentEntries + $userEntries + $machineEntries)
    $env:Path = ($merged -join ";")
}

function Add-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$Entry)

    $normalizedEntry = Get-NormalizedPath $Entry
    if (-not $normalizedEntry) {
        return
    }

    $currentUserEntries = @(
        [Environment]::GetEnvironmentVariable("Path", "User") -split ";"
    )

    $merged = Get-UniquePathEntries ($currentUserEntries + $normalizedEntry)
    [Environment]::SetEnvironmentVariable("Path", ($merged -join ";"), "User")
    Refresh-SessionPath
}

function Get-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function Test-NodeHome {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    return (Test-Path (Join-Path $PathValue "node.exe")) -and (Test-Path (Join-Path $PathValue "npm.cmd"))
}

function Get-ExistingNodeHome {
    $candidates = New-Object System.Collections.Generic.List[string]

    $nodeCommand = Get-CommandPath "node"
    if ($nodeCommand) {
        [void]$candidates.Add((Split-Path -Parent $nodeCommand))
    }

    foreach ($registryPath in @("HKCU:\Software\Node.js", "HKLM:\Software\Node.js")) {
        try {
            $installPath = (Get-ItemProperty -Path $registryPath -ErrorAction Stop).InstallPath
            if ($installPath) {
                [void]$candidates.Add($installPath)
            }
        } catch {
        }
    }

    foreach ($commonPath in @(
        (Join-Path $env:ProgramFiles "nodejs"),
        (Join-Path ${env:ProgramFiles(x86)} "nodejs"),
        (Join-Path $env:LOCALAPPDATA "Programs\nodejs")
    )) {
        if ($commonPath) {
            [void]$candidates.Add($commonPath)
        }
    }

    foreach ($candidate in (Get-UniquePathEntries $candidates)) {
        if (Test-NodeHome $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-NodeArch {
    $archHint = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($archHint.ToUpperInvariant()) {
        "AMD64" { return "x64" }
        "ARM64" { return "arm64" }
        "X86" { return "x86" }
        default { throw "Unsupported Windows architecture: $archHint" }
    }
}

function Get-LatestNodeLtsVersion {
    try {
        $releases = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json"
        $latestLts = $releases | Where-Object { $_.lts } | Select-Object -First 1
        if (-not $latestLts) {
            throw "No LTS release found in Node.js index."
        }

        return $latestLts.version
    } catch {
        Write-Warning "Falling back to Node.js $FallbackNodeLtsVersion because the live LTS lookup failed: $($_.Exception.Message)"
        return $FallbackNodeLtsVersion
    }
}

function Install-Node {
    $arch = Get-NodeArch
    $version = Get-LatestNodeLtsVersion
    $zipName = "node-$version-win-$arch.zip"
    $downloadUrl = "https://nodejs.org/dist/$version/$zipName"
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("node-bootstrap-" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tempRoot $zipName
    $extractRoot = Join-Path $tempRoot "extract"

    Write-Step "Installing Node.js $version ($arch)"
    Write-Note "Download: $downloadUrl"

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

        $expandedFolder = Get-ChildItem -Path $extractRoot -Directory | Select-Object -First 1
        if ($null -eq $expandedFolder) {
            throw "The Node.js archive did not extract as expected."
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $NodeInstallDir) -Force | Out-Null
        if (Test-Path $NodeInstallDir) {
            Remove-Item -Path $NodeInstallDir -Recurse -Force
        }

        Move-Item -Path $expandedFolder.FullName -Destination $NodeInstallDir
    } finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-NodeHome $NodeInstallDir)) {
        throw "Node.js installation completed, but node.exe or npm.cmd was not found in $NodeInstallDir."
    }

    return $NodeInstallDir
}

function Ensure-NodeReady {
    $nodeHome = if (-not $ReinstallNode) { Get-ExistingNodeHome } else { $null }

    if ($nodeHome) {
        Write-Step "Node.js already present"
        Write-Note "Using $nodeHome"
    } else {
        $nodeHome = Install-Node
    }

    Add-UserPathEntry $nodeHome
    Add-UserPathEntry $NpmGlobalPrefix

    $npmCmd = Join-Path $nodeHome "npm.cmd"
    if (-not (Test-Path $npmCmd)) {
        throw "npm.cmd was not found at $npmCmd."
    }

    New-Item -ItemType Directory -Path $NpmGlobalPrefix -Force | Out-Null

    try {
        & $npmCmd config set prefix $NpmGlobalPrefix --location=user | Out-Null
    } catch {
        & $npmCmd config set prefix $NpmGlobalPrefix | Out-Null
    }

    Refresh-SessionPath

    $nodeVersion = & (Join-Path $nodeHome "node.exe") --version
    $npmVersion = & $npmCmd --version

    Write-Note "Node: $nodeVersion"
    Write-Note "npm:  v$npmVersion"

    return @{
        NodeHome = $nodeHome
        NpmCmd = $npmCmd
    }
}

function Test-NpmPackageInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$NpmCmd,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    try {
        $rawJson = (& $NpmCmd list -g --depth=0 --json $PackageName 2>$null | Out-String).Trim()
        if (-not $rawJson) {
            return $false
        }

        $parsed = $rawJson | ConvertFrom-Json
        if ($null -eq $parsed.dependencies) {
            return $false
        }

        return $parsed.dependencies.PSObject.Properties.Name -contains $PackageName
    } catch {
        return $false
    }
}

function Ensure-NpmPackage {
    param(
        [Parameter(Mandatory = $true)][string]$NpmCmd,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [switch]$ForceInstall
    )

    Refresh-SessionPath

    $packageInstalled = if (-not $ForceInstall) { Test-NpmPackageInstalled -NpmCmd $NpmCmd -PackageName $PackageName } else { $false }
    $commandPath = if (-not $ForceInstall) { Get-CommandPath $CommandName } else { $null }

    if ($packageInstalled -and $commandPath) {
        Write-Step "$CommandName already present"
        Write-Note "Using $commandPath"
        return
    }

    Write-Step "Installing $PackageName"
    & $NpmCmd install -g $PackageName
    Refresh-SessionPath

    $installedCommand = Get-CommandPath $CommandName
    if (-not $installedCommand) {
        throw "Installed $PackageName, but the '$CommandName' command is still not available in PATH."
    }

    Write-Note "Installed command: $installedCommand"
}

Write-Step "Preparing environment"
Refresh-SessionPath

$nodeInfo = Ensure-NodeReady

Ensure-NpmPackage -NpmCmd $nodeInfo.NpmCmd -PackageName "@openai/codex" -CommandName "codex" -ForceInstall:$ReinstallCodex
Ensure-NpmPackage -NpmCmd $nodeInfo.NpmCmd -PackageName "opencode-ai" -CommandName "opencode" -ForceInstall:$ReinstallOpenCode

Write-Step "Verifying commands"

$codexVersion = & codex --version
$opencodeVersion = & opencode --version

Write-Host ""
Write-Host "Completed successfully." -ForegroundColor Green
Write-Host "Node:     $(& node --version)"
Write-Host "npm:      $(& npm --version)"
Write-Host "codex:    $codexVersion"
Write-Host "opencode: $opencodeVersion"
Write-Host ""
Write-Host "You can now run: codex" -ForegroundColor Green
Write-Host "You can now run: opencode" -ForegroundColor Green

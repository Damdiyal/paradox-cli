# ParadoxLab Windows hosted PowerShell entrypoint.
# Pairs with install-paradox-standalone.bat: this shim downloads the .bat into TEMP,
# verifies its checksum, and runs it with forwarded arguments.
#
# Run the batch installer from a verified local download. This shim only supports
# hosted execution when the operator explicitly supplies a verified HTTPS URL and checksum URL.
#
# To pin a specific release, set $env:PARADOX_INSTALL_VERSION before invoking,
# e.g. $env:PARADOX_INSTALL_VERSION = 'vX.Y.Z'. This is equivalent to passing
# --version vX.Y.Z to install-paradox-standalone.bat directly.
#
# To point this shim at a non-production hosted endpoint (staging buckets,
# private mirrors), set $env:PARADOX_INSTALLER_BAT_URL to the alternate .bat URL.
# The override is required to be HTTPS so a misconfigured value can't silently
# downgrade the download channel. The downstream .bat continues to honor
# PARADOX_INSTALL_BASE_URL for archive resolution.
#
# By default the matching SHA256SUMS file is read from the same hosted
# directory as the .bat. Set $env:PARADOX_INSTALLER_CHECKSUMS_URL to override it
# when testing a custom installer endpoint.

$ErrorActionPreference = 'Stop'

function Download-File {
    param([string]$Url, [string]$OutFile)
    $prevProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            curl.exe --connect-timeout 15 --max-time 300 --retry 2 -sSfLo $OutFile $Url
            if ($LASTEXITCODE -ne 0) {
                throw "curl.exe download failed (exit code $LASTEXITCODE)"
            }
            return
        }
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 300
    } finally {
        $global:ProgressPreference = $prevProgressPreference
    }
}

function Get-ParadoxInstallBase {
    if (-not [string]::IsNullOrEmpty($env:PARADOX_INSTALL_ROOT)) {
        return $env:PARADOX_INSTALL_ROOT
    }

    if (-not [string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
        return $env:LOCALAPPDATA
    }

    return Join-Path $env:USERPROFILE 'AppData\Local'
}

function Get-ParadoxInstallBinDir {
    if (-not [string]::IsNullOrEmpty($env:PARADOX_INSTALL_BIN_DIR)) {
        return $env:PARADOX_INSTALL_BIN_DIR
    }

    return Join-Path (Get-ParadoxInstallBase) 'bin'
}

function Get-CurrentCmdShimStatePath {
    return Join-Path (Get-ParadoxInstallBase) 'current-cmd-shim.txt'
}

function Save-CurrentCmdPathShim {
    param([string]$ShimPath)

    if ([string]::IsNullOrEmpty($ShimPath)) {
        return
    }

    try {
        $statePath = Get-CurrentCmdShimStatePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        [IO.File]::WriteAllText($statePath, $ShimPath, [Text.UTF8Encoding]::new($false))
    } catch {
        # Best-effort cleanup hint only. The installer still works if this fails.
    }
}

function Update-CurrentSessionPath {
    param([string]$BinDir)

    if ([string]::IsNullOrEmpty($BinDir)) {
        return
    }

    $entries = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrEmpty($_) })
    foreach ($entry in $entries) {
        if ([string]::Equals($entry, $BinDir, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $env:Path = (@($BinDir) + $entries) -join ';'
}

function Get-ParentProcessName {
    try {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        if ($null -eq $current -or $null -eq $current.ParentProcessId) {
            return $null
        }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($current.ParentProcessId)" -ErrorAction Stop
        if ($null -eq $parent) {
            return $null
        }
        return $parent.Name
    } catch {
        return $null
    }
}

function Get-NormalizedPath {
    param([string]$PathValue)

    if ([string]::IsNullOrEmpty($PathValue)) {
        return $null
    }

    $trimmed = $PathValue.Trim().Trim('"')
    if ([string]::IsNullOrEmpty($trimmed)) {
        return $null
    }

    try {
        return [IO.Path]::GetFullPath($trimmed).TrimEnd('\')
    } catch {
        return $trimmed.TrimEnd('\')
    }
}

function Test-PathContainsDirectory {
    param([string]$PathValue, [string]$Directory)

    $target = Get-NormalizedPath -PathValue $Directory
    if ([string]::IsNullOrEmpty($target)) {
        return $false
    }

    foreach ($entry in @($PathValue -split ';')) {
        $normalizedEntry = Get-NormalizedPath -PathValue $entry
        if ([string]::Equals($normalizedEntry, $target, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-WritableDirectory {
    param([string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $false
    }

    $probe = Join-Path $Directory ('.paradox-write-test-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Add-PathCandidate {
    param(
        [System.Collections.Generic.List[string]]$Candidates,
        [string]$Directory
    )

    $normalizedDirectory = Get-NormalizedPath -PathValue $Directory
    if ([string]::IsNullOrEmpty($normalizedDirectory)) {
        return
    }

    foreach ($candidate in $Candidates) {
        $normalizedCandidate = Get-NormalizedPath -PathValue $candidate
        if ([string]::Equals($normalizedCandidate, $normalizedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    [void]$Candidates.Add($Directory.Trim().Trim('"'))
}

function Test-SystemManagedPathDirectory {
    param([string]$Directory)

    $normalizedDirectory = Get-NormalizedPath -PathValue $Directory
    return (
        -not [string]::IsNullOrEmpty($normalizedDirectory) -and
        $normalizedDirectory -match '\\Microsoft\\WindowsApps$'
    )
}

function Install-CurrentCmdPathShim {
    param([string]$ParadoxCommand, [string]$PathValue)

    $pathEntries = @($PathValue -split ';' | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $candidates = [System.Collections.Generic.List[string]]::new()
    $preferredDirectories = @()

    if (-not [string]::IsNullOrEmpty($env:APPDATA)) {
        $preferredDirectories += Join-Path $env:APPDATA 'npm'
    }
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
        $preferredDirectories += Join-Path $env:USERPROFILE '.bun\bin'
    }

    foreach ($preferredDirectory in $preferredDirectories) {
        $preferredNormalized = Get-NormalizedPath -PathValue $preferredDirectory
        foreach ($entry in $pathEntries) {
            $entryNormalized = Get-NormalizedPath -PathValue $entry
            if ([string]::Equals($entryNormalized, $preferredNormalized, [StringComparison]::OrdinalIgnoreCase)) {
                Add-PathCandidate -Candidates $candidates -Directory $entry
            }
        }
    }

    $userRoot = Get-NormalizedPath -PathValue $env:USERPROFILE
    foreach ($entry in $pathEntries) {
        if (Test-SystemManagedPathDirectory -Directory $entry) {
            continue
        }
        $entryNormalized = Get-NormalizedPath -PathValue $entry
        if (
            -not [string]::IsNullOrEmpty($userRoot) -and
            -not [string]::IsNullOrEmpty($entryNormalized) -and
            $entryNormalized.StartsWith($userRoot, [StringComparison]::OrdinalIgnoreCase)
        ) {
            Add-PathCandidate -Candidates $candidates -Directory $entry
        }
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-WritableDirectory -Directory $candidate)) {
            continue
        }

        $shimPath = Join-Path $candidate 'paradox.cmd'
        if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
            $existingShim = Get-Content -LiteralPath $shimPath -Raw -ErrorAction SilentlyContinue
            if ($existingShim -notmatch 'ParadoxLab current-session shim') {
                continue
            }
        }

        $shim = "@echo off`r`nREM ParadoxLab current-session shim. Generated by install-paradox-standalone.ps1.`r`ncall `"$ParadoxCommand`" %*`r`n"
        # Write to a sibling temp file first, then atomically rename so a partial
        # write (process killed, disk full) cannot leave a half-written shim on
        # PATH.
        $shimTempPath = "$shimPath.new"
        [IO.File]::WriteAllText($shimTempPath, $shim, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $shimTempPath -Destination $shimPath -Force
        Save-CurrentCmdPathShim -ShimPath $shimPath
        return $shimPath
    }

    return $null
}

function Update-CurrentShell {
    $paradoxInstallBinDir = Get-ParadoxInstallBinDir
    $paradoxCommandPath = Join-Path $paradoxInstallBinDir 'paradox.cmd'
    if (-not (Test-Path -LiteralPath $paradoxCommandPath -PathType Leaf)) {
        return
    }

    if ($env:PARADOX_NO_MODIFY_PATH -eq '1') {
        return
    }

    $inheritedPath = $env:Path
    Update-CurrentSessionPath -BinDir $paradoxInstallBinDir

    $parentProcessName = Get-ParentProcessName
    if ($parentProcessName -ieq 'cmd.exe') {
        if (Test-PathContainsDirectory -PathValue $inheritedPath -Directory $paradoxInstallBinDir) {
            return
        }

        $shimPath = Install-CurrentCmdPathShim -ParadoxCommand $paradoxCommandPath -PathValue $inheritedPath
        if (-not [string]::IsNullOrEmpty($shimPath)) {
            return
        }
        return
    }
}

if ([string]::IsNullOrEmpty($env:PARADOX_INSTALLER_BAT_URL)) {
    Write-Error 'No verified ParadoxLab hosted installer endpoint is configured. Run install-paradox-standalone.bat from a verified local download.'
    exit 1
} else {
    if ($env:PARADOX_INSTALLER_BAT_URL -notmatch '^https://') {
        Write-Error "PARADOX_INSTALLER_BAT_URL must start with https://"
        exit 1
    }
    $paradoxInstallerUrl = $env:PARADOX_INSTALLER_BAT_URL
}

if ([string]::IsNullOrEmpty($env:PARADOX_INSTALLER_CHECKSUMS_URL)) {
    Write-Error 'PARADOX_INSTALLER_CHECKSUMS_URL must point to the checksum manifest for the configured installer endpoint.'
    exit 1
} else {
    if ($env:PARADOX_INSTALLER_CHECKSUMS_URL -notmatch '^https://') {
        Write-Error "PARADOX_INSTALLER_CHECKSUMS_URL must start with https://"
        exit 1
    }
    $paradoxChecksumsUrl = $env:PARADOX_INSTALLER_CHECKSUMS_URL
}

$paradoxInstallerName = [IO.Path]::GetFileName(([Uri]$paradoxInstallerUrl).AbsolutePath)
if ([string]::IsNullOrEmpty($paradoxInstallerName)) {
    $paradoxInstallerName = 'install-paradox-standalone.bat'
}
if ([string]::IsNullOrEmpty($env:TEMP)) {
    Write-Error "TEMP environment variable is not set. Please set TEMP to a writable directory."
    exit 1
}
# Use a cryptographically random staging filename so a same-user attacker cannot
# pre-stage a malicious .bat at a predictable path and race the verify/execute
# window between Get-FileHash and `& $paradoxInstallerPath`.
$paradoxStagingSuffix = [IO.Path]::GetRandomFileName()
$paradoxInstallerPath = Join-Path $env:TEMP "paradox-installer-$paradoxStagingSuffix.bat"
$paradoxChecksumsPath = Join-Path $env:TEMP "paradox-installation-SHA256SUMS-$paradoxStagingSuffix"

try {
    Download-File -Url $paradoxInstallerUrl -OutFile $paradoxInstallerPath
} catch {
    Write-Error "Failed to download ParadoxLab installer from ${paradoxInstallerUrl}: $($_.Exception.Message)"
    exit 1
}

try {
    Download-File -Url $paradoxChecksumsUrl -OutFile $paradoxChecksumsPath
} catch {
    Remove-Item -LiteralPath $paradoxInstallerPath -Force -ErrorAction SilentlyContinue
    Write-Error "Failed to download ParadoxLab installer checksums from ${paradoxChecksumsUrl}: $($_.Exception.Message)"
    exit 1
}

$paradoxExpectedHash = $null
foreach ($paradoxChecksumLine in Get-Content -LiteralPath $paradoxChecksumsPath) {
    if ($paradoxChecksumLine -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        if ($Matches[2] -eq $paradoxInstallerName) {
            $paradoxExpectedHash = $Matches[1].ToLowerInvariant()
            break
        }
    }
}
if ([string]::IsNullOrEmpty($paradoxExpectedHash)) {
    Remove-Item -LiteralPath $paradoxInstallerPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $paradoxChecksumsPath -Force -ErrorAction SilentlyContinue
    Write-Error "Checksum entry for ${paradoxInstallerName} not found in ${paradoxChecksumsUrl}"
    exit 1
}

$paradoxActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $paradoxInstallerPath).Hash.ToLowerInvariant()
if ($paradoxActualHash -ne $paradoxExpectedHash) {
    Remove-Item -LiteralPath $paradoxInstallerPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $paradoxChecksumsPath -Force -ErrorAction SilentlyContinue
    Write-Error "Checksum mismatch for ${paradoxInstallerName}: expected ${paradoxExpectedHash}, got ${paradoxActualHash}."
    exit 1
}

$paradoxInstallerExitCode = 0
$paradoxPreviousParentPowerShell = $env:PARADOX_INSTALLER_PARENT_POWERSHELL
try {
    $env:PARADOX_INSTALLER_PARENT_POWERSHELL = '1'
    & $paradoxInstallerPath @args
    $paradoxInstallerExitCode = $LASTEXITCODE
} finally {
    if ($null -eq $paradoxPreviousParentPowerShell) {
        Remove-Item Env:\PARADOX_INSTALLER_PARENT_POWERSHELL -ErrorAction SilentlyContinue
    } else {
        $env:PARADOX_INSTALLER_PARENT_POWERSHELL = $paradoxPreviousParentPowerShell
    }
    Remove-Item -LiteralPath $paradoxInstallerPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $paradoxChecksumsPath -Force -ErrorAction SilentlyContinue
}

if ($paradoxInstallerExitCode -ne 0) {
    exit $paradoxInstallerExitCode
}

Update-CurrentShell

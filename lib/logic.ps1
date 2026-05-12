# logic.ps1 - Core Lifecycle Logic (Install, Uninstall, List, Shims)

# ---------------------------------------------
# PACKAGE LISTING
# ---------------------------------------------
function List-Packages {
    if (-not (Test-Path $global:METADATA_DIR)) {
        Write-Log "No packages installed (Metadata registry empty)." "INFO"
        return
    }

    $files = Get-ChildItem -Path $global:METADATA_DIR -Filter "*.json"
    if ($files.Count -eq 0) {
        Write-Log "No packages installed." "INFO"
        return
    }

    $pkgs = @()
    foreach ($f in $files) {
        try {
            $pkgs += Get-Content $f.FullName | ConvertFrom-Json
        } catch {
            Write-Log "Failed to read metadata for $($f.Name)" "WARN"
        }
    }

    Write-Host "`n----- Installed Packages -----" -ForegroundColor Cyan
    $pkgs | Select-Object @{n="Package";e={$_.name}}, version, description | Format-Table -AutoSize
    Write-Host "Total: $($pkgs.Count) package(s) found.`n"
}

# ---------------------------------------------
# INSTALLATION ORCHESTRATION
# ---------------------------------------------
function Install-Package {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log "File not found: $Path" "ERROR"
        return
    }

    # Resolve Engine Path (Assumes standard repo structure)
    $projectRoot = Split-Path (Split-Path $PSScriptRoot)
    $enginePath = Join-Path $projectRoot "package_installer\rmspkg.ps1"

    if (-not (Test-Path $enginePath)) {
        Write-Log "Engine (rmspkg) not found at $enginePath" "ERROR"
        return
    }

    Write-Log "Calling engine (rmspkg) for local installation..." "INFO"
    & $enginePath $Path
}

# ---------------------------------------------
# UNINSTALLATION ORCHESTRATION
# ---------------------------------------------
function Uninstall-Package {
    param([Parameter(Mandatory=$true)][string]$Name)

    # Resolve Engine Path
    $projectRoot = Split-Path (Split-Path $PSScriptRoot)
    $enginePath = Join-Path $projectRoot "package_installer\rmspkg.ps1"

    Write-Log "Calling engine (rmspkg) to uninstall: $Name" "INFO"
    & $enginePath $Name --uninstall
}

# ---------------------------------------------
# SHIM MANAGEMENT (Placeholder for Phase 2)
# ---------------------------------------------
function Manage-Shim {
    param(
        [string]$CommandName,
        [string]$ExecutablePath,
        [switch]$Remove
    )
    # Logic to be moved from Engine to Manager in next sub-step
    Write-Log "Shim management for $CommandName not yet implemented in Manager layer." "WARN"
}

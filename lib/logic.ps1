# logic.ps1 - Core Lifecycle Logic (Install, Uninstall, List, Shims)

# ---------------------------------------------
# REGISTRY SYNCHRONIZATION (Speed Search)
# ---------------------------------------------
function Initialize-Sources {
    if (-not (Test-Path $global:SOURCES_FILE)) {
        Write-Log "Initializing default sources list..." "INFO"
        $defaultSources = @(
            @{ name = "official"; url = $global:OFFICIAL_REPO }
        )
        $defaultSources | ConvertTo-Json | Out-File -FilePath $global:SOURCES_FILE -Encoding utf8
    }
}

function Update-Registry {
    Initialize-Sources

    if (-not (Test-Path $global:CACHE_DIR)) {
        New-Item -ItemType Directory -Path $global:CACHE_DIR -Force | Out-Null
    }

    $sources = Get-Content $global:SOURCES_FILE | ConvertFrom-Json
    Write-Host "`n----- Syncing Repositories -----" -ForegroundColor Cyan

    foreach ($s in $sources) {
        $cacheFile = Join-Path $global:CACHE_DIR "$($s.name).index.json"
        Write-Log "Updating source: $($s.name) ($($s.url))..." "INFO"

        try {
            if ($s.url.StartsWith("http")) {
                Invoke-RestMethod -Uri $s.url -OutFile $cacheFile
            } else {
                # Support local paths for testing
                Copy-Item -Path $s.url -Destination $cacheFile -Force
            }
            Write-Log "Successfully cached $($s.name)." "SUCCESS"
        } catch {
            Write-Log "Failed to update source '$($s.name)': $($_.Exception.Message)" "WARN"
        }
    }
    Write-Host "Sync complete.`n"
}

function Search-Packages {
    param([string]$Query)

    if (-not (Test-Path $global:CACHE_DIR) -or (Get-ChildItem $global:CACHE_DIR -Filter "*.index.json").Count -eq 0) {
        Write-Log "No search cache found. Please run 'roms update' first." "WARN"
        return
    }

    $cacheFiles = Get-ChildItem -Path $global:CACHE_DIR -Filter "*.index.json"
    $allResults = @()

    foreach ($f in $cacheFiles) {
        try {
            $sourceName = $f.Name.Replace(".index.json", "")
            $data = Get-Content $f.FullName | ConvertFrom-Json
            
            # Add Source property to every package
            foreach ($pkg in $data) {
                $pkg | Add-Member -MemberType NoteProperty -Name "Source" -Value $sourceName -Force
                
                # Filter logic
                if (-not $Query -or ($pkg.name -like "*$Query*") -or ($pkg.description -like "*$Query*")) {
                    $allResults += $pkg
                }
            }
        } catch {
            Write-Log "Failed to read cache file: $($f.Name)" "WARN"
        }
    }

    if ($allResults.Count -eq 0) {
        Write-Log "No packages found matching '$Query'." "INFO"
        return
    }

    Write-Host "`n----- Available Packages (Remote) -----" -ForegroundColor Cyan
    $allResults | Select-Object @{n="Package";e={$_.name}}, version, Source, description | Format-Table -AutoSize
    Write-Host "Total: $($allResults.Count) package(s) found matching your query.`n"
}

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

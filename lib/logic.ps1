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
function Invoke-RomsInstall {
    param([Parameter(Mandatory=$true)][string]$Identifier)

    $targetPath = $null

    # 1. Check if it is a local file path
    if (Test-Path $Identifier -PathType Leaf) {
        $targetPath = (Resolve-Path $Identifier).Path
    } 
    # 2. Check the cache for a package name
    else {
        Write-Log "Searching registry for '$Identifier'..." "INFO"
        
        $cacheFiles = Get-ChildItem -Path $global:CACHE_DIR -Filter "*.index.json"
        $pkgInfo = $null

        foreach ($f in $cacheFiles) {
            $data = Get-Content $f.FullName | ConvertFrom-Json
            $pkgInfo = $data | Where-Object { $_.name -eq $Identifier }
            if ($pkgInfo) { break }
        }

        if (-not $pkgInfo) {
            Write-Log "Package '$Identifier' not found in registry. Try 'roms update'." "ERROR"
            return
        }

        # 3. Download the Remote Package
        if (-not (Test-Path $global:TEMP_DIR)) { New-Item -ItemType Directory -Path $global:TEMP_DIR -Force | Out-Null }
        
        $tempFile = Join-Path $global:TEMP_DIR "$($pkgInfo.name)-$($pkgInfo.version).rms"
        Write-Log "Downloading $($pkgInfo.name) ($($pkgInfo.version))..." "INFO"
        
        try {
            Invoke-WebRequest -Uri $pkgInfo.downloadUrl -OutFile $tempFile -UseBasicParsing
            
            # 4. SHA256 Verification
            if ($pkgInfo.sha256 -and $pkgInfo.sha256 -ne "SKIP") {
                Write-Log "Verifying integrity (SHA256)..." "INFO"
                
                $fileStream = $null
                try {
                    # Native .NET Implementation (Universal Support)
                    $fileStream = [System.IO.File]::OpenRead($tempFile)
                    $sha256 = [System.Security.Cryptography.SHA256]::Create()
                    $hashBytes = $sha256.ComputeHash($fileStream)
                    $fileStream.Close()
                    
                    $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToUpper()

                    if ($hash -ne $pkgInfo.sha256.ToUpper()) {
                        Write-Log "Security Alert: SHA256 mismatch! File may be corrupted or tampered with." "ERROR"
                        Write-Log "Expected: $($pkgInfo.sha256.ToUpper())" "DEBUG"
                        Write-Log "Actual:   $hash" "DEBUG"
                        Remove-Item $tempFile -Force
                        return
                    }
                    Write-Log "Integrity verified." "SUCCESS"
                } finally {
                    if ($fileStream) { $fileStream.Dispose() }
                }
            }
            
            $targetPath = $tempFile
        } catch {
            Write-Log "Download failed: $($_.Exception.Message)" "ERROR"
            return
        }
    }

    # 5. Resolve Engine Path
    $projectRoot = Split-Path (Split-Path $PSScriptRoot)
    $enginePath = Join-Path $projectRoot "package_installer\rmspkg.ps1"

    if (-not (Test-Path $enginePath)) {
        Write-Log "Engine (rmspkg) not found at $enginePath" "ERROR"
        return
    }

    Write-Log "Calling engine (rmspkg) to install package..." "INFO"
    & $enginePath install $targetPath
}

# ---------------------------------------------
# UNINSTALLATION ORCHESTRATION
# ---------------------------------------------
function Invoke-RomsUninstall {
    param([Parameter(Mandatory=$true)][string]$Name)

    # Resolve Engine Path
    $projectRoot = Split-Path (Split-Path $PSScriptRoot)
    $enginePath = Join-Path $projectRoot "package_installer\rmspkg.ps1"

    Write-Log "Calling engine (rmspkg) to uninstall: $Name" "INFO"
    & $enginePath uninstall $Name
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

# ---------------------------------------------
# ALTERNATIVES DATA HELPERS
# ---------------------------------------------
function Get-AlternativesData {
    if (Test-Path $global:ALTERNATIVES_FILE) {
        try {
            # .NET Rule: Use native IO for Industrial Strength
            $json = [System.IO.File]::ReadAllText($global:ALTERNATIVES_FILE)
            return $json | ConvertFrom-Json
        } catch {
            Write-Log "Failed to parse alternatives database. Returning empty." "WARN"
            return @{}
        }
    }
    return @{}
}

function Set-AlternativesData {
    param([Parameter(Mandatory=$true)]$Data)
    try {
        # .NET Rule: Use native IO for Industrial Strength
        $json = $Data | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($global:ALTERNATIVES_FILE, $json, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Log "Failed to save alternatives database: $($_.Exception.Message)" "ERROR"
    }
}

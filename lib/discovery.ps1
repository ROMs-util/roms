# ---------------------------------------------
# PACKAGE SEARCH
# Searches all cached registry index files for packages matching a query string.
# Matches against package name and description (case-insensitive).
# Filters by current OS architecture (amd64, arm64, etc.), skipping non-matching.
# Supports both Trinity v1.1.0 nested format and legacy flat array format.
# Logs each cache scan at TRACE level for debugging.
# Returns array of matching packages with Source property added, or $null if none.
# ---------------------------------------------
function Search-Packages {
    param([string]$Query)

    if (-not (Test-Path $global:ROMs_CACHE) -or (Get-ChildItem $global:ROMs_CACHE -Filter "*.index.json").Count -eq 0) {
        Write-Log "No search cache found. Please run 'roms update' first." "WARN"
        return
    }

    $cacheFiles = Get-ChildItem -Path $global:ROMs_CACHE -Filter "*.index.json"
    $allResults = @()
    $sysArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()

    foreach ($f in $cacheFiles) {
        try {
            $sourceName = $f.Name.Replace(".index.json", "")
            if (Test-Path $f.FullName) {
                Write-Log "Scanning registry cache: $sourceName ($($f.Name))" "TRACE"
                $data = Get-Content $f.FullName | ConvertFrom-Json
                
                # Support Trinity v1.1.0 (nested packages) or legacy flat array
                $pkgs = if ($data.packages) { $data.packages } else { $data }

                foreach ($pkg in $pkgs) {
                    # Architecture Filtering 
                    $pkgArch = if ($pkg.architecture) { $pkg.architecture.ToLower() } else { "all" }
                    if ($pkgArch -ne "all" -and $pkgArch -ne $sysArch) { continue }

                    $pkg | Add-Member -MemberType NoteProperty -Name "Source" -Value $sourceName -Force
                    
                    # Filter logic
                    if (-not $Query -or ($pkg.name -like "*$Query*") -or ($pkg.description -like "*$Query*")) {
                        $allResults += $pkg
                    }
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

    Write-Log "----- Available Packages (Remote) -----" "INFO"
    $allResults | Select-Object @{n="Package";e={$_.name}}, version, Source, description | Format-Table -AutoSize
    Write-Log "Total: $($allResults.Count) package(s) found matching your query." "SUCCESS"
}

# ---------------------------------------------
# INSTALLED PACKAGE LIST
# Reads all .json metadata files from $ROMs_METADATA to list installed packages.
# Returns formatted table with Package, version, description.
# Logs each metadata file read at TRACE level.
# Shows "Installed Packages" header if packages found.
# Silently handles missing metadata directory or empty metadata.
# ---------------------------------------------
function List-Packages {
    Write-Log "Scanning metadata registry..." "TRACE"
    if (-not (Test-Path $global:ROMs_METADATA)) {
        Write-Log "No packages installed (Metadata registry empty)." "INFO"
        return
    }

    $files = Get-ChildItem -Path $global:ROMs_METADATA -Filter "*.json"
    if ($files.Count -eq 0) {
        Write-Log "No packages installed." "INFO"
        return
    }

    $pkgs = @()
    foreach ($f in $files) {
        try {
            if (Test-Path $f.FullName) {
                Write-Log "Reading metadata: $($f.Name)" "TRACE"
                $pkgs += Get-Content $f.FullName | ConvertFrom-Json
            }
        } catch {
            Write-Log "Failed to read metadata for $($f.Name)" "WARN"
        }
    }

    Write-Log "----- Installed Packages -----" "INFO"
    $pkgs | Select-Object @{n="Package";e={$_.name}}, version, description | Format-Table -AutoSize
    Write-Log "Total: $($pkgs.Count) package(s) found." "SUCCESS"
}


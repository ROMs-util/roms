# discovery.ps1 - Package Search and Listing Logic

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

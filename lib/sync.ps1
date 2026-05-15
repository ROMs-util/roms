# sync.ps1 - Registry Synchronization and Source Management

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

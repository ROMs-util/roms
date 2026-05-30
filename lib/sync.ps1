# sync.ps1 - Registry Synchronization and Source Management

function Initialize-Sources {
    if (-not (Test-Path $global:ROMs_SOURCES)) {
        Write-Log "Initializing default sources list..." "INFO"
        $defaultSources = @(
            @{ name = "official"; url = $global:ROMs_OFFICIAL }
        )
        $defaultSources | ConvertTo-Json | Out-File -FilePath $global:ROMs_SOURCES -Encoding utf8
    }
}

function Update-Registry {
    Initialize-Sources

    if (-not (Test-Path $global:ROMs_CACHE)) {
        New-Item -ItemType Directory -Path $global:ROMs_CACHE -Force | Out-Null
    }

    $sources = Get-Content $global:ROMs_SOURCES -Raw | ConvertFrom-Json
    if ($sources) {
        Write-Log "Sources Registry: $($sources | ConvertTo-Json -Depth 10)" "RAW"
    }

    Write-Log "----- Syncing Repositories -----" "INFO"

    foreach ($s in $sources) {
        $cacheFile = Join-Path $global:ROMs_CACHE "$($s.name).index.json"
        Write-Log "Updating source: $($s.name) ($($s.url))..." "INFO"

        try {
            if ($s.url.StartsWith("http")) {
                Invoke-RestMethod -Uri $s.url -OutFile $cacheFile
            } else {
                # Support local paths for testing
                Copy-Item -Path $s.url -Destination $cacheFile -Force
            }

            if (Test-Path $cacheFile) {
                Write-Log "Cached registry source: $($s.name) -> $cacheFile" "TRACE"
                $rawContent = Get-Content $cacheFile -Raw
                if ($rawContent) {
                    Write-Log "Registry Data ($($s.name)): $($rawContent.Substring(0, [Math]::Min(200, $rawContent.Length)))" "RAW"
                }
                Write-Log "Successfully cached $($s.name)." "SUCCESS"
            }
        } catch {
            Write-Log "Failed to update source '$($s.name)': $($_.Exception.Message)" "WARN"
        }
    }
    Write-Log "Sync complete." "SUCCESS"
}


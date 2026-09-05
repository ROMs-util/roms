# sync.ps1 - Registry Synchronization and Source Management

# ---------------------------------------------
# SOURCE INITIALIZATION
# Bootstraps the sources.json registry configuration.
#
# HOW IT WORKS:
# 1. Creates a default hierarchical 'official' source if missing.
# 2. Migrates legacy flat-array sources to the new partitioned channel schema.
# 3. Enforces the 'preferred_channel' standard for global defaults.
# ---------------------------------------------
function Initialize-Sources {
    $shouldInitialize = $false
    if (-not (Test-Path $global:ROMs_SOURCES)) {
        $shouldInitialize = $true
    } else {
        # Check if existing file is legacy (flat array)
        $raw = [System.IO.File]::ReadAllText($global:ROMs_SOURCES)
        if ($raw -match "^\s*\[") {
            Write-Log "Legacy sources.json detected. Migrating to hierarchical schema..." "INFO"
            $shouldInitialize = $true
        }
    }

    if ($shouldInitialize) {
        Write-Log "Initializing hierarchical sources registry..." "INFO"
        
        # Define the new Ecosystem Schema
        $newRegistry = @{
            preferred_channel = "mainnet"
            sources = @(
                @{
                    name     = "official"
                    base_url = "https://raw.githubusercontent.com/ROMs-util/rms-atlas/main/"
                    channels = @{
                        mainnet = @{ file = "mainnet.json"; status = "on" }
                        testnet = @{ file = "testnet.json"; status = "off" }
                    }
                }
            )
        }
        
        $newRegistry | ConvertTo-Json -Depth 10 | Out-File -FilePath $global:ROMs_SOURCES -Encoding utf8
    }
}

# ---------------------------------------------
# REGISTRY SYNCHRONIZATION
# Fetches updated package indices from configured sources and active channels.
#
# HOW IT WORKS:
# 1. Resolves the current session-active channel (via pick).
# 2. Iterates through all registered sources and their partitioned channels.
# 3. SYNCS a channel if it is globally 'ON' OR temporarily 'PICKED' for the session.
# 4. Downloads indices using the <source>.<channel>.index.json naming standard.
# ---------------------------------------------
function Update-Registry {
    Initialize-Sources

    if (-not (Test-Path $global:ROMs_CACHE)) {
        New-Item -ItemType Directory -Path $global:ROMs_CACHE -Force | Out-Null
    }

    $registry = Get-Content $global:ROMs_SOURCES -Raw | ConvertFrom-Json
    if ($registry) {
        Write-Log "Registry Configuration: $($registry | ConvertTo-Json -Depth 10)" "RAW"
    }

    Write-Log "----- Syncing Repositories -----" "INFO"

    $activeChannel = Get-RomsActiveChannel
    Write-Log "Registry Sync using channel context: $activeChannel" "INFO"

    foreach ($s in $registry.sources) {
        # Process each channel defined in the source
        $channels = $s.channels.PSObject.Properties.Name
        foreach ($chanName in $channels) {
            $chan = $s.channels.$chanName
            
            # SESSION ACTIVATION LOGIC
            $isPicked = ($chanName -eq $activeChannel)
            if ($chan.status -ne "on" -and -not $isPicked) { 
                Write-Log "Skipping inactive channel: $($s.name).$chanName" "DEBUG"
                continue 
            }

            if ($isPicked -and $chan.status -eq "off") {
                Write-Log "Temporary Activation: $($s.name).$chanName (Reason: Session Picked)" "SUCCESS"
            }

            $cacheFile = Join-Path $global:ROMs_CACHE "$($s.name).$chanName.index.json"
            $targetUrl = if ($s.base_url.EndsWith("/")) { "$($s.base_url)$($chan.file)" } else { "$($s.base_url)/$($chan.file)" }

            Write-Log "Updating channel: $($s.name).$chanName ($targetUrl)..." "INFO"

            try {
                if ($targetUrl.StartsWith("http")) {
                    Invoke-RestMethod -Uri $targetUrl -OutFile $cacheFile
                } else {
                    # Support local paths for testing
                    Copy-Item -Path $targetUrl -Destination $cacheFile -Force
                }

                if (Test-Path $cacheFile) {
                    Write-Log "Cached partitioned source: $($s.name).$chanName -> $cacheFile" "TRACE"
                    $rawContent = Get-Content $cacheFile -Raw
                    if ($rawContent) {
                        $previewLen = [Math]::Min(200, $rawContent.Length)
                        Write-Log "Registry Data ($($s.name).$chanName): $($rawContent.Substring(0, $previewLen))" "RAW"
                    }
                    Write-Log "Successfully cached $($s.name).$chanName." "SUCCESS"
                }
            } catch {
                Write-Log "Failed to update channel '$($s.name).$chanName': $($_.Exception.Message)" "WARN"
            }
        }
    }
    Write-Log "Sync complete." "SUCCESS"
}


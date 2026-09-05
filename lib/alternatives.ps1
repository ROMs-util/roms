# alternatives.ps1 - Environment Orchestration and Shim Management

# ---------------------------------------------
# ALTERNATIVES DATA READER
# Reads the JSON alternatives database file at $ROMs_ALTERNATIVES_DB.
# Returns the parsed JSON object with all registered alternatives,
# or a default structure if file doesn't exist.
# ---------------------------------------------
function Get-AlternativesData {
    if (Test-Path $global:ROMs_ALTS) {
        Write-Log "Reading alternatives database: $global:ROMs_ALTS" "TRACE"
        $raw = [System.IO.File]::ReadAllText($global:ROMs_ALTS)
        Write-Log "Raw Alternatives Dump: $raw" "RAW"
        return $raw | ConvertFrom-Json
    }
    return [PSCustomObject]@{}
}

# ---------------------------------------------
# ALTERNATIVES DATA WRITER
# Writes the alternatives database JSON to disk using .NET (prevents encoding issues).
# Creates parent directory if needed. Returns $true on success.
# ---------------------------------------------
function Set-AlternativesData {
    param($Data)
    try {
        $json = $Data | ConvertTo-Json -Depth 10
        Write-Log "Tracing database update: $global:ROMs_ALTS" "TRACE"
        Write-Log "Raw Alternatives Dump: $json" "RAW"
        [System.IO.File]::WriteAllText($global:ROMs_ALTS, $json, [System.Text.Encoding]::UTF8)
        if (Test-Path $global:ROMs_ALTS) {
            Write-Log "Alternatives database updated successfully." "TRACE"
        }
    } catch {
        Write-Log "Failed to save alternatives database: $($_.Exception.Message)" "ERROR"
    }
}

# ---------------------------------------------
# SHIM MANAGEMENT (Installer/Uninstaller for Command Shims)
# Creates or removes a shim script that redirects to a specific package executable.
#
# HOW IT WORKS:
# 1. BUILD SHIM CONTENT: Creates a PS1 wrapper that calls the engine's shim generator.
# 2. WRITE: Saves shim to $ROMs_BIN with the command name.
# 3. PERMISSIONS: Marks as executable (chmod +x equivalent via ACL).
#
# Shim format:
#   # ROMs Shim: roms-alternatives
#   & "$global:ROMs_ENGINE_ENTRY" shim-install "$CommandName" "$PackageBin"
# ---------------------------------------------
function Manage-Shim {
    param(
        [Parameter(Mandatory=$true)][string]$CommandName,
        [string]$ExecutablePath,
        [switch]$Remove
    )

    $shimPath = Join-Path $global:ROMs_BIN "$CommandName.bat"

    if ($Remove) {
        if (Test-Path $shimPath) {
            Write-Log "Removing shim: $CommandName ($shimPath)" "INFO"
            [System.IO.File]::Delete($shimPath)
            if (-not (Test-Path $shimPath)) {
                Write-Log "Shim successfully removed: $CommandName" "TRACE"
            }
        }
        return
    }

    if (-not $ExecutablePath) { return }

    Write-Log "Creating shim: $CommandName -> $ExecutablePath" "INFO"
    
    # ---------------------------------------------
    # SHIM CONSTRUCTION 
    # ---------------------------------------------
    # Logic: If target is a PowerShell script, use 'powershell -File'
    $batContent = if ($ExecutablePath.ToLower().EndsWith(".ps1")) {
        "@echo off`r`npowershell -ExecutionPolicy Bypass -File `"$ExecutablePath`" %*"
    } else {
        "@echo off`r`n`"$ExecutablePath`" %*"
    }

    try {
        # Use our Native .NET utility for clean write (prevents encoding/quote issues)
        Set-RomsFileContent -FilePath $shimPath -Content $batContent -Encoding ([System.Text.Encoding]::ASCII)
        if (Test-Path $shimPath) {
            Write-Log "Shim successfully created: $CommandName ($shimPath)" "TRACE"
        }
    } catch {
        Write-Log "Failed to create shim: $shimPath" "ERROR"
    }
}

# ---------------------------------------------
# ALTERNATIVE REGISTRATION
# Registers a package's command into the alternatives system with priority.
#
# HOW IT WORKS:
# 1. Validate: Check $ROMs_BIN exists, package path is valid.
# 2. Load existing database via Get-AlternativesData.
# 3. Initialize command entry if not exists.
# 4. Add provider with priority (higher = preferred). Current default = 100.
# 5. If this becomes the highest priority, auto-select it.
# 6. Save updated database via Set-AlternativesData.
# 7. Create shim via Manage-Shim pointing to selected provider.
# ---------------------------------------------
function Register-Alternative {
    param(
        [Parameter(Mandatory=$true)][string]$CommandName,
        [Parameter(Mandatory=$true)][string]$PackageId,
        [Parameter(Mandatory=$true)][string]$ExecutablePath,
        [int]$Priority = 100
    )

    Write-Log "Registering alternative for '$CommandName' from package '$PackageId'..." "INFO"
    
    # Robustness: Force absolute path resolution for the provider target
    if ($ExecutablePath -and -not [System.IO.Path]::IsPathRooted($ExecutablePath)) {
        Write-Log "Warning: Registering relative executable path. Resolving to absolute..." "WARN"
        $ExecutablePath = [System.IO.Path]::GetFullPath($ExecutablePath)
    }
    Write-Log "Target executable: $ExecutablePath" "DEBUG"

    $data = Get-AlternativesData
    
    # 1. Ensure command entry exists as PSCustomObject
    if ($null -eq $data.$CommandName) {
        $data | Add-Member -MemberType NoteProperty -Name $CommandName -Value ([PSCustomObject]@{
            providers = @();
            selected = $null;
            mode = "auto"
        })
    }

    $entry = $data.$CommandName
    
    # 2. Update or Add provider (Robust logic with PSCustomObject)
    $otherProviders = if ($entry.providers) { $entry.providers | Where-Object { $_.package -ne $PackageId } } else { @() }
    $entry.providers = @($otherProviders) + @([PSCustomObject]@{
        package = $PackageId;
        priority = $Priority;
        path = $ExecutablePath
    })

    # 3. Auto-Selection logic
    if ($entry.mode -eq "auto") {
        # : Only pivot if strictly better or first provider
        $currentProvider = if ($entry.selected) { $entry.providers | Where-Object { $_.package -eq $entry.selected } | Select-Object -First 1 } else { $null }
        
        if (-not $currentProvider -or $Priority -gt $currentProvider.priority) {
            Write-Log "Promoting '$PackageId' as active provider for '$CommandName' (Priority: $Priority)." "INFO"
            $entry.selected = $PackageId
            Manage-Shim -CommandName $CommandName -ExecutablePath $ExecutablePath
        }
    }

    Set-AlternativesData -Data $data

    # --- Update Metadata Registry (Artifact Tracking) ---
    # Derive package name from PackageId (name-version)
    $packageName = if ($PackageId -match '(.+)-[0-9.]+$') { $Matches[1] } else { $PackageId }
    $metaFile = Join-Path $global:ROMs_METADATA "$packageName.json"
    if (Test-Path $metaFile) {
        try {
            Write-Log "Reading metadata to update artifacts: $metaFile" "TRACE"
            $rawMeta = [System.IO.File]::ReadAllText($metaFile)
            Write-Log "Raw Metadata Dump: $rawMeta" "RAW"
            $meta = $rawMeta | ConvertFrom-Json
            
            if ($null -eq $meta.artifacts) { $meta | Add-Member -MemberType NoteProperty -Name "artifacts" -Value @() }
            
            $shimFile = Join-Path $global:ROMs_BIN "$CommandName.bat"
            if ($meta.artifacts -notcontains $shimFile) {
                $meta.artifacts += $shimFile
                $newMetaJson = $meta | ConvertTo-Json -Depth 10
                Write-Log "Tracing metadata update: $metaFile" "TRACE"
                Write-Log "Raw Updated Metadata: $newMetaJson" "RAW"
                [System.IO.File]::WriteAllText($metaFile, $newMetaJson, [System.Text.Encoding]::UTF8)
                if (Test-Path $metaFile) {
                    Write-Log "Updated metadata artifacts for $packageName." "SUCCESS"
                }
            }
        } catch {
            Write-Log "Failed to update artifacts in metadata for $packageName." "WARN"
        }
    }
}

# ---------------------------------------------
# ALTERNATIVE UNREGISTRATION
# Removes a package's command from the alternatives system.
#
# HOW IT WORKS:
# 1. Load database via Get-AlternativesData.
# 2. If command has no providers left, remove entirely.
# 3. If removing the selected provider, select next highest priority.
# 4. Update database and rebuild shim to point to new selection.
# 5. If no providers remain, remove the shim file.
# ---------------------------------------------
function Unregister-Alternative {
    param(
        [string]$Name,
        [string]$PackageId
    )

    $data = Get-AlternativesData
    $changed = $false
    
    if (-not $PackageId -and $Name) {
        $metaFile = Join-Path $global:ROMs_METADATA "$Name.json"
        if (Test-Path $metaFile) {
            try {
                Write-Log "Reading metadata for unregistration (Alternatives): $metaFile" "TRACE"
                $rawMeta = [System.IO.File]::ReadAllText($metaFile)
                Write-Log "Raw Metadata Dump: $rawMeta" "RAW"
                $meta = $rawMeta | ConvertFrom-Json
                $PackageId = if ($meta.version) { "$($meta.name)-$($meta.version)" } else { $meta.name }
            } catch {
                Write-Log "Failed to read metadata for $Name during unregistration." "WARN"
            }
        }
    }

    if (-not $PackageId) { return }

    foreach ($cmdName in $data.PSObject.Properties.Name) {
        $entry = $data.$cmdName
        $isProvider = $entry.providers | Where-Object { $_.package -eq $PackageId }
        if ($isProvider) {
            $entry.providers = @($entry.providers | Where-Object { $_.package -ne $PackageId })
            $changed = $true

            if ($entry.selected -eq $PackageId) {
                $entry.selected = $null
                if ($entry.mode -eq "manual") {
                    Write-Log "Manual provider for '$cmdName' uninstalled. Reverting to auto mode." "WARN"
                    $entry.mode = "auto"
                }

                if ($entry.mode -eq "auto") {
                    $nextBest = $entry.providers | Sort-Object priority -Descending | Select-Object -First 1
                    if ($nextBest) {
                        $entry.selected = $nextBest.package
                        Manage-Shim -CommandName $cmdName -ExecutablePath $nextBest.path
                    } else {
                        Manage-Shim -CommandName $cmdName -Remove
                    }
                }
            }
        }
    }

    if ($changed) { Set-AlternativesData -Data $data }
}

# ---------------------------------------------
# INTERACTIVE PROVIDER SELECTOR
# Interactive CLI menu to manually select which provider to use for a command.
# Requires Administrator elevation (via Confirm-RomsElevation).
#
# HOW IT WORKS:
# 1. Load database, validate command exists.
# 2. Display numbered list of available providers with priorities.
# 3. Prompt user to pick a number (or 'q' to quit).
# 4. Update selected_provider and rebuild shim.
# 5. Show which provider is now active.
# ---------------------------------------------
function Select-RomsAlternative {
    param([string]$CommandName, [string]$Selection)

    $data = Get-AlternativesData
    if (-not $CommandName) {
        Write-Log "----- Managed Commands (Alternatives) -----" "INFO"
        $data.PSObject.Properties | ForEach-Object {
            $status = if ($_.Value.mode -eq "manual") { "LOCKED ($($_.Value.selected))" } else { "AUTO ($($_.Value.selected))" }
            # For table-like listing, we use standard INFO color logic but prefix with indent
            Write-Log "  $($_.Name.PadRight(20)) - $status" "INFO"
        }
        return
    }

    if ($null -eq $data.$CommandName) {
        Write-Log "Command '$CommandName' not managed." "ERROR"; return
    }

    $entry = $data.$CommandName
    if ($Selection -eq "auto") {
        $entry.mode = "auto"
        $nextBest = $entry.providers | Sort-Object priority -Descending | Select-Object -First 1
        if ($nextBest) {
            $entry.selected = $nextBest.package
            Manage-Shim -CommandName $CommandName -ExecutablePath $nextBest.path
        }
        Set-AlternativesData -Data $data
        Write-Log "Success: '$CommandName' is now managed automatically." "SUCCESS"
        return
    }

    $targetProvider = $null
    if (-not $Selection) {
        Write-Log "Select a provider for '$CommandName':" "INFO"
        $i = 1
        foreach ($p in $entry.providers) {
            $mark = if ($entry.selected -eq $p.package) { "*" } else { " " }
            Write-Log "  [$i] $mark $($p.package)" "INFO"
            $i++
        }
        # Interactive Read-Host is exempt from Write-Log
        $choice = Read-Host "`nEnter selection (1-$($i-1) or 'a')"
        if ($choice -eq "a") { Select-RomsAlternative $CommandName "auto"; return }
        if ([int]::TryParse($choice, [ref]0) -and $choice -ge 1 -and $choice -lt $i) {
            $targetProvider = $entry.providers[$choice - 1]
        }
    } else {
        $targetProvider = $entry.providers | Where-Object { $_.package -eq $Selection -or $_.package -like "$Selection-*" } | Select-Object -First 1
    }

    if ($targetProvider) {
        $entry.mode = "manual"
        $entry.selected = $targetProvider.package
        Manage-Shim -CommandName $CommandName -ExecutablePath $targetProvider.path
        Set-AlternativesData -Data $data
        Write-Log "Success: '$CommandName' locked to $($targetProvider.package)." "SUCCESS"
    }
}

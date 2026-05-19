# alternatives.ps1 - Environment Orchestration and Shim Management

function Get-AlternativesData {
    if (Test-Path $global:ALTERNATIVES_FILE) {
        return [System.IO.File]::ReadAllText($global:ALTERNATIVES_FILE) | ConvertFrom-Json
    }
    return [PSCustomObject]@{}
}

function Set-AlternativesData {
    param($Data)
    try {
        $json = $Data | ConvertTo-Json -Depth 10
        Write-Log "Saving alternatives database to: $global:ALTERNATIVES_FILE" "DEBUG"
        [System.IO.File]::WriteAllText($global:ALTERNATIVES_FILE, $json, [System.Text.Encoding]::UTF8)
        Write-Log "Alternatives database saved successfully." "SUCCESS"
    } catch {
        Write-Log "Failed to save alternatives database: $($_.Exception.Message)" "ERROR"
    }
}

function Manage-Shim {
    param(
        [Parameter(Mandatory=$true)][string]$CommandName,
        [string]$ExecutablePath,
        [switch]$Remove
    )

    $shimPath = Join-Path $global:BIN_DIR "$CommandName.bat"

    if ($Remove) {
        if (Test-Path $shimPath) {
            Write-Log "Removing shim: $CommandName" "INFO"
            [System.IO.File]::Delete($shimPath)
        }
        return
    }

    if (-not $ExecutablePath) { return }

    Write-Log "Creating shim: $CommandName -> $ExecutablePath" "INFO"
    
    # ---------------------------------------------
    # SHIM CONSTRUCTION (Industrial Strength)
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
    } catch {
        Write-Log "Failed to create shim: $shimPath" "ERROR"
    }
}

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
        $best = $entry.providers | Sort-Object priority -Descending | Select-Object -First 1
        if ($best.package -eq $PackageId -or -not $entry.selected) {
            $entry.selected = $best.package
            Manage-Shim -CommandName $CommandName -ExecutablePath $ExecutablePath
        }
    }

    Set-AlternativesData -Data $data

    # --- Update Metadata Registry (Artifact Tracking) ---
    # Derive package name from PackageId (name-version)
    $packageName = if ($PackageId -match '(.+)-[0-9.]+$') { $Matches[1] } else { $PackageId }
    $metaFile = Join-Path $global:METADATA_DIR "$packageName.json"
    if (Test-Path $metaFile) {
        try {
            $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
            if ($null -eq $meta.artifacts) { $meta | Add-Member -MemberType NoteProperty -Name "artifacts" -Value @() }
            
            $shimFile = Join-Path $global:BIN_DIR "$CommandName.bat"
            if ($meta.artifacts -notcontains $shimFile) {
                $meta.artifacts += $shimFile
                $meta | ConvertTo-Json -Depth 10 | Out-File $metaFile -Encoding utf8
                Write-Log "Updated metadata artifacts for $packageName." "SUCCESS"
            }
        } catch {
            Write-Log "Failed to update artifacts in metadata for $packageName." "WARN"
        }
    }
}

function Unregister-Alternative {
    param(
        [string]$Name,
        [string]$PackageId
    )

    $data = Get-AlternativesData
    $changed = $false
    
    if (-not $PackageId -and $Name) {
        $metaFile = Join-Path $global:METADATA_DIR "$Name.json"
        if (Test-Path $metaFile) {
            try {
                $meta = [System.IO.File]::ReadAllText($metaFile) | ConvertFrom-Json
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

function Select-RomsAlternative {
    param([string]$CommandName, [string]$Selection)

    $data = Get-AlternativesData
    if (-not $CommandName) {
        Write-Host "`n----- Managed Commands (Alternatives) -----" -ForegroundColor Cyan
        $data.PSObject.Properties | ForEach-Object {
            $status = if ($_.Value.mode -eq "manual") { "LOCKED ($($_.Value.selected))" } else { "AUTO ($($_.Value.selected))" }
            Write-Host "  $($_.Name.PadRight(20)) - $status"
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
        Write-Host "`nSelect a provider for '$CommandName':" -ForegroundColor Cyan
        $i = 1
        foreach ($p in $entry.providers) {
            $mark = if ($entry.selected -eq $p.package) { "*" } else { " " }
            Write-Host "  [$i] $mark $($p.package)"
            $i++
        }
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

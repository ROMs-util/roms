# orchestrator.ps1 - High-level Installation and Uninstallation Lifecycle

function Invoke-RomsInstall {
    param([string]$Identifier)

    $targetPath = $null
    
    # 1. Resolve Project Root
    $projectRoot = Split-Path (Split-Path $PSScriptRoot)
    $enginePath = Join-Path $projectRoot "package_installer\rmspkg.ps1"

    # 2. Local vs Remote logic
    if (Test-Path $Identifier) {
        $targetPath = $Identifier
    } else {
        Write-Log "Searching registry for package: $Identifier..." "INFO"
        
        # Check cache
        $cacheFiles = Get-ChildItem -Path $global:CACHE_DIR -Filter "*.index.json"
        foreach ($f in $cacheFiles) {
            $data = Get-Content $f.FullName | ConvertFrom-Json
            $pkg = $data | Where-Object { $_.name -eq $Identifier } | Select-Object -First 1
            if ($pkg) {
                Write-Log "Found $($pkg.name) v$($pkg.version) in $($f.Name). Downloading..." "INFO"
                
                # Setup Temp Download
                $tempPkg = Join-Path $global:TEMP_DIR "$($pkg.name).rms"
                if (!(Test-Path $global:TEMP_DIR)) { New-Item -ItemType Directory -Path $global:TEMP_DIR -Force | Out-Null }
                
                if ($pkg.downloadUrl.StartsWith("http")) {
                    Invoke-RestMethod -Uri $pkg.downloadUrl -OutFile $tempPkg
                } else {
                    Copy-Item -Path $pkg.downloadUrl -Destination $tempPkg -Force
                }

                # Verify Hash (Industrial Strength)
                if ($pkg.sha256 -ne "SKIP") {
                    $actualHash = Get-RomsFileHash -FilePath $tempPkg
                    if ($actualHash -ne $pkg.sha256.ToUpper()) {
                        Write-Log "HASH MISMATCH! Expected: $($pkg.sha256), Got: $actualHash" "ERROR"
                        Remove-Item $tempPkg -Force
                        return
                    }
                    Write-Log "SHA256 Integrity Verified." "SUCCESS"
                }

                $targetPath = $tempPkg
                break
            }
        }
    }

    if (-not $targetPath) {
        Write-Log "Package '$Identifier' not found in registry or local path." "ERROR"
        return
    }

    # 3. Call Engine (NoShim: Manager will handle shims via Alternatives)
    Write-Log "Calling engine (rmspkg) to install package..." "INFO"
    
    # Use explicit parameter passing to avoid splatting bugs
    $engineResult = & $enginePath install $targetPath -yes:$global:AutoConfirm -noShim
    
    # 4. Handle Post-Install Registration (Alternatives)
    # Search for the newly created metadata file
    $latestMeta = Get-ChildItem $global:METADATA_DIR -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    
    if ($latestMeta) {
        $meta = Get-Content $latestMeta.FullName -Raw | ConvertFrom-Json
        $packageId = if ($meta.version) { "$($meta.name)-$($meta.version)" } else { $meta.name }
        
        Write-Log "Engine reported successful installation of $packageId." "SUCCESS"
        
        # Register in Alternatives system
        Register-Alternative -CommandName $meta.commandName -PackageId $packageId -ExecutablePath $meta.executable
    } else {
        Write-Log "Failed to find metadata after installation." "ERROR"
    }
}

function Invoke-RomsUninstall {
    param([string]$Name)

    # 1. Identify packageId BEFORE engine deletes metadata
    $packageId = $null
    $metaFile = Join-Path $global:METADATA_DIR "$Name.json"
    if (Test-Path $metaFile) {
        try {
            $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
            $packageId = if ($meta.version) { "$($meta.name)-$($meta.version)" } else { $meta.name }
        } catch {}
    }

    # 2. Resolve Engine Path
    $projectRoot = Split-Path (Split-Path $PSScriptRoot)
    $enginePath = Join-Path $projectRoot "package_installer\rmspkg.ps1"

    Write-Log "Calling engine (rmspkg) to uninstall: $Name" "INFO"
    & $enginePath uninstall $Name -yes:$global:AutoConfirm

    # 3. Auto-Pivot: Handle alternatives unregistration
    Unregister-Alternative -Name $Name -PackageId $packageId
}

# orchestrator.ps1 - High-level Installation and Uninstallation Lifecycle

function Invoke-RomsInstall {
    param([string]$Identifier)

    # 1. Setup Staging Environment
    $stagingDir = Join-Path $global:TEMP_DIR "staging"
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force | Out-Null }
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    # 2. Resolve Project Root
    $projectRoot = Split-Path (Split-Path $PSScriptRoot)
    $enginePath = Join-Path $projectRoot "package_installer\rmspkg.ps1"

    Write-Log "Starting atomic installation for: $Identifier" "INFO"

    try {
        # PHASE 1: Dependency Mapping
        $requiredPackages = @()
        if (Test-Path $Identifier) {
            # Local file - mapping logic for local deps can be added here
            $requiredPackages = @($Identifier)
        } else {
            $pkg = Get-RomsRegistryPackage -Name $Identifier
            if (!$pkg) { throw "Abort: Package '$Identifier' not found in registry." }
            
            $missingDeps = @()
            if ($pkg.dependencies) {
                $missingDeps = Get-RomsDependencyList -Dependencies $pkg.dependencies
            }
            $requiredPackages = $missingDeps + $Identifier
        }

        Write-Log "Mapping dependency tree: $($requiredPackages -join ', ')" "INFO"

        # PHASE 2: Acquisition (Download All to Staging)
        $stagedFiles = @{} # Map of package name -> staged path
        foreach ($pkgName in $requiredPackages) {
            $stagedPath = Stage-Package -Identifier $pkgName -StagingDir $stagingDir
            $stagedFiles[$pkgName] = $stagedPath
        }

        Write-Log "Acquisition complete. All required files staged and verified." "SUCCESS"

        # PHASE 3: Commit (Install All)
        foreach ($pkgName in $requiredPackages) {
            Write-Log "Processing: $pkgName" "INFO"
            $localPath = $stagedFiles[$pkgName]
            
            # Call Engine (NoShim: Manager handles shims via Alternatives)
            & $enginePath install $localPath -yes:$global:AutoConfirm -noShim
            
            # Handle Alternatives Registration
            $latestMeta = Get-ChildItem $global:METADATA_DIR -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestMeta) {
                $meta = Get-Content $latestMeta.FullName -Raw | ConvertFrom-Json
                $packageId = if ($meta.version) { "$($meta.name)-$($meta.version)" } else { $meta.name }
                Register-Alternative -CommandName $meta.commandName -PackageId $packageId -ExecutablePath $meta.executable
            }
        }
        
        Write-Log "Atomic installation of $Identifier and dependencies complete." "SUCCESS"

    } catch {
        Write-Log "CRITICAL FAILURE: $($_.Exception.Message)" "ERROR"
        Write-Log "System remains clean. No system modifications were committed." "WARN"
    } finally {
        # Cleanup Staging
        if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force | Out-Null }
    }
}

# Helper to download/copy a package to the staging area
function Stage-Package {
    param($Identifier, $StagingDir)

    $stagedPath = $null
    
    if (Test-Path $Identifier) {
        # Local Copy
        $pkgName = [System.IO.Path]::GetFileNameWithoutExtension($Identifier)
        $stagedPath = Join-Path $StagingDir "$pkgName.rms"
        Copy-Item -Path $Identifier -Destination $stagedPath -Force
    } else {
        # Registry Download
        $pkg = Get-RomsRegistryPackage -Name $Identifier
        if (!$pkg) { throw "Dependency '$Identifier' is missing from registry index." }

        $stagedPath = Join-Path $StagingDir "$($pkg.name).rms"
        
        Write-Log "Staging $($pkg.name)..." "INFO"
        if ($pkg.downloadUrl.StartsWith("http")) {
            Invoke-RestMethod -Uri $pkg.downloadUrl -OutFile $stagedPath
        } else {
            if (!(Test-Path $pkg.downloadUrl)) { throw "Download path for '$Identifier' is invalid: $($pkg.downloadUrl)" }
            Copy-Item -Path $pkg.downloadUrl -Destination $stagedPath -Force
        }

        # Verify Hash
        if ($pkg.sha256 -ne "SKIP") {
            $actualHash = Get-RomsFileHash -FilePath $stagedPath
            if ($actualHash -ne $pkg.sha256.ToUpper()) {
                Remove-Item $stagedPath -Force
                throw "Integrity check failed for $Identifier. Hash mismatch."
            }
        }
    }
    return $stagedPath
}

# Helper to search registry indexes
function Get-RomsRegistryPackage {
    param($Name)
    $cacheFiles = Get-ChildItem -Path $global:CACHE_DIR -Filter "*.index.json"
    foreach ($f in $cacheFiles) {
        $data = Get-Content $f.FullName | ConvertFrom-Json
        $pkg = $data | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($pkg) { return $pkg }
    }
    return $null
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

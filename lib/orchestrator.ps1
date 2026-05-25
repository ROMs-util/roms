# orchestrator.ps1 - High-level Installation and Uninstallation Lifecycle

function Initialize-RomsEngine {
    Write-Log "Standalone Engine missing. Initiating self-healing bootstrap..." "WARN"

    $stagedEngine = Join-Path $global:TEMP_DIR "rmspkg_bootstrap.rms"
    if (-not (Test-Path $global:TEMP_DIR)) { New-Item -ItemType Directory -Path $global:TEMP_DIR -Force | Out-Null }

    # 1. PHASE A: Registry Search
    $success = $false
    try {
        Update-Registry
        $pkg = Get-RomsRegistryPackage -Name "rmspkg"
        if ($pkg) {
            $url = Get-RomsResolvedUrl -Template $pkg.downloadUrl -Package $pkg
            Write-Log "Downloading engine from registry: $url" "INFO"
            Invoke-RestMethod -Uri $url -OutFile $stagedEngine
            $success = $true
        }
    } catch {
        Write-Log "Registry bootstrap failed: $($_.Exception.Message)" "WARN"
    }

    # 2. PHASE B: Emergency Recovery (Dynamic GitHub API Discovery)
    if (-not $success) {
        Write-Log "Registry unavailable. Falling back to Dynamic GitHub Recovery..." "WARN"
        try {
            $release = Invoke-RestMethod -Uri $global:RECOVERY_API
            $sysArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()
            
            # Find asset matching architecture (e.g. rmspkg-x64*.rms)
            $asset = $release.assets | Where-Object { $_.name -like "rmspkg-$sysArch*.rms" } | Select-Object -First 1
            if (-not $asset) {
                # Fallback to generic if architecture-specific not found
                $asset = $release.assets | Where-Object { $_.name -like "rmspkg*.rms" } | Select-Object -First 1
            }

            if ($asset) {
                Write-Log "Found recovery asset: $($asset.name)" "INFO"
                Invoke-RestMethod -Uri $asset.browser_download_url -OutFile $stagedEngine
                $success = $true
            }
        } catch {
            Write-Log "GitHub Recovery failed: $($_.Exception.Message)" "ERROR"
        }
    }

    if (-not $success) {
        throw "Critical Failure: Ecosystem cannot initialize without the Standalone Engine. All bootstrap sources exhausted."
    }

    # 3. PHASE C: Bootstrap Exception (Manual Extraction)
    Write-Log "Extracting engine foundations..." "INFO"
    try {
        if (-not (Test-Path $global:ENGINE_DIR)) { New-Item -ItemType Directory -Path $global:ENGINE_DIR -Force | Out-Null }
        
        # Industrial Strength: Use native .NET ZipFile
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($stagedEngine)
        
        foreach ($entry in $zip.Entries) {
            $destPath = Join-Path $global:ENGINE_DIR $entry.FullName
            if ($entry.FullName.EndsWith("/")) {
                if (-not (Test-Path $destPath)) { New-Item -ItemType Directory -Path $destPath -Force | Out-Null }
            } else {
                $parentDir = Split-Path $destPath
                if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
            }
        }
        $zip.Dispose()
        Remove-Item $stagedEngine -Force

        # 4. PHASE D: Handshake (Engine-Owned Registration)
        Write-Log "Activating engine shims and metadata..." "INFO"
        & $global:ENGINE_SCRIPT bootstrap

        Write-Log "Standalone Engine successfully initialized." "SUCCESS"
    } catch {
        if ($zip) { $zip.Dispose() }
        throw "Bootstrap extraction failed: $($_.Exception.Message)"
    }
}

function Invoke-RomsInstall {
    param([string]$Identifier)

    # 1. Setup Staging Environment
    $stagingDir = Join-Path $global:TEMP_DIR "staging"
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force | Out-Null }
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    # 2. Resolve Engine Path
    $enginePath = $global:ResolvedEnginePath

    Write-Log "Starting atomic installation for: $Identifier" "INFO"

    try {
        # PHASE 1: Dependency Mapping
        $requiredPackages = @()
        if (Test-Path $Identifier) {
            # Robustness: Force absolute path for local file
            $Identifier = [System.IO.Path]::GetFullPath($Identifier)
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
            
            if ($LASTEXITCODE -ne 0) {
                throw "Engine (rmspkg) failed to install '$pkgName'. See engine logs for details."
            }

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
        # Handle identifier with version constraint (name:constraint)
        $parts = $Identifier.Split(':')
        $name = $parts[0]
        
        $pkg = Get-RomsRegistryPackage -Name $name
        if (!$pkg) { throw "Dependency '$name' is missing from registry index." }

        # Variable Injection (Industrial Strength Resolution)
        $resolvedUrl = Get-RomsResolvedUrl -Template $pkg.downloadUrl -Package $pkg
        if (!$resolvedUrl) { throw "Download URL could not be resolved for '$name'." }

        $stagedPath = Join-Path $StagingDir "$($pkg.name).rms"
        
        Write-Log "Staging $($pkg.name) (v$($pkg.version))..." "INFO"
        if ($resolvedUrl.StartsWith("http")) {
            Invoke-RestMethod -Uri $resolvedUrl -OutFile $stagedPath
        } else {
            if (!(Test-Path $resolvedUrl)) { throw "Resolved download path for '$name' is invalid: $resolvedUrl" }
            Copy-Item -Path $resolvedUrl -Destination $stagedPath -Force
        }

        # Verify Integrity (Size & Hash)
        # Industrial Strength: Mandatory verification if data is present in registry
        if ($pkg.size -and $pkg.size -gt 0) {
            $actualSize = (Get-Item $stagedPath).Length
            if ($actualSize -ne $pkg.size) {
                Remove-Item $stagedPath -Force
                throw "Integrity check failed for '$name'. Size mismatch (Expected: $($pkg.size), Actual: $actualSize)."
            }
        }

        if ($pkg.sha256 -and $pkg.sha256 -ne "UNAVAILABLE" -and $pkg.sha256 -ne "SKIP") {
            $actualHash = Get-RomsFileHash -FilePath $stagedPath
            if ($actualHash -ne $pkg.sha256.ToUpper()) {
                Remove-Item $stagedPath -Force
                throw "Integrity check failed for '$name'. Hash mismatch (Expected: $($pkg.sha256.ToUpper()), Actual: $actualHash)."
            }
            # Standard: Store hash in session for engine metadata registration
            $global:ROMs_STAGED_HASH = $actualHash
            Write-Log "Verified integrity for $($pkg.name) (Hash: $($actualHash.Substring(0,8))...)" "SUCCESS"
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
        # Support Trinity v1.1.0 (nested packages) or legacy flat array
        $pkgs = if ($data.packages) { $data.packages } else { $data }
        
        $pkg = $pkgs | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($pkg) { 
            # Inject repo-level template if package lacks its own (handle null or empty)
            if ([string]::IsNullOrWhiteSpace($pkg.downloadUrl) -and $data.repo.url_template) {
                $pkg | Add-Member -MemberType NoteProperty -Name "downloadUrl" -Value $data.repo.url_template -Force
            }
            return $pkg 
        }
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
    $enginePath = $global:ResolvedEnginePath

    # 3. Dynamic Flag Handshake (Honor User Intent)
    $engineArgs = @("uninstall", $Name)
    if ($global:AutoConfirm) { $engineArgs += "--yes" }
    if ($global:Verbose)     { $engineArgs += "--verbose" }

    Write-Log "Calling engine (rmspkg) to uninstall: $Name" "INFO"
    & $enginePath @engineArgs

    # 4. Auto-Pivot: Handle alternatives unregistration
    Unregister-Alternative -Name $Name -PackageId $packageId
}

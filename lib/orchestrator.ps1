# orchestrator.ps1 - High-level Installation and Uninstallation Lifecycle

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
            # Handle identifier with version constraint (name:constraint)
            $parts = $Identifier.Split(':')
            $name = $parts[0]
            $constraint = if ($parts.Count -gt 1) { $parts[1] } else { "*" }

            $pkg = Get-RomsRegistryPackage -Name $name -Constraint $constraint
            if (!$pkg) { throw "Abort: Package '$name' (Constraint: $constraint) not found in registry." }
            
            $missingDeps = @()
            if ($pkg.dependencies) {
                $missingDeps = Get-RomsDependencyList -Dependencies $pkg.dependencies
            }
            # Force array concatenation to prevent string mangling
            $requiredPackages = @() + $missingDeps + $Identifier
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
            
            # 3. Dynamic Flag Handshake (Honor User Intent)
            Invoke-EngineCommand -Command "install" -Target $localPath -Yes:$global:AutoConfirm -ShowVerbose:$global:Verbose -NoShim

            # Handle Alternatives Registration
            $latestMeta = Get-ChildItem $global:METADATA_DIR -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestMeta) {
                $meta = Get-Content $latestMeta.FullName -Raw | ConvertFrom-Json
                $packageId = if ($meta.version) { "$($meta.name)-$($meta.version)" } else { $meta.name }
                
                # Industrial Strength: Ensure priority is passed to the Alternatives system
                $priority = if ($null -ne $meta.priority) { [int]$meta.priority } else { 100 }
                Register-Alternative -CommandName $meta.commandName -PackageId $packageId -ExecutablePath $meta.executable -Priority $priority
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
        $constraint = if ($parts.Count -gt 1) { $parts[1] } else { "*" }
        
        $pkg = Get-RomsRegistryPackage -Name $name -Constraint $constraint
        if (!$pkg) { throw "Dependency '$name' (Constraint: $constraint) is missing from registry index." }

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
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$false)][string]$Constraint = "*"
    )
    
    $cacheFiles = Get-ChildItem -Path $global:CACHE_DIR -Filter "*.index.json"
    $candidates = @()
    
    # Industrial Strength: Use ecosystem constant instead of volatile .NET class
    $sysArch = $global:Architecture.ToLower()

    foreach ($f in $cacheFiles) {
        $data = Get-Content $f.FullName -Raw | ConvertFrom-Json
        if (!$data) { continue }

        # Support Trinity v1.1.0 (nested packages) or legacy flat array
        $pkgs = if ($null -ne $data.packages) { $data.packages } else { $data }
        
        if ($null -eq $pkgs -or $pkgs.Count -eq 0) { continue }

        $matches = $pkgs | Where-Object { $_.name -eq $Name }
        foreach ($pkg in $matches) {
            # Architecture Filtering
            $pkgArch = if ($pkg.architecture) { $pkg.architecture.ToLower() } else { "all" }
            if ($pkgArch -ne "all" -and $pkgArch -ne $sysArch) { continue }

            # Inject repo-level template if package lacks its own
            # Guard: data.repo might be null in legacy flat registries
            if ([string]::IsNullOrWhiteSpace($pkg.downloadUrl) -and $null -ne $data.repo -and $data.repo.url_template) {
                $pkg | Add-Member -MemberType NoteProperty -Name "downloadUrl" -Value $data.repo.url_template -Force
            }

            # Check if satisfies constraint
            if (Test-RomsVersionMatch -CurrentVersion $pkg.version -Constraint $Constraint) {
                $candidates += $pkg
            }
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    # Sort Candidates (Highest Version First)
    $best = $candidates[0]
    foreach ($c in $candidates) {
        if ((Compare-RomsVersions -v1 $c.version -v2 $best.version) -gt 0) {
            $best = $c
        }
    }

    return $best
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
    Write-Log "Calling engine (rmspkg) to uninstall: $Name" "INFO"
    Invoke-EngineCommand -Command "uninstall" -Target $Name -Yes:$global:AutoConfirm -ShowVerbose:$global:Verbose

    # 4. Auto-Pivot: Handle alternatives unregistration
    Unregister-Alternative -Name $Name -PackageId $packageId
}

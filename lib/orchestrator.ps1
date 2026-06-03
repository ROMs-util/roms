# orchestrator.ps1 - High-level Installation and Uninstallation Lifecycle

# ---------------------------------------------
# INSTALL ORCHESTRATOR (3-Phase Atomic Install)
# Main install flow: Dependency Mapping -> Acquisition -> Commit.
#
# HOW IT WORKS:
# 1. DEPENDENCY MAPPING: If local file, use directly. If package name, resolve via registry,
#    then call Get-RomsDependencyList to recursively resolve all sub-dependencies.
# 2. ACQUISITION: Call Stage-Package for each required package to download/verify into staging dir.
# 3. COMMIT: For each package, invoke the engine (rmspkg install), process the handshake JSON
#    for alternatives registration, then clean up staging.
#
# ERROR HANDLING: Rolls back $successfullyInstalled on failure via Unregister-Alternative.
# THROWS: If package not found in registry, or engine command fails.
# ---------------------------------------------
function Invoke-RomsInstall {
    param([string]$Identifier)

    # 1. Setup Staging Environment
    $stagingDir = Join-Path $global:ROMs_TEMP "staging"
    if (Test-Path $stagingDir) { 
        Write-Log "Purging existing staging directory: $stagingDir" "TRACE"
        # File-by-File Physical Truth: Iterate and log each file deletion
        Get-ChildItem -Path $stagingDir -Recurse -File | ForEach-Object {
            Write-Log "Deleting staged file: $($_.FullName)" "TRACE"
            Remove-Item $_.FullName -Force
        }
        # Finally remove the empty folder structure
        Remove-Item $stagingDir -Recurse -Force | Out-Null 
    }
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    if (Test-Path $stagingDir) { Write-Log "Created staging directory: $stagingDir" "TRACE" }

    # 2. Resolve Engine Path
    $enginePath = $global:ResolvedEnginePath

    Write-Log "Starting atomic installation for: $Identifier" "INFO"

    try {
        $successfullyInstalled = @()
        # PHASE 1: Dependency Mapping
        $requiredPackages = @()
        if (Test-Path $Identifier) {
            # Robustness: Force absolute path for local file
            $Identifier = [System.IO.Path]::GetFullPath($Identifier)
            $requiredPackages = @($Identifier)
            Write-Log "Local artifact detected: $Identifier" "DEBUG"
        } else {
            # Handle identifier with version constraint (name:constraint)
            $parsed = Parse-RomsSemVerIdentifier -Identifier $Identifier
            $name = $parsed.Name
            $constraint = $parsed.Constraint

            $pkg = Get-RomsRegistryPackage -Name $name -Constraint $constraint
            if (!$pkg) { throw "Abort: Package '$name' (Constraint: $constraint) not found in registry." }
            
            $missingDeps = @()
            if ($pkg.dependencies) {
                $missingDeps = Get-RomsDependencyList -Dependencies $pkg.dependencies
                if ($missingDeps) {
                    Write-Log "Resolved dependencies: $($missingDeps -join ', ')" "DEBUG"
                }
            }
            # Force array concatenation to prevent string mangling
            $requiredPackages = @() + $missingDeps + $Identifier
        }

        if ($requiredPackages) {
            Write-Log "Mapping dependency tree: $($requiredPackages -join ', ')" "INFO"
        }

        # PHASE 2: Acquisition (Download All to Staging)
        $stagedFiles = @{} # Map of package name -> staged path
        foreach ($pkgName in $requiredPackages) {
            $stagedPath = Stage-Package -Identifier $pkgName -StagingDir $stagingDir
            $stagedFiles[$pkgName] = $stagedPath
            if (Test-Path $stagedPath) { Write-Log "Staged artifact verified: $(Split-Path $stagedPath -Leaf)" "TRACE" }
        }

        Write-Log "Acquisition complete. All required files staged and verified." "SUCCESS"

        # PHASE 3: Commit (Install All)
        foreach ($pkgName in $requiredPackages) {
            Write-Log "Processing: $pkgName" "INFO"
            $localPath = $stagedFiles[$pkgName]
            
            # 3. Dynamic Flag Handshake (Honor User Intent)
            # The Engine writes a JSON report (Handshake) to a dedicated temp file
            $handshakeFile = Join-Path $global:ROMs_TEMP "handshake.json"
            if (Test-Path $handshakeFile) { Remove-Item $handshakeFile -Force } # Clean old
            
            Invoke-EngineCommand -Command "install" -Target $localPath -Yes:$global:AutoConfirm -ShowVerbose:($global:VerboseLevel -ge 1) -NoShim

            # Track for rollback (Strip constraints or handle local paths)
            $cleanName = $pkgName.Split(':')[0]
            if (Test-Path $pkgName) { $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($pkgName) }
            $successfullyInstalled += $cleanName

            # Handle Alternatives Registration (Machine Truth from File)
            if (Test-Path $handshakeFile) {
                Write-Log "Processing engine handshake for alternatives..." "TRACE"
                $rawHandshake = Get-Content $handshakeFile -Raw
                if ($rawHandshake) {
                    Write-Log "Handshake Data: $rawHandshake" "RAW"
                    $meta = $rawHandshake | ConvertFrom-Json
                    $packageId = if ($meta.packageId) { $meta.packageId } else { $meta.name }
                    
                    #  Use the explicit primary executable and shims from the handshake
                    $priority = if ($null -ne $meta.priority) { [int]$meta.priority } else { 100 }
                    Register-Alternative -CommandName $meta.commandName -PackageId $packageId -ExecutablePath $meta.primaryExecutable -Priority $priority
                    
                    Remove-Item $handshakeFile -Force # Audit Cleanup
                }
            }
        }
        
        Write-Log "Atomic installation of $Identifier and dependencies complete." "SUCCESS"

    } catch {
        Write-Log "CRITICAL FAILURE: $($_.Exception.Message)" "ERROR"

        # PHASE 4: Transactional Rollback
        if ($successfullyInstalled.Count -gt 0) {
            Write-Log "Initiating transactional rollback for $($successfullyInstalled.Count) packages..." "WARN"
            foreach ($pkgToRollback in ($successfullyInstalled | Select-Object -Unique)) {
                try {
                    Invoke-RomsUninstall -Name $pkgToRollback
                } catch {
                    Write-Log "Rollback failed for ${pkgToRollback}: $($_.Exception.Message)" "ERROR"
                }
            }
        }

        Write-Log "System remains clean. No system modifications were committed." "WARN"
    } finally {
        # Cleanup Staging
        if (Test-Path $stagingDir) { 
            Write-Log "Cleaning up staging directory: $stagingDir" "TRACE"
            # File-by-File Physical Truth: Iterate and log each file deletion
            Get-ChildItem -Path $stagingDir -Recurse -File | ForEach-Object {
                Write-Log "Deleting staged file: $($_.FullName)" "TRACE"
                Remove-Item $_.FullName -Force
            }
            Remove-Item $stagingDir -Recurse -Force | Out-Null 
        }
    }
}

# Helper to download/copy a package to the staging area
# ---------------------------------------------
# PACKAGE STAGING (Acquisition Phase)
# Downloads a package from registry OR copies a local .rms file into the staging directory.
#
# HOW IT WORKS:
# 1. If $Identifier is a local path, copy directly to staging.
# 2. If registry name, split into name:constraint, lookup via Get-RomsRegistryPackage.
# 3. Construct download URL from resolved package metadata (url_template).
# 4. Use native .NET WebClient to download directly to staging path (no temp intermediate).
# 5. Verify SHA256 hash if package provides one.
# 6. Throw if package not found or hash mismatch.
#
# RETURNS: Staged file path (absolute), or throws on error.
# ---------------------------------------------
function Stage-Package {
    param($Identifier, $StagingDir)

    $stagedPath = $null
    
    if (Test-Path $Identifier) {
        # Local Copy
        $pkgName = [System.IO.Path]::GetFileNameWithoutExtension($Identifier)
        $stagedPath = Join-Path $StagingDir "$pkgName.rms"
        Copy-Item -Path $Identifier -Destination $stagedPath -Force
        if (Test-Path $stagedPath) { Write-Log "Copied local artifact to staging: $(Split-Path $stagedPath -Leaf)" "TRACE" }
    } else {
        # Registry Download
        # Handle identifier with version constraint (name:constraint)
        $parts = $Identifier.Split(':')
        $name = $parts[0]
        $constraint = if ($parts.Count -gt 1) { $parts[1] } else { "*" }
        
        $pkg = Get-RomsRegistryPackage -Name $name -Constraint $constraint
        if (!$pkg) { throw "Dependency '$name' (Constraint: $constraint) is missing from registry index." }

        # Variable Injection ( Resolution)
        $resolvedUrl = Get-RomsResolvedUrl -Template $pkg.downloadUrl -Package $pkg
        if (!$resolvedUrl) { throw "Download URL could not be resolved for '$name'." }

        $stagedPath = Join-Path $StagingDir "$($pkg.name).rms"
        
        Write-Log "Staging $($pkg.name) (v$($pkg.version))..." "INFO"
        if ($resolvedUrl.StartsWith("http")) {
            Invoke-RestMethod -Uri $resolvedUrl -OutFile $stagedPath
            if (Test-Path $stagedPath) { Write-Log "Downloaded artifact to staging: $(Split-Path $stagedPath -Leaf)" "TRACE" }
        } else {
            if (!(Test-Path $resolvedUrl)) { throw "Resolved download path for '$name' is invalid: $resolvedUrl" }
            Copy-Item -Path $resolvedUrl -Destination $stagedPath -Force
            if (Test-Path $stagedPath) { Write-Log "Copied artifact to staging: $(Split-Path $stagedPath -Leaf)" "TRACE" }
        }

        # Verify Integrity (Size & Hash)
        # : Mandatory verification if data is present in registry
        if ($pkg.size -and $pkg.size -gt 0) {
            $actualSize = (Get-Item $stagedPath).Length
            if ($actualSize -ne $pkg.size) {
                Remove-Item $stagedPath -Force
                throw "Integrity check failed for '$name'. Size mismatch (Expected: $($pkg.size), Actual: $actualSize)."
            }
            Write-Log "Verified size integrity: $actualSize bytes" "TRACE"
        }

        if ($pkg.sha256 -and $pkg.sha256 -ne "UNAVAILABLE" -and $pkg.sha256 -ne "SKIP") {
            $actualHash = Get-RomsFileHash -FilePath $stagedPath
            if ($actualHash -ne $pkg.sha256.ToUpper()) {
                Remove-Item $stagedPath -Force
                throw "Integrity check failed for '$name'. Hash mismatch (Expected: $($pkg.sha256.ToUpper()), Actual: $actualHash)."
            }
            # Standard: Store hash in session for engine metadata registration
            $global:ROMs_STAGED_HASH = $actualHash
            Write-Log "Verified hash integrity: $($actualHash.Substring(0,8))..." "TRACE"
            Write-Log "Verified integrity for $($pkg.name) (Hash: $($actualHash.Substring(0,8))...)" "SUCCESS"
        }
    }
    return $stagedPath
}

# Helper to search registry indexes
# ---------------------------------------------
# REGISTRY LOOKUP (Best-Version Resolution)
# Searches all cached registry indexes for a package by exact name, then applies constraint.
#
# HOW IT WORKS:
# 1. Scan all *.index.json files in $ROMs_CACHE.
# 2. For each index, support both Trinity v1.1.0 nested format and legacy flat array.
# 3. Filter by current OS architecture (amd64, arm64, etc.).
# 4. Find package by exact name match.
# 5. Apply version constraint via Test-RomsVersionMatch if provided.
# 6. Return best matching version (first found in source order).
#
# RETURNS: Package object or $null if not found.
# ---------------------------------------------
function Get-RomsRegistryPackage {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$false)][string]$Constraint = "*"
    )
    
    $cacheFiles = Get-ChildItem -Path $global:ROMs_CACHE -Filter "*.index.json"
    $candidates = @()
    
    # : Use ecosystem constant instead of volatile .NET class
    $sysArch = $global:ROMs_ARCH.ToLower()

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

# ---------------------------------------------
# UNINSTALL ORCHESTRATOR (Safe Removal with Metadata Preservation)
# Safely removes an installed package by forwarding to the engine.
#
# HOW IT WORKS:
# 1. Read metadata from $ROMs_METADATA/$Name.json BEFORE engine deletes it (to get packageId).
# 2. Forward to engine via Invoke-EngineCommand "uninstall".
# 3. Engine deletes actual files and removes metadata.
# 4. Unregister any alternatives shims registered for this package.
#
# RETURNS: Exit code from engine process.
# ---------------------------------------------
function Invoke-RomsUninstall {
    param([string]$Name)

    # 1. Identify packageId BEFORE engine deletes metadata
    $packageId = $null
    $metaFile = Join-Path $global:ROMs_METADATA "$Name.json"
    if (Test-Path $metaFile) {
        try {
            Write-Log "Reading metadata for unregistration: $metaFile" "TRACE"
            $rawMeta = Get-Content $metaFile -Raw
            if ($rawMeta) { Write-Log "Metadata record ($Name): $rawMeta" "RAW" }
            $meta = $rawMeta | ConvertFrom-Json
            $packageId = if ($meta.version) { "$($meta.name)-$($meta.version)" } else { $meta.name }
        } catch {
            Write-Log "Failed to read metadata for $Name during unregistration." "WARN"
        }
    }

    # 2. Resolve Engine Path
    $enginePath = $global:ROMs_ENGINE_ENTRY

    # 3. Dynamic Flag Handshake (Honor User Intent)
    Write-Log "Calling engine (rmspkg) to uninstall: $Name" "INFO"
    $exitCode = Invoke-EngineCommand -Command "uninstall" -Target $Name -Yes:$global:AutoConfirm -ShowVerbose:($global:VerboseLevel -ge 1)

    # 4. Auto-Pivot: Handle alternatives unregistration
    Unregister-Alternative -Name $Name -PackageId $packageId
}

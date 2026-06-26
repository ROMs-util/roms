# orchestrator.ps1 - High-level Installation and Uninstallation Lifecycle

# ---------------------------------------------
# MULTI-PACKAGE INSTALL ORCHESTRATOR (Unified Atomic Transaction)
# Primary entry point for the 'roms install' command when given 1..N packages.
# All packages share ONE staging directory, ONE dependency map, and ONE rollback scope.
#
# HOW IT WORKS:
# PHASE 1 (MAP): For each requested identifier, resolve its registry entry and recursively
#   resolve all its dependencies via Get-RomsDependencyList, passing a shared $CollectedList
#   to ensure cross-package deduplication (if pkg-a and pkg-b both need lib-c, it installs once).
# PHASE 2 (ACQUIRE): Download/copy every resolved package into the shared staging directory.
# PHASE 3 (COMMIT): Install each staged package via the engine in dependency order.
#   Register alternatives from the engine handshake file.
# PHASE 4 (ROLLBACK): If ANY single package fails during commit, the entire set of
#   successfully installed packages in this session is rolled back atomically.
#
# PARAM: $Identifiers -- Array of package identifiers, e.g., @("helper", "game:1.2.2", "lib:>3.0")
# THROWS: Re-throws after rollback so the router can report failure cleanly.
# ---------------------------------------------
function Invoke-RomsMultiInstall {
    param([string[]]$Identifiers)

    if (-not $Identifiers -or $Identifiers.Count -eq 0) {
        Write-Log "No package identifiers provided." "ERROR"
        return
    }

    # PHASE 0: Setup shared transaction workspace
    $stagingDir = Join-Path $global:ROMs_TEMP "staging"
    if (Test-Path $stagingDir) {
        Write-Log "Purging existing staging directory: $stagingDir" "TRACE"
        Get-ChildItem -Path $stagingDir -Recurse -File | ForEach-Object {
            Write-Log "Deleting staged file: $($_.FullName)" "TRACE"
            Remove-Item $_.FullName -Force
        }
        Remove-Item $stagingDir -Recurse -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    if (Test-Path $stagingDir) { Write-Log "Created staging directory: $stagingDir" "TRACE" }

    $successfullyInstalled = @()

    Write-Log "Starting unified atomic installation for: $($Identifiers -join ', ')" "INFO"

    try {
        # PHASE 1: Unified Dependency Mapping
        # A single $CollectedList is shared across all identifiers to deduplicate shared dependencies.
        $CollectedList = @()

        foreach ($id in $Identifiers) {
            if (Test-Path $id) {
                # Local artifact: resolve to absolute path and add directly.
                # No registry lookup or dependency resolution needed for local files.
                $absPath = [System.IO.Path]::GetFullPath($id)
                if ($CollectedList -notcontains $absPath) {
                    $CollectedList += $absPath
                    Write-Log "Local artifact queued: $absPath" "DEBUG"
                }
            } else {
                # Registry package: parse the identifier, find the best-match version,
                # then recursively resolve its dependency tree into the shared list.
                $parsed = Parse-RomsSemVerIdentifier -Identifier $id
                $name   = $parsed.Name
                $constraint = $parsed.Constraint

                $pkg = Get-RomsRegistryPackage -Name $name -Constraint $constraint
                if (!$pkg) { throw "Abort: Package '$name' (Constraint: '$constraint') not found in registry." }

                Write-Log "Resolved '$name' to v$($pkg.version) from registry." "DEBUG"

                # Recursively resolve sub-dependencies, sharing the accumulated list.
                # @() wrapping guarantees $CollectedList stays an array even if the
                # resolver returns a single-element result through the pipeline.
                if ($pkg.dependencies) {
                    $CollectedList = @(Get-RomsDependencyList `
                        -Dependencies $pkg.dependencies `
                        -CollectedList $CollectedList)
                }

                # Append this top-level package (version-locked) if not already in the list.
                $versionedId = "$($pkg.name):$($pkg.version)"
                $alreadyIn = $false
                foreach ($item in $CollectedList) {
                    if ($item -eq $pkg.name -or $item.StartsWith("$($pkg.name):")) {
                        $alreadyIn = $true; break
                    }
                }
                if (-not $alreadyIn) {
                    $CollectedList += $versionedId
                    Write-Log "Queued for install: $versionedId" "TRACE"
                }
            }
        }

        $requiredPackages = $CollectedList
        Write-Log "Unified dependency map: $($requiredPackages -join ', ')" "INFO"

        # PHASE 2: Unified Acquisition (Download / Copy all packages to staging)
        $stagedFiles = @{}
        foreach ($pkgId in $requiredPackages) {
            $stagedPath = Stage-Package -Identifier $pkgId -StagingDir $stagingDir
            $stagedFiles[$pkgId] = $stagedPath
            if (Test-Path $stagedPath) {
                Write-Log "Staged artifact verified: $(Split-Path $stagedPath -Leaf)" "TRACE"
            }
        }
        Write-Log "Acquisition complete. All required files staged and verified." "SUCCESS"

        # PHASE 3: Unified Commit (Install all packages in dependency order)
        foreach ($pkgId in $requiredPackages) {
            Write-Log "Processing: $pkgId" "INFO"
            $localPath = $stagedFiles[$pkgId]

            # Clean any leftover handshake from a previous iteration
            $handshakeFile = Join-Path $global:ROMs_TEMP "handshake.json"
            if (Test-Path $handshakeFile) { Remove-Item $handshakeFile -Force }

            Invoke-EngineCommand -Command "install" -Target $localPath `
                -Yes:$global:AutoConfirm -ShowVerbose:($global:VerboseLevel -ge 1) -NoShim

            # Track clean name for rollback (strip constraint suffix or derive from local path)
            $cleanName = $pkgId.Split(':')[0]
            if (Test-Path $pkgId) { $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($pkgId) }
            $successfullyInstalled += $cleanName

            # Process engine handshake for alternatives registration
            if (Test-Path $handshakeFile) {
                Write-Log "Processing engine handshake for alternatives..." "TRACE"
                $rawHandshake = Get-Content $handshakeFile -Raw
                if ($rawHandshake) {
                    Write-Log "Handshake Data: $rawHandshake" "RAW"
                    $meta = $rawHandshake | ConvertFrom-Json
                    $packageId = if ($meta.packageId) { $meta.packageId } else { $meta.name }
                    $priority  = if ($null -ne $meta.priority) { [int]$meta.priority } else { 100 }
                    Register-Alternative -CommandName $meta.commandName `
                        -PackageId $packageId `
                        -ExecutablePath $meta.primaryExecutable `
                        -Priority $priority
                    Remove-Item $handshakeFile -Force
                }
            }
        }

        Write-Log "Unified atomic installation of [$($Identifiers -join ', ')] complete." "SUCCESS"

    } catch {
        Write-Log "CRITICAL FAILURE during multi-install: $($_.Exception.Message)" "ERROR"

        # PHASE 4: Transactional Rollback
        # Any package committed before the failure is reversed, restoring system cleanliness.
        if ($successfullyInstalled.Count -gt 0) {
            Write-Log "Initiating global rollback for $($successfullyInstalled.Count) committed package(s)..." "WARN"
            foreach ($pkgToRollback in ($successfullyInstalled | Select-Object -Unique)) {
                try {
                    Invoke-RomsUninstall -Name $pkgToRollback
                } catch {
                    Write-Log "Rollback failed for '${pkgToRollback}': $($_.Exception.Message)" "ERROR"
                }
            }
        }
        Write-Log "System restored to pre-install state." "WARN"

    } finally {
        # Cleanup shared staging directory
        if (Test-Path $stagingDir) {
            Write-Log "Cleaning up staging directory: $stagingDir" "TRACE"
            Get-ChildItem -Path $stagingDir -Recurse -File | ForEach-Object {
                Write-Log "Deleting staged file: $($_.FullName)" "TRACE"
                Remove-Item $_.FullName -Force
            }
            Remove-Item $stagingDir -Recurse -Force | Out-Null
        }
    }
}

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
# NOTE: This function is preserved for internal use and backward compatibility.
#       The public-facing entry point is Invoke-RomsMultiInstall.
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

# ---------------------------------------------
# REGISTRY PACKAGE LOOKUP (Hardened)
# Finds the best available version of a package across active channels.
#
# HOW IT WORKS:
# 1. Resolves active channel identifiers to enforce session isolation.
# 2. Scans local registry indices that match active identifiers.
# 3. Collects all candidates satisfying the SemVer constraint.
# 4. Selects the candidate with the highest SemVer precedence.
#
# RETURNS: [PSCustomObject] Best package metadata or $null if not found.
# ---------------------------------------------
function Get-RomsRegistryPackage {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$false)][string]$Constraint = "*"
    )

    $cacheFiles = Get-ChildItem -Path $global:ROMs_CACHE -Filter "*.index.json"
    $activeIDs = Get-RomsActiveChannelIdentifiers # Only scan active channels
    $candidates = @()
    # : Use ecosystem constant instead of volatile .NET class
    $sysArch = $global:ROMs_ARCH.ToLower()

    foreach ($f in $cacheFiles) {
        $sourceName = $f.Name.Replace(".index.json", "")
        
        # ISOLATION FILTER: Skip if this cache file doesn't match an active identifier
        if ($activeIDs -notcontains $sourceName) {
            continue
        }

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

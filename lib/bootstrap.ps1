# bootstrap.ps1 - Standalone Engine Discovery and Self-Healing logic

# ---------------------------------------------
# ENGINE INTEGRITY (Self-Healing Watchdog)
# Verifies the standalone engine (rmspkg) is installed and uncorrupted.
# Checks three layers: (1) metadata exists, (2) all files in metadata are present,
# (3) entry point has correct signature header.
# Skips manifest check in dev workspace (detects package_installer\rmspkg.ps1 path).
# Returns $true if clean, $false if integrity compromised.
# ---------------------------------------------
function Test-RomsEngineIntegrity {
    $enginePath = Get-RomsEnginePath
    if (-not $enginePath) { return $false }
    
    if (Test-Path $enginePath) {
        Write-Log "Tracing engine path discovery: $enginePath" "TRACE"
    }

    # Workspace/Dev detection (Skip strict manifest check if in a Git repo)
    if ($enginePath -match "package_installer\\rmspkg.ps1") {
        Write-Log "Development Workspace detected. Skipping strict manifest check." "DEBUG"
        return $true
    }

    try {
        # 1. Metadata Verification (Source of Truth)
        $metadataPath = Join-Path $global:ROMs_METADATA "rmspkg.json"
        if (-not (Test-Path $metadataPath)) {
            Write-Log "Standalone Engine metadata is missing. Integrity compromised." "WARN"
            return $false
        }
        Write-Log "Verified metadata source: $metadataPath" "TRACE"

        # 2. Manifest Verification (Recursive File Check)
        $rawMeta = Get-Content $metadataPath -Raw
        Write-Log "rmspkg metadata: $rawMeta" "RAW"
        $metadata = $rawMeta | ConvertFrom-Json
        $engineRoot = $global:ROMs_ENGINE_DIR
        
        foreach ($fileRelPath in $metadata.files) {
            $fileAbsPath = Join-Path $engineRoot $fileRelPath
            if (Test-Path $fileAbsPath) {
                Write-Log "Verified file integrity: $fileRelPath" "TRACE"
            } else {
                Write-Log "Standalone Engine integrity failure: Missing file [$fileRelPath]" "WARN"
                return $false
            }
        }

        # 3. Header Signature Check (Main Entry Point)
        if (Test-Path $enginePath) {
            $header = Get-Content $enginePath -TotalCount 1 -ErrorAction Stop
            if ($header) { Write-Log "rmspkg header signature: $header" "RAW" }
            if ($header -notlike "# rmspkg.ps1 - The ROMs-util Standalone Engine*") {
                Write-Log "Standalone Engine binary has an invalid header signature." "WARN"
                return $false
            }
            Write-Log "Verified engine header signature." "TRACE"
        }

        return $true
    } catch {
        Write-Log "Integrity check error: $($_.Exception.Message)" "DEBUG"
        return $false
    }
}

# ---------------------------------------------
# ENGINE DISCOVERY
# Locates the standalone engine (rmspkg.ps1) in this order:
# (1) Standard path via $global:ROMs_ENGINE_ENTRY, (2) Dev workspace (if .git exists),
# (3) Returns $null if not found.
# ---------------------------------------------
function Get-RomsEnginePath {
    # 1. Deterministic Standard Root
    if (Test-Path $global:ROMs_ENGINE_ENTRY) {
        return $global:ROMs_ENGINE_ENTRY
    }

    # 2. Workspace Detection (Internal/Dev only - strictly if .git exists)
    $repoRoot = (Split-Path (Split-Path $PSScriptRoot))
    $devPath = Join-Path $repoRoot "package_installer\rmspkg.ps1"
    if ((Test-Path (Join-Path $repoRoot ".git")) -and (Test-Path $devPath)) {
        return $devPath
    }

    return $null
}

# ---------------------------------------------
# SELF-HEALING BOOTSTRAP (Hybrid Recovery)
# Attempts to restore a missing or corrupted standalone engine via a 4-phase approach:
# Phase A: Downloads from official registry (Update-Registry + Get-RomsRegistryPackage).
# Phase B: Falls back to GitHub Recovery API if registry fails.
# Phase C: Extracts .rms archive to $ROMs_ENGINE_DIR using native .NET ZipFile.
# Phase D: Calls engine's bootstrap command to register shims and metadata.
# Throws if all sources exhausted.
# ---------------------------------------------
function Initialize-RomsEngine {
    $path = Get-RomsEnginePath
    if ($path) {
        Write-Log "Standalone Engine integrity failure detected. Initiating automated repair..." "WARN"
    } else {
        Write-Log "Standalone Engine missing. Initiating self-healing bootstrap..." "WARN"
    }

    $stagedEngine = Join-Path $global:ROMs_TEMP "rmspkg_bootstrap.rms"
    if (-not (Test-Path $global:ROMs_TEMP)) { New-Item -ItemType Directory -Path $global:ROMs_TEMP -Force | Out-Null }

    # 1. PHASE A: Registry Search
    $success = $false
    try {
        Update-Registry
        $pkg = Get-RomsRegistryPackage -Name "rmspkg"
        if ($pkg) {
            $url = Get-RomsResolvedUrl -Template $pkg.downloadUrl -Package $pkg
            Write-Log "Downloading engine from registry: $url" "INFO"
            Invoke-RestMethod -Uri $url -OutFile $stagedEngine
            if (Test-Path $stagedEngine) {
                Write-Log "Standalone Engine artifact staged: $(Split-Path $stagedEngine -Leaf)" "TRACE"
                Write-Log "[SUCCESS] Standalone Engine sourced from official cloud registry." "SUCCESS"
                $success = $true
            }
        }
    } catch {
        Write-Log "Registry bootstrap failed: $($_.Exception.Message)" "WARN"
    }

    # 2. PHASE B: Emergency Recovery (Dynamic GitHub API Discovery)
    if (-not $success) {
        Write-Log "Registry unavailable. Falling back to Dynamic GitHub Recovery..." "WARN"
        try {
            $release = Invoke-RestMethod -Uri $global:ROMs_RECOVERY
            $sysArch = $global:ROMs_ARCH.ToLower()
            
            # Find asset matching architecture (e.g. rmspkg-x64*.rms)
            $asset = $release.assets | Where-Object { $_.name -like "rmspkg-$sysArch*.rms" } | Select-Object -First 1
            if (-not $asset) {
                # Fallback to generic if architecture-specific not found
                $asset = $release.assets | Where-Object { $_.name -like "rmspkg*.rms" } | Select-Object -First 1
            }

            if ($asset) {
                Write-Log "Found recovery asset: $($asset.name)" "INFO"
                Invoke-RestMethod -Uri $asset.browser_download_url -OutFile $stagedEngine
                if (Test-Path $stagedEngine) {
                    Write-Log "Standalone Engine artifact staged: $(Split-Path $stagedEngine -Leaf)" "TRACE"
                    Write-Log "[SUCCESS] Standalone Engine sourced from GitHub Recovery API." "SUCCESS"
                    $success = $true
                }
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
        if (-not (Test-Path $global:ROMs_ENGINE_DIR)) { New-Item -ItemType Directory -Path $global:ROMs_ENGINE_DIR -Force | Out-Null }
        
        #  Use native .NET ZipFile
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($stagedEngine)
        
        foreach ($entry in $zip.Entries) {
            $destPath = Join-Path $global:ROMs_ENGINE_DIR $entry.FullName
            if ($entry.FullName.EndsWith("/")) {
                if (-not (Test-Path $destPath)) { New-Item -ItemType Directory -Path $destPath -Force | Out-Null }
            } else {
                $parentDir = Split-Path $destPath
                if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
                if (Test-Path $destPath) {
                    Write-Log "Extracted file: $($entry.FullName)" "TRACE"
                }
            }
        }
        $zip.Dispose()
        Remove-Item $stagedEngine -Force

        # 4. PHASE D: Handshake (Engine-Owned Registration)
        Write-Log "Activating engine shims and metadata..." "INFO"
        & $global:ROMs_ENGINE_ENTRY bootstrap

        Write-Log "Standalone Engine successfully initialized." "SUCCESS"
    } catch {
        if ($zip) { $zip.Dispose() }
        throw "Bootstrap extraction failed: $($_.Exception.Message)"
    }
}

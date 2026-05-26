# bootstrap.ps1 - Standalone Engine Discovery and Self-Healing logic

# ---------------------------------------------
# ENGINE INTEGRITY (Self-Healing Watchdog)
# ---------------------------------------------
function Test-RomsEngineIntegrity {
    $enginePath = Get-RomsEnginePath
    if (-not $enginePath) { return $false }

    # Workspace/Dev detection (Skip strict manifest check if in a Git repo)
    if ($enginePath -match "package_installer\\rmspkg.ps1") {
        Write-Log "Development Workspace detected. Skipping strict manifest check." "DEBUG"
        return $true
    }

    try {
        # 1. Metadata Verification (Source of Truth)
        $metadataPath = Join-Path $global:METADATA_DIR "rmspkg.json"
        if (-not (Test-Path $metadataPath)) {
            Write-Log "Standalone Engine metadata is missing. Integrity compromised." "WARN"
            return $false
        }

        # 2. Manifest Verification (Recursive File Check)
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $engineRoot = $global:ENGINE_DIR
        
        foreach ($fileRelPath in $metadata.files) {
            $fileAbsPath = Join-Path $engineRoot $fileRelPath
            if (-not (Test-Path $fileAbsPath)) {
                Write-Log "Standalone Engine integrity failure: Missing file [$fileRelPath]" "WARN"
                return $false
            }
        }

        # 3. Header Signature Check (Main Entry Point)
        $header = Get-Content $enginePath -TotalCount 1 -ErrorAction Stop
        if ($header -notlike "# rmspkg.ps1 - The ROMs-util Standalone Engine*") {
            Write-Log "Standalone Engine binary has an invalid header signature." "WARN"
            return $false
        }

        return $true
    } catch {
        Write-Log "Integrity check error: $($_.Exception.Message)" "DEBUG"
        return $false
    }
}

# ---------------------------------------------
# ENGINE DISCOVERY (Industrial Strength)
# ---------------------------------------------
function Get-RomsEnginePath {
    # 1. Deterministic Standard Root
    if (Test-Path $global:ENGINE_SCRIPT) {
        return $global:ENGINE_SCRIPT
    }

    # 2. Workspace Detection (Internal/Dev only - strictly if .git exists)
    $devPath = Join-Path (Split-Path (Split-Path $PSScriptRoot)) "package_installer\rmspkg.ps1"
    if ((Test-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot)) ".git")) -and (Test-Path $devPath)) {
        return $devPath
    }

    return $null
}

# ---------------------------------------------
# SELF-HEALING BOOTSTRAP (Hybrid Recovery)
# ---------------------------------------------
function Initialize-RomsEngine {
    $path = Get-RomsEnginePath
    if ($path) {
        Write-Log "Standalone Engine integrity failure detected. Initiating automated repair..." "WARN"
    } else {
        Write-Log "Standalone Engine missing. Initiating self-healing bootstrap..." "WARN"
    }

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
            Write-Log "[SUCCESS] Standalone Engine sourced from official cloud registry." "SUCCESS"
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
                Write-Log "[SUCCESS] Standalone Engine sourced from GitHub Recovery API." "SUCCESS"
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

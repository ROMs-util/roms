# roms.ps1 - The ROMs-util Package Manager (Router)
# Usage: roms <command> [args]

# ---------------------------------------------
# BOOTSTRAP LIBRARY 
# ---------------------------------------------
$global:EntryScriptPath = $PSCommandPath
$libPath = Join-Path $PSScriptRoot "lib"
if (-not (Test-Path $libPath)) {
    Write-Error "[FATAL] Library folder not found at $libPath"
    exit 1
}

# Load Modules in safe Foundation-First order (Modularity Standard)
. (Join-Path $libPath "core.ps1")         # Foundations
. (Join-Path $libPath "util.ps1")         # Primitives
. (Join-Path $libPath "semver.ps1")       # SemVer 2.0 Engine
. (Join-Path $libPath "bootstrap.ps1")    # Engine Discovery & Self-Healing
. (Join-Path $libPath "executor.ps1")     # Command Execution (rmspkg)
. (Join-Path $libPath "help.ps1")         # UI
. (Join-Path $libPath "sync.ps1")         # Registry
. (Join-Path $libPath "discovery.ps1")    # Search
. (Join-Path $libPath "resolver.ps1")     # Dependencies
. (Join-Path $libPath "alternatives.ps1") # Environment
. (Join-Path $libPath "orchestrator.ps1") # Orchestration (Loaded last)

# ---------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------
$global:OriginalArgs = @($args)
$command = $args[0]
$subArgs = @($args | Select-Object -Skip 1)

# Handle global flags
$global:AutoConfirm = ($args -contains "-y") -or ($args -contains "--yes")

# Multi-Level Verbosity Parsing
$global:VerboseLevel = 0
if ($args -contains "-vvv") { $global:VerboseLevel = 3 }
elseif ($args -contains "-vv") { $global:VerboseLevel = 2 }
elseif ($args -contains "-v" -or ($args -contains "--verbose")) { $global:VerboseLevel = 1 }

# Legacy flag compatibility
$global:Verbose = ($global:VerboseLevel -gt 0)

# ---------------------------------------------
# IDENTITY DISCOVERY (RAW Telemetry)
# ---------------------------------------------
if ($args) { Write-Log "Raw Args: $($args -join ' ')" "RAW" }

# ---------------------------------------------
# COMMAND NORMALIZATION (Modern Standard)
# ---------------------------------------------
# Default to help if nothing provided or help requested
if (-not $command -or $command -eq "help") {
    Show-Help
    exit 0
}

# ---------------------------------------------
# ENGINE INITIALIZATION (Self-Healing)
# ---------------------------------------------
if (-not (Test-RomsEngineIntegrity)) {
    Initialize-RomsEngine
    if (-not (Test-RomsEngineIntegrity)) {
        Write-Error "[FATAL] Standalone Engine could not be initialized or is corrupted."
        exit 1
    }
}
$global:ResolvedEnginePath = Get-RomsEnginePath

# ---------------------------------------------
# COMMAND ROUTING
# ---------------------------------------------
# Resolve local paths early to handle elevation/context changes
if ($command -eq "install" -and $subArgs[0]) {
    # --- CMD COMPATIBILITY GUARDRAIL (REMOVABLE IF RUNNING NATIVE PS1) ---
    # Detect if CMD mangled the command by interpreting '>' as redirection
    # When redirected, CMD strips everything from '>' onwards, leaving only the colon.
    if ($subArgs[0].EndsWith(":")) {
        $pkgName = $subArgs[0].TrimEnd(':')
        
        # : Write to Stderr so the message is visible even if Stdout is redirected to a file
        [Console]::Error.WriteLine("[ERROR] Detected mangled version constraint for '$pkgName'.")
        [Console]::Error.WriteLine("[WARN] CMD likely intercepted a redirection character (>, <). Wrap constraints in quotes: roms install `"${pkgName}:>=1.0.0`"")
        
        # Find potential redirection file (0-byte, created in last 5 seconds)
        $potentialFile = Get-ChildItem -File | 
            Where-Object { $_.Length -eq 0 -and $_.LastWriteTime -gt (Get-Date).AddSeconds(-5) } | 
            Sort-Object LastWriteTime -Descending | 
            Select-Object -First 1

        if ($null -ne $potentialFile) {
            [Console]::Error.Write("[WARN] Accidental redirection created file: '$($potentialFile.Name)'. Delete it? [Y/n]: ")
            $choice = [Console]::In.ReadLine()
            if ($choice -match '^[Yy]') {
                # Launch decoupled background cleanup (CMD holds a lock until this process exits)
                $cleanupCmd = "Start-Sleep -s 1; if (Test-Path '$($potentialFile.FullName)') { Remove-Item '$($potentialFile.FullName)' -Force }"
                Start-Process powershell -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -Command `"$cleanupCmd`""
                [Console]::Error.WriteLine("[INFO] Background cleanup scheduled for '$($potentialFile.Name)'.")
            }
        }
        
        exit 1
    }
    # --- END CMD COMPATIBILITY GUARDRAIL ---

    if (Test-Path $subArgs[0] -PathType Leaf) {
        $absolutePath = (Resolve-Path $subArgs[0]).Path
        $subArgs[0] = $absolutePath
        # Update OriginalArgs so the relaunch uses the absolute path
        $global:OriginalArgs = @($command) + $subArgs
    }
}

# Start Transaction for modifying commands
if ($command -in @("select")) {
    Confirm-RomsElevation | Out-Null
    Enter-RomsTransaction
}

try {
    switch ($command) {
        "list"      { List-Packages }
        "update"    { Update-Registry }
        "search"    { Search-Packages -Query $subArgs[0] }
        "select"    { Select-RomsAlternative -CommandName $subArgs[0] -Selection $subArgs[1] }
        "install"   { 
            if (-not $subArgs[0]) { Write-Log "Package name or .rms path required." "ERROR"; break }
            Invoke-RomsInstall -Identifier $subArgs[0] 
        }
        "uninstall" { 
            if (-not $subArgs[0]) { Write-Log "Package name required." "ERROR"; break }
            foreach ($pkgName in $subArgs) {
                # Skip flags like -y or -v
                if ($pkgName.StartsWith("-")) { continue }
                Invoke-RomsUninstall -Name $pkgName
            }
        }
        Default     { 
            Write-Log "Unknown command: $command" "ERROR"
            Show-Help 
        }
    }
} finally {
    Exit-RomsTransaction
}

# roms.ps1 - The ROMs-util Package Manager (Router)
# Usage: roms <command> [args]

# ---------------------------------------------
# BOOTSTRAP LIBRARY (Industrial Strength)
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
$global:OriginalArgs = $args
$command = $args[0]
$subArgs = @($args | Select-Object -Skip 1)

# Handle global flags
$global:AutoConfirm = ($args -contains "-y") -or ($args -contains "--yes")
$global:Verbose     = ($args -contains "-v") -or ($args -contains "--verbose")

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
        
        # Industrial Strength: Write to Stderr so the message is visible even if Stdout is redirected to a file
        [Console]::Error.WriteLine("[ERROR] Detected mangled version constraint for '$pkgName'.")
        [Console]::Error.WriteLine("[WARN] CMD likely intercepted a redirection character (>, <). Wrap constraints in quotes: roms install `"${pkgName}:>=1.0.0`"")
        
        # Note: We cannot delete the redirection file here because CMD holds a lock on it until this process exits.
        # However, the user is now clearly informed of the error.
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
if ($command -in @("install", "uninstall", "upgrade", "verify", "select")) {
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

# roms.ps1 - The ROMs-util Package Manager (Router)
# Usage: roms <command> [args]

# ---------------------------------------------
# BOOTSTRAP LIBRARY (Industrial Strength)
# ---------------------------------------------
$global:EntryScriptPath = $MyInvocation.MyCommand.Definition
$libPath = Join-Path $PSScriptRoot "lib"
if (-not (Test-Path $libPath)) {
    Write-Error "[FATAL] Library folder not found at $libPath"
    exit 1
}

# Load Modules in safe Foundation-First order
. (Join-Path $libPath "core.ps1")         # Foundations
. (Join-Path $libPath "util.ps1")         # Primitives
. (Join-Path $libPath "help.ps1")         # UI
. (Join-Path $libPath "sync.ps1")         # Registry
. (Join-Path $libPath "discovery.ps1")    # Search
. (Join-Path $libPath "alternatives.ps1") # Environment
. (Join-Path $libPath "orchestrator.ps1") # Brain (Loaded last)

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
# COMMAND ROUTING
# ---------------------------------------------
# Resolve local paths early to handle elevation/context changes
if ($command -eq "install" -and $subArgs[0] -and (Test-Path $subArgs[0] -PathType Leaf)) {
    $absolutePath = (Resolve-Path $subArgs[0]).Path
    $subArgs[0] = $absolutePath
    # Update OriginalArgs so the relaunch uses the absolute path
    $global:OriginalArgs = @($command) + $subArgs
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
            Invoke-RomsUninstall -Name $subArgs[0] 
        }
        Default     { 
            Write-Log "Unknown command: $command" "ERROR"
            Show-Help 
        }
    }
} finally {
    Exit-RomsTransaction
}

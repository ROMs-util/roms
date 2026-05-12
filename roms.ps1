# roms.ps1 - The ROMs-util Package Manager (Router)
# Usage: roms <command> [args]

# ---------------------------------------------
# BOOTSTRAP LIBRARY
# ---------------------------------------------
$libPath = Join-Path $PSScriptRoot "lib"
if (-not (Test-Path $libPath)) {
    Write-Error "[FATAL] Library folder not found at $libPath"
    exit 1
}

. (Join-Path $libPath "core.ps1")
. (Join-Path $libPath "help.ps1")
. (Join-Path $libPath "logic.ps1")

# ---------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------
$command = $args[0]
$subArgs = [array]($args | Select-Object -Skip 1)

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
# Start Transaction for modifying commands
if ($command -in @("install", "uninstall", "update", "upgrade", "verify")) {
    Enter-RomsTransaction
}

try {
    switch ($command) {
        "list"      { List-Packages }
        "update"    { Update-Registry }
        "search"    { Search-Packages -Query $subArgs[0] }
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


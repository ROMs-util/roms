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
. (Join-Path $libPath "core.ps1")         ; Write-Log "Sourced core.ps1" "TRACE"
. (Join-Path $libPath "util.ps1")         ; Write-Log "Sourced util.ps1" "TRACE"
. (Join-Path $libPath "semver.ps1")       ; Write-Log "Sourced semver.ps1" "TRACE"
. (Join-Path $libPath "bootstrap.ps1")    ; Write-Log "Sourced bootstrap.ps1" "TRACE"
. (Join-Path $libPath "executor.ps1")     ; Write-Log "Sourced executor.ps1" "TRACE"
. (Join-Path $libPath "help.ps1")         ; Write-Log "Sourced help.ps1" "TRACE"
. (Join-Path $libPath "source.ps1")       ; Write-Log "Sourced source.ps1" "TRACE"
. (Join-Path $libPath "sync.ps1")         ; Write-Log "Sourced sync.ps1" "TRACE"
. (Join-Path $libPath "discovery.ps1")    ; Write-Log "Sourced discovery.ps1" "TRACE"
. (Join-Path $libPath "resolver.ps1")     ; Write-Log "Sourced resolver.ps1" "TRACE"
. (Join-Path $libPath "alternatives.ps1") ; Write-Log "Sourced alternatives.ps1" "TRACE"
. (Join-Path $libPath "orchestrator.ps1") ; Write-Log "Sourced orchestrator.ps1" "TRACE"

# ---------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------
# USER-RECOMMENDED TUNNEL BRIDGE: Capture raw input via environment variable.
$global:ROMs_Args = Get-RomsRawArguments -FallbackArgs @($args)
$command = $global:ROMs_Args[0]
$subArgs = @($global:ROMs_Args | Select-Object -Skip 1)

# Handle global flags
$global:AutoConfirm = ($global:ROMs_Args -contains "-y") -or ($global:ROMs_Args -contains "--yes")
$global:VerboseLevel = 0
if ($global:ROMs_Args -contains "-vvv") { $global:VerboseLevel = 3 }
elseif ($global:ROMs_Args -contains "-vv") { $global:VerboseLevel = 2 }
elseif ($global:ROMs_Args -contains "-v" -or ($global:ROMs_Args -contains "--verbose")) { $global:VerboseLevel = 1 }

# Legacy flag compatibility
$global:Verbose = ($global:VerboseLevel -gt 0)

# Raw Telemetry
if ($global:ROMs_Args) { Write-Log "Raw Args: $($global:ROMs_Args -join ' ')" "RAW" }

# ---------------------------------------------
# COMMAND ROUTING & MIRRORING (Log Restoration)
# ---------------------------------------------
if ($command -eq "install") {
    # --- INDUSTRIAL GHOST RECONSTRUCTOR (MIRROR PIPE) ---
    # Detect if CMD mangled output into a file. If so, we enable MIRRORING
    # to show all logs in the CURRENT terminal bypassing the redirection.
    for ($i = 0; $i -lt $subArgs.Count; $i++) {
        if ($subArgs[$i].EndsWith(":") -and -not $subArgs[$i].StartsWith("-")) {
            $pkgName = $subArgs[$i].TrimEnd(':')
            $potentialFile = Get-ChildItem -File | 
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-20) } | 
                Sort-Object LastWriteTime -Descending | Select-Object -First 1

            if ($null -ne $potentialFile) {
                # 1. Recover coordinate from trash file
                $verPart = ($potentialFile.Name -split " ")[0]
                $op = ">"; if ($verPart.StartsWith("=")) { $op = ">="; $verPart = $verPart.Substring(1) }
                $subArgs[$i] = "${pkgName}:${op}${verPart}"
                
                # 2. Enable Mirroring: Write-Log will now use Console.Error for all output.
                $global:Roms_RedirectionActive = $true
                Write-Log "Redirection Detected. Mirroring logs to terminal for $pkgName..." "SUCCESS"

                # SCHEDULE AGGRESSIVE CLEANUP: Wait for current PID and its children to exit.
                $cleanupPath = $potentialFile.FullName
                $cleanupScript = "while (Get-Process -Id $PID -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 500 }; if (Test-Path '$cleanupPath') { Remove-Item '$cleanupPath' -Force }"
                Start-Process powershell -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass", "-Command", $cleanupScript
            }
        }
    }
    # Update globals with reconstructed values
    $global:ROMs_Args = @($command) + $subArgs

    if ($subArgs[0] -and (Test-Path $subArgs[0] -PathType Leaf)) {
        $subArgs[0] = (Resolve-Path $subArgs[0]).Path
        $global:ROMs_Args = @($command) + $subArgs
    }
}

# ---------------------------------------------
# COMMAND NORMALIZATION
# ---------------------------------------------
if (-not $command -or $command -eq "help") { Show-Help; exit 0 }

# ---------------------------------------------
# ENGINE INITIALIZATION
# ---------------------------------------------
if (-not (Test-RomsEngineIntegrity)) {
    Initialize-RomsEngine
    if (-not (Test-RomsEngineIntegrity)) {
        Write-Error "[FATAL] Standalone Engine could not be initialized or is corrupted."
        exit 1
    }
}
$global:ResolvedEnginePath = Get-RomsEnginePath

# Start Transaction for modifying commands
if ($command -in @("select", "source", "install", "uninstall", "update")) {
    $needsWrite = $false
    if ($command -eq "source" -and $subArgs[0] -in @("on", "off")) { $needsWrite = $true }
    elseif ($command -in @("select")) { $needsWrite = $true }

    if ($needsWrite) {
        Confirm-RomsElevation | Out-Null
        Enter-RomsTransaction
    }
}

try {
    switch ($command) {
        "list"      { List-Packages }
        "update"    { Update-Registry }
        "source"    { Invoke-RomsSourceCommand -SubCommand $subArgs[0] -RemainingArgs @($subArgs | Select-Object -Skip 1) }
        "search"    { Search-Packages -Query $subArgs[0] }
        "select"    { Select-RomsAlternative -CommandName $subArgs[0] -Selection $subArgs[1] }
        "install"   { 
            if (-not $subArgs[0]) { Write-Log "Package name or .rms path required." "ERROR"; break }
            foreach ($identifier in $subArgs) {
                if ($identifier.StartsWith("-")) { continue }
                Invoke-RomsInstall -Identifier $identifier
            }
        }
        "uninstall" { 
            if (-not $subArgs[0]) { Write-Log "Package name required." "ERROR"; break }
            foreach ($pkgName in $subArgs) {
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

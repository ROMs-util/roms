# executor.ps1 - Command Execution and Session Path Synchronization

# ---------------------------------------------
# COMMAND EXECUTION (Phase 2 - Professionalism)
# Forwards commands to the standalone engine (rmspkg) via session PATH or absolute path.
# Auto-adds ROMs bin to PATH if engine not found, then falls back to $ResolvedEnginePath.
# Passes through verbosity flags (-v, -vv, -vvv) to the engine.
# Uses Start-Process to preserve engine's native Write-Host colors and spacing.
# Returns exit code from the engine process.
# ---------------------------------------------
function Invoke-EngineCommand {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$Target,
        [switch]$Yes,
        [switch]$ShowVerbose,
        [switch]$NoShim
    )

    # 1. Resolve Engine Entry Point
    # Mandate: Use direct .ps1 execution via powershell.exe to bypass shell-association issues.
    $engineEntry = $global:ResolvedEnginePath
    if (-not (Test-Path $engineEntry)) {
        throw "Standalone Engine entry point not found at '$engineEntry'."
    }

    # 2. Build Arguments (Design Standard: Flag Pattern)
    # Use explicit powershell array for -ArgumentList to preserve symbols.
    [array]$finalArgs = @("-ExecutionPolicy", "Bypass", "-File", $engineEntry, $Command)
    if ($Target)      { $finalArgs += $Target }
    if ($Yes)         { $finalArgs += "--yes" }
    if ($NoShim)      { $finalArgs += "--no-shim" }
    if ($global:Roms_MirrorLogs) { $finalArgs += "--mirror" }

    # Forward Diagnostic Verbosity ( Propagation)
    if ($global:VerboseLevel -eq 3) { $finalArgs += "-vvv" }
    elseif ($global:VerboseLevel -eq 2) { $finalArgs += "-vv" }
    elseif ($global:VerboseLevel -eq 1 -or $ShowVerbose) { $finalArgs += "-v" }

    # 3. Simple & Clean Execution (Restores Native Colors and Spacing)
    Write-Log "Executing engine: powershell.exe $($finalArgs -join ' ')" "TRACE"
    
    # Use powershell.exe explicitly to ensure the script runs correctly.
    $proc = Start-Process powershell.exe -ArgumentList $finalArgs -Wait -NoNewWindow -PassThru
    
    # Standard Handshake verification
    if ($proc.ExitCode -ne 0) {
        throw "Standalone Engine reported failure (Exit Code: $($proc.ExitCode))."
    }
    Write-Log "Engine command completed successfully (Exit Code: 0)" "TRACE"

    # We return NOTHING to the pipeline to prevent the '0' leak
    return
}


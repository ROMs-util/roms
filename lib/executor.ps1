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

    # 1. Resolve Priority (Command -> Session PATH -> Absolute)
    $executable = "rmspkg"
    
    # 2. Logic Bug Fix: Session Refresh
    # If not in path, try to add ROMs bin dir to the CURRENT session
    if (-not (Get-Command $executable -ErrorAction SilentlyContinue)) {
        $binDir = $global:ROMs_BIN
        if (Test-Path $binDir) {
            $env:PATH = "$binDir;$env:PATH"
        }
    }

    # 3. Fallback to Absolute if still missing
    if (-not (Get-Command $executable -ErrorAction SilentlyContinue)) {
        $executable = $global:ResolvedEnginePath
    }

    # 4. Build Arguments (Design Standard: Flag Pattern)
    [array]$finalArgs = @($Command)
    if ($Target)      { $finalArgs += $Target }
    if ($Yes)         { $finalArgs += "--yes" }
    if ($NoShim)      { $finalArgs += "--no-shim" }

    # Forward Diagnostic Verbosity ( Propagation)
    # Mandate: Never cap verbosity. Ensure -vvv and -vv reach the engine.
    if ($global:VerboseLevel -eq 3) { $finalArgs += "-vvv" }
    elseif ($global:VerboseLevel -eq 2) { $finalArgs += "-vv" }
    elseif ($global:VerboseLevel -eq 1 -or $ShowVerbose) { $finalArgs += "-v" }
    # 5. Simple & Clean Execution (Restores Native Colors and Spacing)
    Write-Log "Executing engine command: $executable $($finalArgs -join ' ')" "TRACE"
    
    # We execute directly WITHOUT pipeline capture.
    # This restores the Engine's native Write-Host colors and professional boxes.
    # Data is exchanged via the dedicated 'handshake.json' file instead of the pipeline.
    & $executable $finalArgs
    
    # Standard Handshake verification
    if ($LASTEXITCODE -ne 0) {
        throw "Standalone Engine reported failure (Exit Code: $LASTEXITCODE)."
    }
    Write-Log "Engine command completed successfully (Exit Code: 0)" "TRACE"

    # We return NOTHING to the pipeline to prevent the '0' leak
    return
}


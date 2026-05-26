# executor.ps1 - Command Execution and Session Path Synchronization

# ---------------------------------------------
# COMMAND EXECUTION (Phase 2 - Professionalism)
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
        $binDir = "C:\roms\bin"
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
    if ($ShowVerbose) { $finalArgs += "--verbose" }
    if ($NoShim)      { $finalArgs += "--no-shim" }

    # 5. Industrial Strength Execution (Separate Process)
    # Use powershell.exe wrapper to ensure Bypass and NoProfile are enforced
    $powershellCommand = "& '$executable' $($finalArgs -join ' ')"
    $proc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$powershellCommand`"" -PassThru -Wait -NoNewWindow
    
    # Standard Handshake verification
    if ($proc.ExitCode -ne 0) {
        throw "Standalone Engine reported failure (Exit Code: $($proc.ExitCode))."
    }

    return $proc.ExitCode
}

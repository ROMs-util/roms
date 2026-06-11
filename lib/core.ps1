# core.ps1 - Global Constants, Logging, and Transaction Safety

# ---------------------------------------------
# GLOBAL CONSTANTS (Industrial Purity)
# ---------------------------------------------
$global:ROMs_ROOT       = "C:\roms"
$global:ROMs_BIN        = "$global:ROMs_ROOT\bin"
$global:ROMs_METADATA   = "$global:ROMs_ROOT\.metadata"
$global:ROMs_CACHE      = "$global:ROMs_ROOT\cache"
$global:ROMs_LOGS       = "$global:ROMs_ROOT\logs"
$global:ROMs_MASTER_LOG = "$global:ROMs_LOGS\roms.log"

$global:ROMs_SOURCES    = "$global:ROMs_ROOT\sources.json"
$global:ROMs_ALTS       = "$global:ROMs_ROOT\alternatives.json"
$global:ROMs_OFFICIAL   = "https://raw.githubusercontent.com/ROMs-util/rms-atlas/main/index.json"

# Channel Awareness Globals 
$global:ROMs_CHANNEL         = "mainnet"

# Standalone Engine Constants
$global:ROMs_ENGINE_DIR = "$global:ROMs_ROOT\rmspkg"
$global:ROMs_ENGINE_ENTRY = "$global:ROMs_ENGINE_DIR\rmspkg.ps1"
$global:ROMs_RECOVERY   = "https://api.github.com/repos/ROMs-util/rmspkg/releases/latest"

$global:ROMs_TEMP       = "$global:ROMs_ROOT\temp"
$global:ROMs_LOCK       = "$global:ROMs_TEMP\roms.lock"

#  Multi-Version Architecture Detection
$global:ROMs_ARCH = if ($PSVersionTable.PSVersion.Major -ge 6) {
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
} else {
    $env:PROCESSOR_ARCHITECTURE
}

# ---------------------------------------------
# LOGGING SYSTEM
# Writes timestamped log entries to console (color-coded) and master log file.
# Uses global $VerboseLevel: 0=INFO/WARN/ERROR/SUCCESS, 1=+DEBUG, 2=+TRACE, 3=+RAW
# Detects JSON in message and pretty-prints it for human readability.
# Retries file write up to 5 times on lock contention.
# ---------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG", "TRACE", "RAW")][string]$Level = "INFO",
        [string]$Source = "Manager"
    )

    # Initialize global verbosity if not set
    if ($null -eq $global:VerboseLevel) { $global:VerboseLevel = 0 }

    if (-not (Test-Path $global:ROMs_LOGS)) {
        New-Item -ItemType Directory -Path $global:ROMs_LOGS -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # 1. INDUSTRIAL DATA PREPARATION (Extract JSON once)
    $isJson = ($Message -match "^\s*\{" -or $Message -match "^\s*\[" -or $Message -match ":\s*\{" -or $Message -match ":\s*\[")
    $prefix = ""
    $jsonObj = $null
    
    if ($isJson) {
        try {
            # Extraction logic (Non-greedy prefix capture)
            if ($Message -match "(?s)(.*?):\s*([\{\[].*)") {
                $prefix = $matches[1].Trim()
                $jsonObj = $matches[2].Trim() | ConvertFrom-Json
            } else {
                $jsonObj = $Message | ConvertFrom-Json
            }
        } catch { 
            $isJson = $false # False positive or corrupt JSON
        }
    }

    # 2. FILE LOGGING (Tight Inline: One Line, One Event)
    $fileContent = if ($isJson) {
        $compactJson = $jsonObj | ConvertTo-Json -Depth 10 -Compress
        if ($prefix) { "${prefix}: $compactJson" } else { $compactJson }
    } else {
        # Flatten multi-line strings for log consistency
        ($Message -split "\r?\n" | ForEach-Object { $_.Trim() }) -join " "
    }

    # Log to BOTH the master log and the task-specific log if available
    $logFileLine = "[$timestamp] [$Level] [$Source] $fileContent"
    $targetLogs = @($global:ROMs_MASTER_LOG)
    if ($script:logFile) { $targetLogs += $script:logFile }

    foreach ($logPath in $targetLogs) {
        $retryCount = 0
        $success = $false
        while (-not $success -and $retryCount -lt 5) {
            try {
                $logFileLine | Out-File -FilePath $logPath -Append -Encoding utf8 -ErrorAction Stop
                $success = $true
            } catch {
                $retryCount++
                Start-Sleep -Milliseconds 50
            }
        }
    }

    # 3. CONSOLE OUTPUT (Pretty-RAW for Humans)
    $shouldDisplay = $true
    if ($Level -eq "DEBUG" -and $global:VerboseLevel -lt 1) { $shouldDisplay = $false }
    elseif ($Level -eq "TRACE" -and $global:VerboseLevel -lt 2) { $shouldDisplay = $false }
    elseif ($Level -eq "RAW"   -and $global:VerboseLevel -lt 3) { $shouldDisplay = $false }

    if ($shouldDisplay) {
        $consoleContent = if ($isJson) {
            $prettyJson = $jsonObj | ConvertTo-Json -Depth 10
            if ($prefix) { "${prefix}:`n$prettyJson" } else { $prettyJson }
        } else {
            $Message
        }

        # DESIGN STANDARD: No timestamps at Level 0
        $consoleLine = if ($global:VerboseLevel -ge 1) { "[$timestamp] [$Level] [$Source] $consoleContent" } else { "[$Level] [$Source] $consoleContent" }
        
        $color = switch ($Level) {
            "ERROR"   { "Red" }
            "WARN"    { "Yellow" }
            "SUCCESS" { "Green" }
            "DEBUG"   { "Gray" }
            "TRACE"   { "Cyan" }
            "RAW"     { "Magenta" }
            Default   { "White" }
        }

        # MIRROR PIPE: If redirection is active, standard Write-Host is hidden in the trash file.
        # We mirror to Console.Error with ANSI colors to force visibility in the current terminal.
        if ($global:Roms_RedirectionActive) {
            # ANSI Escape Codes for high-fidelity terminal coloring
            $ansiColor = switch ($Level) {
                "ERROR"   { "$([char]27)[31m" } # Red
                "WARN"    { "$([char]27)[33m" } # Yellow
                "SUCCESS" { "$([char]27)[32m" } # Green
                "DEBUG"   { "$([char]27)[90m" } # Gray
                "TRACE"   { "$([char]27)[36m" } # Cyan
                "RAW"     { "$([char]27)[35m" } # Magenta
                Default   { "$([char]27)[0m"  } # Reset
            }
            $reset = "$([char]27)[0m"
            
            # Bypasses redirection handle with full color support
            [Console]::Error.WriteLine("${ansiColor}${consoleLine}${reset}")
        } else {
            Write-Host $consoleLine -ForegroundColor $color
        }
    }
}

# ---------------------------------------------
# TRANSACTION SAFETY (The Lock System)
# Prevents concurrent ROMs operations by writing the process ID to a lock file.
# Implements re-entrant safety and process-exclusive cleanup.
# ---------------------------------------------
$script:RomsLockAcquired = $false

# ---------------------------------------------
# ENTER TRANSACTION
# Acquires an exclusive lock for the current process.
#
# HOW IT WORKS:
# 1. Checks if a lock file exists.
# 2. If existing lock belongs to the current PID, allows re-entry (bypass).
# 3. If lock belongs to another active process, aborts with 'System Busy'.
# 4. If lock is stale (PID dead), auto-cleans and proceeds.
# 5. Writes a new JSON lock file with current PID and timestamp.
# ---------------------------------------------
function Enter-RomsTransaction {
    if (-not (Test-Path $global:ROMs_TEMP)) {
        New-Item -ItemType Directory -Path $global:ROMs_TEMP -Force | Out-Null
    }

    if (Test-Path $global:ROMs_LOCK) {
        try {
            $lockInfo = Get-Content $global:ROMs_LOCK | ConvertFrom-Json
            $procId = $lockInfo.pid
            
            # FIX: If the lock belongs to US, we already have it (Re-entrant safety)
            if ($procId -eq $PID) {
                $script:RomsLockAcquired = $true
                return 
            }
            
            if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
                Write-Log "System Busy: Another ROMs operation is running (PID: $procId)." "ERROR"
                exit 1
            } else {
                Write-Log "Stale lock found from PID $procId. Cleaning up..." "WARN"
                Remove-Item $global:ROMs_LOCK -Force
            }
        } catch {
            Remove-Item $global:ROMs_LOCK -Force
        }
    }

    $lockData = @{ pid = $PID; startTime = (Get-Date -Format "o") }
    $lockData | ConvertTo-Json | Out-File -FilePath $global:ROMs_LOCK -Encoding utf8
    $script:RomsLockAcquired = $true
}

# ---------------------------------------------
# EXIT TRANSACTION
# Releases the exclusive lock held by the current process.
#
# HOW IT WORKS:
# 1. Verifies that the current script instance actually acquired the lock.
# 2. Verifies that the lock file on disk still belongs to the current PID.
# 3. Deletes the lock file to allow other operations to proceed.
# ---------------------------------------------
function Exit-RomsTransaction {
    if ($script:RomsLockAcquired -and (Test-Path $global:ROMs_LOCK)) {
        try {
            $lockInfo = Get-Content $global:ROMs_LOCK | ConvertFrom-Json
            if ($lockInfo.pid -eq $PID) {
                Remove-Item $global:ROMs_LOCK -Force
            }
        } catch {
            # Fallback if file is corrupted
            Remove-Item $global:ROMs_LOCK -Force
        }
        $script:RomsLockAcquired = $false
    }
}

# ---------------------------------------------
# ELEVATION UTILITY (Manager Level)
# Checks if running as Administrator. If not, re-launches the script
# with elevation (RunAs), preserving all original args and verbosity flags.
# ---------------------------------------------
function Confirm-RomsElevation {
    $currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Elevation required for system modification. Requesting Administrator privileges..." "INFO"
        
        $scriptPath = $global:EntryScriptPath
        
        # PREVENTION-FIRST BRIDGE: Pass arguments via Base64 JSON
        # This makes it physically impossible for the shell to interpret '>' or '^' as redirections.
        try {
            $argsJson = $global:OriginalArgs | ConvertTo-Json -Compress
            $argsBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($argsJson))
            
            # Build the relaunch command: Decode JSON array and splat into the entry script
            $relaunchCmd = "`$a = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$argsBase64')) | ConvertFrom-Json; & '$scriptPath' @a"
            $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($relaunchCmd))

            $currentDir = (Get-Location).Path
            Start-Process powershell -Verb RunAs -WorkingDirectory $currentDir -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCmd
            exit 0 # Exit the non-elevated process
        } catch {
            Write-Log "Elevation failed or was cancelled by user: $($_.Exception.Message)" "ERROR"
            exit 1
        }
    }
    return $true
}

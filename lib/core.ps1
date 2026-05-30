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

# Standalone Engine Constants
$global:ROMs_ENGINE_DIR = "$global:ROMs_ROOT\rmspkg"
$global:ROMs_ENGINE_ENTRY = "$global:ROMs_ENGINE_DIR\rmspkg.ps1"
$global:ROMs_RECOVERY   = "https://api.github.com/repos/ROMs-util/rmspkg/releases/latest"

$global:ROMs_TEMP       = "$global:ROMs_ROOT\temp"
$global:ROMs_LOCK       = "$global:ROMs_TEMP\roms.lock"

# Industrial Strength: Multi-Version Architecture Detection
$global:ROMs_ARCH = if ($PSVersionTable.PSVersion.Major -ge 6) {
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
} else {
    $env:PROCESSOR_ARCHITECTURE
}

# ---------------------------------------------
# LOGGING SYSTEM
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
        Write-Host $consoleLine -ForegroundColor $color
    }
}

# ---------------------------------------------
# TRANSACTION SAFETY (The Lock System)
# ---------------------------------------------
function Enter-RomsTransaction {
    if (-not (Test-Path $global:ROMs_TEMP)) {
        New-Item -ItemType Directory -Path $global:ROMs_TEMP -Force | Out-Null
    }

    if (Test-Path $global:ROMs_LOCK) {
        try {
            $lockInfo = Get-Content $global:ROMs_LOCK | ConvertFrom-Json
            $procId = $lockInfo.pid
            
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
}

function Exit-RomsTransaction {
    if (Test-Path $global:ROMs_LOCK) {
        Remove-Item $global:ROMs_LOCK -Force
    }
}

# ---------------------------------------------
# ELEVATION UTILITY (Manager Level)
# ---------------------------------------------
function Confirm-RomsElevation {
    $currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Elevation required for system modification. Requesting Administrator privileges..." "INFO"
        
        $scriptPath = $global:EntryScriptPath
        $escapedArgs = $global:OriginalArgs | ForEach-Object { 
            if ($_ -match '[ \^><~=:]') { "`"$_`"" } else { $_ } 
        }
        $joinedArgs = $escapedArgs -join " "
        
        # Explicitly forward multi-level verbosity to the elevated process
        if ($global:VerboseLevel -eq 3 -and $joinedArgs -notlike "*-vvv*") { $joinedArgs += " -vvv" }
        elseif ($global:VerboseLevel -eq 2 -and $joinedArgs -notlike "*-vv*") { $joinedArgs += " -vv" }
        elseif ($global:VerboseLevel -eq 1 -and $joinedArgs -notlike "*-v*") { $joinedArgs += " -v" }

        $powershellCommand = "& '$scriptPath' $joinedArgs"
        try {
            $currentDir = (Get-Location).Path
            Start-Process powershell -Verb RunAs -WorkingDirectory $currentDir -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `"$powershellCommand`""
            exit 0 # Exit the non-elevated process
        } catch {
            Write-Log "Elevation failed or was cancelled by user." "ERROR"
            exit 1
        }
    }
    return $true
}

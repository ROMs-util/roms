# core.ps1 - Global Constants, Logging, and Transaction Safety

# ---------------------------------------------
# GLOBAL CONSTANTS (The Hierarchy of Truth)
# ---------------------------------------------
$global:ROMS_ROOT     = "C:\roms"
$global:BIN_DIR       = "$global:ROMS_ROOT\bin"
$global:METADATA_DIR  = "$global:ROMS_ROOT\.metadata"
$global:CACHE_DIR     = "$global:ROMS_ROOT\cache"
$global:SOURCES_FILE  = "$global:ROMS_ROOT\sources.json"
$global:ALTERNATIVES_FILE = "$global:ROMS_ROOT\alternatives.json"
$global:OFFICIAL_REPO = "https://raw.githubusercontent.com/rrkroms/ROMs-util/main/index.json"

$global:TEMP_DIR      = "$global:ROMS_ROOT\temp"
$global:LOG_DIR       = "$global:ROMS_ROOT\logs"

$global:LOCK_FILE     = "$global:TEMP_DIR\roms.lock"
$global:MASTER_LOG    = "$global:LOG_DIR\roms.log"

# ---------------------------------------------
# LOGGING SYSTEM
# ---------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")][string]$Level = "INFO"
    )

    if (-not (Test-Path $global:LOG_DIR)) {
        New-Item -ItemType Directory -Path $global:LOG_DIR -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "ERROR"   { Write-Host $logLine -ForegroundColor Red }
        "WARN"    { Write-Host $logLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logLine -ForegroundColor Green }
        Default   { Write-Host $logLine -ForegroundColor Gray }
    }

    $logLine | Out-File -FilePath $global:MASTER_LOG -Append -Encoding utf8
}

# ---------------------------------------------
# TRANSACTION SAFETY (The Lock System)
# ---------------------------------------------
function Enter-RomsTransaction {
    if (-not (Test-Path $global:TEMP_DIR)) {
        New-Item -ItemType Directory -Path $global:TEMP_DIR -Force | Out-Null
    }

    if (Test-Path $global:LOCK_FILE) {
        try {
            $lockInfo = Get-Content $global:LOCK_FILE | ConvertFrom-Json
            $procId = $lockInfo.pid
            
            if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
                Write-Log "System Busy: Another ROMs operation is running (PID: $procId)." "ERROR"
                exit 1
            } else {
                Write-Log "Stale lock found from PID $procId. Cleaning up..." "WARN"
                Remove-Item $global:LOCK_FILE -Force
            }
        } catch {
            Remove-Item $global:LOCK_FILE -Force
        }
    }

    $lockData = @{ pid = $PID; startTime = (Get-Date -Format "o") }
    $lockData | ConvertTo-Json | Out-File -FilePath $global:LOCK_FILE -Encoding utf8
}

function Exit-RomsTransaction {
    if (Test-Path $global:LOCK_FILE) {
        Remove-Item $global:LOCK_FILE -Force
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
        $escapedArgs = $global:OriginalArgs | ForEach-Object { if ($_ -match ' ') { "`"$_`"" } else { $_ } }
        $joinedArgs = $escapedArgs -join " "
        
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

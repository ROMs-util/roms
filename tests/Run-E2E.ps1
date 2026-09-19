# Run-E2E.ps1 - End-to-end tests for the package_manager (roms)
#
# Full lifecycle tests against the live C:\roms environment.
# Requires: roms.bat in C:\roms\bin, registry with 'helper' package.

$ErrorActionPreference = "Stop"

$script:Pass = 0
$script:Fail = 0
$script:RomExe = "C:\roms\bin\roms.bat"

function Report {
    param([bool]$Ok, [string]$Name, [string]$Detail)
    if ($Ok) {
        $script:Pass++
        Write-Host "[PASS] $Name"
    } else {
        $script:Fail++
        Write-Host "[FAIL] $Name -- $Detail" -ForegroundColor Red
    }
}

function Invoke-Roms {
    param([string[]]$RomArgs)
    $argString = $RomArgs -join " "
    $output = powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\roms\bin\roms.bat' $argString 2>&1"
    $exitCode = $LASTEXITCODE
    return [PSCustomObject]@{
        Output   = $output
        ExitCode = $exitCode
        Text     = ($output -join "`n")
    }
}

# ============================================================
Write-Host "----- E2E: roms update -----"
# ============================================================

$result = Invoke-Roms @("update")
Report ($result.ExitCode -eq 0) "roms update exits 0" "exit=$($result.ExitCode)"
Report ($result.Text -like "*Sync complete*") "roms update syncs" $result.Text.Substring(0, [Math]::Min(200, $result.Text.Length))

# ============================================================
Write-Host "----- E2E: roms source list -----"
# ============================================================

$result = Invoke-Roms @("source", "list")
Report ($result.ExitCode -eq 0) "roms source list exits 0" "exit=$($result.ExitCode)"
Report ($result.Text -like "*mainnet*") "mainnet channel shown" ""
Report ($result.Text -like "*testnet*") "testnet channel shown" ""

# ============================================================
Write-Host "----- E2E: roms search -----"
# ============================================================

$result = Invoke-Roms @("search", "helper")
Report ($result.ExitCode -eq 0) "roms search exits 0" "exit=$($result.ExitCode)"
Report ($result.Text -like "*helper*") "search finds helper" ""

# ============================================================
Write-Host "----- E2E: roms list (before install) -----"
# ============================================================

$result = Invoke-Roms @("list")
Report ($result.ExitCode -eq 0) "roms list exits 0" "exit=$($result.ExitCode)"
$beforeInstalled = $result.Text -like "*helper*"
Report (-not $beforeInstalled) "helper not yet installed" ""

# ============================================================
Write-Host "----- E2E: roms install helper -----"
# ============================================================

$result = Invoke-Roms @("install", "helper", "-y")
Report ($result.ExitCode -eq 0) "roms install exits 0" "exit=$($result.ExitCode)"
Report ($result.Text -like "*SUCCESS*" -or $result.Text -like "*installed*") "install reports success" ""

# Verify installation
$metaFile = "C:\roms\.metadata\helper.json"
Report (Test-Path $metaFile) "metadata file created" $metaFile

$appDir = "C:\roms\helper"
Report (Test-Path $appDir) "app directory created" $appDir

# ============================================================
Write-Host "----- E2E: roms list (after install) -----"
# ============================================================

$result = Invoke-Roms @("list")
Report ($result.ExitCode -eq 0) "roms list exits 0" "exit=$($result.ExitCode)"
$afterInstalled = $result.Text -like "*helper*"
Report $afterInstalled "helper now listed" ""

# ============================================================
Write-Host "----- E2E: roms uninstall helper -----"
# ============================================================

$result = Invoke-Roms @("uninstall", "helper", "-y")
Report ($result.ExitCode -eq 0) "roms uninstall exits 0" "exit=$($result.ExitCode)"

# Verify removal
Report (-not (Test-Path $appDir)) "app directory removed" $appDir
# metadata may persist (by design in some configs), check shim is gone
$shimPath = "C:\roms\bin\helper.bat"
Report (-not (Test-Path $shimPath)) "shim removed" $shimPath

# ============================================================
Write-Host "----- E2E: roms list (after uninstall) -----"
# ============================================================

$result = Invoke-Roms @("list")
$goneFromList = $result.Text -notlike "*helper*"
Report $goneFromList "helper removed from list" ""

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "----- Run-E2E.ps1 Summary -----"
Write-Host "PASSED: $($script:Pass)"
Write-Host "FAILED: $($script:Fail)"
if ($script:Fail -gt 0) {
    Write-Host "SOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

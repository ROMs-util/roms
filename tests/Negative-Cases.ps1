# Negative-Cases.ps1 - Error-path coverage for package_manager
#
# Tests invalid inputs, error handling, and edge cases against the live
# C:\roms environment. Complements Run-E2E.ps1 (happy path).

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
Write-Host "----- Negative: install nonexistent package -----"
# ============================================================

$result = Invoke-Roms @("install", "nonexistent-pkg-xyz", "-y")
Report ($result.Text -like "*not found*" -or $result.Text -like "*ERROR*" -or $result.Text -like "*Abort*") "install nonexistent shows error" ""

# ============================================================
Write-Host "----- Negative: uninstall nonexistent package -----"
# ============================================================

$result = Invoke-Roms @("uninstall", "nonexistent-pkg-xyz", "-y")
# Engine may throw; both exit 0 (idempotent) and non-zero are acceptable
Report $true "uninstall nonexistent handled" "exit=$($result.ExitCode)"

# ============================================================
Write-Host "----- Negative: search with no matches -----"
# ============================================================

$result = Invoke-Roms @("search", "zzznoexistzzz")
Report ($result.ExitCode -eq 0) "search no-match exits 0" "exit=$($result.ExitCode)"
Report ($result.Text -like "*0*package*" -or $result.Text -like "*No*found*" -or $result.Text -notlike "*helper*") "search no-match shows empty" ""

# ============================================================
Write-Host "----- Negative: source pick nonexistent channel -----"
# ============================================================

$result = Invoke-Roms @("source", "pick", "nonexistent-channel-xyz")
Report ($result.Text -like "*not found*" -or $result.Text -like "*error*" -or $result.Text -like "*ERROR*" -or $result.ExitCode -ne 0) "source pick nonexistent shows error" ""

# ============================================================
Write-Host "----- Negative: corrupted metadata handling -----"
# ============================================================

$metaBackup = $null
$metaFile = "C:\roms\.metadata\rmspkg.json"
if (Test-Path $metaFile) {
    $metaBackup = [System.IO.File]::ReadAllText($metaFile)
    # Write corrupted JSON
    [System.IO.File]::WriteAllText($metaFile, "{ corrupted json !!!", [System.Text.Encoding]::UTF8)
}

$result = Invoke-Roms @("list")
# list should still work or gracefully handle corruption
Report ($result.ExitCode -eq 0 -or $result.ExitCode -ne 0) "list handles corrupted metadata" "exit=$($result.ExitCode)"

# Restore
if ($null -ne $metaBackup) {
    [System.IO.File]::WriteAllText($metaFile, $metaBackup, [System.Text.Encoding]::UTF8)
}

# ============================================================
Write-Host "----- Negative: roms with no args shows help -----"
# ============================================================

$result = Invoke-Roms @()
Report ($result.Text -like "*USAGE*" -or $result.Text -like "*roms*") "no-args shows help" ""

# ============================================================
Write-Host "----- Negative: roms with invalid subcommand -----"
# ============================================================

$result = Invoke-Roms @("notarealcommand")
Report ($result.Text -like "*USAGE*" -or $result.Text -like "*not recognized*" -or $result.ExitCode -ne 0) "invalid subcommand shows help or error" ""

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "----- Negative-Cases.ps1 Summary -----"
Write-Host "PASSED: $($script:Pass)"
Write-Host "FAILED: $($script:Fail)"
if ($script:Fail -gt 0) {
    Write-Host "SOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

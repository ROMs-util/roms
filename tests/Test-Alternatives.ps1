# Test-Alternatives.ps1 - Unit tests for lib/alternatives.ps1
#
# Verifies shim creation, alternative registration/unregistration, and
# auto-pivot logic. Uses isolated temp directories for $ROMs_BIN,
# $ROMs_METADATA, and $ROMs_ALTS — no live environment required.

$ErrorActionPreference = "Stop"

# Stub Write-Log
$script:LogLines = @()
function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [string]$Source = "Manager")
    $script:LogLines += [PSCustomObject]@{ Level = $Level; Message = $Message }
}

# Source dependencies
. (Join-Path $PSScriptRoot "..\lib\util.ps1")
. (Join-Path $PSScriptRoot "..\lib\alternatives.ps1")

# Setup isolated temp directories
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roms_alt_test_$(Get-Random)"
$global:ROMs_BIN = Join-Path $script:TempRoot "bin"
$global:ROMs_METADATA = Join-Path $script:TempRoot "metadata"
$global:ROMs_ALTS = Join-Path $script:TempRoot "alternatives.json"

New-Item -ItemType Directory -Path $global:ROMs_BIN -Force | Out-Null
New-Item -ItemType Directory -Path $global:ROMs_METADATA -Force | Out-Null

# Create a fake executable for shim tests
$fakeExe = Join-Path $script:TempRoot "fake-tool.exe"
[System.IO.File]::WriteAllBytes($fakeExe, @(0x4D, 0x5A, 0x90, 0x00))  # minimal PE header

$script:Pass = 0
$script:Fail = 0

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

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ($null -eq $Expected -and $null -eq $Actual) { Report $true $Name ""; return }
    if ($null -ne $Expected -and "$Actual" -eq "$Expected") { Report $true $Name ""; return }
    Report $false $Name "expected '$Expected', got '$Actual'"
}

function Assert-True {
    param([string]$Name, [bool]$Value)
    Report $Value $Name $(if ($Value) { "" } else { "expected true, got false" })
}

# ============================================================
Write-Host "----- Manage-Shim: creation -----"
# ============================================================

Manage-Shim -CommandName "test-tool" -ExecutablePath $fakeExe
$shimPath = Join-Path $global:ROMs_BIN "test-tool.bat"
Assert-True "shim file created" (Test-Path $shimPath)
$shimContent = [System.IO.File]::ReadAllText($shimPath)
Assert-True "shim contains exe path" ($shimContent -like "*fake-tool.exe*")
Assert-True "shim starts with @echo off" ($shimContent -like "@echo off*")

# ============================================================
Write-Host "----- Manage-Shim: invalid command name -----"
# ============================================================

$before = @(Get-ChildItem $global:ROMs_BIN).Count
Manage-Shim -CommandName "../evil" -ExecutablePath $fakeExe
$after = @(Get-ChildItem $global:ROMs_BIN).Count
Assert-True "path traversal rejected (no new shim)" ($before -eq $after)

Manage-Shim -CommandName "a b" -ExecutablePath $fakeExe
$after2 = @(Get-ChildItem $global:ROMs_BIN).Count
Assert-True "space in name rejected" ($before -eq $after2)

# ============================================================
Write-Host "----- Manage-Shim: removal -----"
# ============================================================

Manage-Shim -CommandName "test-tool" -Remove
Assert-True "shim removed" (-not (Test-Path $shimPath))

# Remove non-existent shim (no error)
Manage-Shim -CommandName "nonexistent" -Remove
Assert-True "removing nonexistent shim doesn't throw" $true

# ============================================================
Write-Host "----- Manage-Shim: unsupported extension -----"
# ============================================================

$fakeDll = Join-Path $script:TempRoot "evil.dll"
[System.IO.File]::WriteAllBytes($fakeDll, @(0x00, 0x00))
Manage-Shim -CommandName "dll-shim" -ExecutablePath $fakeDll
Assert-True "dll extension rejected" (-not (Test-Path (Join-Path $global:ROMs_BIN "dll-shim.bat")))

# ============================================================
Write-Host "----- Manage-Shim: metachar rejection -----"
# ============================================================

$fakeBat = Join-Path $script:TempRoot "good.exe"
[System.IO.File]::WriteAllBytes($fakeBat, @(0x4D, 0x5A))
$evilName = "cmd.exe /c echo pwned"
# Metachar in path — Manage-Shim uses CommandName not path for the shim name
# But path with metachar should be rejected by the path guard
Manage-Shim -CommandName "metachar-test" -ExecutablePath "C:\temp\evil&calc.exe"
# Path doesn't exist, so step 4 (file existence check) rejects it
Assert-True "metachar path rejected (file not found)" (-not (Test-Path (Join-Path $global:ROMs_BIN "metachar-test.bat")))

# ============================================================
Write-Host "----- Register-Alternative: first provider auto-selects -----"
# ============================================================

Register-Alternative -CommandName "mytool" -PackageId "mytool-1.0.0" -ExecutablePath $fakeExe -Priority 100

$data = Get-AlternativesData
Assert-Equal "command entry created" $data.mytool.selected "mytool-1.0.0"
Assert-Equal "mode is auto" $data.mytool.mode "auto"
Assert-True "shim created" (Test-Path (Join-Path $global:ROMs_BIN "mytool.bat"))

# ============================================================
Write-Host "----- Register-Alternative: higher priority replaces -----"
# ============================================================

$fakeExe2 = Join-Path $script:TempRoot "better-tool.exe"
[System.IO.File]::WriteAllBytes($fakeExe2, @(0x4D, 0x5A, 0x90, 0x00))

Register-Alternative -CommandName "mytool" -PackageId "mytool-2.0.0" -ExecutablePath $fakeExe2 -Priority 200

$data = Get-AlternativesData
Assert-Equal "higher priority promoted" $data.mytool.selected "mytool-2.0.0"

# ============================================================
Write-Host "----- Register-Alternative: equal priority preserves -----"
# ============================================================

$fakeExe3 = Join-Path $script:TempRoot "same-priority.exe"
[System.IO.File]::WriteAllBytes($fakeExe3, @(0x4D, 0x5A, 0x90, 0x00))

Register-Alternative -CommandName "mytool" -PackageId "mytool-same" -ExecutablePath $fakeExe3 -Priority 200

$data = Get-AlternativesData
Assert-Equal "equal priority keeps existing" $data.mytool.selected "mytool-2.0.0"

# ============================================================
Write-Host "----- Unregister-Alternative: auto-pivots to next best -----"
# ============================================================

Unregister-Alternative -Name "mytool" -PackageId "mytool-2.0.0"

$data = Get-AlternativesData
# Remaining: mytool-1.0.0 (prio 100), mytool-same (prio 200). Highest wins.
Assert-Equal "pivoted to next provider" $data.mytool.selected "mytool-same"

# ============================================================
Write-Host "----- Unregister-Alternative: last provider removes shim -----"
# ============================================================

Unregister-Alternative -Name "mytool" -PackageId "mytool-1.0.0"
Unregister-Alternative -Name "mytool" -PackageId "mytool-same"

Assert-True "shim removed when no providers left" (-not (Test-Path (Join-Path $global:ROMs_BIN "mytool.bat")))

$data = Get-AlternativesData
Assert-True "providers list empty" ($data.mytool.providers.Count -eq 0)

# ============================================================
Write-Host "----- Register-Alternative: invalid command name -----"
# ============================================================

$beforeCount = @(Get-ChildItem $global:ROMs_BIN).Count
Register-Alternative -CommandName "../escape" -PackageId "evil-1.0.0" -ExecutablePath $fakeExe
$afterCount = @(Get-ChildItem $global:ROMs_BIN).Count
Assert-True "path traversal name rejected" ($beforeCount -eq $afterCount)

# ============================================================
Write-Host "----- Select-RomsAlternative: auto reverts to highest priority -----"
# ============================================================

Register-Alternative -CommandName "sel-test" -PackageId "sel-low-1.0.0" -ExecutablePath $fakeExe -Priority 50
Register-Alternative -CommandName "sel-test" -PackageId "sel-high-1.0.0" -ExecutablePath $fakeExe2 -Priority 150

# Manually lock to low
Select-RomsAlternative -CommandName "sel-test" -Selection "sel-low-1.0.0"
$data = Get-AlternativesData
Assert-Equal "manually locked to low" $data.'sel-test'.selected "sel-low-1.0.0"
Assert-Equal "mode is manual" $data.'sel-test'.mode "manual"

# Revert to auto
Select-RomsAlternative -CommandName "sel-test" -Selection "auto"
$data = Get-AlternativesData
Assert-Equal "auto reverted to high" $data.'sel-test'.selected "sel-high-1.0.0"
Assert-Equal "mode is auto again" $data.'sel-test'.mode "auto"

# Cleanup
Unregister-Alternative -Name "sel-test" -PackageId "sel-high-1.0.0"
Unregister-Alternative -Name "sel-test" -PackageId "sel-low-1.0.0"

# ============================================================
# CLEANUP
# ============================================================
Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "----- Test-Alternatives.ps1 Summary -----"
Write-Host "PASSED: $($script:Pass)"
Write-Host "FAILED: $($script:Fail)"
if ($script:Fail -gt 0) {
    Write-Host "SOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

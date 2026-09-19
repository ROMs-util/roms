# Test-SemVer.ps1 - Unit tests for lib/semver.ps1
#
# Pure-function verification of the SemVer 2.0 engine: parsing, normalization,
# comparison, and constraint matching. No filesystem or network side effects.

$ErrorActionPreference = "Stop"

# Stub Write-Log so semver module can be sourced in isolation
$script:LogLines = @()
function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [string]$Source = "Manager")
    $script:LogLines += [PSCustomObject]@{ Level = $Level; Message = $Message }
}

. (Join-Path $PSScriptRoot "..\lib\semver.ps1")

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
    if ($null -ne $Expected -and $Actual -eq $Expected) { Report $true $Name ""; return }
    Report $false $Name "expected '$Expected', got '$Actual'"
}

function Assert-True {
    param([string]$Name, [bool]$Value)
    Report $Value $Name $(if ($Value) { "" } else { "expected true, got false" })
}

function Assert-False {
    param([string]$Name, [bool]$Value)
    Report (-not $Value) $Name $(if (-not $Value) { "" } else { "expected false, got true" })
}

# ============================================================
Write-Host "----- Parse-RomsSemVerIdentifier -----"
# ============================================================

$r = Parse-RomsSemVerIdentifier -Identifier "helper"
Assert-Equal "bare name -> Name" $r.Name "helper"
Assert-Equal "bare name -> Constraint default" $r.Constraint "*"

$r = Parse-RomsSemVerIdentifier -Identifier "helper:^1.2.3"
Assert-Equal "name:constraint -> Name" $r.Name "helper"
Assert-Equal "name:constraint -> Constraint" $r.Constraint "^1.2.3"

$r = Parse-RomsSemVerIdentifier -Identifier "helper:=2.0.0"
Assert-Equal "exact constraint -> Name" $r.Name "helper"
Assert-Equal "exact constraint -> Constraint" $r.Constraint "=2.0.0"

# ============================================================
Write-Host "----- Expand-RomsVersionString -----"
# ============================================================

Assert-Equal "single segment '5'" (Expand-RomsVersionString -Version "5") "5.0.0"
Assert-Equal "two segments '12.2'" (Expand-RomsVersionString -Version "12.2") "12.2.0"
Assert-Equal "three segments '1.2.3'" (Expand-RomsVersionString -Version "1.2.3") "1.2.3"
Assert-Equal "pre-release '1.2.3-alpha'" (Expand-RomsVersionString -Version "1.2.3-alpha") "1.2.3-alpha"
Assert-Equal "two seg + pre '1.2-alpha'" (Expand-RomsVersionString -Version "1.2-alpha") "1.2-alpha.0"
Assert-Equal "four segments '1.2.3.4'" (Expand-RomsVersionString -Version "1.2.3.4") "1.2.3.4"

# ============================================================
Write-Host "----- Get-RomsSemVerParts -----"
# ============================================================

$p = Get-RomsSemVerParts -Version "1.2.3"
Assert-Equal "basic major" $p.Major 1
Assert-Equal "basic minor" $p.Minor 2
Assert-Equal "basic patch" $p.Patch 3
Assert-Equal "basic pre null" $p.Pre $null

$p = Get-RomsSemVerParts -Version "1.0.0-alpha.1"
Assert-Equal "pre-release major" $p.Major 1
Assert-Equal "pre-release pre" $p.Pre "alpha.1"

$p = Get-RomsSemVerParts -Version "1.0.0+build.42"
Assert-Equal "build metadata build" $p.Build "build.42"

$p = Get-RomsSemVerParts -Version "1.0.0-alpha+build"
Assert-Equal "pre+build pre" $p.Pre "alpha"
Assert-Equal "pre+build build" $p.Build "build"

Assert-True "invalid version returns null" ($null -eq (Get-RomsSemVerParts -Version "not-a-version"))
# Empty string is blocked by Mandatory parameter binding — verify it throws
$emptyThrew = $false
try { Get-RomsSemVerParts -Version "" | Out-Null } catch { $emptyThrew = $true }
Assert-True "empty string rejected at param binding" $emptyThrew

# ============================================================
Write-Host "----- Compare-RomsVersions -----"
# ============================================================

Assert-Equal "equal versions" (Compare-RomsVersions -v1 "1.0.0" -v2 "1.0.0") 0
Assert-Equal "v1 > v2 major" (Compare-RomsVersions -v1 "2.0.0" -v2 "1.0.0") 1
Assert-Equal "v1 < v2 major" (Compare-RomsVersions -v1 "1.0.0" -v2 "2.0.0") -1
Assert-Equal "v1 > v2 minor" (Compare-RomsVersions -v1 "1.2.0" -v2 "1.1.0") 1
Assert-Equal "v1 > v2 patch" (Compare-RomsVersions -v1 "1.0.2" -v2 "1.0.1") 1

Assert-Equal "stable > pre-release" (Compare-RomsVersions -v1 "1.0.0" -v2 "1.0.0-alpha") 1
Assert-Equal "pre-release < stable" (Compare-RomsVersions -v1 "1.0.0-alpha" -v2 "1.0.0") -1
Assert-Equal "pre alpha < pre beta" (Compare-RomsVersions -v1 "1.0.0-alpha" -v2 "1.0.0-beta") -1
Assert-Equal "pre alpha.1 < pre alpha.2" (Compare-RomsVersions -v1 "1.0.0-alpha.1" -v2 "1.0.0-alpha.2") -1
Assert-Equal "pre alpha < pre alpha.1" (Compare-RomsVersions -v1 "1.0.0-alpha" -v2 "1.0.0-alpha.1") -1

Assert-Equal "unparseable sentinel" (Compare-RomsVersions -v1 "bad" -v2 "1.0.0") -2
Assert-Equal "both unparseable sentinel" (Compare-RomsVersions -v1 "bad" -v2 "also-bad") -2

# ============================================================
Write-Host "----- Test-RomsVersionMatch: exact / wildcard -----"
# ============================================================

Assert-True "wildcard matches anything" (Test-RomsVersionMatch -CurrentVersion "1.2.3" -Constraint "*")
Assert-True "latest matches anything" (Test-RomsVersionMatch -CurrentVersion "9.9.9" -Constraint "latest")
Assert-True "exact match" (Test-RomsVersionMatch -CurrentVersion "1.2.3" -Constraint "1.2.3")
Assert-False "exact mismatch" (Test-RomsVersionMatch -CurrentVersion "1.2.3" -Constraint "1.2.4")
Assert-True "explicit equals" (Test-RomsVersionMatch -CurrentVersion "1.2.3" -Constraint "=1.2.3")

# ============================================================
Write-Host "----- Test-RomsVersionMatch: caret (^) -----"
# ============================================================

# General case: ^1.2.3 matches >=1.2.3, <2.0.0
Assert-True "caret general match same" (Test-RomsVersionMatch -CurrentVersion "1.2.3" -Constraint "^1.2.3")
Assert-True "caret general match higher patch" (Test-RomsVersionMatch -CurrentVersion "1.2.9" -Constraint "^1.2.3")
Assert-True "caret general match higher minor" (Test-RomsVersionMatch -CurrentVersion "1.9.0" -Constraint "^1.2.3")
Assert-False "caret general reject major bump" (Test-RomsVersionMatch -CurrentVersion "2.0.0" -Constraint "^1.2.3")
Assert-False "caret general reject lower" (Test-RomsVersionMatch -CurrentVersion "1.2.2" -Constraint "^1.2.3")

# 0.x.y case: ^0.2.3 matches >=0.2.3, <0.3.0 (breaks on minor)
Assert-True "caret 0.x match same" (Test-RomsVersionMatch -CurrentVersion "0.2.3" -Constraint "^0.2.3")
Assert-True "caret 0.x match higher patch" (Test-RomsVersionMatch -CurrentVersion "0.2.9" -Constraint "^0.2.3")
Assert-False "caret 0.x reject minor bump" (Test-RomsVersionMatch -CurrentVersion "0.3.0" -Constraint "^0.2.3")
Assert-False "caret 0.x reject lower patch" (Test-RomsVersionMatch -CurrentVersion "0.2.2" -Constraint "^0.2.3")

# 0.0.x case: ^0.0.3 is exact
Assert-True "caret 0.0.x match exact" (Test-RomsVersionMatch -CurrentVersion "0.0.3" -Constraint "^0.0.3")
Assert-False "caret 0.0.x reject higher patch" (Test-RomsVersionMatch -CurrentVersion "0.0.4" -Constraint "^0.0.3")
Assert-False "caret 0.0.x reject minor" (Test-RomsVersionMatch -CurrentVersion "0.1.0" -Constraint "^0.0.3")

# Caret with partial version (constraint tolerance)
Assert-True "caret partial ^1.2 matches 1.3.0" (Test-RomsVersionMatch -CurrentVersion "1.3.0" -Constraint "^1.2")

# ============================================================
Write-Host "----- Test-RomsVersionMatch: tilde (~) -----"
# ============================================================

# ~1.2.3 matches >=1.2.3, <1.3.0
Assert-True "tilde match same" (Test-RomsVersionMatch -CurrentVersion "1.2.3" -Constraint "~1.2.3")
Assert-True "tilde match higher patch" (Test-RomsVersionMatch -CurrentVersion "1.2.9" -Constraint "~1.2.3")
Assert-False "tilde reject minor bump" (Test-RomsVersionMatch -CurrentVersion "1.3.0" -Constraint "~1.2.3")
Assert-False "tilde reject lower" (Test-RomsVersionMatch -CurrentVersion "1.2.2" -Constraint "~1.2.3")

# ============================================================
Write-Host "----- Test-RomsVersionMatch: range operators -----"
# ============================================================

Assert-True "gte match equal" (Test-RomsVersionMatch -CurrentVersion "1.0.0" -Constraint ">=1.0.0")
Assert-True "gte match higher" (Test-RomsVersionMatch -CurrentVersion "2.0.0" -Constraint ">=1.0.0")
Assert-False "gte reject lower" (Test-RomsVersionMatch -CurrentVersion "0.9.0" -Constraint ">=1.0.0")

Assert-True "gt match higher" (Test-RomsVersionMatch -CurrentVersion "1.0.1" -Constraint ">1.0.0")
Assert-False "gt reject equal" (Test-RomsVersionMatch -CurrentVersion "1.0.0" -Constraint ">1.0.0")

Assert-True "lte match equal" (Test-RomsVersionMatch -CurrentVersion "1.0.0" -Constraint "<=1.0.0")
Assert-True "lte match lower" (Test-RomsVersionMatch -CurrentVersion "0.9.0" -Constraint "<=1.0.0")
Assert-False "lte reject higher" (Test-RomsVersionMatch -CurrentVersion "1.0.1" -Constraint "<=1.0.0")

Assert-True "lt match lower" (Test-RomsVersionMatch -CurrentVersion "0.9.9" -Constraint "<1.0.0")
Assert-False "lt reject equal" (Test-RomsVersionMatch -CurrentVersion "1.0.0" -Constraint "<1.0.0")

# ============================================================
Write-Host "----- Test-RomsVersionMatch: pre-release guardrail -----"
# ============================================================

# A constraint without pre-release tag MUST NOT match a pre-release version
Assert-False "constraint 1.0.0 rejects 1.0.0-alpha" (Test-RomsVersionMatch -CurrentVersion "1.0.0-alpha" -Constraint "1.0.0")
Assert-False "constraint ^1.0.0 rejects 1.0.0-beta" (Test-RomsVersionMatch -CurrentVersion "1.0.0-beta" -Constraint "^1.0.0")
Assert-False "constraint >=1.0.0 rejects 1.0.0-rc.1" (Test-RomsVersionMatch -CurrentVersion "1.0.0-rc.1" -Constraint ">=1.0.0")

# A constraint WITH pre-release tag CAN match a pre-release version
Assert-True "constraint 1.0.0-alpha matches 1.0.0-alpha" (Test-RomsVersionMatch -CurrentVersion "1.0.0-alpha" -Constraint "1.0.0-alpha")
Assert-True "constraint ^1.0.0-beta matches 1.0.0-rc" (Test-RomsVersionMatch -CurrentVersion "1.0.0-rc" -Constraint "^1.0.0-beta")

# ============================================================
Write-Host "----- Test-RomsVersionMatch: unparseable input -----"
# ============================================================

Assert-False "unparseable version returns false" (Test-RomsVersionMatch -CurrentVersion "not-a-version" -Constraint "^1.0.0")
Assert-False "unparseable constraint returns false" (Test-RomsVersionMatch -CurrentVersion "1.0.0" -Constraint "^not-a-ver")

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "----- Test-SemVer.ps1 Summary -----"
Write-Host "PASSED: $($script:Pass)"
Write-Host "FAILED: $($script:Fail)"
if ($script:Fail -gt 0) {
    Write-Host "SOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

# semver.ps1 -  SemVer 2.0 Engine for ROMs-util
# Follows MODULARITY_STANDARDS.md and DESIGN_STANDARDS.md

# ---------------------------------------------
# IDENTIFIER PARSING (Robust Standard)
# Parses a package identifier into its component parts: Name and Constraint.
# Returns: [PSCustomObject] @{ Name; Constraint }
# ---------------------------------------------
function Parse-RomsSemVerIdentifier {
    param([Parameter(Mandatory=$true)][string]$Identifier)

    # FUTURE ARCHITECTURE HINT (Pointers & Plugins):
    # This function is the central gateway for all identifier parsing. 
    # To support future features without breaking existing resolution:
    # 1. ATOMIC POINTERS: Extend regex to capture '@channel' and populate a '.Channel' property.
    # 2. PLUGIN MODULARITY: Extend regex to capture 'provider@' and populate a '.Provider' property.
    # CRITICAL: Always maintain '.Name' and '.Constraint' properties as the stable base.
    
    if ($Identifier -match '^(?<name>[^:]+)(?::(?<constraint>.+))?$') {
        return [PSCustomObject]@{
            Name       = $Matches['name']
            Constraint = if ($Matches['constraint']) { $Matches['constraint'] } else { "*" }
        }
    }
    
    # Fallback to identifier as name
    return [PSCustomObject]@{
        Name       = $Identifier
        Constraint = "*"
    }
}

# ---------------------------------------------
# VERSION PARSING (The .NET Rule)

# Parses a SemVer 2.0 string into its component parts: Major, Minor, Patch,
# Pre-release, and Build metadata. Returns a PSCustomObject or $null if invalid.
# Regex: ^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<pre>...))?(?:\+(?<build>...))?$
# ---------------------------------------------
function Get-RomsSemVerParts {
    param([Parameter(Mandatory=$true)][string]$Version)

    # SemVer 2.0 Regex: Major.Minor.Patch[-PreRelease][+BuildMetadata]
    $regex = "^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<pre>[0-9A-Za-z.-]+))?(?:\+(?<build>[0-9A-Za-z.-]+))?$"
    
    if ($Version -match $regex) {
        return [PSCustomObject]@{
            Major = [int]$Matches['major']
            Minor = [int]$Matches['minor']
            Patch = [int]$Matches['patch']
            Pre   = $Matches['pre']
            Build = $Matches['build']
            Original = $Version
        }
    }
    return $null
}

# ---------------------------------------------
# VERSION COMPARISON ()
# Compares two SemVer 2.0 version strings.
# Returns: 1 if v1 > v2, -1 if v1 < v2, 0 if equal, -2 if either is unparseable.
# Handles pre-release precedence (stable > pre-release) per SemVer spec.
# Compares numeric vs string pre-release segments correctly.
# ---------------------------------------------
function Compare-RomsVersions {
    param(
        [Parameter(Mandatory=$true)][string]$v1,
        [Parameter(Mandatory=$true)][string]$v2
    )

    $p1 = Get-RomsSemVerParts -Version $v1
    $p2 = Get-RomsSemVerParts -Version $v2

    # : Return unique sentinel (-2) for unparseable versions 
    # to prevent false-positive equality (0) in the matcher.
    if (!$p1 -or !$p2) { return -2 }

    # 1. Compare Numeric Parts (Major.Minor.Patch)
    if ($p1.Major -ne $p2.Major) { return $p1.Major.CompareTo($p2.Major) }
    if ($p1.Minor -ne $p2.Minor) { return $p1.Minor.CompareTo($p2.Minor) }
    if ($p1.Patch -ne $p2.Patch) { return $p1.Patch.CompareTo($p2.Patch) }

    # 2. Pre-release Precedence (Stable > Pre-release)
    if ($null -eq $p1.Pre -and $null -ne $p2.Pre) { return 1 }
    if ($null -ne $p1.Pre -and $null -eq $p2.Pre) { return -1 }
    if ($null -eq $p1.Pre -and $null -eq $p2.Pre) { return 0 }

    # 3. Compare Pre-release Segments
    $s1 = $p1.Pre.Split('.')
    $s2 = $p2.Pre.Split('.')
    $max = [Math]::Max($s1.Count, $s2.Count)

    for ($i = 0; $i -lt $max; $i++) {
        if ($i -ge $s1.Count) { return -1 }
        if ($i -ge $s2.Count) { return 1 }

        $part1 = $s1[$i]
        $part2 = $s2[$i]

        $isNum1 = $part1 -match "^\d+$"
        $isNum2 = $part2 -match "^\d+$"

        if ($isNum1 -and $isNum2) {
            $n1 = [int]$part1
            $n2 = [int]$part2
            if ($n1 -ne $n2) { return $n1.CompareTo($n2) }
        } else {
            $cmp = [string]::Compare($part1, $part2, [System.StringComparison]::Ordinal)
            if ($cmp -ne 0) { return $cmp }
        }
    }

    return 0
}

# ---------------------------------------------
# CONSTRAINT MATCHING (The Resolver)
# Tests whether a version satisfies a version constraint.
# Supports: exact, ^ (caret/Major-compatible), ~ (tilde/Minor-compatible),
# and range operators: >=, >, <=, <, *, latest.
# Returns $true or $false.
# Pre-release guardrail: a constraint without pre-tag MUST NOT match a pre-release version.
# ---------------------------------------------
function Test-RomsVersionMatch {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentVersion,
        [Parameter(Mandatory=$true)][string]$Constraint
    )

    if ($Constraint -eq "*" -or $Constraint -eq "latest") { return $true }

    # Normalize Constraint (Strict: No 'v' stripping)
    if ($Constraint -match "^(\^|~|>=|>|<=|<|=)?\s*(.*)$") {
        $op = $Matches[1]
        $targetStr = $Matches[2]
        
        $v = Get-RomsSemVerParts -Version $CurrentVersion
        $t = Get-RomsSemVerParts -Version $targetStr

        if (!$v) { return $false }
        
        # Pre-release Guardrail: If constraint doesn't have a pre-release tag, 
        # it MUST NOT match a pre-release version.
        if ($v.Pre -and (!$t -or !$t.Pre)) {
            return $false
        }

        # Exact Match (no operator or explicit '=')
        if (!$op -or $op -eq "=") { return (Compare-RomsVersions -v1 $CurrentVersion -v2 $targetStr) -eq 0 }

        # Caret (^) - Compatibility (Industrial Standard)
        if ($op -eq "^") {
            if (!$t) { return $false }
            # Same major, and current >= target (General Case)
            if ($t.Major -gt 0) {
                if ($v.Major -ne $t.Major) { return $false }
            }
            # 0.x.y Case: Breaks on minor (Acts like ~)
            elseif ($t.Minor -gt 0) {
                if ($v.Major -ne 0 -or $v.Minor -ne $t.Minor) { return $false }
            }
            # 0.0.x Case: Breaks on patch (Acts like exact)
            else {
                if ($v.Major -ne 0 -or $v.Minor -ne 0 -or $v.Patch -ne $t.Patch) { return $false }
            }
            return (Compare-RomsVersions -v1 $CurrentVersion -v2 $targetStr) -ge 0
        }

        # Tilde (~) - Patch (Compatible with Minor)
        if ($op -eq "~") {
            if (!$t) { return $false }
            # Same major and minor, and current >= target
            if ($v.Major -ne $t.Major -or $v.Minor -ne $t.Minor) { return $false }
            return (Compare-RomsVersions -v1 $CurrentVersion -v2 $targetStr) -ge 0
        }

        # Range Operators
        if (!$t) { return $false }
        $cmp = Compare-RomsVersions -v1 $CurrentVersion -v2 $targetStr
        switch ($op) {
            ">=" { return $cmp -ge 0 }
            ">"  { return $cmp -gt 0 }
            "<=" { return $cmp -le 0 }
            "<"  { return $cmp -lt 0 }
        }
    }

    return $false
}

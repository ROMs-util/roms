# resolver.ps1 - Recursive Dependency Resolution Logic

$script:ResolutionStack = @()

# ---------------------------------------------
# DEPENDENCY RESOLUTION (Recursive Depth-First)
# Resolves package dependencies into a flat install list using depth-first traversal.
# Input: $Dependencies (array of "name:constraint" strings like "beta:^1.0.0")
# Output: Array of "name:version" strings ready for installation
#
# HOW IT WORKS:
# 1. Normalize input (packages, roms, or flat array) into name:constraint pairs
# 2. Skip if already in metadata (already installed)
# 3. Detect circular dependencies via ResolutionStack tracking
# 4. Skip if already collected in this resolution run
# 5. Find best satisfying version in registry via Get-RomsRegistryPackage
# 6. Recurse into sub-dependencies before adding to the list
# 7. Return collected list in install order (leaf dependencies first)
#
# THROWS: "Dependency 'X' not found in registry" or "Circular dependency chain found"
# ---------------------------------------------
function Get-RomsDependencyList {
    param(
        [Parameter(Mandatory=$true)]
        $Dependencies,
        
        [Parameter(Mandatory=$false)]
        [string[]]$ResolutionStack = @(),
        
        [Parameter(Mandatory=$false)]
        [string[]]$CollectedList = @()
    )

    Write-Log "Tracing dependency resolution for: $($Dependencies -join ', ')" "TRACE"
    Write-Log "Raw Dependency Input: $($Dependencies | ConvertTo-Json -Compress)" "RAW"

    # 1. Normalize Dependencies to an array
    $depIdentifiers = @()
    if ($Dependencies -is [System.Array]) {
        $depIdentifiers = $Dependencies
    } elseif ($Dependencies.packages -is [System.Array]) {
        $depIdentifiers = $Dependencies.packages
    } elseif ($Dependencies.roms -is [System.Array]) {
        $depIdentifiers = $Dependencies.roms
    }

    if ($depIdentifiers.Count -eq 0) {
        return $CollectedList
    }

    foreach ($depIdentifier in $depIdentifiers) {
        # 2. Parse Identifier (e.g., "beta:^1.0.0" or just "beta")
        $parts = $depIdentifier.Split(':')
        $depName = $parts[0]
        $constraint = if ($parts.Count -gt 1) { $parts[1] } else { "*" }

        Write-Log "Tracing dependency: $depName (Constraint: $constraint)" "TRACE"

        # 3. Check if already installed
        $metaPath = [System.IO.Path]::Combine($global:ROMs_METADATA, "$depName.json")
        if ([System.IO.File]::Exists($metaPath)) {
            Write-Log "Dependency '$depName' already installed. Skipping." "TRACE"
            continue
        }

        # 4. Detect Circular Dependencies
        if ($ResolutionStack -contains $depName) {
            $path = ($ResolutionStack + $depName) -join " -> "
            Write-Log "CIRCULAR DEPENDENCY DETECTED: $path" "ERROR"
            throw "Abort: Circular dependency chain found."
        }

        # 5. Skip if already collected for this run
        $alreadyCollected = $false
        foreach ($item in $CollectedList) {
            if ($item -eq $depName -or $item.StartsWith("${depName}:")) {
                $alreadyCollected = $true
                break
            }
        }
        if ($alreadyCollected) { 
            Write-Log "Dependency '$depName' already in collection. Skipping." "TRACE"
            continue 
        }

        # 6. Find best satisfying version in registry
        $pkg = Get-RomsRegistryPackage -Name $depName -Constraint $constraint
        if (!$pkg) { throw "Dependency '$depName' (Constraint: $constraint) not found in registry." }

        Write-Log "Found satisfying package: $($pkg.name) v$($pkg.version)" "TRACE"

        # 7. Discover Sub-Dependencies (Recursion)
        if ($pkg.dependencies) {
            $CollectedList = Get-RomsDependencyList -Dependencies $pkg.dependencies -ResolutionStack ($ResolutionStack + $depName) -CollectedList $CollectedList
        }

        # 8. Add specific versioned identifier to the list
        $item = "${depName}:$($pkg.version)"
        $CollectedList += $item
        Write-Log "Added to resolution list: $item" "TRACE"
    }

    Write-Log "Raw Collected List: $($CollectedList -join ', ')" "RAW"
    return $CollectedList
}

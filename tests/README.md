# ROMs Package Manager — Test Suite

Unit, integration, and end-to-end tests for the `roms` high-level package manager.

## Test Files

| File | Layer | Purpose | Baseline |
| :--- | :--- | :--- | :--- |
| `Test-SemVer.ps1` | Unit | `lib/semver.ps1` — constraint parsing, `^`/`~`/`=` operators, pre-1.0 safety, sentinel `-2` | 74/74 |
| `Test-Utilities.ps1` | Unit | `lib/util.ps1` — `Get-RomsRawArguments`, `Assert-RomsSecureUrl`, `Get-RomsFileHash`, `Set-RomsFileContent`, `Get-RomsResolvedUrl` | 25/25 |
| `Test-Alternatives.ps1` | Unit | `lib/alternatives.ps1` — `Manage-Shim`, `Register-Alternative`, `Unregister-Alternative`, auto-pivot | 22/22 |
| `Run-E2E.ps1` | Integration | Full lifecycle: `update`, `search`, `install`, `list`, `uninstall`, `source list` | 19/19 |
| `Negative-Cases.ps1` | Negative | Error paths: nonexistent packages, corrupted metadata, invalid inputs | 8/8 |

## Architecture

**Unit tests** (no live environment):
- `Test-SemVer.ps1` — Pure functions only. No filesystem, no network. Tests every constraint operator, pre-release precedence, and sentinel values.
- `Test-Utilities.ps1` — Uses isolated temp directories for file I/O and hash tests. Stubs `Write-Log` to capture log output in-process.
- `Test-Alternatives.ps1` — Uses isolated temp directories for `$ROMs_BIN`, `$ROMs_METADATA`, and `$ROMs_ALTS`. Creates fake `.exe` files for shim tests.

**Integration tests** (live `C:\roms` required):
- `Run-E2E.ps1` — Runs real `roms` commands via a subprocess. Tests the full install/uninstall lifecycle with the `helper` package from the official registry.
- `Negative-Cases.ps1` — Tests error handling against the live environment. Verifies graceful degradation for invalid inputs and corrupted state.

## How to Run

```powershell
# Unit tests (safe, no side effects)
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-SemVer.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-Utilities.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-Alternatives.ps1

# All unit tests in sequence
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-SemVer.ps1; `
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-Utilities.ps1; `
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-Alternatives.ps1

# E2E tests (modifies live environment — installs/uninstalls helper)
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Run-E2E.ps1

# Negative cases (modifies live environment temporarily)
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Negative-Cases.ps1
```

## Adding New Tests

1. **Unit test**: Add a new `Test-<Module>.ps1` file. Stub `Write-Log` before dot-sourcing the module under test. Use the `Report`/`Assert-Equal`/`Assert-True` pattern.
2. **E2E test**: Add new test blocks to `Run-E2E.ps1`. Use `Invoke-Roms` to run commands and check output/exit codes.
3. **Negative case**: Add new error-path blocks to `Negative-Cases.ps1`.

## Known Edge Cases

- `Get-RomsRawArguments`: The tunnel regex strips trailing `"` (shell-wrap cleanup), which breaks quoted arguments with spaces. The `&` in `"hello & world"` is treated as an unquoted operator. This is a known limitation of the tunnel recovery path.
- `Register-Alternative`: The command entry is preserved (with empty providers list) after all providers are removed, not deleted from the JSON.

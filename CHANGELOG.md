# Changelog - roms (Package Manager)

All notable changes to the `roms` package manager will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]
### Added
- **Industrial Diagnostic Standardization**:
  - Ported the refactored `Write-Log` with dual-target formatting (Pretty-RAW for Console, Tight-Inline for machine audits).
  - Enforced **"File-by-File Physical Truth"** for Level 2 (TRACE) logging, ensuring every individual file operation is audited.
  - Implemented **"Anti-Ghost"** diagnostics: all diagnostic logs are now physically verified via `Test-Path` before emission.
  - Synchronized all core paths to the standardized **`$global:ROMs_`** variable hierarchy.
- **Robustness**:
  - Hardened argument parsing and router logic using array sub-expressions `@($args | ...)` to prevent null-indexing crashes.
  - Standardized the purging of legacy variables (e.g., `$systemRoot`, `$metadataRoot`).

## [b00fc6c] - 2026-05-29
### Fixed
- **Interactive Redirection Cleanup:** The manager now detects accidental files created by unquoted SemVer constraints (e.g., `>1.0.0`), prompts for deletion via Stderr, and performs background cleanup after shell-lock release.

## [2232294] - 2026-05-29
### Fixed
- **Path and Pipeline Hardening:** 
    - Switched to absolute entry path resolution (`$PSCommandPath`) to ensure deterministic UAC elevation regardless of working directory.
    - Captured engine exit codes in the orchestration layer to suppress stray `0` outputs in console and audit logs.

## [v0.8.1-alpha | 0d55b9a] - 2026-05-28
### Fixed
- **Log-First Audit Strategy:** Refactored `lib/alternatives.ps1` to log shim removal intent *before* execution. This ensures the master audit log (`roms.log`) captures the removal process even if the standalone engine deletes the artifact before the manager's post-check.

## [v0.8.0-alpha | c4955ee] - 2026-05-28
### Added
- **Robust SemVer Resolution:** Implemented comprehensive support for Caret (`^`), Tilde (`~`), and version ranges in CLI requests.
- **Shell-Bridge Hardening:** Implemented industrial-strength quoting and redirection guards to protect special SemVer characters from being mangled during the CMD-to-PowerShell handoff.

## [d3ed04b] - 2026-05-28 
### Added
- **Transactional Rollback:** Implemented a global failure recovery system in the orchestrator. If a multi-package installation chain fails at any step, the manager now automatically uninstalls all previously successful dependencies from that session, ensuring a 100% clean system state.

### Fixed
- **Dependency String Hardening:** Updated the engine dependency check to strip version constraints (e.g., `:^1.0.0`) from package names. This allows the engine to correctly verify installed metadata even when requested with complex SemVer tags.
- **PowerShell String Safety:** Fixed a syntax error in the rollback logger where colons were misinterpreted as drive qualifiers; implemented delimited `${var}` syntax for robust logging.

## [v0.7.0-alpha | 98e7ec6] - 2026-05-27
### Added
- **SemVer 2.0 Engine:** Implemented an industrial-strength version resolution module (`lib/semver.ps1`) supporting caret (`^`), tilde (`~`), range (`>=`, `<=`, `>`, `<`), and wildcard (`*`) constraints.
- **Best-Match Selection:** Upgraded the registry discovery engine to collect all version candidates and select the highest satisfying version according to SemVer precedence.
- **Version-Locked Mapping:** Updated the recursive resolver to return explicit versioned identifiers (e.g., `name:version`), ensuring the orchestrator commits to the exact resolution found during the mapping phase.

### Fixed
- **Pre-release Ignoring (Legacy Logic):** Replaced the basic .NET `[version]` casting in `util.ps1` which incorrectly ignored pre-release tags and build metadata. The new engine uses segment-by-segment lexical and numeric comparison for full SemVer 2.0 compliance.
- **Constraint Loss:** Resolved a bug where the manager would default to the latest version of dependencies even if a specific constraint was provided, by ensuring constraints are passed through the entire mapping and acquisition lifecycle.

## [v0.6.1-alpha | aff7897] - 2026-05-27
### Fixed
- **Priority Registration:** Updated the installation orchestrator to correctly extract the `priority` field from package metadata and pass it to the Alternatives system. This enables automatic takeover by higher-priority providers.
- **Strict Auto-Pivot:** Refined the Alternatives switching logic to only pivot the active provider if the new candidate has a **strictly higher** priority than the current selection, preventing unwanted environment churn on equal priorities.
- **Dependency Schema Support:** Hardened the recursive resolver to support the Trinity v1.1.0 `packages` property in addition to legacy formats.

## [v0.6.1-alpha | 4f19d8f] - 2026-05-27
### Fixed
- **Strict Priority Comparison:** Replaced the sort-and-select auto-pivot logic in `lib/alternatives.ps1` with an explicit priority guard. The active provider is now only replaced if the incoming provider's priority is strictly greater than the current one, preventing inadvertent shim churn when equal-priority packages are installed.

## [v0.6.1-alpha | 6eb69eb] - 2026-05-27
### Fixed
- **Trinity `packages` Property Support:** Extended the dependency schema handler in `lib/resolver.ps1` to recognise the `packages` array key introduced in Trinity v1.1.0, in addition to the legacy `roms` key. Prevents dependency resolution failures for manifests using the newer schema.

---

## [v0.6.0-alpha | 328ed7e] - 2026-05-26
### Added
- **Truth-Verification Watchdog:** Implemented a manifest-driven integrity check that verifies engine files against their own metadata. This prevents "empty folder" false positives and ensures a robust self-healing bootstrap.
- **Sacred Ledger Audit:** Performed a full reconciliation of the project history to ensure 100% accuracy of commit hashes and task status.

## [v0.6.0-alpha | 31bf0a2] - 2026-05-26
### Changed
- **Command-Based Orchestration:** Refactored the core installation and uninstallation lifecycle to use the `Invoke-EngineCommand` wrapper, transitioning from script-pathing to global command resolution.
- **Same-Window Recovery:** Implemented automated session PATH synchronization, allowing the manager to use a bootstrapped engine immediately without a terminal restart.

## [v0.6.0-alpha | 2b1183c] - 2026-05-26
### Added
- **Command-Based Execution:** Implemented `lib/executor.ps1` with `Invoke-EngineCommand` to prioritize global command resolution over direct script paths.
- **Session PATH Synchronization:** Added automated `$env:PATH` refresh logic to ensure engine shims are immediately discoverable in the same terminal session.

## [v0.6.0-alpha | c30e455] - 2026-05-26
### Added
- **Engine Source Attribution:** Added explicit logging to identify if the standalone engine was sourced from the Official Registry or the GitHub Recovery API.

## [v0.6.0-alpha | 9dffc5b] - 2026-05-26
### Changed
- **Modular Foundations:** Relocated recovery and discovery logic to a dedicated `lib/bootstrap.ps1` module, enforcing Rule 5 of Modularity Standards (Side-Effect Isolation).
- **Loading Sequence:** Refactored the core router to follow the mandatory Foundation-First loading order for increased stability.

## [v0.6.0-alpha | 274f0c4] - 2026-05-25
### Fixed
- **Handshake Reporting:** Refactored orchestrator to use dynamic flag splatting, resolving the "Fake Error" where the manager reported failure despite engine success.

## [v0.6.0-alpha | b5df055] - 2026-05-25
### Added
- **Secure Engine Discovery:** Implemented deterministic path resolution in `util.ps1` to prevent environment injection attacks.
- **Dynamic Cloud Bootstrap:** Implemented `Initialize-RomsEngine` with live GitHub API discovery and .NET-powered extraction for architecture-specific recovery.
- **Self-Healing Startup:** Integrated automatic engine restoration into the core manager router for a zero-setup user experience.

## [v0.6.0-alpha | 0903717] - 2026-05-24
### Added
- **Modular Hook Orchestration:** Refactored the orchestrator to support the full 4-stage lifecycle (pre/post install & uninstall).
- **Log Contention Resilience:** Implemented a retry-logger with jitter in `core.ps1` to resolve the "Concurrent Log Lock" race condition between Manager and Engine.

---

## [v0.5.0-alpha | 257458a] - 2026-05-23
### Fixed
- **Registry Template Injection:** Hardened the template injector to correctly handle packages with empty `downloadUrl` strings, preventing resolution crashes.
- **Engine Orchestration:** Implemented mandatory exit-code verification for all `rmspkg` calls to ensure the manager correctly reports and halts on engine failures.

## [v0.5.0-alpha | 57534c7] - 2026-05-23
### Added
- **Trinity v1.1.0 Logic Sync**:
  - Implemented mandatory SHA256 and Size verification for all remote packages.
  - Standardized dependency resolution to support object-based manifest schemas.
  - Fixed shim creation bug by adding missing `Set-RomsFileContent` native utility.

---

## [v0.4.0-alpha | 886a810] - 2026-05-20
### Fixed
- **Absolute Path Enforcement:** Hardened the manager to ensure all registered alternative executables and shim targets are stored as absolute paths, preventing "Broken Shims."
- **Orchestration Stability:** Updated the installation lifecycle to force absolute path resolution for local `.rms` files before passing them to the engine.

## [v0.4.0-alpha | 714c0c9] - 2026-05-19
### Added
- **Atomic AVC Model:** Implemented the "Acquire-Verify-Commit" lifecycle for dependency resolution. Packages are staged to `C:\roms\temp\staging` and verified before any system modifications occur.
- **Recursive Resolver:** Implemented `resolver.ps1` for multi-tier dependency mapping with circular dependency detection.

### Changed
- **Pre-Install Verification:** The manager now aborts and cleans up the staging area if any dependency in the tree is missing or corrupted, ensuring zero system pollution.

---

## [v0.3.0-alpha | 6849299] - 2026-05-18
### Added
- **Recursive Dependency Resolution:** Implemented `resolver.ps1` module for automatic, multi-tier dependency fetching and installation.
- **Circular Dependency Detection:** Implemented stack-based guardrails to prevent infinite recursion in dependency chains.

### Fixed
- **Shim Migration Completion:** Fixed a variable inconsistency between `SHIM_DIR` and `BIN_DIR`.

## [v0.3.0-alpha | 03853f0] - 2026-05-15
### Added
- **Manual Provider Selection (`roms select`):** Implemented `Select-RomsAlternative` in `lib/logic.ps1` with full interactive mode — lists all managed commands with their current lock status, lets the user pick a numbered provider, and applies a manual lock. Supports `roms select <command> auto` to revert a locked command back to automatic mode.
- **Manual→Auto Safety Fallback:** If a manually-locked provider is uninstalled, the system automatically reverts that command to auto mode and promotes the next-best provider rather than leaving a broken shim.
- **Help Menu Updated:** Added `roms select <command> [pkg]` entry to the help output.
- **Router Updated:** Added `roms select` to the command routing table and elevated it alongside `install`/`uninstall` to require administrator privileges.

---

## [v0.3.0-alpha | 8b6062a] - 2026-05-16
### Added
- **Modular Refactor:** Decomposed monolithic logic into specialized library modules: `core`, `util`, `sync`, `discovery`, `alternatives`, and `orchestrator`.
- **Manual Locking (`roms select`):** Implemented interactive provider selection and shim locking.

---

## [v0.2.0-alpha | ff4a877] - 2026-05-15
### Added
- **Auto-Pivot:** Automatic shim redirection when the active provider for a command is uninstalled.
- **Improved Logging:** Master log (`roms.log`) tracks all system modifications with timestamps.

## [v0.2.0-alpha | f8f4862] - 2026-05-14
### Changed
- **Help Menu Styling:** Updated section headers in `lib/help.ps1` — "Usage:" and "Global Flags:" are now rendered in yellow (`USAGE:`, `GLOBAL FLAGS:`) for improved CLI readability.

## [v0.2.0-alpha | 231ce6c] - 2026-05-14
### Added
- **Manager-Side Shim Layer:** Implemented `Manage-Shim` in `lib/logic.ps1`. The manager now directly writes `.bat` shim files to `C:\roms\bin`, handling both `.ps1` and native executable targets. Returns the shim path as an artifact for transaction tracking.
- **Alternatives Registration:** Implemented `Register-Alternative` — after the engine reports a successful install via JSON, the manager parses the report and registers each executable as a provider in the alternatives database, creating shims immediately.
- **UAC Elevation Utility:** Implemented `Confirm-RomsElevation` in `lib/core.ps1`. Detects if the session lacks administrator rights and re-launches the script with `RunAs`, forwarding all original arguments verbatim.
- **Engine Delegation:** The install flow now calls `rmspkg install <path> -noShim`, parses the structured JSON report, and delegates shim creation entirely to the manager layer.

---

## [v0.1.0-alpha] - 2026-05-14
### Added
- **Initial Release:** Core `roms` CLI router with `install`, `uninstall`, and `list` capabilities.
- **Speed Search:** Remote registry synchronization with local caching.

## [v0.1.0-alpha | af58b6b] - 2026-05-13
### Added
- **Alternatives Database Persistence:** Implemented `Get-AlternativesData` and `Set-AlternativesData` helpers in `lib/logic.ps1` using `.NET` native IO (`[System.IO.File]`) for reliable read/write of `alternatives.json`. Added `$global:ALTERNATIVES_FILE` path constant to `lib/core.ps1`.

## [v0.1.0-alpha | ee9ead6] - 2026-05-13
### Fixed
- **Router Array Unwrapping Bug:** Fixed a PowerShell coercion issue in `roms.ps1` where a single-element argument array was being unwrapped into a bare string. Changed `[array](...)` cast to `@(...)` to enforce array type and prevent argument-parsing failures in sub-commands.

## [v0.1.0-alpha | e9cced5] - 2026-05-13
### Added
- **Remote Package Install:** `Invoke-RomsInstall` (renamed from `Install-Package`) now resolves packages by name from the local registry cache. Downloads the `.rms` file, performs SHA256 integrity verification using native `.NET` crypto, and aborts on mismatch.
- **Command-Based CLI Standard:** Install and uninstall calls to `rmspkg` now use subcommand syntax (`rmspkg install <path>`, `rmspkg uninstall <name>`) instead of positional flag passing.
- **Internal Namespace Protection:** Added help-as-default routing and input guards to prevent empty or internal command strings from reaching the engine.

## [v0.1.0-alpha | 35b7cb7] - 2026-05-12
### Added
- **Multi-Source Registry Synchronization (`roms update`):** Implemented `Update-Registry` and `Initialize-Sources` in `lib/logic.ps1`. On first run, bootstraps a default `sources.json` pointing to the official registry. On update, iterates all sources and caches their index files to `C:\roms\cache\`.
- **Package Discovery (`roms search`):** Implemented `Search-Packages` — queries all cached `.index.json` files, annotates each result with its source name, and renders a formatted table. Warns if the cache is empty and prompts `roms update`.
- **Path & Registry Constants:** Added `$global:SOURCES_FILE`, `$global:OFFICIAL_REPO`, and corrected cache path to `$global:CACHE_DIR = C:\roms\cache` in `lib/core.ps1`.

## [v0.1.0-alpha | 72124ea] - 2026-05-12
### Added
- **Initial Modular Release:** Created the foundational file structure: `roms.ps1` (CLI entry point), `roms.bat` (Windows launcher shim), `lib/core.ps1` (global constants, logging, transaction lock), `lib/help.ps1` (help output), `lib/logic.ps1` (install/uninstall/list stubs).
- **CLI Router:** `roms.ps1` dispatches `list`, `install`, `uninstall`, and `help` commands with argument parsing and global flag support (`-y`, `-v`).
- **Transaction System:** `Enter-RomsTransaction` / `Exit-RomsTransaction` in `lib/core.ps1` provides a file-based lock at `C:\roms\roms.lock` to prevent concurrent modifications.
- **Structured Logging:** `Write-Log` in `lib/core.ps1` writes timestamped, severity-tagged entries to `C:\roms\logs\roms.log` with retry-on-lock resilience.
- **Package Listing:** `List-Packages` reads installed package metadata from `C:\roms\.metadata\` and renders a formatted table.

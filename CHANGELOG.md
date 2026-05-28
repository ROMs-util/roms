# Changelog - roms (Package Manager)

All notable changes to the `roms` package manager will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v0.5.1] - 2026-05-27

### [aff7897] - 2026-05-27
- **fix:** Registry & Manager Priority Alignment.
- **logic:** Updated the installation orchestrator to correctly extract the `priority` field from package metadata.
- **logic:** Passed explicit priority to the Alternatives system during registration, enabling correctly ranked apps to take over shims.

### [4f19d8f] - 2026-05-27
- **fix:** Fix Alternatives Auto-Pivot logic.
- **logic:** Updated `Register-Alternative` to only pivot the active provider if the new one has a **strictly higher** priority than the current selection, preventing unnecessary environment churn.

### [6eb69eb] - 2026-05-27
- **fix:** Fix Dependency Resolution Schema Mismatch.
- **logic:** Updated `Get-RomsDependencyList` in `resolver.ps1` to support both `.packages` and `.roms` for normalization.

---

## [v0.5.0] - 2026-05-26

### [328ed7e] - 2026-05-26
- **feat:** Truth-Verification Watchdog (Course Correction).
- **logic:** Refactored `Test-RomsEngineIntegrity` to use the engine's metadata (`.metadata/rmspkg.json`) as a manifest.
- **logic:** Recursively verify every file listed in the manifest exists to prevent false positives from empty directories.

### [31bf0a2] - 2026-05-26
- **feat:** Command-Based Orchestrator Refactor.
- **logic:** Decouple the orchestrator from static file paths, prioritizing global command resolution.
- **logic:** Implement automated session `$env:PATH` synchronization for immediate discovery of bootstrapped shims.

### [2b1183c] - 2026-05-26
- **feat:** Command-Based Execution Bridge.
- **logic:** Implemented `lib/executor.ps1` with `Invoke-EngineCommand` to prioritize global command resolution.

### [c30e455] - 2026-05-26
- **feat:** Truth Verification & Source Attribution.
- **logic:** Implement "Source Attribution" logging in recovery logic (Registry vs GitHub API).
- **logic:** Confirmed "Cold boot" explicit logging: `[SUCCESS] Standalone Engine sourced from official cloud registry`.

### [9dffc5b] - 2026-05-26
- **refactor:** Modular Refactor of Manager Recovery Foundations.
- **logic:** Relocate `Get-RomsEnginePath` and `Initialize-RomsEngine` to a dedicated `lib/bootstrap.ps1` feature module.
- **logic:** Purge all IO and global state modification from `util.ps1` to restore it to a "Pure Foundation" state per Modularity Rule 5.

---

## [v0.4.1] - 2026-05-25

### [274f0c4] - 2026-05-25
- **fix:** Handshake & Positional Argument Integrity.
- **logic:** Refactored orchestrator call-sites to use dynamic splatting to correctly transmit user intent (`--yes`, `--verbose`).
- **logic:** Resolved character-indexing errors where the engine misinterpreted input as package names.

### [b5df055] - 2026-05-25
- **feat:** Robust Discovery & Dynamic Cloud Bootstrap.
- **logic:** Implement Strict Deterministic Discovery (`C:\roms\rmspkg\rmspkg.ps1`).
- **logic:** Implement Multi-Stage Hybrid Bootstrap (Registry -> Dynamic GitHub API discovery).
- **logic:** Implement Native .NET extraction to break the circular engine dependency.

---

## [v0.4.0] - 2026-05-24

### [0903717] - 2026-05-24
- **feat:** Modular Hybrid Lifecycle Hooks.
- **logic:** Implemented `lib/hooks.ps1` feature module for discovery and execution.
- **logic:** Implemented retry logic in the core logger to handle concurrent writes and resolve log contention in `package_manager/lib/core.ps1`.

### [257458a] - 2026-05-23
- **fix:** Engine Hook & Rollback Hardening.
- **logic:** Updated Manager `orchestrator.ps1` to explicitly verify Engine exit codes and fix template injection for empty `downloadUrl` strings.

### [57534c7] - 2026-05-23
- **feat:** Trinity v1.1.0 Logic & Manifest Sync.
- **logic:** Updated `package_manager/lib/orchestrator.ps1` for mandatory SHA256/Size verification.
- **logic:** Standardized dependency resolution to support object-based manifest schemas.
- **logic:** Implemented missing `Set-RomsFileContent` function in `util.ps1` using native .NET `File::WriteAllText`.

---

## [v0.3.1] - 2026-05-20

### [886a810] - 2026-05-20
- **fix:** Path Resolution Hardening.
- **logic:** Enforced `.NET [System.IO.Path]::GetFullPath` for all application directories, executables, and shim targets.
- **logic:** Standardized on "Name-as-Folder" model for absolute path resolution.

### [714c0c9] - 2026-05-19
- **feat:** Phase D: Dependency Resolution (Atomic AVC).
- **logic:** Switched to a 3-phase lifecycle (Map -> Acquire -> Commit). 
- **logic:** All `.rms` files are staged to `C:\roms\temp\staging` and verified before any system modifications occur.

---

## [v0.2.1] - 2026-05-18

### [6849299] - 2026-05-18
- **refactor:** Phase 4: Architectural Hardening.
- **logic:** Decomposed monolithic logic into specialized library modules: `util`, `sync`, `discovery`, `alternatives`, and `orchestrator`.
- **logic:** Implemented recursive dependency mapping with circular dependency detection in `resolver.ps1`.

---

## [v0.2.0] - 2026-05-16

### [03853f0] - 2026-05-15
- **feat:** Manual Locking (`roms select`).
- **logic:** Implemented interactive provider selection and shim locking.
- **logic:** Verified automatic safety fallback to auto-mode on uninstallation of locked providers.

### [ff4a877] - 2026-05-14
- **feat:** Phase 3: Environment Orchestration.
- **logic:** Implemented Alternatives system for tracking multiple providers of the same command.
- **logic:** Implemented Auto-Pivot logic for shim management with registry collision fixes and persistence hardening.

### [f8f4862] - 2026-05-14
- **style:** Documentation Overhaul (Persona-Driven).
- **logic:** Standardized User/Developer README and finalized App Reference implementation docs.
- **logic:** Standardized ROMs-util help template and usage menus for CLI cohesion.

### [231ce6c] - 2026-05-14
- **feat:**  CLI Router (roms).
- **logic:** Implement manager-side shimming and engine delegation logic.
- **logic:** Implemented basic install/uninstall routing to the `rmspkg` engine.

---

## [v0.1.0] - 2026-05-13

### [af58b6b] - 2026-05-13
- **feat:** Alternatives Persistence.
- **logic:** Implemented Alternatives database persistence using native .NET IO for atomic writes and structured data integrity.

### [ee9ead6] - 2026-05-13
- **fix:** Router Deserialization hardening.
- **logic:** Prevented PowerShell 5.1 from unwrapping single-element dependency arrays into strings during JSON conversion.

### [e9cced5] - 2026-05-13
- **feat:** High-level Manager Initial Foundation.
- **logic:** Implemented remote installation and command-based CLI routing.
- **logic:** Established internal namespace protection (`Invoke-Roms*`) for logic-heavy functions.

### [35b7cb7] - 2026-05-12
- **feat:** Multi-source Registry Synchronization.
- **logic:** Implemented registry synchronization (`update`) and package discovery (`search`) with local caching.

### [72124ea] - 2026-05-12
- **feat:** Initial Release.
- **logic:** Core CLI router foundations and transactional extraction engine connection.
- **logic:** Established `C:\roms` ecosystem root and directory structure.

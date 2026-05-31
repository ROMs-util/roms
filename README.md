# ROMs Package Manager (`roms`)

> The high-level orchestrator and "Intelligence" layer of the ROMs ecosystem.

`roms` is the user-facing command-line tool designed to manage the full lifecycle of utility applications on Windows. It handles discovery, remote synchronization, dependency resolution, and environment orchestration through a Linux-style Alternatives system.

---

## 👤 User Guide
This guide covers installation and daily operations for end-users.

### 1. Getting Started
- **Root Directory:** All ROMs-util apps are installed to `C:\roms\`.
- **System PATH:** Ensure **`C:\roms\bin`** is added to your User or System Environment Variables. This allows you to run installed apps from any terminal.
- **First Run:** Launch `roms` with Administrator privileges. It will self-bootstrap the standalone engine if needed.

### 2. Global Flags
These flags work with all commands:

| Flag | Description |
| :--- | :--- |
| `-v` | Verbose output (shows DEBUG messages) |
| `-vv` | Very verbose (shows TRACE messages) |
| `-vvv` | Raw output (shows RAW messages and JSON) |
| `-h`, `--help` | Show help for the command |
| `--version` | Show version information |

### 3. Common Commands

| Command | Description |
| :--- | :--- |
| `roms help` | Show help menu with all available commands. |
| `roms list` | List all currently installed packages. |
| `roms update` | Sync with remote registries to fetch the latest package indexes. |
| `roms search <query>` | Find packages in the registry matching a name or description. |
| `roms install <name>` | Download and install a package by name from the registry. |
| `roms install <path>` | Install a local `.rms` package file. |
| `roms uninstall <name>` | Completely remove an app and its associated shims. |
| `roms select <command>` | Manually choose which provider to use for a shared command. |

### 4. Managing Alternatives (`roms select`)
If multiple packages provide the same command (e.g., two versions of a tool), `roms` uses an Alternatives system:
- **Auto Mode:** Automatically uses the provider with the highest priority.
- **Manual Mode:** Users can "lock" a command to a specific package using `roms select <command>`.
- **Auto-Pivot:** If you uninstall your locked choice, `roms` automatically switches to the next best available provider so the command doesn't break.

### 5. Environment Variables
| Variable | Description | Default |
| :--- | :--- | :--- |
| `ROMs_ROOT` | Ecosystem root directory | `C:\roms` |
| `ROMs_CACHE` | Registry index cache | `C:\roms\cache` |
| `ROMs_BIN` | Command shims directory | `C:\roms\bin` |
| `ROMs_METADATA` | Package metadata registry | `C:\roms\.metadata` |
| `ROMs_LOGS` | Log files directory | `C:\roms\logs` |
| `ROMs_TEMP` | Temporary workspace | `C:\roms\temp` |

### 6. Troubleshooting
- **Elevation:** Most `roms` operations require Administrator privileges for disk writes. A UAC prompt will appear; the elevated window will stay open (`-NoExit`) so you can review the results.
- **System Busy:** If you see "Another ROMs operation is running," it means a lock file exists. If no other `roms` window is open, you can manually delete `C:\roms\temp\roms.lock`.
- **Logs:** Review the master log at `C:\roms\logs\roms.log` for detailed error information.
- **Engine Missing:** If `rmspkg` is not found, `roms` will automatically attempt to self-heal by downloading the latest version.
- **Registry Outdated:** Run `roms update` to fetch the latest package indexes from all configured sources.

### 7. Examples
```powershell
# List installed packages
roms list

# Search for a package
roms search git

# Install from registry
roms install git

# Install from local file
roms install C:\Downloads\package-v1.0.0.rms

# Update registry indexes
roms update

# Select alternative provider
roms select git

# Uninstall a package
roms uninstall git

# Show verbose debug output
roms install git -vvv
```

---

## 🛠️ Developer Guide
This guide is for developers extending the manager or integrating it with other tools.

### 1. Architecture: The Tiered Model
`roms` is the High-level Manager: it handles the logic and "Intelligence," but delegates the "Physics" (extraction and file writes) to the Standalone Engine, **`rmspkg`**.

- **Router:** `roms.ps1` handles argument parsing and command routing.
- **Orchestrator:** `lib/orchestrator.ps1` contains the main installation and uninstallation lifecycle logic.
- **Core:** `lib/core.ps1` manages global constants, colorized logging, and the Transaction/Lock system.
- **Registry:** `lib/sync.ps1` and `lib/discovery.ps1` handle remote registry synchronization and package search.
- **Resolver:** `lib/resolver.ps1` provides recursive dependency resolution.
- **Alternatives:** `lib/alternatives.ps1` manages the Linux-style command alternatives system.
- **Utilities:** `lib/util.ps1` (hashing, file I/O, URL resolution), `lib/semver.ps1` (version parsing/comparison), `lib/bootstrap.ps1` (engine integrity and recovery), `lib/executor.ps1` (engine command forwarding), `lib/help.ps1` (CLI help).

### 2. Transaction Integrity
To prevent registry corruption, all modifying commands are wrapped in a transaction:
1. **`Enter-RomsTransaction`**: Creates a global lock file with the current PID.
2. **`Confirm-RomsElevation`**: Ensures the process has the necessary permissions.
3. **`Exit-RomsTransaction`**: Releases the lock on completion or failure.

### 3. Module Dependency Flow
```
roms.ps1 (Router)
    |
    +---> lib/help.ps1 (Show-Help)
    |
    +---> lib/core.ps1 (Write-Log, Enter/Exit-RomsTransaction, Confirm-RomsElevation)
    |
    +---> lib/bootstrap.ps1 (Test-RomsEngineIntegrity, Get-RomsEnginePath, Initialize-RomsEngine)
    |
    +---> lib/executor.ps1 (Invoke-EngineCommand)
    |
    +---> lib/sync.ps1 (Initialize-Sources, Update-Registry)
    |
    +---> lib/discovery.ps1 (Search-Packages, List-Packages)
    |
    +---> lib/resolver.ps1 (Get-RomsDependencyList)
    |
    +---> lib/alternatives.ps1 (Register-Alternative, Unregister-Alternative, Select-RomsAlternative)
    |
    +---> lib/orchestrator.ps1 (Invoke-RomsInstall, Invoke-RomsUninstall)

```

### 4. Standards
- **.NET Rule:** All integrity checks (SHA256) and file streams MUST use native .NET namespaces for performance and version independence.
- **Modularity:** New features should be added as functions in the appropriate `lib/*.ps1` module and routed via `roms.ps1`.
- **Bilingual Flags:** All tools must support `--long-flag` (Public) and `-NativeFlag` (Internal) using `[Alias()]`.
- **Surgical Edits:** Never reformat or re-indent untouched lines when fixing code.

### 5. Contributing
1. Add new functions to the appropriate module in `lib/`.
2. Add comprehensive comments explaining HOW IT WORKS.
3. Export the function from the main `roms.ps1` if it's a new command.
4. Test with `-vvv` flag to verify RAW output logging.
5. Update this README if adding new commands or changing architecture.

---

## 📚 See Also
- [ROMs-util Documentation](https://github.com/ROMs-util/roms-docs/blob/main/README.md)
- [Standalone Engine](https://github.com/ROMs-util/rmspkg/blob/main/readme.md)
- [Package Builder](https://github.com/ROMs-util/rms-builder/blob/main/README.md)
- [Registry Indexer](https://github.com/<owner>/ROMs-util/blob/main/package_registry/README.md)

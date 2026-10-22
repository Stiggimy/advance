# Changelog

All notable changes to Advance will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.35] — 2026-10-22

### Added
- **XDG Base Directory Support**: Configuration, data, state, and cache paths now honor `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` (as well as `ADVANCE_*_DIR` overrides) with automatic one-time migration from legacy paths (`lib/xdg.sh`).
- **Arch Linux Packaging (`PKGBUILD`)**: Added VCS `PKGBUILD`, `.SRCINFO`, and `advance-git.install` for system-wide Arch Linux installation (`makepkg -si`).
- **In-App Changelog Browser & Release Notes**: Added `advance changelog` subcommand, `--changelog` flag, interactive FZF release notes browser in `advance config`, and automatic "What's New" highlights after `advance self-update`.
- **`NO_COLOR` Standard Support**: Automatically disables ANSI color sequences when the `NO_COLOR` environment variable is set.

### Changed
- **FZF Menu & Preview Performance**: Cached catalog drift checks per session, eliminated `sed`/`find`/`grep` subshell lookups during FZF cursor movement via hidden tab-delimited metadata columns, cached static previews in `advance config`, and replaced external process spawns in the catalog and changelog browsers with pure-bash/awk parsing.
- **Catalog Tool Path & Check Fallbacks**: Updated `pnpm`, `pipx`, and `cargo` catalog recipes to respect tool-specific home variables (`PNPM_HOME`, `PIPX_HOME`, `CARGO_HOME`), and added `-Qu` fallback to `pacman`, `paru`, and `yay` when `checkupdates` is not installed.
- **Packaged Install Guard**: `advance self-update` now detects system-wide package installations and advises updating via the system package manager.

### Fixed
- **Safe `DEFAULTS` Argument Parsing**: Parsed `DEFAULTS` via `read -r -a` to avoid unquoted glob expansion and word-splitting edge cases.
- **Atomic Configuration Writes**: `save_config` now writes to a temporary file and atomically renames it into place with sorted group keys.

## [0.9.34] — 2026-10-21

### Added
- **Interactive Check Updates Configuration Flow**: Added guided presets (Always Run, Output-Based, and Exit-Code detection), timeout customization, and a 15-second live test runner to both the Custom Manager Wizard and Manager Edit menus.
- **Priority Reordering Hotkeys & Badges**: Added direct `Alt+Up` and `Alt+Down` (`Ctrl+Up`/`Ctrl+Down`) keyboard shortcuts in the configuration menu to reorder priority groups and package managers with live cursor tracking, visual execution order badges (`[★ Active Winner]`, `[↳ Standby #N]`, `[#1]`), and automatic conflict-free priority assignment.
- **Companion Self-Update Synchronization**: `advance self-update` now automatically verifies and updates companion tool Checkpoint when installed.
- **Dynamic Service Probing**: Added runtime evaluation of `PROBE_ACTIVE_CMD` in package manager recipes to verify active daemon or service states before scheduling updates.
- **In-App Changelog Browser**: Added `advance changelog` subcommand, `--changelog` flag, and interactive version browser in `advance config`.

### Changed
- **Hardened Self-Update Engine**: Explicitly pulls the current upstream tracking branch and cleanly aborts without installing stale code if network or pull errors occur.
- **Configuration Hub Memory Safety**: Replaced temporary files in configuration previews with in-memory environment buffers, preventing buffer loss on menu cancellation.
- **Documentation & CLI Parity**: Standardized command descriptions, column alignment, troff man page references (`advance.1`), and README usage examples across all platforms.

### Fixed
- **WSL Quoting & Piping**: Resolved bash syntax and pipe evaluation issues when executing automated confirmation wrappers.
- **Parser Trailing Newlines**: Added non-empty line guards to configuration parsers so recipe and settings files without trailing newlines parse reliably.
- **Preview Metadata Lookup**: Implemented fallback metadata lookup by recipe name to eliminate empty previews when display titles differ from filenames.

## [0.9.33] — 2026-10-20

### Added
- **Native Windows Shipping Pipeline**: Added `ship.ps1` with feature parity to `ship.sh` for native pre-flight validation, syntax checks, and dual-remote publishing without WSL overhead.
- **Dynamic Repository Resolution**: Updated repository resolution to locate source directories relative to the executing script.

## [0.9.32] — 2026-10-20

### Added
- **Guided Custom Manager Wizard**: Redesigned custom manager creation into a 5-step guided walkthrough with automatic binary detection, wrapper stripping, and conflict validation.
- **Interactive Flags & Extras Editor**: Added non-destructive configuration editing submenus that preserve untouched values.

## [0.9.29] — 2026-10-20

### Added
- **Multi-Tier Network Connectivity Check**: Implemented default route verification, NetworkManager connectivity checks, DNS resolution via system resolver, and distro HTTP fallbacks.
- **Non-Interactive Manager Declarations**: Added declarative `FLAGS_AUTO_CONFIRM=none` schema to prevent redundant warnings on non-interactive managers.

## [0.9.25] — 2026-10-20

### Changed
- **Headless Environment Guard**: Prevented menu hangs in headless environments by alerting and exiting gracefully.
- **Package Hold Cleanup**: Guaranteed automatic release of temporary package manager holds on interruption or abort signals.

## [0.9.1] — 2026-10-15

### Added
- **Modular Multi-File Architecture**: Decomposed core functionality into modular libraries with lazy-loaded configuration wizards.
- **3-Tier Manager Catalog**: Introduced upstream catalog recipes, active symlink enrollment, and custom drop-in overrides with automatic discovery.
- **Transactional Porcelain IPC**: Added machine-readable communication contracts with Checkpoint for pre- and post-update safety snapshots.

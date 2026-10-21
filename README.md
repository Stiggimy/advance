# Advance

**Universal Modular System Update Manager**

Advance is a modern, modular, distro-agnostic update orchestrator for Linux. It automates the complex task of keeping a system up to date while ensuring safety through automated snapshots, priority-based group management with fallback, package exclusion rules, and automated failure recovery.

---

## Key Features

- 🧩 **100% Modular Plugin Architecture:** No hardcoded manager logic. All package managers (`pacman`, `yay`, `paru`, `apt`, `dnf`, `flatpak`, `npm`, `pnpm`, etc.) are `.conf` plugins organized into directory-based groups.
- 🎯 **Smart Group & Priority Resolution:**
  - Managers inside `managers.d/<group>/` compete by priority (highest priority available wins).
  - Standby managers automatically step in via **[F] Fallback** if the active manager fails during updates.
  - Force-run multiple managers from the same group using repeatable `--only <manager>` flags.
- 🛡️ **Safety & Snapshots:** Deep integration with [`checkpoint`](https://github.com/Stiggimy/checkpoint) for transactional pre/post snapshot pairing via porcelain IPC, supporting Snapper and Timeshift (BTRFS and RSYNC) with retention policies and minimum age thresholds.
- 🔁 **Advanced Error Escalation:**
  - Interactive retry menu on failure:
    - `[R] Retry` — Re-execute command
    - `[O] Override` — Apply force/conflict override flags
    - `[I] Interactive` — Strip non-interactive flags for manual confirmation
    - `[F] Fallback` — Switch to next available manager in group
    - `[S] Skip` / `[A] Abort`
- 🚫 **Unified Package Exclusions:** Exclude problematic packages on the fly (`-ex <pkg>`), via config (`EXCLUDE_PACKAGES`), or via `~/.config/advance/excludes`. Automatically mapped to manager-native exclusion flags.
- 🌐 **Pre-flight Connectivity Check:** Verifies network before checking or applying updates to prevent hung scripts.
- ⚙️ **FZF Menus & Scheduling:** Rich interactive configuration hub (`advance config`) with a guided custom package manager wizard, non-destructive flag tuning, and systemd auto-update scheduler (`advance schedule`).

---

## Directory & Group Structure

Groups are defined by **subdirectories** inside `~/.config/advance/managers.d/`:

```
~/.config/advance/managers.d/
├── system/                  ← GROUP: system (highest priority available wins)
│   ├── pacman.conf          (priority: 0)
│   ├── yay.conf             (priority: 10)
│   ├── paru.conf            (priority: 15)
│   ├── apt.conf             (priority: 0)
│   └── dnf.conf             (priority: 0)
├── flatpak/                 ← GROUP: flatpak
│   └── flatpak.conf         (priority: 0)
├── node/                    ← GROUP: node
│   ├── npm.conf             (priority: 0)
│   └── pnpm.conf            (priority: 10)
└── my-custom-tool.conf      ← STANDALONE (always runs if enabled)
```

Groups execute in order of their group priority (configured in `~/.config/advance/config` via `GROUP_PRIORITY_<group>=<number>`, or interactively in `advance config`). By default, `system` runs first (priority 100), followed by other groups (priority 50).

### Plugin Format

Each `.conf` file defines manager behavior:

```ini
NAME=Yay
EMOJI=🖥️
REQUIRES_CMD=yay          # Binary required for manager to be considered available
PRIORITY=10               # Higher value wins within group (must be unique per group)
CHECK_CMD=checkupdates 2>/dev/null; yay -Qua 2>/dev/null
UPDATE_CMD=yay -Syu
FLAGS=--needed
AUTO_CONFIRM=
FLAGS_AUTO_CONFIRM=--noconfirm
FLAGS_INTERACTIVE=
FLAGS_OVERRIDE=--overwrite '*'
COLOR_FLAG=--color=always
EXCLUDE_FLAG=--ignore
EXCLUDE_JOIN=,
ENABLED=true
```

---

## Installation

### Recommended

Clone the repository and run the installer:

```bash
git clone https://github.com/Stiggimy/advance.git
cd advance
./install.sh
```

The installer automatically creates symlinks, deploys the man page, and enrolls detected package managers from the official catalog.

> **Tip:** Install [`checkpoint`](https://github.com/Stiggimy/checkpoint) alongside Advance for automated snapshot support.

---

## Usage

```bash
advance [OPTIONS] [SUBCOMMAND]
```

### Command-Line Options

#### Modes & Target Selection
| Option | Description |
|---|---|
| `-ch, --check` | Check for updates without applying them (add `-v` to list packages; no sudo required) |
| `-o, --only <mgr>` | Run specific package manager (repeatable; bypasses group mutual exclusion) |
| `-og, --only-group <group>` | Run specific group (repeatable) |
| `-n, --no <mgr>` | Skip specific package manager (repeatable; falls back to standby) |
| `-ng, --no-group <group>` | Skip specific group (repeatable) |

#### Phase Control
| Option | Description |
|---|---|
| `-oprs, --only-pre-snapshot` | Create pre-update snapshot only and exit |
| `-ops, --only-post-snapshot` | Create post-update snapshot only and exit |
| `-nprs, --no-pre-snapshot` | Skip pre-update snapshot |
| `-ns, --no-snapshot` | Skip post-update snapshot |
| `-nc, --no-cleanup` | Skip automatic snapshot cleanup |

#### Snapshot Modifiers
| Option | Description |
|---|---|
| `-fprs, --force-pre-snapshot` | Force pre-snapshot creation regardless of minimum age threshold |
| `-fs, --force-snapshot` | Force post-snapshot creation |
| `-kprs, --keep-pre-snapshot` | Mark pre-update snapshot with `[KEEP]` tag (protects from routine cleanup) |
| `-ks, --keep-snapshot` | Mark post-update snapshot with `[KEEP]` tag |
| `-fd, --force-delete` | Allow deletion of `[KEEP]` protected snapshots during cleanup |
| `-k, --keep <N>` | Temporarily override snapshot retention limit |

#### Update Modifiers & General
| Option | Description |
|---|---|
| `-ef, --extra-flag <mgr:flag>` | Append extra CLI flag to manager for this run (repeatable) |
| `-nef, --no-extra-flags <mgr>` | Clear configured extra flags for manager for this run (repeatable) |
| `-ex, --exclude <pkg>` | Exclude package from updates for this run (repeatable) |
| `-i, --interactive` | Force manual confirmation mode for all managers |
| `-v, --verbose, --debug` | Enable detailed debug logging |
| `-V, --version` | Print version and build number, then exit |
| `-h, --help` | Display command usage and option summary |

### Quick Modes
```bash
advance                 # Run full update workflow
advance --check, -ch    # Survey sources and check for updates only (no sudo)
advance -ch -v          # Check for updates and list available packages
```

### Target Selection
```bash
advance -o yay                   # Only run Yay
advance -o yay -o pacman         # Force-run both Yay and Pacman (bypasses group exclusion)
advance -og system               # Only run the system group winner
advance -n yay                   # Skip Yay (falls back to next in system group, e.g. Paru/Pacman)
advance -ng flatpak              # Skip the entire flatpak group
```

### Modifiers & Exclusions
```bash
advance -ef yay:--devel             # Append extra flag to manager for this run
advance -nef yay                    # Clear extra flags for manager for this run
advance -ex linux -ex nvidia        # Exclude packages from system update
advance -i, --interactive           # Force manual confirmation mode for all managers
advance -v, --verbose               # Enable debug output
```

### Subcommands
```bash
advance config                      # Interactive settings & priority hub (Alt+Up/Down to reorder)
advance config export [mgr|--all]   # Export manager configs
advance config import <file|url>    # Import manager configs
advance catalog                     # Official recipe catalog (list, scan, enroll, remove)
advance catalog scan                # Auto-detect and enroll installed package managers
advance schedule                    # Setup background auto-update timers
advance self-update                 # Pull latest git changes and reinstall
```

---

## Documentation

Full documentation is available via the manual:
```bash
man advance
```
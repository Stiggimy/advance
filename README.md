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
    - `[U]nlock` — Detect and safely remove verified orphaned lock files before retrying
    - `[R]etry` — Re-execute command
    - `[O]verride` — Apply force/conflict override flags
    - `[I]nteractive` — Strip non-interactive flags for manual confirmation
    - `[F]allback` — Switch to next available manager in group
    - `[E]dit` — Pre-populate and edit the failing command on the fly
    - `[S]kip` / `[A]bort`
- 🚫 **Unified Package Exclusions:** Exclude problematic packages on the fly (`-ex <pkg>`), via config (`EXCLUDE_PACKAGES`), or via `$XDG_CONFIG_HOME/advance/excludes`. Automatically mapped to manager-native exclusion flags.
- ⏱️ **Smart Stalled-Command Watchdog:** Monitors update processes for output activity. When commands freeze (dead mirrors, hung TCP sockets, or silent prompts), triggers an attention alert with in-band prompt (`[W]ait`, `[T]erminate & Escalate`, `[A]bort`).
- 📁 **XDG-Aware:** Configuration, data, cache, and state follow the XDG Base Directory specification.
- 🧙 **Granular Custom Manager Wizard:** Guided step-by-step walkthrough (`advance config`) or Quick Setup with smart defaults, auto-inferred binaries (`_infer_required_binary`), and advanced engine settings (`PROBE_ACTIVE_CMD`, `LOCK_FILE`, `STALL_TIMEOUT`, `EXCLUDE_HOLD_CMD`, `POST_UPDATE_MSG`).
- 🔄 **Smart Self-Update Detector:** Asynchronous background check against upstream tracking branch with 6-hour caching, interactive `[Y/n/a/d]` prompt, notification banner, or auto-update mode (`advance config`).
- 🌐 **Pre-flight Connectivity Check:** Verifies network before checking or applying updates to prevent hung scripts.
- ⚙️ **FZF Menus & Scheduling:** Rich interactive configuration hub (`advance config`) with priority reordering (`Alt+Up`/`Alt+Down`), non-destructive flag tuning, and systemd auto-update scheduler (`advance schedule`).

---

## Directory & Group Structure

Groups are defined by **subdirectories** inside `$XDG_CONFIG_HOME/advance/managers.d/` (default: `~/.config/advance/managers.d/`):

```
$XDG_CONFIG_HOME/advance/managers.d/
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

Groups execute in order of their group priority (configured in `$XDG_CONFIG_HOME/advance/config` via `GROUP_PRIORITY_<group>=<number>`, or interactively in `advance config`). By default, `system` runs first (priority 100), followed by other groups (priority 50).

### Plugin Format

Each `.conf` file defines declarative manager behavior:

```ini
NAME=Yay
EMOJI=🖥️
REQUIRES_CMD=yay             # Binary required for manager to be considered available
PROBE_ACTIVE_CMD=            # Optional custom service/status probe command
PRIORITY=10                  # Higher value wins within group (must be unique per group)
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
EXCLUDE_HOLD_CMD=            # Optional command to hold excluded packages before update
EXCLUDE_UNHOLD_CMD=          # Optional command to release held packages after update
POST_UPDATE_MSG=             # Optional notice shown to user after updating this manager
LOCK_FILE=/var/lib/pacman/db.lck  # Optional existence-based lock file for orphaned lock recovery
STALL_TIMEOUT=180            # Optional inactivity watchdog timeout in seconds (0 = disabled)
ENABLED=true
```

---

## Installation

### Recommended (One-Line Public Installer)

Install Advance (and optionally its companion snapshot manager Checkpoint) requiring only standard tools (`bash`, `tar`, and `curl` or `wget` — no `git` or `gh` needed):

```bash
curl -fsSL https://raw.githubusercontent.com/Stiggimy/advance/master/bootstrap.sh | bash
```

To install both Advance and Checkpoint non-interactively in a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/Stiggimy/advance/master/bootstrap.sh | bash -s -- --with-checkpoint
```

Or download and inspect the installer first:

```bash
curl -fsSL --max-time 30 https://raw.githubusercontent.com/Stiggimy/advance/master/bootstrap.sh -o advance-bootstrap.sh && bash advance-bootstrap.sh
```

New installations keep their source files in `$ADVANCE_DATA_DIR/source` (default `~/.local/share/advance/source`). Run `advance -U` for routine updates (zero-dependency tarball updates for public installs, or fast-forward `git pull` for `.git` checkouts; add `--repair` to force repairing symlinks/man pages). If an old updater hangs, or installation was interrupted, run the bootstrap command again. Downloads default to a 30-second timeout; set `SELF_UPDATE_TIMEOUT=120s` for slower connections. Pass `--no-checkpoint` to skip the interactive companion prompt.

If the installer reports an unexpected origin, inspect the linked checkout with `git -C /path/to/checkout remote -v`. Older releases could change the public origin to `advance-dev.git` when a checkout contained `.agents` or `.gemini`. **Only if this checkout should track public releases**, restore the URL with `git -C /path/to/checkout remote set-url origin https://github.com/Stiggimy/advance.git` and retry. For a private checkout, use its configured upstream and run its own `./install.sh`.

### Manual Git install

To choose the checkout location yourself:

```bash
git clone https://github.com/Stiggimy/advance.git
cd advance
./install.sh
```

The installer automatically creates symlinks, deploys the man page, and enrolls detected package managers from the official catalog.

> **Tip:** Install [`checkpoint`](https://github.com/Stiggimy/checkpoint) alongside Advance for automated snapshot support.

### Manual recovery from an older updater

If you installed from a public Git clone and `advance -U` hangs or fails, press Ctrl+C to close it. In your existing Advance checkout, on a clean `master` branch, run:

```bash
GIT_TERMINAL_PROMPT=0 timeout -k 2s 30s git -c credential.helper= pull --ff-only https://github.com/Stiggimy/advance.git master &&
  ./install.sh &&
  "$HOME/.local/bin/advance" --version
```

The command pulls directly from the public repository and keeps your configured remote and user settings. If Git reports local changes or diverged history, save your work and review the checkout before retrying. For a package-managed install, use the same package source you installed from.

### Arch Linux (PKGBUILD)

A VCS `PKGBUILD` is included for a system-wide install. It builds `advance-git` from the latest commit on `master`, so rebuilding the package picks up new changes:

```bash
git clone https://github.com/Stiggimy/advance.git
cd advance
makepkg -si
```

The package installs the binary to `/usr/bin/advance`, libraries to `/usr/lib/advance`, the catalog to `/usr/share/advance/catalog`, and the manual to `/usr/share/man/man1`. It provides `advance` and conflicts with a non-VCS `advance` package. The catalog is enrolled into each user's config directory on first run (or via `advance catalog scan`).

### XDG directories

Advance follows the [XDG Base Directory specification](https://specifications.freedesktop.org/basedir-spec/):

| Purpose | Default location | Override |
|---|---|---|
| Configuration | `~/.config/advance/` | `XDG_CONFIG_HOME` / `ADVANCE_CONFIG_DIR` |
| Catalog & per-user libraries | `~/.local/share/advance/` | `XDG_DATA_HOME` / `ADVANCE_DATA_DIR` |
| Persistent state (dismissed tips) | `~/.local/state/advance/` | `XDG_STATE_HOME` / `ADVANCE_STATE_DIR` |
| Cache (catalog probes) | `~/.cache/advance/` | `XDG_CACHE_HOME` / `ADVANCE_CACHE_DIR` |

Legacy files in the old hardcoded locations are migrated automatically when a non-default XDG directory is set. Set `NO_COLOR=1` to disable colored output.

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
| `-st, --stall-timeout <dur>` | Watchdog inactivity timeout before stall prompt (e.g. 3m, 180s, 0) |
| `-i, --interactive` | Force manual confirmation mode for all managers |
| `-c, --changelog [ver]` | View release notes or open interactive FZF version browser |
| `-U, --self-update, --selfupdate` | Pull latest git changes and reinstall the tool suite (`--repair` to repair install) |
| `-v, --verbose, --debug` | Enable detailed debug logging |
| `-V, --version` | Print version and build number, then exit |
| `-h, --help` | Display command usage and option summary |

### Quick Modes
```bash
advance                 # Run full update workflow
advance --check, -ch    # Survey sources and check for updates only (no sudo)
advance -ch -v          # Check for updates and list available packages
advance changelog       # Browse interactive release notes and changelog
```

The default Apt recipe shows **Always runs** in `--check`. A normal update refreshes the package lists before upgrading. The check-only package total includes only managers that reported packages.

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
advance changelog [version]         # View release notes or open interactive FZF version browser
advance config                      # Interactive settings & priority hub (Alt+Up/Down to reorder)
advance config export [mgr|--all]   # Export manager configs
advance config import <file|url>    # Import manager configs
advance catalog                     # Official recipe catalog (list, scan, enroll, remove)
advance catalog scan                # Auto-detect and enroll installed package managers
advance schedule                    # Setup background auto-update timers
advance self-update [--repair]      # Update tool suite (or repair per-user install)
advance selfupdate                  # Alias for self-update
advance uninstall [OPTIONS]         # Remove per-user Advance installation
```

### Uninstallation

Remove a per-user Advance installation safely at any time:

```bash
advance uninstall
```

Or directly from a repository checkout:

```bash
./uninstall.sh
```

Useful flags:
- `--dry-run`: Preview everything that would be removed without changing files.
- `--keep-config`: Preserve `~/.config/advance` (including custom managers and overrides) without prompting.
- `--purge`: Also remove `~/.config/advance` and `~/.local/state/advance`.
- `-y, --yes`: Skip confirmation prompts (preserves config unless `--purge` is passed).

System packages, snapshots, and any external repository checkouts are never modified. Disabled user systemd auto-update timers (`advance-update.timer`), if configured, are automatically cleaned up.

---

Public installations created with `bootstrap.sh` update automatically using only `curl`/`wget` and `tar` (no `git` or `gh` required). Git checkouts pull the current branch from the configured `origin` without rewriting remotes; public HTTPS clones bypass local credential helpers automatically so stalled helpers (such as GitHub CLI) cannot block updates, while private checkouts use configured HTTPS credentials or non-interactive SSH. Self-update serializes runs with `flock`, offers an interactive auto-stash prompt for uncommitted tracked changes in Git checkouts, and cancels cleanly on Ctrl+C.

Network operations time out after 30 seconds by default (`SELF_UPDATE_TIMEOUT=120s` for slower connections). If installation fails after downloading, or if installed symlinks/man pages are missing, `advance self-update` (or `advance self-update --repair`) automatically repairs the installation. If the companion Checkpoint update fails, Advance reports partial success, returns a failure status, and shows a retry command.

## Documentation

Full documentation is available via the manual:
```bash
man advance
```

For upcoming features in development and full release history, see [CHANGELOG.md](CHANGELOG.md) (or run `advance -c`).

---

## License

This project is licensed under the GNU General Public License v3.0 (GPLv3) — see the [LICENSE](LICENSE) file for details.

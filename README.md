# Advance

**One command to update everything on Linux, safely.**

Advance updates your system packages, Flatpaks, language tools (`npm`, `cargo`, `pipx`, etc.), and firmware in one clean run. It pairs with [`checkpoint`](https://github.com/Stiggimy/checkpoint) to create automatic system backups before updating and gives you an interactive recovery menu if anything fails or freezes.

---

## Installation

### Quick Install (Recommended)

Install Advance (requires only `bash`, `tar`, and `curl` or `wget` — no `git` or `gh` needed):

```bash
curl -fsSL https://raw.githubusercontent.com/Stiggimy/advance/master/bootstrap.sh | bash
```

To install both **Advance and Checkpoint** together in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/Stiggimy/advance/master/bootstrap.sh | bash -s -- --with-checkpoint
```

> **Tip:** Pass `--no-checkpoint` if you want to skip the interactive prompt to install Checkpoint.

<details>
<summary><strong>Other install methods (Inspect script first, Manual Git clone, Arch Linux PKGBUILD)</strong></summary>

#### Download and inspect before running
```bash
curl -fsSL --max-time 30 https://raw.githubusercontent.com/Stiggimy/advance/master/bootstrap.sh -o advance-bootstrap.sh && bash advance-bootstrap.sh
```

#### Manual Git install
```bash
git clone https://github.com/Stiggimy/advance.git
cd advance
./install.sh
```

#### Arch Linux (PKGBUILD)
Build and install system-wide (`advance-git`, tracking `master`):
```bash
git clone https://github.com/Stiggimy/advance.git
cd advance
makepkg -si
```
This installs the binary to `/usr/bin/advance`, libraries to `/usr/lib/advance`, the catalog to `/usr/share/advance/catalog`, and the manual to `/usr/share/man/man1`. Built-in package managers are enrolled into each user's configuration on first run (or via `advance catalog scan`).

</details>

---

## Quick Start & Examples

### Everyday usage
```bash
advance                 # Update everything (with pre/post snapshots if Checkpoint is installed)
advance -ch             # Check for available updates only (no changes, no sudo)
advance -ch -v          # Check for updates and list every upgradable package
advance config          # Open interactive settings and package manager menu
advance schedule        # Set up automatic background updates (systemd timer)
advance changelog       # Browse release notes interactively
```

> **Note for Debian/Ubuntu (`apt`):** `advance -ch` displays **Always runs** because normal updates automatically refresh package lists before upgrading. The check-only package total counts only managers that report package lists.

### Run or skip specific package managers
```bash
advance -o yay                   # Only run Yay
advance -o yay -o pacman         # Force-run both Yay and Pacman together
advance -og system               # Only run the preferred manager in the 'system' group
advance -n yay                   # Skip Yay (uses the next tool in the group, e.g. Paru or Pacman)
advance -ng flatpak              # Skip the entire Flatpak group
```

### Exclude packages, tweak flags, or handle slow commands
```bash
advance -ex linux -ex nvidia        # Skip specific packages for this run
advance -ef yay:--devel             # Pass an extra flag to a manager for this run
advance -nef yay                    # Clear saved extra flags for a manager for this run
advance -i                          # Ask for manual confirmation on every manager
advance -st 3m                      # Alert if a command stalls with no output for 3 minutes
advance -v                          # Show detailed debug output
```

### Control backups (snapshots) on the fly
```bash
advance -nprs -ns                   # Run updates without taking pre/post snapshots
advance -ks                         # Protect the post-update snapshot from auto-cleanup ([KEEP])
advance -k 10                       # Keep the last 10 normal snapshots for this cleanup run
advance -oprs                       # Only create a pre-update snapshot and exit
advance -ops                        # Only create a post-update snapshot and exit
```

---

## What Advance Does

- 🧩 **Works with any package manager:** Ships ready-to-use recipes for `pacman`, `yay`, `paru`, `apt`, `dnf`, `flatpak`, `snap`, `brew`, `npm`, `pnpm`, `cargo`, `pipx`, `fwupdmgr`, and more.
- 🎯 **Smart priorities & automatic fallback:** When you have multiple tools for the same job (like `paru`, `yay`, and `pacman`), Advance runs only your highest-priority tool — and offers to fall back to the next one if it fails.
- 🛡️ **Automatic backups with Checkpoint:** Takes linked before-and-after system snapshots (Snapper or Timeshift) so you can safely roll back a broken update.
- 🔁 **Interactive error recovery:** If an update fails, Advance doesn't just crash. It pauses with clear options:
  - `[U]nlock` — Safely remove stale lock files (when no process is using them) and retry
  - `[R]etry` — Try the command again
  - `[O]verride` — Retry with conflict/force flags when configured
  - `[I]nteractive` — Switch to manual prompts so you can answer questions yourself
  - `[F]allback` — Switch to the backup manager in the same group
  - `[E]dit` — Edit the command right in your terminal and run it
  - `[S]kip` / `[A]bort` — Skip this manager or stop the run
- ⏱️ **Freeze detection:** Watches command output and rings an alert + desktop notification if an update hangs silently (`[W]ait`, `[T]erminate & Recover`, `[A]bort`).
- 🚫 **Easy package exclusions:** Hold back problematic packages on the command line (`-ex <pkg>`), in settings (`EXCLUDE_PACKAGES`), or in `~/.config/advance/excludes`.
- 🌐 **Pre-flight connection check:** Checks network connectivity before starting so offline runs fail fast instead of hanging.
- ⚙️ **Interactive hub & custom tools:** Use `advance config` to reorder priorities (`Alt+Up`/`Alt+Down`), tune flags without editing catalog files, browse official recipes (`advance catalog`), or add your own update commands with a guided wizard.

---

## Updating & Uninstalling

### Updating
```bash
advance -U                     # Update Advance (and Checkpoint, if installed)
advance self-update --repair   # Repair symlinks, libraries, or manual pages if needed
```
Public installations update using only `curl`/`wget` and `tar` — no `git` or `gh` needed.

### Uninstalling
```bash
advance uninstall              # Remove Advance cleanly (prompts before touching your config)
advance uninstall --dry-run    # Preview what would be removed without changing anything
advance uninstall --keep-config # Keep ~/.config/advance (custom managers & overrides)
advance uninstall --purge      # Also remove ~/.config/advance and ~/.local/state/advance
advance uninstall -y           # Skip confirmation prompts (still keeps config unless --purge)
```
System packages, snapshots, and any external repository folders are never touched. Disabled user auto-update timers (`advance-update.timer`) are removed automatically.

*(If you installed Advance via your distro's package manager such as `makepkg -si`, update or remove it with your package manager instead, e.g. `sudo pacman -R advance-git`.)*

---

## Complete Command Reference

### Modes & Target Selection
| Option | Description |
|---|---|
| `-ch, --check` | Check for updates without installing (add `-v` to list packages; no sudo required) |
| `-o, --only <mgr>` | Only run this manager (repeatable; runs all selected even in the same group) |
| `-og, --only-group <group>` | Only run this group (repeatable) |
| `-n, --no <mgr>` | Skip this manager (repeatable; falls back to next manager in group) |
| `-ng, --no-group <group>` | Skip an entire group (repeatable) |

### Snapshot & Phase Control
| Option | Description |
|---|---|
| `-oprs, --only-pre-snapshot` | Create pre-update snapshot only and exit |
| `-ops, --only-post-snapshot` | Create post-update snapshot only and exit |
| `-nprs, --no-pre-snapshot` | Skip pre-update snapshot |
| `-ns, --no-snapshot` | Skip post-update snapshot |
| `-nc, --no-cleanup` | Skip automatic snapshot cleanup |
| `-fprs, --force-pre-snapshot` | Force pre-snapshot creation regardless of minimum age |
| `-fs, --force-snapshot` | Force post-snapshot creation even if nothing changed |
| `-kprs, --keep-pre-snapshot` | Protect pre-update snapshot from auto-cleanup (`[KEEP]`) |
| `-ks, --keep-snapshot` | Protect post-update snapshot from auto-cleanup (`[KEEP]`) |
| `-fd, --force-delete` | Allow deleting `[KEEP]` snapshots during cleanup |
| `-k, --keep <N>` | Temporarily override snapshot retention limit |

### Update Modifiers & General Options
| Option | Description |
|---|---|
| `-ef, --extra-flag <mgr:flag>` | Append an extra flag to a manager for this run (repeatable) |
| `-nef, --no-extra-flags <mgr>` | Clear saved extra flags for a manager for this run (repeatable) |
| `-ex, --exclude <pkg>` | Exclude a package from updates for this run (repeatable) |
| `-st, --stall-timeout <dur>` | Freeze-detection timeout before prompting (e.g. `3m`, `180s`, `0` to disable) |
| `-i, --interactive` | Force manual confirmation mode for all managers |
| `-c, --changelog [ver]` | View release notes or open interactive release browser |
| `-U, --self-update, --selfupdate` | Update Advance and Checkpoint (add `--repair` to repair installation) |
| `-v, --verbose, --debug` | Enable detailed debug logs |
| `-V, --version` | Print version and build number, then exit |
| `-h, --help` | Display usage and options summary |

### Subcommands
| Command | Description |
|---|---|
| `advance config` | Interactive settings, flags, and priority hub (`Alt+Up`/`Alt+Down` to reorder) |
| `advance config export [mgr\|--all]` | Export manager configurations |
| `advance config import <file\|url>` | Import manager configurations |
| `advance catalog [list\|scan\|enroll\|remove]` | Browse, scan, enable, or disable official package manager recipes |
| `advance schedule` | Set up background auto-update systemd timers |
| `advance changelog [ver]` | Browse release history interactively or print a specific version |
| `advance self-update [--repair]` | Update Advance and Checkpoint (or repair per-user install) |
| `advance uninstall [OPTIONS]` | Remove per-user Advance installation |

---

## Advanced & Customization

### How Groups & Priorities Work

Managers live as `.conf` files inside `~/.config/advance/managers.d/`. Each subfolder is a **group** where only the highest-priority available tool runs (with lower-priority tools kept on standby for fallback). Loose `.conf` files at the top level always run when enabled.

```text
~/.config/advance/managers.d/
├── system/                  <- Group: system (highest priority installed wins)
│   ├── pacman.conf          (priority: 0)
│   ├── yay.conf             (priority: 10)
│   ├── paru.conf            (priority: 15)
│   ├── apt.conf             (priority: 0)
│   └── dnf.conf             (priority: 0)
├── flatpak/                 <- Group: flatpak
│   └── flatpak.conf         (priority: 0)
├── node/                    <- Group: node
│   ├── npm.conf             (priority: 0)
│   └── pnpm.conf            (priority: 10)
└── my-custom-tool.conf      <- Standalone (always runs if enabled)
```

Groups run in order of group priority (set via `advance config` or `GROUP_PRIORITY_<group>=<number>` in `~/.config/advance/config`; by default `system` is `100` and other groups are `50`).

### Creating Custom Package Manager Plugins

You can add or edit managers visually in `advance config`, or create your own `.conf` file (drop-in overrides can also be placed in `~/.config/advance/overrides.d/<manager>.conf` without touching catalog defaults):

```ini
NAME=Yay
EMOJI=🖥️
REQUIRES_CMD=yay                  # Command that must exist for this manager to be active
PROBE_ACTIVE_CMD=                 # Optional command to check if the service/tool is usable
PRIORITY=10                       # Higher number wins within a group (unique per group)
CHECK_CMD=checkupdates 2>/dev/null; yay -Qua 2>/dev/null
UPDATE_CMD=yay -Syu
FLAGS=--needed
AUTO_CONFIRM=                     # true, false, or empty (follow global setting)
FLAGS_AUTO_CONFIRM=--noconfirm
FLAGS_INTERACTIVE=
FLAGS_OVERRIDE=--overwrite '*'
COLOR_FLAG=--color=always
EXCLUDE_FLAG=--ignore
EXCLUDE_JOIN=,                    # 'comma' (or ',') vs 'repeat'
EXCLUDE_HOLD_CMD=                 # Optional command to hold excluded packages before update
EXCLUDE_UNHOLD_CMD=               # Optional command to unhold packages after update
POST_UPDATE_MSG=                  # Optional notice shown after this manager updates
LOCK_FILE=/var/lib/pacman/db.lck  # Optional lock file path for [U]nlock recovery
STALL_TIMEOUT=180                 # Optional freeze watchdog in seconds (0 = disabled)
ENABLED=true
```

<details>
<summary><strong>Technical Details (XDG Directories, Environment Variables & Updater Behavior)</strong></summary>

#### XDG Directories & Environment Variables
Advance follows the [XDG Base Directory specification](https://specifications.freedesktop.org/basedir-spec/):

| Purpose | Default location | Override |
|---|---|---|
| Configuration | `~/.config/advance/` | `XDG_CONFIG_HOME` / `ADVANCE_CONFIG_DIR` |
| Catalog & libraries | `~/.local/share/advance/` | `XDG_DATA_HOME` / `ADVANCE_DATA_DIR` |
| Persistent state (dismissed tips) | `~/.local/state/advance/` | `XDG_STATE_HOME` / `ADVANCE_STATE_DIR` |
| Cache (update & probe cache) | `~/.cache/advance/` | `XDG_CACHE_HOME` / `ADVANCE_CACHE_DIR` |

Set `NO_COLOR=1` to disable colored terminal output.

#### Self-Update Internals
- **Per-user public installs (`bootstrap.sh`):** Update by downloading the `master.tar.gz` archive over HTTPS with `curl` or `wget` and extracting with `tar` (no `git` or `gh` required).
- **Git checkouts (`.git` present):** Pull the current branch from `origin` with `--ff-only` without rewriting remotes. Public HTTPS clones automatically bypass local credential helpers (`-c credential.helper=`); private clones use your configured HTTPS credentials or non-interactive SSH (`BatchMode=yes`). Uncommitted tracked changes trigger an interactive auto-stash prompt in terminals (or refuse safely non-interactively).
- **Reliability guards:** Runs are serialized with `flock`, downloads/fetches default to a 30-second timeout (`SELF_UPDATE_TIMEOUT=120s` for slow connections), Ctrl+C stops helper processes cleanly, and interrupted installations are retried automatically on the next run. If a companion Checkpoint update fails, Advance exits non-zero and shows a retry command.

</details>

---

## Documentation & License

- Full manual: `man advance`
- Release history & upcoming features: [CHANGELOG.md](CHANGELOG.md) or `advance -c`
- Licensed under the GNU General Public License v3.0 (GPLv3) — see [LICENSE](LICENSE)

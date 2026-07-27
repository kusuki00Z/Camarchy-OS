# Camarchy-OS — Architecture

**Goal:** A bootable ISO that installs **CachyOS** as the base (kernel, repos, optimizations, update channel) and **Omarchy** as the full opinionated desktop layer (Hyprland + apps + configs + its own update channel).

**Status:** Design document. No implementation yet.

---

## 1. What we're actually gluing together

### 1.1 CachyOS side

CachyOS builds its ISO with a lightly customized **archiso** profile:

- Repo: `https://github.com/CachyOS/CachyOS-Live-ISO`
- Build: `sudo ./buildiso.sh -p desktop -v -w` → output in `out/`
- Build deps: `archiso mkinitcpio-archiso git squashfs-tools grub`

Layout that matters to us:

| Path | Role |
|---|---|
| `buildiso.sh` | Entry point; `-p <profile>` selects a buildset |
| `archiso/profiledef.sh` | ISO name, version, boot modes, file permissions |
| `archiso/bootstrap_packages.x86_64` | Packages for the bootstrap/base tarball |
| `archiso/packages_desktop.x86_64` | Packages for the live desktop environment |
| `archiso/pacman.conf` | Repos used **during ISO build** (CachyOS repos live here) |
| `archiso/airootfs/` | Overlay copied onto the live filesystem |
| `machines/` | Machine/profile-specific configuration |
| `util-iso*.sh`, `util.sh` | Build helper libraries |

Two facts drive the design:

1. **CachyOS's optimized repos** (`[cachyos]`, `[cachyos-core-v3]`, `[cachyos-extra-v3]`, etc.) are ordered **above** Arch's `[core]`/`[extra]` in `/etc/pacman.conf`. Pacman resolves same-named packages by **repo order in the file**, so base-system updates naturally come from Cachy. This is exactly the behaviour Goal #3 asks for, and it's free — we just must not break the ordering.
2. **CachyOS supports Limine + Btrfs with `limine-snapper-sync`**, and ships `snap-pac` so snapshots happen automatically around pacman transactions. This matters enormously — see below.

### 1.2 Omarchy side

- Repo: `https://github.com/basecamp/omarchy`
- Online install: `boot.sh` → clones to `~/.local/share/omarchy` → sources `install.sh`
- Offline/update path: `install.sh` directly (`OMARCHY_ONLINE_INSTALL` controls which)

`install.sh` sources phase modules in a fixed order:

```
install/helpers/all.sh       # logging + utilities
install/preflight/all.sh     # guards, keyring, mirrors, pacman.conf, -Syyuu
install/packaging/all.sh     # package installation (omarchy-pkg-add)
install/config/all.sh        # dotfiles → ~/.config, .bashrc, hardware detection
install/login/all.sh         # display manager / session
install/post-install/all.sh  # migrations, cleanup
```

Key environment:

```sh
OMARCHY_PATH="$HOME/.local/share/omarchy"
OMARCHY_INSTALL="$OMARCHY_PATH/install"
OMARCHY_INSTALL_LOG_FILE="/var/log/omarchy-install.log"
```

Omarchy has its **own signed package repo** with three channels — `stable`, `rc`, `edge` — selected by `OMARCHY_REF` (branch `master`/`rc`/`dev`) and materialized by copying a branch-specific pacman config into `/etc/pacman.conf`, plus `omarchy-keyring`. That's our desktop-side update channel, satisfying Goal #4.

---

## 2. The central blocker

`install/preflight/guard.sh` runs eight checks. Verbatim behaviour:

| # | Check | Abort message |
|---|---|---|
| 1 | `/etc/arch-release` exists | `Vanilla Arch` |
| 2 | **none of** `/etc/cachyos-release`, `/etc/eos-release`, `/etc/garuda-release`, `/etc/manjaro-release` exist | `Vanilla Arch` |
| 3 | `EUID != 0` | `Running as root (not user)` |
| 4 | `uname -m` == `x86_64` | `x86_64 CPU` |
| 5 | `bootctl status` does not report Secure Boot enabled | `Secure Boot disabled` |
| 6 | `gnome-shell` and `plasma-desktop` not installed | `Fresh + Vanilla Arch` |
| 7 | `limine` in `PATH` | `Limine bootloader` |
| 8 | `findmnt` root fstype == `btrfs` | `Btrfs root filesystem` |

**Check #2 names CachyOS explicitly.** Camarchy-OS is, by construction, the thing Omarchy refuses to install on.

Everything else is satisfiable and in fact *aligns* with CachyOS's own strengths:

- #7 + #8 → install CachyOS with **Limine + Btrfs**, which is a first-class supported combination and gives us bootable Snapper snapshots for free.
- #6 → install CachyOS in a **minimal / no-DE** configuration.
- #5 → Secure Boot off (document it; it's a user-facing install requirement).

Note: current guard code prompts for confirmation rather than hard-exiting on unmet requirements. **Do not build on that.** It's an interactive prompt in an unattended firstboot context, and it's upstream behaviour that can tighten at any time. We handle #2 explicitly.

### 2.1 Three ways past the guard

| Option | Mechanism | Verdict |
|---|---|---|
| **A. Fork + patch guard** | Maintain `camarchy` fork of Omarchy; patch `guard.sh` to treat `/etc/cachyos-release` as allowed | ✅ **Chosen** |
| B. Hide the marker | Temporarily move `/etc/cachyos-release` during install | ❌ Lies to every later tool; `cachyos-*` packages may recreate it; fragile |
| C. Upstream a flag | PR an `OMARCHY_ALLOW_DERIVATIVE=1` escape hatch | 🟡 Worth attempting *in parallel*; can't be a dependency |

**Chosen: A**, structured so the patch is a *single small diff* that rebases cleanly onto upstream `master`. The fork exists to hold that diff and the package-exclusion list (§4.2) — nothing else. Every other Omarchy behaviour is inherited unmodified so upstream updates keep flowing.

---

## 3. High-level architecture

```
┌─────────────────────────────────────────────────────────┐
│  camarchy-iso   (fork of CachyOS-Live-ISO)              │
│  archiso profile: "camarchy"                            │
│   • CachyOS repos + optimized packages                  │
│   • Limine + Btrfs enforced in installer defaults       │
│   • NO desktop environment                              │
│   • ships camarchy-firstboot into airootfs              │
└────────────────────────┬────────────────────────────────┘
                         │ user boots ISO, runs installer
                         ▼
┌─────────────────────────────────────────────────────────┐
│  STAGE 1 — CachyOS base install                         │
│  Btrfs root · Limine bootloader · minimal, no DE        │
│  /etc/pacman.conf = CachyOS repos (base update channel) │
└────────────────────────┬────────────────────────────────┘
                         │ first boot, systemd oneshot
                         ▼
┌─────────────────────────────────────────────────────────┐
│  STAGE 2 — camarchy-bootstrap                           │
│  clones camarchy fork of Omarchy → runs install.sh      │
│  adds [omarchy] repo (desktop update channel)           │
│  installs Hyprland + full opinionated app/config set    │
└────────────────────────┬────────────────────────────────┘
                         ▼
              Camarchy-OS, two update streams:
              base → CachyOS repos · desktop → Omarchy repo
```

### 3.1 Why two stages rather than baking Omarchy into the ISO

Omarchy is a **per-user, post-install bootstrap**: it writes to `$HOME/.config`, needs a real non-root user with sudo, detects hardware on the actual machine, and pulls from a live network repo. Baking its output into the squashfs would mean freezing dotfiles for a user that doesn't exist yet and pinning package versions at ISO-build time.

Two-stage keeps Omarchy running the way upstream intends — which is the only way its update path (`omarchy-update`) keeps working afterwards.

**Cost:** Stage 2 needs a network connection at first boot, and takes several minutes. Accepted. An offline-capable variant is out of scope for v1 (see §8).

---

## 4. Repository layout

```
Camarchy-OS/
├── README.md
├── ARCHITECTURE.md              ← this file
├── iso/                         # fork/subtree of CachyOS-Live-ISO
│   ├── buildiso.sh
│   └── archiso/
│       ├── profiledef.sh                 # patched: iso_name=camarchy
│       ├── packages_camarchy.x86_64      # NEW: our buildset
│       ├── pacman.conf
│       └── airootfs/
│           └── usr/local/bin/camarchy-firstboot
├── bootstrap/
│   ├── camarchy-bootstrap.sh    # Stage 2 driver
│   ├── camarchy-firstboot.service
│   └── exclusions.txt           # packages Omarchy must NOT install (§4.2)
├── patches/
│   └── 0001-guard-allow-cachyos.patch    # the one Omarchy diff
├── scripts/
│   └── install-on-existing-cachyos.sh    # Goal #2
└── docs/
    └── update-model.md
```

### 4.1 The guard patch

Conceptually:

```diff
-for marker in /etc/cachyos-release /etc/eos-release \
-              /etc/garuda-release /etc/manjaro-release; do
+for marker in /etc/eos-release /etc/garuda-release /etc/manjaro-release; do
   [[ -f $marker ]] && abort "Vanilla Arch"
 done
```

Maintained as a patch file, applied to a pinned upstream tag. Rebasing on a new Omarchy release should be a no-op unless upstream restructures `guard.sh`.

### 4.2 Package conflict surface — the real engineering risk

Omarchy assumes vanilla Arch and will happily `pacman -S` packages that CachyOS already provides an optimized or renamed equivalent for. The collision classes to resolve **before** first build:

| Class | CachyOS provides | Omarchy may pull | Resolution |
|---|---|---|---|
| **Kernel** | `linux-cachyos` (+ headers) | `linux` / `linux-headers` | **Must exclude.** Two kernels installed is the single most likely way to produce a broken or confusing boot. |
| **Bootloader** | `limine` + `limine-snapper-sync` | assumes `limine` present | Compatible — CachyOS's is a superset. Keep Cachy's. |
| **Mesa / graphics stack** | `-v3`-optimized builds | stock | Let repo ordering decide; Cachy repos rank first. Verify no explicit `--overwrite`/pinning in Omarchy. |
| **Snapshots** | `snapper`, `snap-pac`, `limine-snapper-sync` | its own snapshot tooling | Prefer CachyOS's; it's already wired to Limine. |
| **pacman.conf** | Cachy repos, order-critical | **rewrites `/etc/pacman.conf`** in preflight + post-install | 🔴 **Highest risk.** See §5. |
| **Shell / prompt** | Cachy defaults (fish et al.) | its own `.bashrc` | Omarchy wins — it's the DE layer, that's the point. |

`bootstrap/exclusions.txt` is the machine-readable form of this table, consumed by Stage 2 to filter Omarchy's package manifests.

**This table is a hypothesis until validated.** The first implementation task is §7 step 1: diff the actual manifests.

---

## 5. The pacman.conf problem

This is the crux of Goals #3 and #4, and the part most likely to bite.

Omarchy's preflight **copies a branch-specific pacman config over `/etc/pacman.conf`**, and post-install **re-applies mirror settings**. A naive run therefore **destroys CachyOS's repo stanzas and their ordering** — killing the base update channel entirely.

**Required behaviour:**

```ini
# /etc/pacman.conf — Camarchy-OS composed form

[cachyos-v3]          # ← CachyOS optimized repos FIRST
[cachyos-core-v3]     #   base system updates resolve here
[cachyos-extra-v3]
[cachyos]

[core]                # ← stock Arch fallback
[extra]

[omarchy]             # ← desktop layer, LAST
                      #   only wins for packages Cachy/Arch don't ship
```

**Ordering rationale:** Cachy first means every package that exists in both resolves to the optimized build — Goal #3 holds by construction. Omarchy last means it supplies only its *own* packages (`omarchy-*`, its curated tooling) and can never silently replace a base package — Goal #4 holds without leaking into the base.

**Implementation: `camarchy-pacman-merge`.** Rather than let Omarchy overwrite the file, Stage 2:

1. Snapshots CachyOS's stanzas before Omarchy runs.
2. Lets Omarchy do its thing.
3. Recomposes `/etc/pacman.conf` in the canonical order above, idempotently.
4. Runs after both preflight *and* post-install, since Omarchy touches it twice.

The merge tool must be **idempotent and re-runnable**, because `omarchy-update` will rewrite pacman.conf again on every future update. That means it can't be install-time-only — it needs to be a persistent hook.

**Open question (needs validation):** whether a pacman hook, a systemd path unit watching `/etc/pacman.conf`, or a wrapper around `omarchy-update` is the right enforcement point. A pacman `PostTransaction` hook is the current front-runner — it runs inside the transaction that would have clobbered the file. Decide in step 3 of §7.

---

## 6. Update model

| Layer | Source | Command | Notes |
|---|---|---|---|
| Base OS, kernel, drivers | CachyOS repos | `pacman -Syu` | Repo ordering guarantees Cachy wins |
| Desktop, apps, configs | Omarchy repo + git | `omarchy-update` | Runs migrations; **rewrites pacman.conf** → merge hook must re-fire |
| Camarchy glue | this repo | `camarchy-update` (TBD) | Re-applies guard patch, exclusions, pacman ordering |

The uncomfortable truth: `omarchy-update` pulling new **migrations** is the long-term maintenance burden. A migration that assumes vanilla Arch (e.g. installing a package CachyOS renames) can break the base. Mitigation: pin to Omarchy `stable` (`OMARCHY_REF=master`), and gate migration runs behind the exclusion list.

---

## 7. Implementation plan

Ordered by dependency, with the validation work first — the design above contains assumptions that must be tested before any ISO is built.

1. **Validate the conflict surface.** Clone both repos. Diff `packages_desktop.x86_64` + Cachy base manifests against Omarchy's package manifests. Produce a real `exclusions.txt`. *This either confirms §4.2 or rewrites it.*
2. **Manual proof-of-concept — no ISO.** Install stock CachyOS in a VM (Btrfs + Limine + no DE, Secure Boot off). Apply the guard patch by hand. Run Omarchy's `install.sh`. **Record every breakage.** This is the single highest-value step; everything downstream is shaped by what fails here.
3. **Solve pacman.conf.** Build and test `camarchy-pacman-merge` against the PoC box. Verify base updates still resolve to Cachy repos *after* a full `omarchy-update` cycle.
4. **Script it →** `scripts/install-on-existing-cachyos.sh`. This delivers **Goal #2 on its own**, and is the reusable core of Stage 2. Ship this before touching archiso.
5. **Fork the ISO.** Add the `camarchy` buildset, strip the DE, wire `camarchy-firstboot` into `airootfs`.
6. **Installer defaults.** Ensure the CachyOS installer path used by the ISO defaults to Btrfs + Limine + no DE, so Stage 2's guard checks pass unattended.
7. **CI.** Automate ISO build; boot-test in QEMU via `testiso.sh`.

Steps 1–4 need no ISO tooling and produce a working product. **Do them first.**

---

## 8. Open questions

- **CachyOS installer automation.** Can its installer be driven unattended/preseeded to guarantee Btrfs + Limine + no-DE, or must the ISO ship a custom install profile? Unverified — affects step 6.
- **Secure Boot.** Guard requires it off. Document as an install prerequisite, or attempt to relax?
- **`omarchy-update` interception.** Wrapper, pacman hook, or systemd path unit? (§5)
- **Branding.** `/etc/os-release` and `/etc/cachyos-release` — Camarchy-OS identity vs. keeping Cachy markers that Cachy's own tooling depends on. Leaning: keep Cachy markers, add `/etc/camarchy-release` alongside.
- **Offline ISO.** Stage 2 currently requires network. Pre-seeding Omarchy's packages into the squashfs would fix it but reintroduces version-pinning problems. Out of scope for v1.
- **Upstream flag.** Attempt the `OMARCHY_ALLOW_DERIVATIVE` PR to Omarchy? Would retire the fork's only real patch.

---

## Sources

- [CachyOS/CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO) — archiso profile, `buildiso.sh`, package manifests
- [CachyOS Optimized Repositories](https://wiki.cachyos.org/features/optimized_repos/) — repo ordering and `-v3` builds
- [CachyOS Offered Boot Managers](https://wiki.cachyos.org/installation/boot_managers/) — Limine support
- [CachyOS Btrfs Snapshots](https://wiki.cachyos.org/configuration/btrfs_snapshots/) — `limine-snapper-sync`, `snap-pac`
- [Omarchy — Installation and Setup](https://deepwiki.com/basecamp/omarchy/2-installation-and-setup) — requirements, preflight guards
- [Omarchy — Installation Process](https://deepwiki.com/basecamp/omarchy/2.1-installation-process) — `boot.sh`, `install.sh`, phase modules, mirror channels
- [basecamp/omarchy](https://github.com/basecamp/omarchy) — `install/preflight/guard.sh`

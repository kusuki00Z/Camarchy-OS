# Camarchy-OS — Architecture

**Goal:** A single bootable ISO that installs **CachyOS** as the base (kernel, repos, optimizations, update channel) and **Omarchy** as the full opinionated desktop layer (Hyprland + apps + configs + its own update channel).

**Status:** Design, revision 3. `install.sh` is written but **untested** — no ISO has been built yet.

## Roadmap

1. `install.sh` — the ISO merge script
2. Place it in a directory alongside the CachyOS ISO and the Omarchy ISO
3. Run it
4. It emits `CamarchyOS_<date>.iso`
5. Boot that ISO in a VM to test

**Boot flow of the produced ISO:** CachyOS live environment, **no desktop** → CachyOS TUI installer (interactive prompts on the console) → installs CachyOS with **no DE** → chroots into the fresh target and applies the Omarchy layer → reboot into Camarchy-OS.

> Revisions 1 and 2 planned to fork and rebuild an ISO from source (CachyOS's archiso profile, then Omarchy's). Revision 3 replaces that with **remastering two prebuilt ISOs**, which needs no build infrastructure and no forks. The conflict analysis from those revisions survives in §3–§4; the working notes were removed in cleanup and remain in git history at `9bbaa50`.

---

## 1. The one thing that does not work as stated

The roadmap describes "run the CachyOS installer, then load into the Omarchy installer."

**Both ISOs ship complete, disk-partitioning installers.** CachyOS's installs CachyOS end to end. Omarchy 4.0's is a nine-phase Python orchestrator over `archinstall` that partitions the disk, pacstraps a base, installs Limine, creates the user, and validates boot. Running it after CachyOS's installer would re-partition and overwrite everything CachyOS just did. They are not composable stages — they are two complete installers.

**What we do instead.** The Omarchy ISO bundles a full **offline pacman mirror** inside its squashfs:

```
/var/cache/omarchy/mirror/offline
```

Its `profiledef.sh` stores that subtree *uncompressed* on purpose:

```sh
airootfs_image_tool_options=(
  '-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M'
  '-action' 'uncompressed@subpathname(var/cache/omarchy/mirror/offline)'
)
```

That mirror holds `omarchy`, `omarchy-settings`, `omarchy-keyring`, `omarchy-nvim` and their dependencies — everything the Omarchy layer *is*. Omarchy 4.0 ships as **Arch packages**, not a bootstrap script, and the entire root-side install reduces to two commands that upstream's own ISO calls in the chroot:

```sh
omarchy-setup-system  --install-user "$USER" --first-install   # as root
omarchy-finalize-user --force --first-install                  # as that user
```

So we harvest the mirror and call those two entry points. We skip Omarchy's installer entirely, because CachyOS's installer has already done that job.

**This is strictly better for the "no unnecessary packages" requirement**, because we choose exactly which packages get installed from the mirror rather than accepting whatever the Omarchy orchestrator decides.

---

## 2. How the merge works

```
  cachyos.iso                          omarchy.iso
      │                                     │
      │ extract ISO tree                    │ extract airootfs.sfs, then
      │                                     │ unsquash ONLY the offline mirror
      ▼                                     ▼
  isoroot/                            var/cache/omarchy/mirror/offline
      │                                     │
      │ unsquash airootfs.sfs               │
      ▼                                     │
  squashfs-root/  ◄─────────────────────────┘  inject mirror
      │
      │ + default.target → multi-user.target   (no desktop)
      │ + /usr/local/bin/camarchy-install      (orchestrator)
      │ + autostart on tty1 login
      │
      ▼ mksquashfs
  new airootfs.sfs  →  regenerate checksums  →  xorriso replay boot
      │
      ▼
  CamarchyOS_<date>.iso
```

**Base live environment = CachyOS's.** It already contains the CachyOS installer, the CachyOS kernel, the Cachy repos and mirrorlists, and hardware detection (`chwd`). Rebuilding that on Omarchy's live env would mean reproducing CachyOS. We keep it and add to it.

### 2.1 No desktop environment

CachyOS's live ISO boots to a desktop to run Calamares. Its airootfs ships:

```
etc/systemd/system/default.target → /usr/lib/systemd/system/graphical.target
etc/systemd/system/getty@tty1.service.d/autologin.conf   (autologin as liveuser)
```

We repoint `default.target` at `multi-user.target`. The system boots to a console, autologs in on tty1, and our orchestrator starts from the login profile. No DE is ever loaded.

### 2.2 Interactive prompts without a desktop

CachyOS's package manifest includes **`cachyos-cli-installer-new`** — a terminal installer. That is what gives you interactive disk/locale/user prompts on a console with no graphical session, exactly as the roadmap requires.

The orchestrator invokes it, then takes over once it exits.

### 2.3 Applying the Omarchy layer

After the CachyOS installer finishes, the target system is mounted (conventionally at `/mnt`). The orchestrator then:

1. Copies the harvested offline mirror into the target.
2. Registers it as a **local file-backed pacman repo**, placed **below** the CachyOS repos so Cachy still wins for anything both provide:
   ```ini
   [omarchy]
   SigLevel = Optional TrustAll
   Server = file:///var/cache/omarchy/mirror/offline
   ```
3. `pacman -Sy omarchy omarchy-settings omarchy-nvim` into the target.
4. `arch-chroot` → `omarchy-setup-system --install-user "$user" --first-install`.
5. `arch-chroot -u "$user"` → `omarchy-finalize-user --force --first-install`.
6. Re-asserts pacman repo ordering (§3).

---

## 3. The pacman ordering problem — still the core risk

Unchanged across all three revisions, and **not fixed in Omarchy 4.0**.

`install/post-install/pacman.sh`, which `omarchy-setup-system` runs, does:

```bash
cp -f "$OMARCHY_PATH/default/pacman/pacman-${OMARCHY_MIRROR:-stable}.conf" /etc/pacman.conf
cp -f "$OMARCHY_PATH/default/pacman/mirrorlist-${OMARCHY_MIRROR:-stable}" /etc/pacman.d/mirrorlist
```

`pacman-stable.conf` contains `[core] [extra] [multilib] [omarchy]` and **no CachyOS repos**; `mirrorlist-stable` is a single line pointing at `stable-mirror.omarchy.org`. Left alone this **deletes every `[cachyos*]` stanza** and orphans the installed Cachy packages — they stay on disk but belong to no configured repo and are never updated again. That silently destroys the "base updates come from Cachy" goal.

**Required final ordering:**

```ini
[cachyos-v3]        # optimized builds win for anything Cachy ships
[cachyos-core-v3]
[cachyos-extra-v3]
[cachyos]
[core]              # Arch fallback
[extra]
[multilib]
[omarchy]           # desktop layer only — supplies what nothing else does
```

Pacman resolves same-named packages by **first matching repo in file order**, so this ordering satisfies both update-channel goals by construction.

**The fix follows upstream's own pattern.** The line immediately after the clobber sources `install/hardware/pacman.sh`, which exists precisely to re-add repos afterwards:

```bash
# Hardware-specific pacman repository extensions that must survive the final
# pacman.conf restore.
```

We do the same, with one difference: `arch-mact2` is *appended* (lowest priority, correct for it), whereas the CachyOS repos must be **prepended**. So we recompose the file rather than append to it.

Because `omarchy update` and `omarchy-refresh-pacman` both re-clobber these files later, the fix must be **persistent and idempotent**, not a one-shot at install time. That is a libalpm hook on the installed system — deferred to after the ISO boots successfully (§6).

---

## 4. Other known conflicts

All verified by reading Omarchy 4.0 master directly; file paths below are exact.

| | Issue | Impact |
|---|---|---|
| **Kernel headers** | `install/hardware/nvidia.sh` resolves headers with `pacman -Qqs '^linux(-zen\|-lts\|-hardened\|-t2\|-ptl)?$'`, which **never matches `linux-cachyos`**. No headers get installed, then `nvidia-open-dkms` is installed anyway and cannot build. | 🔴 NVIDIA users get a black screen. Mitigate by pre-installing `linux-cachyos-headers`. |
| **Hardcoded `linux-headers`** | `fix-bcm43xx.sh`, `fix-tuxedo-backlight.sh`, `fix-yt6801-ethernet-adapter.sh`, `omarchy-install-gaming-xbox-controllers` | 🟡 DKMS builds against the wrong kernel |
| **Kernel takeover** | `install/hardware/intel/ptl-kernel.sh` runs `pacman -Rdd --noconfirm linux linux-headers`, installs `linux-ptl`, and seizes Limine boot order | 🟡 Intel Panther Lake only |
| **Direct-pacman guard** | `00-omarchy-update-guard.hook` is a libalpm `PreTransaction` hook with `AbortOnFail` that **blocks `pacman -Syu`**, redirecting users to `omarchy update`. Escape: `OMARCHY_ALLOW_DIRECT_PACMAN=1`. | 🟡 Collides with base updates; prefer a `camarchy update` wrapper over disabling it |
| **Bootloader** | Omarchy assumes Limine; CachyOS supports Limine with `limine-snapper-sync` | 🟢 Compatible — select Limine in the CachyOS installer |
| **Snapper** | Both configure snapper + Limine snapshots | 🟡 Ownership of the boot menu unresolved |
| **`os-release`** | `omarchy-settings` `cp -f`'s over `/etc/os-release` via `etc-overrides/` | 🟡 Branding collides with CachyOS identity |

Prior art: **`mroboff/omarchy-on-cachyos`** does this for Omarchy 3.x and independently reports the same NVIDIA driver trouble, plus AUR helper (`yay` vs `paru`), shell (`bash` vs `fish`), and `tldr` vs `tealdeer` conflicts.

---

## 5. Repository layout

```
Camarchy-OS/
├── install.sh          # the ISO merge script — the whole build
├── ARCHITECTURE.md     # this file
└── README.md
```

Deliberately flat. `install.sh` embeds the in-ISO orchestrator (`camarchy-install`) as a heredoc, so the entire build is one file you drop next to two ISOs and run — no support tree to keep in sync.

---

## 6. What is done and what is next

**Done** — `install.sh` is written: dependency checks, ISO discovery, extraction, offline-mirror harvesting, no-DE conversion, orchestrator injection, squashfs repack, checksum regeneration, and a boot-preserving `xorriso` rebuild.

**Untested.** No ISO has been built. `xorriso` and `squashfs-tools` are not installed on this machine:

```sh
sudo pacman -S libisoburn squashfs-tools
```

**Next, in order:**

1. **Build the ISO.** Fetch both upstream ISOs, run `install.sh`, confirm it produces `CamarchyOS_<date>.iso` without errors.
2. **Boot it in a VM.** Confirm it reaches a console with no desktop and the CachyOS TUI installer starts.
3. **Complete an install.** Confirm the CachyOS half lands a bootable no-DE system with Btrfs + Limine.
4. **Confirm the Omarchy half.** Packages install from the offline mirror; `omarchy-setup-system` and `omarchy-finalize-user` succeed.
5. **Verify the update channels (§3).** After first boot, check that `[cachyos*]` still exists in `/etc/pacman.conf` and that base packages resolve to Cachy. This is where it is most likely to be broken.
6. **Make the pacman fix persistent.** Once 1–5 pass, add the libalpm hook so `omarchy update` cannot undo it.

Step 5 is the one that decides whether this is Camarchy-OS or just Omarchy with extra steps.

---

## Sources

Read directly from source:

- `omacom-io/omarchy-iso` @ master — `README.md`, `configs/profiledef.sh`, `builder/build-iso.sh`, `builder/archinstall.packages`, `configs/pacman-online-*.conf`, `orchestrator/phases_impl.py`
- `basecamp/omarchy` @ master (`4.0.0.alpha`, `f4e8470`, 2026-07-27) — `docs/file-layout.md`, `bin/omarchy-setup-system`, `bin/omarchy-refresh-pacman`, `bin/omarchy-update-pacman-guard`, `install/post-install/pacman.sh`, `install/hardware/*`, `default/pacman/*`, `default/libalpm/hooks/*`
- `basecamp/omarchy` @ tag `v3.8.4` — 3.x baseline for comparison
- `CachyOS/CachyOS-Live-ISO` @ master — `archiso/pacman.conf`, `archiso/packages_desktop.x86_64`, `archiso/airootfs/etc/systemd/system/`
- `mroboff/omarchy-on-cachyos` — prior art, Omarchy 3.x on CachyOS

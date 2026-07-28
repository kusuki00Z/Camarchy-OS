# Camarchy-OS

**CachyOS** as the base, **Omarchy** as the desktop — in one installer ISO.

Rather than building a distro from scratch, `install.sh` merges two prebuilt
upstream ISOs into a single one.

## Usage

Put `install.sh` in a directory with both ISOs:

```
.
├── install.sh
├── cachyos-desktop-<version>.iso
└── omarchy-<version>.iso
```

Then:

```sh
sudo pacman -S libisoburn squashfs-tools   # build dependencies
sudo ./install.sh
```

Output: `CamarchyOS_<date>.iso`.

## What the ISO does

1. Boots the CachyOS live environment with **no desktop**
2. Runs the CachyOS TUI installer — interactive prompts on the console
3. Installs CachyOS with **no DE** (choose Limine + Btrfs when prompted)
4. Applies the Omarchy layer into the fresh target from an offline package
   mirror harvested out of the Omarchy ISO
5. Reboots into Camarchy-OS

## Update channels

The point of the project is keeping two update streams separate:

- **Base system, kernel, drivers** → CachyOS repos
- **Desktop, apps, configs** → Omarchy repo

This is enforced by pacman repo ordering, which
[`ARCHITECTURE.md`](ARCHITECTURE.md) §3 covers in detail — it is also the most
fragile part, since Omarchy's own post-install step rewrites `pacman.conf`.

## Status

`install.sh` is written but **untested** — no ISO has been built yet. See
[`ARCHITECTURE.md`](ARCHITECTURE.md) §6 for the verification plan.

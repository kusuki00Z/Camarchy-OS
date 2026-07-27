# Phase 1 — Conflict Surface Validation

**Step 1 of the implementation plan in [`ARCHITECTURE.md`](../ARCHITECTURE.md).** Validates the design's assumptions against actual upstream source rather than documentation.

**Method:** shallow clones of `CachyOS/CachyOS-Live-ISO` (master) and `basecamp/omarchy` (master + tag `v3.8.4`), read verbatim. No VM, no install performed.

**Verdict:** the design holds, but **three assumptions were wrong** and one new blocker appeared. Details below.

---

## F1 🔴 Omarchy 4.0 deletes the installer entirely

`basecamp/omarchy` master is `version` = **`4.0.0.alpha`**, and it no longer contains:

- `boot.sh` — gone
- `install.sh` — gone
- `install/preflight/` — gone (including `guard.sh`)
- `install/packaging/` — gone

The `install/` tree is restructured to `config/ hardware/ helpers/ login/ post-install/ user/` plus two flat manifests (`omarchy-base.packages`, `omarchy-other.packages`).

The latest released tag is **`v3.8.4`**, which *does* contain `boot.sh`, `install.sh`, and `install/preflight/guard.sh` exactly as `ARCHITECTURE.md` describes.

**Reading:** Omarchy 4.0 appears to be moving installation out of this repo (most likely into its own ISO). Camarchy-OS's entire Stage 2 depends on an installer that upstream is in the process of removing.

**Decision — pin to `v3.8.4`.** Do not track `master`. All work targets the v3.8.x line.

**Consequence:** the "rebase our patch onto upstream" maintenance story in `ARCHITECTURE.md` §4.1 is only viable within v3.8.x. Omarchy 4.0 is not an incremental upgrade — it is a re-architecture that will require re-planning Stage 2 from scratch. This is now the project's largest medium-term risk and should be tracked deliberately.

---

## F2 ✅ The guard is exactly as documented — and it is *soft*

`install/preflight/guard.sh` @ v3.8.4, verbatim:

```bash
abort() {
  echo -e "\e[31mOmarchy install requires: $1\e[0m"
  echo
  gum confirm "Proceed anyway on your own accord and without assistance?" || exit 1
}

# Must not be an Arch derivative distro
for marker in /etc/cachyos-release /etc/eos-release /etc/garuda-release /etc/manjaro-release; do
  if [[ -f $marker ]]; then
    abort "Vanilla Arch"
  fi
done
```

All eight checks in the `ARCHITECTURE.md` §2 table are **confirmed accurate**.

`abort()` does **not** exit — it prompts via `gum confirm`. So the guard is bypassable interactively. `ARCHITECTURE.md`'s instruction not to rely on that is **upheld**: `gum confirm` requires a TTY and an answer, which an unattended firstboot oneshot cannot provide. The patch is still required.

---

## F3 🟢 `boot.sh` has a supported fork hook — no patch needed to redirect it

`boot.sh` @ v3.8.4:

```bash
OMARCHY_REF="${OMARCHY_REF:-master}"
OMARCHY_REPO="${OMARCHY_REPO:-basecamp/omarchy}"
git clone --branch "$OMARCHY_REF" "https://github.com/${OMARCHY_REPO}.git" ~/.local/share/omarchy
```

Both the repo and the ref are **environment-overridable**. Stage 2 can point Omarchy at our fork without modifying `boot.sh` at all:

```sh
OMARCHY_REPO="kusuki00Z/camarchy" OMARCHY_REF="v3.8.4-camarchy" bash boot.sh
```

This is a cleaner fork mechanism than `ARCHITECTURE.md` assumed, and it is an upstream-supported interface.

⚠️ Caveat: `boot.sh` also unconditionally overwrites `/etc/pacman.d/mirrorlist` *before* cloning — see F4.

---

## F4 🔴🔴 The pacman problem is far worse than documented

`ARCHITECTURE.md` §5 says Omarchy "overwrites `/etc/pacman.conf`". The reality is worse in three separate ways.

**It replaces two files, not one.** `install/preflight/pacman.sh`:

```bash
sudo cp -f ~/.local/share/omarchy/default/pacman/pacman-${OMARCHY_MIRROR:-stable}.conf /etc/pacman.conf
sudo cp -f ~/.local/share/omarchy/default/pacman/mirrorlist-${OMARCHY_MIRROR:-stable} /etc/pacman.d/mirrorlist
```

`install/post-install/pacman.sh` runs the **identical two lines again**. Plus `boot.sh` writes the mirrorlist a third time. So the files are clobbered **three times per install**.

**What replaces them destroys the base channel completely.** `default/pacman/pacman-stable.conf` contains exactly these repos:

```ini
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[multilib]
Include = /etc/pacman.d/mirrorlist
[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch
```

And `default/pacman/mirrorlist-stable` is a **single line**:

```
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
```

Compare CachyOS's shipped ordering (`archiso/pacman.conf`), where `[cachyos]` is deliberately first:

```ini
[cachyos]
Server = https://mirror.cachyos.org/repo/$arch/$repo
[core]
Include = /etc/pacman.d/mirrorlist
...
```

**Net effect of a stock Omarchy run on a CachyOS box:**

1. Every `[cachyos*]` repo stanza is **deleted**. Not reordered — removed.
2. `core`/`extra`/`multilib` are repointed at **Omarchy's own mirror**, not Arch's and not CachyOS's.
3. Already-installed CachyOS packages (`linux-cachyos`, the `-v3` optimized builds) become **orphaned** — present on disk, but belonging to no configured repo, so never updated again.

This does not degrade Goal #3 ("base updates pull from Cachy repo"). It **eliminates** it, silently, and leaves a system that looks fine until it quietly stops receiving CachyOS updates.

**Reclassification:** this is not one risk among several. It is *the* defining engineering problem of Camarchy-OS. The `camarchy-pacman-merge` component proposed in `ARCHITECTURE.md` §5 is the project's core deliverable, not a supporting fixup.

It must also fire **after** each of the three clobbers, and persist — v3.8.4 ships `bin/omarchy-update-pacman-guard` and `default/libalpm/hooks/00-omarchy-update-guard.hook`, confirming Omarchy itself uses a **libalpm hook** to defend this file. That validates the pacman-hook approach floated as an open question in §5, and gives us a working reference implementation to model.

---

## F5 ✅ Package conflicts are much narrower than assumed

`install/omarchy-base.packages` @ v3.8.4 is **149 packages**. Checked against the §4.2 hypothesis table:

| §4.2 predicted conflict | Actual | Status |
|---|---|---|
| `linux` / `linux-headers` pulled in | **Absent** from base manifest | ❌ **Disconfirmed** |
| `limine` | **Absent** — Omarchy assumes it pre-installed | ❌ Disconfirmed (no conflict) |
| Mesa / graphics stack | **Absent** from base manifest | ❌ Disconfirmed |
| Snapshot tooling | `install/config/snapper.sh` exists | 🟡 Needs runtime check vs CachyOS's `snap-pac` + `limine-snapper-sync` |
| Display manager | `sddm` in base manifest | 🟡 Fine given no-DE base install |
| pacman.conf | see F4 | 🔴 Confirmed, worse |

**The blanket package-exclusion list is largely unnecessary.** Omarchy's base manifest is desktop/application packages — it does not fight CachyOS for the base system. `ARCHITECTURE.md` §4.2's kernel row was wrong.

---

## F6 🔴 The real kernel problem: DKMS header resolution ignores `linux-cachyos`

The kernel conflict is real, but not where §4.2 predicted. It is in **header selection for out-of-tree (DKMS) drivers**.

`install/config/hardware/nvidia.sh` @ v3.8.4:

```bash
KERNEL_HEADERS="$(pacman -Qqs '^linux(-zen|-lts|-hardened)?$' | head -1)-headers"
```

The regex `^linux(-zen|-lts|-hardened)?$` **does not match `linux-cachyos` or `linux-cachyos-lts`**, which is exactly what CachyOS installs (confirmed in `archiso/packages_desktop.x86_64`).

On a CachyOS base the subshell returns empty, so `KERNEL_HEADERS` becomes the literal string **`-headers`** — an invalid package name — and the correct `linux-cachyos-headers` is never installed. `nvidia-open-dkms` is then installed with no matching headers present, so **the DKMS module cannot build**.

Failure mode: NVIDIA users get a broken driver, surfacing as a black screen or software rendering after first boot — with a misleading error about a package named `-headers`.

Same class of bug, hardcoding vanilla `linux-headers`:

- `install/config/hardware/fix-bcm43xx.sh` → `broadcom-wl dkms linux-headers`
- `install/config/hardware/fix-tuxedo-backlight.sh` → `linux-headers tuxedo-drivers-nocompatcheck-dkms`
- `install/config/hardware/fix-yt6801-ethernet-adapter.sh` → `linux-headers yt6801-dkms`

Each would pull vanilla `linux-headers` onto a `linux-cachyos` system — wrong headers, DKMS builds against a kernel that isn't running.

Worst case, `install/config/hardware/intel/ptl-kernel.sh` actively **removes** `linux` and `linux-headers` and installs `linux-ptl`, taking over the bootloader entry order:

```
BOOT_ORDER="linux-ptl*, *fallback, Snapshots"
```

On Intel Panther Lake hardware this would fight CachyOS's kernel for control of boot.

**Required:** a kernel-detection patch making header resolution CachyOS-aware, applied across all of the above. This is the second patch in the fork, alongside the guard.

---

## Revised patch set

Phase 1 replaces the "one small guard diff" story with **three** required changes:

| # | Target | Change | Risk |
|---|---|---|---|
| P1 | `install/preflight/guard.sh` | Drop `/etc/cachyos-release` from the derivative marker loop | Low — 1 line |
| P2 | `install/config/hardware/*.sh` | CachyOS-aware kernel/header resolution | Medium — several files, hardware-specific |
| P3 | *(new component)* `camarchy-pacman-merge` + libalpm hook | Recompose `pacman.conf` + `mirrorlist` after every Omarchy write | **High — core deliverable** |

P1 and P2 live in the Omarchy fork. P3 lives in this repo and must survive `omarchy-update`.

---

## Corrections to ARCHITECTURE.md

| § | Claim | Correction |
|---|---|---|
| §4.1 | "single small diff, rebases cleanly" | Two diffs (P1 + P2); P2 touches several hardware scripts |
| §4.2 | Kernel row: Omarchy pulls `linux`/`linux-headers` | Wrong for the base manifest. Real issue is DKMS header *resolution* (F6) |
| §4.2 | Mesa / bootloader rows | No conflict — absent from Omarchy's manifest |
| §5 | "overwrites `/etc/pacman.conf`" | Also `/etc/pacman.d/mirrorlist`; three times per install; deletes all Cachy repos (F4) |
| §5 | Open question: hook vs path unit vs wrapper | **Resolved** — libalpm hook, modelled on Omarchy's own `00-omarchy-update-guard.hook` |
| §6 | "pin to Omarchy stable (`OMARCHY_REF=master`)" | `master` is now 4.0.0.alpha. Pin to tag **`v3.8.4`** (F1) |
| §7 step 1 | — | ✅ Complete. This document is its output |
| §8 | Fork mechanism | `OMARCHY_REPO`/`OMARCHY_REF` env vars are an upstream-supported hook (F3) |

---

## Next: step 2

Everything above is static source analysis. It predicts failures; it has not observed them. Step 2 (VM proof-of-concept) should specifically confirm:

1. Does a stock Omarchy run on CachyOS actually orphan the Cachy repos as F4 predicts?
2. Does `KERNEL_HEADERS="-headers"` fail the way F6 predicts on NVIDIA hardware?
3. Does `install/config/snapper.sh` collide with CachyOS's `snap-pac` + `limine-snapper-sync`?
4. Does CachyOS's installer support an unattended Btrfs + Limine + no-DE configuration? (`ARCHITECTURE.md` §8, still open)

---

## Sources

All findings read directly from source at these revisions:

- `basecamp/omarchy` @ tag `v3.8.4` — `boot.sh`, `install.sh`, `install/preflight/guard.sh`, `install/preflight/pacman.sh`, `install/post-install/pacman.sh`, `install/omarchy-base.packages`, `install/config/hardware/*`, `default/pacman/pacman-stable.conf`, `default/pacman/mirrorlist-stable`
- `basecamp/omarchy` @ `master` — `version` (4.0.0.alpha), `install/` tree
- `CachyOS/CachyOS-Live-ISO` @ `master` — `archiso/pacman.conf`, `archiso/packages_desktop.x86_64`, `archiso/bootstrap_packages.x86_64`

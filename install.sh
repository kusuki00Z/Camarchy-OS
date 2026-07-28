#!/bin/bash
#
# Camarchy-OS ISO builder
#
# Merges a CachyOS ISO and an Omarchy ISO into a single installer ISO.
#
#   1. Put this script in a directory with both ISOs
#   2. sudo ./install.sh
#   3. Get CamarchyOS_<date>.iso
#
# The produced ISO boots the CachyOS live environment with NO desktop, runs
# the CachyOS TUI installer for interactive prompts, installs CachyOS with no
# DE, then applies the Omarchy layer into the fresh target from an offline
# package mirror harvested out of the Omarchy ISO.
#
# See ARCHITECTURE.md for why the Omarchy installer is not used directly.

set -euo pipefail

readonly SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK_DIR="${CAMARCHY_WORK_DIR:-$SELF_DIR/.camarchy-build}"
readonly OUT_ISO="${CAMARCHY_OUT:-$SELF_DIR/CamarchyOS_$(date +%Y.%m.%d).iso}"
readonly OMARCHY_MIRROR_PATH="var/cache/omarchy/mirror/offline"

# ── output ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  readonly C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
  readonly C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

step()  { echo -e "\n${C_BLUE}${C_BOLD}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
info()  { echo -e "    $*"; }
warn()  { echo -e "${C_YELLOW}    warning:${C_RESET} $*" >&2; }
die()   { echo -e "\n${C_RED}${C_BOLD}error:${C_RESET} $*" >&2; exit 1; }
ok()    { echo -e "${C_GREEN}    ✓${C_RESET} $*"; }

# ── preflight ─────────────────────────────────────────────────────────────────

require_root() {
  (( EUID == 0 )) || die "must run as root (squashfs needs to preserve ownership)\n       try: sudo $0"
}

require_deps() {
  step "Checking dependencies"
  local -a missing=()
  local -A pkg_of=(
    [xorriso]=libisoburn
    [unsquashfs]=squashfs-tools
    [mksquashfs]=squashfs-tools
    [rsync]=rsync
  )

  local tool
  for tool in xorriso unsquashfs mksquashfs rsync; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool"
    else
      missing+=("$tool")
    fi
  done

  if (( ${#missing[@]} )); then
    local -A pkgs=()
    local t
    for t in "${missing[@]}"; do pkgs["${pkg_of[$t]}"]=1; done
    die "missing tools: ${missing[*]}\n       install with: pacman -S ${!pkgs[*]}"
  fi
}

require_space() {
  # Rough: both ISOs extracted + squashfs unpacked + repacked. 25G is safe.
  local avail_kb
  avail_kb=$(df -Pk "$SELF_DIR" | awk 'NR==2 {print $4}')
  local avail_gb=$(( avail_kb / 1024 / 1024 ))
  if (( avail_gb < 25 )); then
    warn "only ${avail_gb}G free in $SELF_DIR; 25G+ recommended"
  else
    ok "${avail_gb}G free"
  fi
}

# ── ISO discovery ─────────────────────────────────────────────────────────────

# Pick exactly one ISO matching a name pattern. Sets the named variable.
find_iso() {
  local -n _out=$1
  local label=$2
  shift 2

  local -a found=()
  local f
  for f in "$SELF_DIR"/*.iso "$SELF_DIR"/*.ISO; do
    [[ -f $f ]] || continue
    local base
    base=$(basename "$f")
    # skip our own previous output
    [[ $base == CamarchyOS_* ]] && continue
    local pat
    for pat in "$@"; do
      if [[ ${base,,} == *"$pat"* ]]; then
        found+=("$f")
        break
      fi
    done
  done

  case ${#found[@]} in
    0) die "no $label ISO found in $SELF_DIR\n       expected a filename containing one of: $*" ;;
    1) _out="${found[0]}" ;;
    *) die "multiple $label ISOs found:\n$(printf '         %s\n' "${found[@]}")\n       leave only one in the directory" ;;
  esac
}

# ── extraction ────────────────────────────────────────────────────────────────

extract_iso_tree() {
  local iso=$1 dest=$2
  rm -rf "$dest"
  mkdir -p "$dest"
  # -osirrox lets xorriso act as an extractor. Ownership is restored so the
  # repacked ISO keeps sane permissions.
  xorriso -osirrox on:auto_chmod_on \
          -indev "$iso" \
          -extract / "$dest" \
          >/dev/null 2>&1 \
    || die "failed to extract $(basename "$iso")"
}

# archiso images vary in where the squashfs lands; find it.
locate_sfs() {
  local -n _sfs=$1
  local root=$2
  local hit
  hit=$(find "$root" -type f \( -name 'airootfs.sfs' -o -name 'airootfs.erofs' \) 2>/dev/null | head -1)
  [[ -n $hit ]] || die "no airootfs image found under $root — is this an archiso-based ISO?"
  [[ $hit == *.erofs ]] && die "found an EROFS airootfs ($hit); this script only handles squashfs"
  _sfs=$hit
}

# ── build steps ───────────────────────────────────────────────────────────────

harvest_omarchy_mirror() {
  local omarchy_iso=$1 dest=$2

  step "Harvesting Omarchy offline package mirror"
  local tree="$WORK_DIR/omarchy-iso"
  info "extracting $(basename "$omarchy_iso")"
  extract_iso_tree "$omarchy_iso" "$tree"

  local sfs
  locate_sfs sfs "$tree"
  info "airootfs: ${sfs#$tree/}"

  # Only unpack the mirror subtree. It is stored uncompressed in the Omarchy
  # squashfs precisely so pacman can read it, so this is fast.
  info "unpacking $OMARCHY_MIRROR_PATH"
  rm -rf "$dest"
  mkdir -p "$dest"
  unsquashfs -no-progress -d "$dest" -e "$OMARCHY_MIRROR_PATH" "$sfs" >/dev/null 2>&1 \
    || die "failed to unsquash the Omarchy mirror"

  local mirror="$dest/$OMARCHY_MIRROR_PATH"
  [[ -d $mirror ]] || die "Omarchy ISO has no $OMARCHY_MIRROR_PATH\n       this script targets Omarchy 4.x; older ISOs are not supported"

  local count
  count=$(find "$mirror" -name '*.pkg.tar.*' 2>/dev/null | wc -l)
  (( count > 0 )) || die "offline mirror at $OMARCHY_MIRROR_PATH contains no packages"

  # Sanity-check the packages that define the Omarchy layer.
  local p
  for p in omarchy omarchy-settings; do
    find "$mirror" -name "$p-*.pkg.tar.*" | grep -q . \
      || warn "no '$p' package in the offline mirror — the Omarchy layer may be incomplete"
  done

  ok "$count packages harvested"

  # The extracted ISO tree is large; free it now.
  rm -rf "$tree"
}

unpack_cachyos_rootfs() {
  local cachy_iso=$1

  step "Unpacking CachyOS live environment"
  info "extracting $(basename "$cachy_iso")"
  extract_iso_tree "$cachy_iso" "$ISO_ROOT"

  locate_sfs SFS_PATH "$ISO_ROOT"
  info "airootfs: ${SFS_PATH#$ISO_ROOT/}"

  info "unsquashing (this takes a few minutes)"
  rm -rf "$ROOTFS"
  unsquashfs -no-progress -d "$ROOTFS" "$SFS_PATH" >/dev/null 2>&1 \
    || die "failed to unsquash the CachyOS airootfs"

  [[ -d $ROOTFS/usr/bin ]] || die "unpacked airootfs looks wrong (no /usr/bin)"
  ok "live filesystem unpacked"
}

disable_desktop() {
  step "Disabling the desktop environment"

  # Boot to a console instead of a graphical session.
  local target="$ROOTFS/etc/systemd/system/default.target"
  mkdir -p "$(dirname "$target")"
  ln -sfn /usr/lib/systemd/system/multi-user.target "$target"
  ok "default.target → multi-user.target"

  # Belt and braces: if a display manager is enabled in the live env, unhook it.
  local dm
  for dm in sddm gdm lightdm ly greetd; do
    local unit="$ROOTFS/etc/systemd/system/display-manager.service"
    if [[ -L $unit && $(readlink "$unit") == *"$dm"* ]]; then
      rm -f "$unit"
      ok "unhooked $dm"
    fi
  done
  rm -f "$ROOTFS/etc/systemd/system/graphical.target.wants/"*.service 2>/dev/null || true
}

inject_mirror() {
  local src=$1
  step "Injecting Omarchy mirror into the live filesystem"
  mkdir -p "$ROOTFS/$(dirname "$OMARCHY_MIRROR_PATH")"
  rm -rf "${ROOTFS:?}/$OMARCHY_MIRROR_PATH"
  # -a preserves the repo db symlinks pacman needs.
  rsync -a "$src/$OMARCHY_MIRROR_PATH/" "$ROOTFS/$OMARCHY_MIRROR_PATH/"
  local size
  size=$(du -sh "$ROOTFS/$OMARCHY_MIRROR_PATH" | cut -f1)
  ok "mirror injected ($size)"
}

install_orchestrator() {
  step "Installing the Camarchy orchestrator"

  local bin="$ROOTFS/usr/local/bin/camarchy-install"
  mkdir -p "$(dirname "$bin")"
  write_orchestrator > "$bin"
  chmod 0755 "$bin"
  ok "/usr/local/bin/camarchy-install"

  # Autostart on the live user's console login. CachyOS autologs in on tty1.
  local snippet='
# Camarchy-OS: start the installer on the first console
if [[ -z ${CAMARCHY_NO_AUTOSTART:-} ]] && [[ $(tty) == /dev/tty1 ]]; then
  exec camarchy-install
fi
'
  local home
  for home in "$ROOTFS/root" "$ROOTFS/home/liveuser" "$ROOTFS/etc/skel"; do
    [[ -d $home ]] || continue
    local rc
    for rc in .bash_profile .zprofile; do
      # Only append to profiles that already exist, plus always ensure bash.
      if [[ -f $home/$rc || $rc == .bash_profile ]]; then
        grep -q 'camarchy-install' "$home/$rc" 2>/dev/null && continue
        printf '%s\n' "$snippet" >> "$home/$rc"
        ok "autostart → ${home#$ROOTFS}/$rc"
      fi
    done
  done
}

repack_rootfs() {
  step "Repacking the live filesystem"
  local tmp="$SFS_PATH.new"
  rm -f "$tmp"

  # Match archiso defaults, and keep the Omarchy mirror uncompressed so pacman
  # can read packages straight out of the squashfs, as the Omarchy ISO does.
  info "mksquashfs (this is the slow part)"
  mksquashfs "$ROOTFS" "$tmp" \
    -comp zstd -Xcompression-level 19 -b 1M -noappend -no-progress \
    -action "uncompressed@subpathname($OMARCHY_MIRROR_PATH)" \
    >/dev/null 2>&1 \
    || die "mksquashfs failed"

  mv -f "$tmp" "$SFS_PATH"
  local size
  size=$(du -sh "$SFS_PATH" | cut -f1)
  ok "airootfs.sfs rebuilt ($size)"
}

refresh_checksums() {
  step "Regenerating airootfs checksums"
  # archiso's initramfs verifies these when the 'checksum'/'verify' boot params
  # are set. Stale values would abort the boot.
  local dir
  dir=$(dirname "$SFS_PATH")
  local base
  base=$(basename "$SFS_PATH")

  ( cd "$dir"
    if [[ -f airootfs.sha512 ]]; then
      sha512sum "$base" > airootfs.sha512
      ok "airootfs.sha512"
    fi
    if [[ -f airootfs.md5 ]]; then
      md5sum "$base" > airootfs.md5
      ok "airootfs.md5"
    fi
    # A signature over the old squashfs can never be valid again.
    if [[ -f airootfs.sfs.sig ]]; then
      rm -f airootfs.sfs.sig
      warn "removed airootfs.sfs.sig (cannot re-sign); boot with verify=n if the ISO checks it"
    fi
  )
}

build_iso() {
  local source_iso=$1
  step "Building $(basename "$OUT_ISO")"

  rm -f "$OUT_ISO"
  # 'replay' copies the El Torito boot records and the isohybrid MBR from the
  # source ISO, so the result stays bootable on both BIOS and UEFI without us
  # hand-writing archiso's boot flags.
  xorriso -indev "$source_iso" \
          -outdev "$OUT_ISO" \
          -boot_image any replay \
          -volid "CAMARCHY_$(date +%Y%m)" \
          -map "$ISO_ROOT" / \
          -compliance joliet_utf16 \
          >/dev/null 2>&1 \
    || die "xorriso failed to build the ISO"

  [[ -f $OUT_ISO ]] || die "xorriso reported success but produced no ISO"
  ok "$(du -h "$OUT_ISO" | cut -f1)  $OUT_ISO"
}

# ── the in-ISO orchestrator ───────────────────────────────────────────────────
# Emitted into the live filesystem as /usr/local/bin/camarchy-install.

write_orchestrator() {
cat <<'ORCHESTRATOR'
#!/bin/bash
#
# Camarchy-OS installer — runs inside the live environment.
#
#   1. CachyOS TUI installer (interactive, no desktop)
#   2. Omarchy layer applied into the installed target
#
# Re-runnable: if the CachyOS half is already done and /mnt holds a system,
# pass --omarchy-only to skip straight to the Omarchy layer.

set -uo pipefail

readonly TARGET="${CAMARCHY_TARGET:-/mnt}"
readonly MIRROR="var/cache/omarchy/mirror/offline"
readonly LOG="/var/log/camarchy-install.log"

C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'
C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'

step() { echo -e "\n${C_BLUE}${C_BOLD}==>${C_RESET} ${C_BOLD}$*${C_RESET}" | tee -a "$LOG"; }
info() { echo -e "    $*" | tee -a "$LOG"; }
warn() { echo -e "${C_YELLOW}    warning:${C_RESET} $*" | tee -a "$LOG" >&2; }
ok()   { echo -e "${C_GREEN}    ✓${C_RESET} $*" | tee -a "$LOG"; }
fail() { echo -e "\n${C_RED}${C_BOLD}error:${C_RESET} $*" | tee -a "$LOG" >&2; }

banner() {
  clear
  cat <<'BANNER'
   ____                              _              ___  ____
  / ___|__ _ _ __ ___   __ _ _ __ __| |__  _   _   / _ \/ ___|
 | |   / _` | '_ ` _ \ / _` | '__/ _` |\ \| | | | | | | \___ \
 | |__| (_| | | | | | | (_| | | | (_| | \ \ |_| | | |_| |___) |
  \____\__,_|_| |_| |_|\__,_|_|  \__,_|  \_\__, |  \___/|____/
                                            |___/
   CachyOS base  ·  Omarchy desktop
BANNER
  echo
}

die() { fail "$*"; echo; echo "Log: $LOG"; echo "Dropping to a shell so you can inspect."; exec bash -l; }

confirm() {
  local reply
  read -rp "$1 [y/N] " reply
  [[ ${reply,,} == y* ]]
}

# ── stage 1: CachyOS ──────────────────────────────────────────────────────────

find_cachy_installer() {
  local c
  for c in cachyos-cli-installer cachy-installer cachyos-installer; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}

run_cachyos_installer() {
  step "Stage 1 of 2 — installing CachyOS"
  cat <<'NOTE'
    The CachyOS installer will start now.

    Two choices matter for Camarchy-OS:

      • Desktop environment : choose NONE / minimal.
        Omarchy provides the desktop; anything else is wasted packages.

      • Bootloader          : choose Limine, with a Btrfs root.
        Omarchy's snapshot and boot tooling is built around that pair.

NOTE
  confirm "Ready to start the CachyOS installer?" || die "aborted by user"

  local installer
  if ! installer=$(find_cachy_installer); then
    die "no CachyOS CLI installer found in the live environment\n       expected 'cachyos-cli-installer' (package: cachyos-cli-installer-new)"
  fi

  info "running $installer"
  if ! "$installer"; then
    die "the CachyOS installer exited with an error"
  fi
  ok "CachyOS installed"
}

# ── stage 2: Omarchy ──────────────────────────────────────────────────────────

ensure_target_mounted() {
  if ! mountpoint -q "$TARGET"; then
    warn "$TARGET is not mounted"
    echo "    The CachyOS installer usually leaves the new system mounted there."
    echo "    Mount your new root at $TARGET (with /boot and the ESP), then continue."
    confirm "Is the target system mounted at $TARGET now?" || die "target not mounted"
    mountpoint -q "$TARGET" || die "$TARGET is still not a mountpoint"
  fi
  [[ -d $TARGET/etc && -d $TARGET/usr ]] || die "$TARGET does not look like an installed system"
  ok "target at $TARGET"
}

detect_target_user() {
  # First non-system account in the target.
  local u
  u=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' "$TARGET/etc/passwd" 2>/dev/null || true)
  if [[ -z $u ]]; then
    warn "could not detect the user account created by the CachyOS installer"
    read -rp "    Username to set up Omarchy for: " u
  fi
  [[ -n $u ]] || die "no target user"
  id -u --root "$TARGET" "$u" >/dev/null 2>&1 || \
    grep -q "^$u:" "$TARGET/etc/passwd" || die "user '$u' does not exist in the target"
  echo "$u"
}

copy_mirror_to_target() {
  step "Copying the Omarchy package mirror into the target"
  [[ -d /$MIRROR ]] || die "offline mirror missing from the live environment (/$MIRROR)"
  mkdir -p "$TARGET/$(dirname "$MIRROR")"
  rsync -a "/$MIRROR/" "$TARGET/$MIRROR/"
  ok "$(find "$TARGET/$MIRROR" -name '*.pkg.tar.*' | wc -l) packages staged"
}

# Compose /etc/pacman.conf so CachyOS repos outrank everything and [omarchy]
# comes last. See ARCHITECTURE.md §3 — this ordering IS the update-channel
# split, and Omarchy's own post-install rewrites the file, so we reassert it.
compose_pacman_conf() {
  local conf="$TARGET/etc/pacman.conf"
  [[ -f $conf ]] || { warn "no $conf to compose"; return 0; }

  python3 - "$conf" <<'PY'
import re, sys

path = sys.argv[1]
text = open(path).read()

# Split into [options] preamble + repo blocks.
parts = re.split(r'(?m)^(?=\[)', text)
preamble, blocks = [], []
for part in parts:
    if not part.strip():
        continue
    name = re.match(r'\[([^\]]+)\]', part)
    if name and name.group(1) != 'options':
        blocks.append((name.group(1), part.rstrip() + '\n'))
    else:
        preamble.append(part.rstrip() + '\n')

def cachy_rank(name):
    # CachyOS's own ordering: newer ISA tiers outrank older, and the plain
    # [cachyos] repo comes LAST of the group. Sorting these alphabetically
    # would put [cachyos] above [cachyos-core-v3] and silently defeat the
    # x86-64-v3 optimized builds, since pacman takes the first match.
    if '-v4' in name:
        tier = 0
    elif '-v3' in name:
        tier = 1
    else:
        tier = 2
    if 'core' in name:
        sub = 1
    elif 'extra' in name:
        sub = 2
    elif name in ('cachyos', 'cachyos-v3', 'cachyos-v4'):
        sub = 0
    else:
        sub = 3
    return (tier, sub, name)

def rank(item):
    name = item[0]
    if name.startswith('cachyos'):
        return (0, cachy_rank(name))   # optimized builds win
    if name in ('core', 'extra', 'multilib'):
        return (1, (0, {'core': 0, 'extra': 1, 'multilib': 2}[name], name))
    if name == 'omarchy':
        return (3, (0, 0, name))       # desktop layer last
    return (2, (0, 0, name))           # anything else (arch-mact2, AUR helpers…)

blocks.sort(key=rank)

# Guarantee an [omarchy] stanza pointing at the on-disk mirror.
if not any(n == 'omarchy' for n, _ in blocks):
    blocks.append(('omarchy',
                   '[omarchy]\nSigLevel = Optional TrustAll\n'
                   'Server = file:///var/cache/omarchy/mirror/offline\n'))

open(path, 'w').write(''.join(preamble) + '\n' + '\n'.join(b for _, b in blocks))
print('\n'.join(n for n, _ in blocks))
PY
}

register_omarchy_repo() {
  step "Configuring pacman in the target"
  local order
  if ! order=$(compose_pacman_conf); then
    die "failed to compose $TARGET/etc/pacman.conf"
  fi
  info "repo order: $(echo "$order" | tr '\n' ' ')"

  if ! grep -q '^\[cachyos' "$TARGET/etc/pacman.conf"; then
    warn "no [cachyos*] repos in the target's pacman.conf"
    warn "base updates will NOT come from CachyOS — see ARCHITECTURE.md §3"
  else
    ok "CachyOS repos rank above [omarchy]"
  fi
}

install_omarchy_packages() {
  step "Installing Omarchy packages"
  # Local mirror, no network needed. Keyring first so the rest verifies.
  local -a pkgs=(omarchy-keyring omarchy-settings omarchy omarchy-nvim)

  # Pre-install matching kernel headers: Omarchy's DKMS logic does not
  # recognise linux-cachyos and would otherwise install none.
  # (ARCHITECTURE.md §4)
  local kernel
  kernel=$(arch-chroot "$TARGET" pacman -Qq 2>/dev/null | grep -E '^linux-cachyos(-lts)?$' | head -1 || true)
  if [[ -n $kernel ]]; then
    pkgs=("$kernel-headers" "${pkgs[@]}")
    info "adding $kernel-headers for DKMS"
  else
    warn "no linux-cachyos kernel detected in the target; skipping headers"
  fi

  if ! arch-chroot "$TARGET" pacman -Sy --noconfirm --needed "${pkgs[@]}" 2>&1 | tee -a "$LOG"; then
    die "failed to install the Omarchy packages"
  fi
  ok "Omarchy packages installed"
}

run_omarchy_setup() {
  local user=$1

  step "Running Omarchy system setup"
  if ! arch-chroot "$TARGET" omarchy-setup-system --install-user "$user" --first-install 2>&1 | tee -a "$LOG"; then
    die "omarchy-setup-system failed"
  fi
  ok "system setup complete"

  step "Running Omarchy user setup for '$user'"
  if ! arch-chroot "$TARGET" runuser -u "$user" -- omarchy-finalize-user --force --first-install 2>&1 | tee -a "$LOG"; then
    warn "omarchy-finalize-user failed; it can be re-run after first boot"
  else
    ok "user setup complete"
  fi
}

reassert_pacman_conf() {
  step "Re-asserting repository order"
  # omarchy-setup-system's post-install step overwrites pacman.conf and the
  # mirrorlist with Omarchy's own, dropping every CachyOS repo. Put it back.
  register_omarchy_repo
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  (( EUID == 0 )) || exec sudo -E "$0" "$@"

  local omarchy_only=0
  [[ ${1:-} == --omarchy-only ]] && omarchy_only=1

  : > "$LOG" 2>/dev/null || true
  banner

  if (( ! omarchy_only )); then
    run_cachyos_installer
  else
    info "skipping the CachyOS stage (--omarchy-only)"
  fi

  step "Stage 2 of 2 — applying the Omarchy layer"
  ensure_target_mounted

  local user
  user=$(detect_target_user) || die "could not determine the target user"
  ok "target user: $user"

  copy_mirror_to_target
  register_omarchy_repo
  install_omarchy_packages
  run_omarchy_setup "$user"
  reassert_pacman_conf

  step "Done"
  cat <<DONE

    Camarchy-OS is installed.

      base    → CachyOS repos
      desktop → Omarchy

    Log: $LOG

DONE
  if confirm "Reboot now?"; then
    umount -R "$TARGET" 2>/dev/null || true
    systemctl reboot
  fi
}

main "$@"
ORCHESTRATOR
}

# ── main ──────────────────────────────────────────────────────────────────────

cleanup() {
  local rc=$?
  if (( rc != 0 )) && [[ -d ${WORK_DIR:-} ]]; then
    echo -e "\n${C_DIM}    build tree kept for inspection: $WORK_DIR${C_RESET}" >&2
  fi
}
trap cleanup EXIT

main() {
  echo -e "${C_BOLD}Camarchy-OS ISO builder${C_RESET}"
  echo -e "${C_DIM}CachyOS base + Omarchy desktop${C_RESET}"

  require_root
  require_deps
  require_space

  step "Locating source ISOs"
  local cachy_iso omarchy_iso
  find_iso cachy_iso   "CachyOS" cachy cachyos
  find_iso omarchy_iso "Omarchy" omarchy
  ok "CachyOS: $(basename "$cachy_iso")"
  ok "Omarchy: $(basename "$omarchy_iso")"

  [[ $cachy_iso != "$omarchy_iso" ]] || die "both patterns matched the same file"

  mkdir -p "$WORK_DIR"
  readonly ISO_ROOT="$WORK_DIR/isoroot"
  readonly ROOTFS="$WORK_DIR/squashfs-root"
  SFS_PATH=""

  local harvest="$WORK_DIR/omarchy-mirror"
  harvest_omarchy_mirror "$omarchy_iso" "$harvest"

  unpack_cachyos_rootfs "$cachy_iso"
  disable_desktop
  inject_mirror "$harvest"
  install_orchestrator
  repack_rootfs
  refresh_checksums
  build_iso "$cachy_iso"

  step "Cleaning up"
  rm -rf "$ROOTFS" "$harvest"
  info "removed intermediate trees (kept $ISO_ROOT)"

  cat <<DONE

${C_GREEN}${C_BOLD}Built:${C_RESET} $OUT_ISO

  Test it in a VM, for example:

    qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \\
      -bios /usr/share/edk2/x64/OVMF.4m.fd \\
      -drive file=test.qcow2,if=virtio \\
      -cdrom "$OUT_ISO"

  Create the test disk first:

    qemu-img create -f qcow2 test.qcow2 40G

DONE
}

main "$@"

#!/usr/bin/env bash
#===============================================================================
# Gentoo Linux Automated Installer - AMD64 / OpenRC
#===============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[!!]${NC} $*" >&2; }
step()  { echo -e "${CYAN}==>${NC} $*"; }

cleanup() {
    warn "Script interrupted. Unmounting..."
    umount -R /mnt/gentoo 2>/dev/null || true
    exit 1
}
trap cleanup ERR INT TERM

#--- Pre-flight ---
[[ $EUID -ne 0 ]] && { err "Run as root."; exit 1; }
ping -c 1 -W 3 gentoo.org &>/dev/null || { err "No network."; exit 1; }
BOOT_MODE="bios"; [[ -d /sys/firmware/efi ]] && BOOT_MODE="uefi"
CPU_CORES=$(nproc)
info "Boot: $BOOT_MODE | Cores: $CPU_CORES"

#--- Disk selection ---
lsblk -d -o NAME,SIZE,MODEL
echo -n "Target disk (e.g., sda, nvme0n1): "; read -r TARGET_DISK
TARGET_DISK="/dev/${TARGET_DISK#/dev/}"
[[ -b "$TARGET_DISK" ]] || { err "Not a block device."; exit 1; }

if echo "$TARGET_DISK" | grep -qE 'nvme|mmcblk'; then P="${TARGET_DISK}p"; else P="$TARGET_DISK"; fi

warn "ALL DATA on $TARGET_DISK will be DESTROYED!"
echo -n "Type YES to continue: "; read -r CONFIRM
[[ "$CONFIRM" == "YES" ]] || { err "Aborted."; exit 1; }

echo -n "Swap size (e.g., 8G, or 'no'): "; read -r SWAP_SIZE
echo -n "Boot size (e.g., 512M): "; read -r BOOT_SIZE
echo -n "Root size (e.g., 'all' for remaining): "; read -r ROOT_SIZE

#--- Partition ---
step "Partitioning $TARGET_DISK"
sgdisk --zap-all "$TARGET_DISK"
wipefs -a "$TARGET_DISK" 2>/dev/null || true

if [[ "$BOOT_MODE" == "uefi" ]]; then
    sgdisk -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
    [[ "$SWAP_SIZE" != "no" ]] && sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"SWAP" "$TARGET_DISK"
    [[ "$ROOT_SIZE" == "all" ]] && sgdisk -n $((SWAP_SIZE=="no"?2:3)):0:0 -t $((SWAP_SIZE=="no"?2:3)):8304 -c $((SWAP_SIZE=="no"?2:3)):"ROOT" "$TARGET_DISK" \
                                || sgdisk -n $((SWAP_SIZE=="no"?2:3)):0:+${ROOT_SIZE} -t $((SWAP_SIZE=="no"?2:3)):8304 -c $((SWAP_SIZE=="no"?2:3)):"ROOT" "$TARGET_DISK"
else
    sgdisk -n 1:0:+2M -t 1:ef02 -c 1:"BIOS-BOOT" "$TARGET_DISK"
    sgdisk -n 2:0:+${BOOT_SIZE} -t 2:8300 -c 2:"BOOT" "$TARGET_DISK"
    [[ "$SWAP_SIZE" != "no" ]] && sgdisk -n 3:0:+${SWAP_SIZE} -t 3:8200 -c 3:"SWAP" "$TARGET_DISK"
    local n=$([[ "$SWAP_SIZE" != "no" ]] && echo 4 || echo 3)
    [[ "$ROOT_SIZE" == "all" ]] && sgdisk -n $n:0:0 -t $n:8304 -c $n:"ROOT" "$TARGET_DISK" \
                                || sgdisk -n $n:0:+${ROOT_SIZE} -t $n:8304 -c $n:"ROOT" "$TARGET_DISK"
fi
partprobe "$TARGET_DISK"; sleep 2

# Determine partition numbers
if [[ "$BOOT_MODE" == "uefi" ]]; then
    P1="${P}1"; [[ "$SWAP_SIZE" != "no" ]] && P2="${P}2" && P3="${P}3" || P2="${P}2"
else
    P1="${P}2"; [[ "$SWAP_SIZE" != "no" ]] && P2="${P}3" && P3="${P}4" || P2="${P}3"
fi

#--- Format & mount ---
step "Formatting"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkfs.vfat -F 32 -n EFI "${P}1"
    mkfs.ext4 -F -L ROOT "${P2}"
    mount "${P2}" /mnt/gentoo
    mkdir -p /mnt/gentoo/boot
    mount "${P}1" /mnt/gentoo/boot
else
    mkfs.ext4 -F -L BOOT "$P1"
    mkfs.ext4 -F -L ROOT "$P2"
    mount "$P2" /mnt/gentoo
    mkdir -p /mnt/gentoo/boot
    mount "$P1" /mnt/gentoo/boot
fi
[[ -n "${P3:-}" && "$SWAP_SIZE" != "no" ]] && mkswap -L SWAP "$P3" && swapon "$P3"

#--- Stage3 ---
step "Downloading stage3"
cd /mnt/gentoo
STAGE3=$(wget -qO- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v '^#' | head -1 | awk '{print $1}' | tr -d '\r')
[[ -z "$STAGE3" ]] && { err "Could not get stage3 filename."; exit 1; }
info "Stage3: $STAGE3"
wget -q --show-progress "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3}" -O stage3.tar.xz
wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3}.sha256" -O /tmp/stage3.sha256
sha256sum -c /tmp/stage3.sha256 --status && info "Checksum OK" || warn "Checksum FAILED"
tar xpf stage3.tar.xz --xattrs --numeric-owner && rm -f stage3.tar.xz

#--- Mount pseudo for chroot ---
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev
cp -L /etc/resolv.conf /mnt/gentoo/etc/resolv.conf

#--- Write chroot script ---
cat > /mnt/gentoo/root/chroot.sh << 'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile
export PS1="(chroot) ${PS1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "${CYAN}==>${NC} $*"; }

BOOT_MODE="${BOOT_MODE}"
CPU_CORES="${CPU_CORES}"

#--- make.conf ---
step "Configuring make.conf"
cat > /etc/portage/make.conf <<MAKE
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${CPU_CORES}"
FEATURES="\${FEATURES} parallel-fetch parallel-install userfetch"
ACCEPT_LICENSE="-* @FREE"
USE="-systemd -pulseaudio -gnome -kde -gtk -qt -wayland -X udev elogind"
EMERGE_DEFAULT_OPTS="--ask=n --quiet-build=y --with-bdeps=y"
MAKE

#--- repos.conf ---
mkdir -p /etc/portage/repos.conf
cat > /etc/portage/repos.conf/gentoo.conf <<REPO
[DEFAULT]
main-repo = gentoo
[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
REPO

#--- Sync & profile ---
step "Syncing portage tree"
emerge-webrsync 2>&1 || emerge --sync 2>&1 || warn "Sync had issues"
PROFILE=$(eselect profile list 2>/dev/null | grep -i "openrc" | grep -v "desktop\|hardened\|musl\|selinux" | grep "amd64" | tail -1 | awk '{print $1}' | tr -d '[]')
[[ -n "$PROFILE" ]] && eselect profile set "$PROFILE" && info "Profile: $(eselect profile show)"

#--- Timezone / Locales / Hostname ---
echo "Etc/UTC" > /etc/timezone; emerge --config sys-libs/timezone-data 2>/dev/null || true
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; locale-gen; eselect locale set en_US.UTF-8 2>/dev/null || true
env-update && source /etc/profile
echo "gentoo-box" > /etc/hostname

#--- Kernel ---
step "Installing kernel sources & genkernel"
emerge --autounmask-write sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/linux-firmware 2>&1 || true
yes | etc-update --automode -3 2>/dev/null || true
emerge -q sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/linux-firmware 2>&1

# Symlink kernel
KERNEL_DIR=$(ls -d /usr/src/linux-* 2>/dev/null | head -1)
[[ -n "$KERNEL_DIR" ]] && ln -sf "$KERNEL_DIR" /usr/src/linux && eselect kernel set 1 2>/dev/null || true

# Microcode
grep -qi "GenuineIntel" /proc/cpuinfo && emerge -q sys-firmware/intel-microcode 2>/dev/null || true
grep -qi "AuthenticAMD" /proc/cpuinfo && emerge -q sys-firmware/amd-microcode 2>/dev/null || true

# Build kernel with genkernel
step "Building kernel (this takes time...)"
cd /usr/src/linux
genkernel --no-mrproper --install all 2>&1 || {
    warn "genkernel failed, trying distribution kernel..."
    emerge -q sys-kernel/gentoo-kernel 2>&1
}
info "Kernel build done."

#--- Bootloader ---
step "Installing GRUB"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    emerge -q sys-boot/grub sys-boot/efibootmgr 2>&1
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --recheck 2>&1
    grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck 2>&1 || true
else
    emerge -q sys-boot/grub 2>&1
    grub-install /dev/${TARGET_DISK#/dev/} 2>&1
fi

# Write clean GRUB defaults
cat > /etc/default/grub <<GRUB
GRUB_DISTRIBUTOR="Gentoo"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="net.ifnames=0"
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=false
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
GRUB_GFXMODE=auto
GRUB
grub-mkconfig -o /boot/grub/grub.cfg 2>&1

#--- fstab ---
step "Writing fstab"
ROOT_UUID=$(findmnt -n -o UUID /)
BOOT_UUID=$(findmnt -n -o UUID /boot)
cat > /etc/fstab <<FSTAB
UUID=${ROOT_UUID}  /           ext4    defaults,noatime  0 1
UUID=${BOOT_UUID}  /boot       vfat    defaults,noatime  0 2
FSTAB
swapon --show=NAME --noheadings | head -1 | xargs -r blkid -s UUID -o value | xargs -r -I{} echo "UUID={}  none  swap  sw  0 0" >> /etc/fstab

#--- Password ---
step "Set root password"
echo "root:gentoo123" | chpasswd
info "Root password set to: gentoo123"
echo -n "Change it now? (y/n): "; read -r CHANGE
[[ "$CHANGE" == "y" ]] && passwd

#--- User ---
echo -n "Create regular user? (y/n): "; read -r CU
if [[ "$CU" == "y" ]]; then
    echo -n "Username: "; read -r U
    useradd -m -G wheel,users,audio,video,usb,portage -s /bin/bash "$U"
    passwd "$U"
fi

#--- Networking ---
emerge -q sys-apps/dhcpcd 2>&1 || true
rc-update add dhcpcd default 2>/dev/null || true

#--- Tools ---
step "Installing tools"
emerge -q app-portage/eix app-portage/gentoolkit sys-process/htop app-editors/vim net-misc/wget net-misc/curl 2>&1 || true
eix-update 2>/dev/null || true
emerge --depclean -q 2>/dev/null || true

info "Installation complete inside chroot."
CHROOT

chmod +x /mnt/gentoo/root/chroot.sh

#--- Execute ---
export BOOT_MODE CPU_CORES
chroot /mnt/gentoo /bin/bash /root/chroot.sh

#--- Cleanup ---
rm -f /mnt/gentoo/root/chroot.sh
sync
umount -R /mnt/gentoo 2>/dev/null || true

echo ""
echo -e "${GREEN}Gentoo installation complete!${NC}"
echo -n "Reboot now? (y/n): "; read -r R
[[ "$R" == "y" ]] && { info "Rebooting..."; sleep 2; reboot; }

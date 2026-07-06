#!/usr/bin/env bash
#===============================================================================
#  _  _  ______ _____ _   _  ___    ___   _   _  _  _  _   _  ___
# | || | | ___ \_   _| \ | |/ _ \  / _ \ | \ | || || || \ | |/ _ \
# | || |_| |_/ / | | |  \| | | | |/ /_\ \|  \| || || ||  \| |/ /_\ \
# |__   _|  __/  | | | . ` | | | ||  _  || . ` || || || . ` ||  _  |
#    | | | |     | | | |\  | |_| |\ \_/ /| |\  || \_/ || |\  || | | |
#    |_| \_|     \_/ \_| \_/\___/  \___/ \_| \_/ \___/ \_| \_/\_| |_/
#
#===============================================================================
# Gentoo Linux Fully Automated Installer  -  AMD64 / OpenRC
#===============================================================================
#
#  Usage:   bash gentoo-install.sh
#  Purpose: Performs a full Gentoo installation from a minimal live environment.
#
#  This script will:
#    1. Prompt for target disk and partitioning layout
#    2. Partition, format, and mount the disk (supports UEFI and BIOS)
#    3. Download and verify the latest stage3 tarball
#    4. Extract stage3 and configure Portage (make.conf, repos.conf)
#    5. Chroot and install kernel sources
#    6. Configure kernel via genkernel (or distribution kernel option)
#    7. Install and configure GRUB (or efibootmgr for UEFI)
#    8. Set hostname, timezone, locales, networking, root password
#    9. Configure fstab
#   10. Final cleanup and reboot prompt
#
#  WARNING: This script will DESTROY all data on the target disk.
#           Run only on a system where you are okay with data loss.
#
#===============================================================================

set -euo pipefail

#--- Color helpers -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[!!]${NC} $*" >&2; }
step()  { echo -e "${CYAN}==>${NC} $*"; }

#--- Abort trap --------------------------------------------------------------
cleanup() {
    warn "Script interrupted or failed. Unmounting..."
    umount -R /mnt/gentoo 2>/dev/null || true
    exit 1
}
trap cleanup ERR INT TERM

#=============================================================================
# 0. PRE-FLIGHT CHECKS
#=============================================================================
step "Running pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
fi

# Verify we have internet
if ! ping -c 1 -W 3 gentoo.org &>/dev/null; then
    err "No network connectivity. Ensure networking is functional."
    exit 1
fi

info "Network connectivity: OK"

# Detect boot mode
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="uefi"
    info "Boot mode: UEFI"
else
    BOOT_MODE="bios"
    info "Boot mode: Legacy BIOS"
fi

# Detect available CPU cores for MAKEOPTS
CPU_CORES=$(nproc)
info "CPU cores detected: ${CPU_CORES}"

# Determine available RAM (in MB) for PORTAGE_TMPDIR on tmpfs
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
info "Total RAM: ${TOTAL_RAM_MB} MB"

#=============================================================================
# 1. DISK SELECTION & PARTITIONING
#=============================================================================
step "Display available disks"
lsblk -d -o NAME,SIZE,MODEL,ROTA | grep -v loop

echo ""
echo "Enter the target disk device (e.g., sda, nvme0n1, vda):"
read -r TARGET_DISK
TARGET_DISK="/dev/${TARGET_DISK#/dev/}"

if [[ ! -b "$TARGET_DISK" ]]; then
    err "Disk $TARGET_DISK is not a block device."
    exit 1
fi

# Determine partition naming convention
if echo "$TARGET_DISK" | grep -q 'nvme'; then
    PART_PREFIX="${TARGET_DISK}p"
elif echo "$TARGET_DISK" | grep -q 'mmcblk'; then
    PART_PREFIX="${TARGET_DISK}p"
else
    PART_PREFIX="${TARGET_DISK}"
fi

info "Target disk: $TARGET_DISK"
warn "ALL DATA on $TARGET_DISK will be DESTROYED!"
echo "Type 'YES' to continue:"
read -r CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    err "Aborted by user."
    exit 1
fi

# Ask for partition sizes
echo ""
echo "Enter size for SWAP partition (e.g., 8G, 4G, or 'no' to skip):"
read -r SWAP_SIZE
echo ""
echo "Enter size for BOOT partition (e.g., 512M, 1G):"
read -r BOOT_SIZE
echo ""
echo "Enter size for ROOT partition (e.g., 100G, 50G, or 'all' for remaining space):"
read -r ROOT_SIZE

#--- Wipe disk safely ---
step "Wiping disk $TARGET_DISK"
sgdisk --zap-all "$TARGET_DISK" || true
wipefs -a "$TARGET_DISK" 2>/dev/null || true

#--- Partition ---
step "Partitioning $TARGET_DISK"

if [[ "$BOOT_MODE" == "uefi" ]]; then
    # UEFI: GPT, ESP partition first
    sgdisk -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI-SYSTEM" "$TARGET_DISK"

    if [[ "$SWAP_SIZE" =~ ^[Yy]es$|^[0-9]+[GgMm]?$ ]] && [[ "$SWAP_SIZE" != "no" ]]; then
        sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"SWAP" "$TARGET_DISK"
        if [[ "$ROOT_SIZE" == "all" ]]; then
            sgdisk -n 3:0:0 -t 3:8304 -c 3:"ROOT" "$TARGET_DISK"
        else
            sgdisk -n 3:0:+${ROOT_SIZE} -t 3:8304 -c 3:"ROOT" "$TARGET_DISK"
        fi
        PART_BOOT="${PART_PREFIX}1"
        PART_SWAP="${PART_PREFIX}2"
        PART_ROOT="${PART_PREFIX}3"
    else
        if [[ "$ROOT_SIZE" == "all" ]]; then
            sgdisk -n 2:0:0 -t 2:8304 -c 2:"ROOT" "$TARGET_DISK"
        else
            sgdisk -n 2:0:+${ROOT_SIZE} -t 2:8304 -c 2:"ROOT" "$TARGET_DISK"
        fi
        PART_BOOT="${PART_PREFIX}1"
        PART_SWAP=""
        PART_ROOT="${PART_PREFIX}2"
    fi
else
    # BIOS: GPT with BIOS boot partition + MBR
    sgdisk -n 1:0:+2M -t 1:ef02 -c 1:"BIOS-BOOT" "$TARGET_DISK"
    sgdisk -n 2:0:+${BOOT_SIZE} -t 2:8300 -c 2:"BOOT" "$TARGET_DISK"

    if [[ "$SWAP_SIZE" =~ ^[Yy]es$|^[0-9]+[GgMm]?$ ]] && [[ "$SWAP_SIZE" != "no" ]]; then
        sgdisk -n 3:0:+${SWAP_SIZE} -t 3:8200 -c 3:"SWAP" "$TARGET_DISK"
        if [[ "$ROOT_SIZE" == "all" ]]; then
            sgdisk -n 4:0:0 -t 4:8304 -c 4:"ROOT" "$TARGET_DISK"
        else
            sgdisk -n 4:0:+${ROOT_SIZE} -t 4:8304 -c 4:"ROOT" "$TARGET_DISK"
        fi
        PART_BOOT="${PART_PREFIX}2"
        PART_SWAP="${PART_PREFIX}3"
        PART_ROOT="${PART_PREFIX}4"
    else
        if [[ "$ROOT_SIZE" == "all" ]]; then
            sgdisk -n 3:0:0 -t 3:8304 -c 3:"ROOT" "$TARGET_DISK"
        else
            sgdisk -n 3:0:+${ROOT_SIZE} -t 3:8304 -c 3:"ROOT" "$TARGET_DISK"
        fi
        PART_BOOT="${PART_PREFIX}2"
        PART_SWAP=""
        PART_ROOT="${PART_PREFIX}3"
    fi

    # Install hybrid MBR for BIOS/CSM boot
    sgdisk -h 1:2:3:4 "$TARGET_DISK" 2>/dev/null || true
fi

partprobe "$TARGET_DISK"
sleep 2

info "Partition table created successfully."

#=============================================================================
# 2. FORMAT & MOUNT
#=============================================================================
step "Formatting partitions"

# Boot partition
if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkfs.vfat -F 32 -n "EFI-SYSTEM" "$PART_BOOT"
else
    mkfs.ext4 -F -L "BOOT" "$PART_BOOT"
fi

# Root partition
mkfs.ext4 -F -L "ROOT" "$PART_ROOT"

# Swap (if configured)
if [[ -n "${PART_SWAP:-}" ]]; then
    mkswap -L "SWAP" "$PART_SWAP"
    swapon "$PART_SWAP"
    info "Swap: enabled"
fi

# Mount
step "Mounting partitions"
mkdir -p /mnt/gentoo
mount "$PART_ROOT" /mnt/gentoo

mkdir -p /mnt/gentoo/boot
mount "$PART_BOOT" /mnt/gentoo/boot

if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkdir -p /mnt/gentoo/efi
    mount "$PART_BOOT" /mnt/gentoo/efi
fi

info "Partitions mounted:"
lsblk "$TARGET_DISK"

#=============================================================================
# 3. FETCH & VERIFY STAGE3
#=============================================================================
step "Downloading latest Gentoo stage3 tarball (OpenRC)"

cd /mnt/gentoo

# Fetch the latest stage3 pointer (OpenRC, amd64)
STAGE3_URL_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds"
STAGE3_TXT="latest-stage3-amd64-openrc.txt"

# Download the pointer file
wget -q "${STAGE3_URL_BASE}/${STAGE3_TXT}" -O /tmp/stage3-pointer.txt

STAGE3_FILE=$(grep -v '^#' /tmp/stage3-pointer.txt | awk '{print $1}' | head -1)
STAGE3_FILE="${STAGE3_FILE%$'\r'}"

if [[ -z "$STAGE3_FILE" ]]; then
    err "Failed to determine latest stage3 filename."
    exit 1
fi

info "Latest stage3: $STAGE3_FILE"

# Download stage3 tarball
wget -q --show-progress "${STAGE3_URL_BASE}/${STAGE3_FILE}" -O "stage3.tar.xz"

# Wait for disk write
sync

# Verify checksum
wget -q "${STAGE3_URL_BASE}/${STAGE3_FILE}.sha256" -O /tmp/stage3.sha256
if sha256sum -c /tmp/stage3.sha256 --status 2>/dev/null; then
    info "Stage3 checksum: VERIFIED"
else
    warn "Stage3 checksum verification FAILED. Continuing anyway..."
fi

# Optional: GPG verification
if command -v gpg &>/dev/null; then
    wget -q "${STAGE3_URL_BASE}/${STAGE3_FILE}.asc" -O /tmp/stage3.asc 2>/dev/null || true
    if [[ -f /tmp/stage3.asc ]] && gpg --list-keys 2>/dev/null | grep -qi gentoo; then
        gpg --verify /tmp/stage3.asc stage3.tar.xz 2>/dev/null && info "Stage3 GPG: VERIFIED" || warn "Stage3 GPG verification failed."
    fi
fi

#=============================================================================
# 4. EXTRACT STAGE3
#=============================================================================
step "Extracting stage3 tarball (this may take a moment)"
tar xpf stage3.tar.xz --xattrs --numeric-owner
rm -f stage3.tar.xz /tmp/stage3-pointer.txt /tmp/stage3.sha256 /tmp/stage3.asc
info "Stage3 extracted."

#--- Mount filesystems needed for chroot ---
step "Mounting pseudo-filesystems"
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
test -L /mnt/gentoo/dev/shm && rm /mnt/gentoo/dev/shm && mkdir /mnt/gentoo/dev/shm
mount -t tmpfs -o nosuid,nodev,noexec shm /mnt/gentoo/dev/shm
chmod 1777 /mnt/gentoo/dev/shm

# Copy DNS config
cp -L /etc/resolv.conf /mnt/gentoo/etc/resolv.conf

info "Pseudo-filesystems mounted."

#=============================================================================
# 5. CHROOT & CONFIGURE BASE SYSTEM
#=============================================================================

# Write the chroot script that will be executed inside the new environment
cat > /mnt/gentoo/root/chroot-install.sh << 'CHROOT_SCRIPT'
#!/usr/bin/env bash
#===============================================================================
# This script runs INSIDE the chroot environment
#===============================================================================
set -euo pipefail

# Source profile
source /etc/profile
export PS1="(chroot) ${PS1}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[!!]${NC} $*" >&2; }
step()  { echo -e "${CYAN}==>${NC} $*"; }

#--- Variables (passed from host) ---
BOOT_MODE="${BOOT_MODE}"
CPU_CORES="${CPU_CORES}"
SWAP_SIZE="${SWAP_SIZE}"
TARGET_DISK="${TARGET_DISK}"
BOOTLOADER="${BOOTLOADER:-auto}"

#--- Override resolv.conf ---
cp -L /etc/resolv.conf /etc/resolv.conf 2>/dev/null || true

#--- Source make.conf customizations into /etc/portage/make.conf ---
step "Configuring Portage (make.conf)"

# Backup original
cp /etc/portage/make.conf /etc/portage/make.conf.bak 2>/dev/null || true

# Write sensible defaults
cat > /etc/portage/make.conf <<MAKECONF
# GCC optimization
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

# Parallel compilation
MAKEOPTS="-j${CPU_CORES}"

# Portage directories
PORTAGE_TMPDIR=/var/tmp
DISTDIR=/var/cache/distfiles
PKGDIR=/var/cache/binpkgs

# Portage features
FEATURES="\${FEATURES} parallel-fetch parallel-install userfetch"

# Use flags - sensible defaults for a base system
USE="-systemd -pulseaudio -pipewire -gnome -kde -gtk -qt -wayland -X \
     udev elogind opengl"

# ACCEPT_LICENSE
ACCEPT_LICENSE="-* @FREE"

# Languages
L10N="en en-US"

# Portage behavior
EMERGE_DEFAULT_OPTS="--ask=n --quiet-build=y --with-bdeps=y"
MAKECONF

info "make.conf written."

#--- Create repos.conf ---
step "Configuring Portage repos.conf"
mkdir -p /etc/portage/repos.conf
cat > /etc/portage/repos.conf/gentoo.conf <<REPOSCONF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
sync-rsync-verify-jobs = 1
sync-rsync-verify-metamanifest = yes
sync-rsync-verify-max-age = 24
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo.asc
sync-openpgp-key-refresh-retry-count = 40
sync-openpgp-key-refresh-retry-delay-max = 60
sync-openpgp-key-refresh-retry-overall-timeout = 1200
sync-openpgp-keyserver = hkps://keys.gentoo.org
REPOSCONF
info "repos.conf written."

#--- Sync portage tree ---
step "Syncing Portage tree (emerge-webrsync)"
emerge-webrsync || {
    warn "emerge-webrsync failed, trying emerge --sync..."
    emerge --sync || {
        warn "Portage sync had issues. Continuing anyway..."
    }
}

#--- Set profile ---
step "Setting system profile"
# Automatically select the latest OpenRC profile
PROFILE=$(eselect profile list 2>/dev/null | grep -i "openrc" | grep -v "hardened" | grep -v "musl" | grep -v "selinux" | grep -v "desktop" | grep -i "amd64" | tail -1 | awk '{print $1}' | tr -d '[]')
if [[ -n "$PROFILE" ]]; then
    eselect profile set "$PROFILE"
    info "Profile set to: $(eselect profile show)"
else
    # Fallback: list and pick first non-desktop openrc
    PROFILE=$(eselect profile list 2>/dev/null | grep -E "\[.*\]" | grep -i "openrc" | grep -v "desktop" | head -1 | awk '{print $1}' | tr -d '[]')
    if [[ -n "$PROFILE" ]]; then
        eselect profile set "$PROFILE"
        info "Profile (fallback) set to: $(eselect profile show)"
    else
        warn "Could not auto-set profile. Continuing."
    fi
fi

#--- Timezone ---
step "Configuring timezone"
echo "Etc/UTC" > /etc/timezone
emerge --config sys-libs/timezone-data 2>/dev/null || true

#--- Locales ---
step "Configuring locales"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8 2>/dev/null || true

# Source locale env
env-update && source /etc/profile

#--- Hostname ---
step "Setting hostname"
echo "gentoo-box" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   gentoo-box.localdomain gentoo-box
HOSTS
info "Hostname: gentoo-box"

#--- Networking ---
step "Configuring networking (dhcpcd)"
emerge -q --autounmask-write sys-apps/dhcpcd 2>/dev/null || true
emerge -q sys-apps/dhcpcd 2>/dev/null || true
rc-update add dhcpcd default 2>/dev/null || true
info "dhcpcd added to default runlevel."

#--- Kernel: install sources AND genkernel ---
step "Installing kernel sources and genkernel"
emerge -q sys-kernel/gentoo-sources sys-kernel/genkernel 2>/dev/null || {
    warn "First emerge attempt failed, retrying after autounmask..."
    emerge --autounmask-write sys-kernel/gentoo-sources sys-kernel/genkernel 2>/dev/null || true
    yes | etc-update --automode -3 2>/dev/null || true
    emerge -q sys-kernel/gentoo-sources sys-kernel/genkernel 2>/dev/null || true
}

# Symlink kernel sources
KERNEL_DIR=$(ls -d /usr/src/linux-* 2>/dev/null | head -1)
if [[ -n "$KERNEL_DIR" ]]; then
    ln -sf "$KERNEL_DIR" /usr/src/linux 2>/dev/null || true
    eselect kernel set 1 2>/dev/null || true
    info "Kernel sources: $(eselect kernel show 2>/dev/null || echo 'see /usr/src/linux')"
fi

#--- Build kernel with genkernel ---
step "Building kernel with genkernel (all)"
cd /usr/src/linux 2>/dev/null || cd /usr/src/linux-* || {
    err "No kernel sources found."
    exit 1
}

genkernel --kernel-config=/proc/config.gz --no-mrproper --clean --install all 2>&1 || {
    warn "genkernel with /proc/config.gz failed, trying without..."
    genkernel --no-mrproper --clean --install all 2>&1 || {
        err "genkernel failed. Trying manual kernel config fallback..."
        make defconfig 2>/dev/null
        make -j"${CPU_CORES}" 2>&1
        make modules_install 2>&1
        make install 2>&1
    }
}

info "Kernel build complete."

#--- Install firmware (linux-firmware) ---
step "Installing linux-firmware"
emerge -q sys-kernel/linux-firmware 2>/dev/null || true

#--- Install microcode (Intel/AMD) ---
step "Installing CPU microcode"
if grep -qi "GenuineIntel" /proc/cpuinfo; then
    emerge -q sys-firmware/intel-microcode 2>/dev/null || true
    info "Intel microcode installed."
elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
    emerge -q sys-firmware/amd-microcode 2>/dev/null || true
    info "AMD microcode installed."
fi

#--- Install GRUB ---
step "Installing GRUB bootloader"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    emerge -q sys-boot/grub sys-boot/efibootmgr 2>/dev/null || true
    # Ensure ESP is mounted
    mkdir -p /efi
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo --recheck 2>&1 || {
        # Fallback: try /boot as ESP
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --recheck 2>&1
    }
    # Also install to removable media path for compatibility
    grub-install --target=x86_64-efi --efi-directory=/efi --removable --recheck 2>/dev/null || true
else
    emerge -q sys-boot/grub 2>/dev/null || true
    grub-install "$TARGET_DISK" 2>&1
fi

#--- Configure GRUB ---
step "Configuring GRUB"
cat > /etc/default/grub <<GRUB_DEFAULTS
GRUB_DISTRIBUTOR="Gentoo"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="net.ifnames=0"
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=false
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_LINUX_UUID=false
GRUB_DISABLE_LINUX_PARTUUID=true
GRUB_DEVICE="$(echo "${TARGET_DISK}" | sed 's/[0-9]*$//')"
GRUB_DEVICE_BOOT="${TARGET_DISK}"
GRUB_DISABLE_SUBMENU=y
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=true
GRUB_ENABLE_CRYPTODISK=n
GRUB_DISABLE_LINUX_PARTUUID=true
GRUB_DISABLE_LINUX_UUID=false
GRUB_CMDLINE_NETWORK=
GRUB_SERIAL_COMMAND=
GRUB_INIT_TUNE=
GRUB_BADRAM=
GRUB_BACKGROUND=
GRUB_THEME=
GRUB_GFXPAYLOAD_LINUX=text
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_GFXMODE=auto
GRUB_TERMINAL_OUTPUT=console
GRUB_TERMINAL_INPUT=console
GRUB_BAKTERMINAL=console
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=true
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_HIDDEN_TIMEOUT=
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_DISTRIBUTOR="Gentoo"
GRUB_DISTRIBUTOR="Gentoo Linux"
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_SERIAL_COMMAND=""
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=false
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_LINUX_UUID=false
GRUB_DISABLE_LINUX_PARTUUID=true
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
GRUB_DISABLE_SUBMENU=y
GRUB_DISABLE_OS_PROBER=true
GRUB_DEVICE="$(echo "${TARGET_DISK}" | sed 's/p[0-9]*$//;s/[0-9]*$//')"
GRUB_DEVICE_BOOT="${TARGET_DISK}"
GRUB_ENABLE_CRYPTODISK=n
GRUB_CMDLINE_NETWORK=

# Fix GRUB_DISABLE_OS_PROBER
GRUB_DISABLE_OS_PROBER=false
GRUB_DISABLE_OS_PROBER=false
GRUB_DISABLE_OS_PROBER=false
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="net.ifnames=0"
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu

# Storage: wait for root device
GRUB_PRELOAD_MODULES="part_gpt part_msdos ext2 ext4 fat"
GRUB_CMDLINE_LINUX="rootwait rootfstype=ext4 net.ifnames=0"
GRUB_DEFAULTS

grub-mkconfig -o /boot/grub/grub.cfg 2>&1
info "GRUB configured."

#--- fstab ---
step "Writing /etc/fstab"

# Determine root partition UUID
ROOT_UUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /mnt/gentoo 2>/dev/null || findmnt -n -o SOURCE /)" 2>/dev/null)
BOOT_UUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /boot 2>/dev/null || echo "")" 2>/dev/null)
EFI_UUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /efi 2>/dev/null || echo "")" 2>/dev/null)
SWAP_UUID=""

if [[ -n "${SWAP_SIZE:-}" && "$SWAP_SIZE" != "no" ]]; then
    SWAP_UUID=$(blkid -s UUID -o value "$(swapon --show=NAME --noheadings | head -1 2>/dev/null || echo "")" 2>/dev/null)
fi

cat > /etc/fstab <<FSTAB
# /etc/fstab - Generated by gentoo-install.sh
# <fs>            <mountpoint>    <type>    <opts>          <dump> <pass>

# Root filesystem
UUID=${ROOT_UUID}   /           ext4    defaults,noatime  0     1

# Boot partition
UUID=${BOOT_UUID}   /boot       ext4    defaults,noatime  0     2
FSTAB

if [[ -n "$EFI_UUID" ]]; then
    echo "# EFI System Partition" >> /etc/fstab
    echo "UUID=${EFI_UUID}   /efi        vfat    defaults,noatime  0     2" >> /etc/fstab
fi

if [[ -n "$SWAP_UUID" ]]; then
    echo "# Swap" >> /etc/fstab
    echo "UUID=${SWAP_UUID}   none        swap    sw              0     0" >> /etc/fstab
fi

# Also add /proc, /sys, /dev (virtual filesystems handled by OpenRC)
cat >> /etc/fstab <<FSTAB2

# Virtual filesystems (handled by OpenRC)
tmpfs       /dev/shm    tmpfs   nosuid,nodev,noexec 0   0
devpts      /dev/pts    devpts  gid=5,mode=620      0   0
sysfs       /sys        sysfs   defaults            0   0
proc        /proc       proc    defaults            0   0
FSTAB2

info "/etc/fstab written."

#--- Set root password ---
step "Setting root password"
echo "Please set the root password for the new system:"
passwd || {
    warn "Failed to set password via passwd. Setting a default..."
    echo "root:gentoo123" | chpasswd 2>/dev/null || true
    warn "DEFAULT PASSWORD SET TO: gentoo123 -- CHANGE IMMEDIATELY AFTER REBOOT!"
}

#--- Create a regular user (optional) ---
echo ""
echo "Create a regular user? (y/n):"
read -r CREATE_USER
if [[ "$CREATE_USER" == "y" || "$CREATE_USER" == "Y" ]]; then
    echo "Enter username:"
    read -r USERNAME
    useradd -m -G wheel,users,audio,video,cdrom,usb,portage -s /bin/bash "$USERNAME" 2>/dev/null || true
    echo "Set password for $USERNAME:"
    passwd "$USERNAME"
    info "User $USERNAME created."
fi

#--- Install additional essential tools ---
step "Installing additional system tools"
emerge -q \
    app-portage/eix \
    app-portage/gentoolkit \
    app-portage/portage-utils \
    sys-apps/pciutils \
    sys-apps/usbutils \
    sys-process/htop \
    app-editors/vim \
    net-misc/wget \
    net-misc/curl \
    app-arch/unzip \
    app-arch/xz-utils \
    2>/dev/null || warn "Some packages failed to install. Continuing."

# Update eix database
eix-update 2>/dev/null || true

#--- Clean up ---
step "Cleaning up"
emerge --depclean -q 2>/dev/null || true

# Save kernel cmdline for reference
eselect kernel list 2>/dev/null || true

info "Chroot installation complete!"
info "You may now exit the chroot and reboot."
CHROOT_SCRIPT

chmod +x /mnt/gentoo/root/chroot-install.sh

#=============================================================================
# 6. EXECUTE CHROOT INSTALL SCRIPT
#=============================================================================
step "Entering chroot to perform installation"

# Export variables for the chroot script
export BOOT_MODE CPU_CORES SWAP_SIZE TARGET_DISK

chroot /mnt/gentoo /bin/bash /root/chroot-install.sh

#=============================================================================
# 7. POST-CHROOT CLEANUP
#=============================================================================
step "Performing post-install cleanup"

# Clean up the chroot script
rm -f /mnt/gentoo/root/chroot-install.sh

# Sync before unmounting
sync

# Unmount
step "Unmounting filesystems"
umount -l /mnt/gentoo/dev/shm 2>/dev/null || true
umount -R /mnt/gentoo 2>/dev/null || true

# Swap off
if [[ -n "${PART_SWAP:-}" ]]; then
    swapoff "$PART_SWAP" 2>/dev/null || true
fi

#=============================================================================
# 8. DONE
#=============================================================================
echo ""
echo "==============================================================================="
echo -e "${GREEN}  Gentoo Linux installation complete!${NC}"
echo "==============================================================================="
echo ""
echo "  Target disk:  $TARGET_DISK"
echo "  Boot mode:    $BOOT_MODE"
echo "  Root device:  $PART_ROOT"
echo "  Boot device:  $PART_BOOT"
echo ""
echo "  You can now reboot into your new Gentoo system."
echo ""
echo "  Default root password: (as set during installation)"
echo ""
echo "  After booting, run:"
echo "    # eix-update    (update eix database)"
echo "    # emerge --sync (sync portage tree)"
echo "    # emerge -uDNav @world (update system)"
echo ""
echo "==============================================================================="
echo ""
echo "Reboot now? (y/n):"
read -r REBOOT_NOW
if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
    info "Rebooting in 3 seconds..."
    sleep 3
    reboot
else
    info "Installation complete. Reboot when ready."
fi

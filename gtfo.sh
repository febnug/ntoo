#!/bin/bash
#===============================================================================
# Gentoo Linux Full Desktop Installer — Two-Phase Automated Installer
# 
# USAGE:
#   Phase 1 (from LiveISO):
#     # Make sure you have a working internet connection and a target disk
#     # You may want to edit the variables below (DISK, etc.)
#     chmod +x gentoo-installer.sh
#     ./gentoo-installer.sh phase1
#
#   Phase 2 (automatically runs in chroot — or manually):
#     # After phase1 drops you into the chroot, run:
#     ./gentoo-installer.sh phase2
#
# WARNING: This will COMPLETELY WIPE the target disk. All data will be lost.
#===============================================================================

set -euo pipefail

# ============================= CONFIGURATION ==================================
# --- EDIT THESE TO MATCH YOUR HARDWARE ---
DISK="/dev/nvme0n1"           # Target disk (e.g., /dev/sda, /dev/nvme0n1)
HOSTNAME="gentoo-box"
ROOT_PASSWORD="gentoo"
USERNAME="user"
USER_PASSWORD="user"

# --- Desktop environment selection (choose ONE) ---
# Options: "plasma", "gnome", "xfce", "lxqt", "budgie", "sway"
DESKTOP="plasma"
# Init system: "openrc" or "systemd"
INIT_SYSTEM="openrc"

# --- EFI vs BIOS ---
# Auto-detected below, but force with: UEFI=true or UEFI=false
UEFI=""

# --- Mirrors ---
GENTOO_MIRROR="https://distfiles.gentoo.org"
# ==============================================================================

# ============================= AUTO-DETECTION =================================
[[ -z "$UEFI" ]] && [[ -d /sys/firmware/efi ]] && UEFI=true || UEFI=false

if [[ "$UEFI" == "true" ]]; then
    PARTITION_TYPE="gpt"
    BOOT_PARTITION="${DISK}p1"   # EFI system partition
    ROOT_PARTITION="${DISK}p2"   # Root partition
else
    PARTITION_TYPE="msdos"
    BOOT_PARTITION="${DISK}p1"   # /boot (or / for BIOS)
    ROOT_PARTITION="${DISK}p2"
fi

# Stage3 selection based on init system and desktop
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    STAGE3_BASE="stage3-amd64-desktop-systemd"
else
    STAGE3_BASE="stage3-amd64-desktop-openrc"
fi

# EFI partition label (FAT32 filesystem label)
EFI_LABEL="EFI"
# ==============================================================================

# ============================= HELPER FUNCTIONS ===============================
info()  { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[+]\033[0m $*"; }
err()   { echo -e "\033[1;31m[-]\033[0m $*" >&2; }
die()   { err "$*"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root."
}

check_internet() {
    ping -c 1 -W 3 8.8.8.8 &>/dev/null || \
        die "No internet connection. Please connect to the internet first."
}

get_disk_suffix() {
    # Returns p1/p2 for NVMe, 1/2 for sdX
    [[ "$DISK" =~ nvme ]] && echo "p" || echo ""
}
# ==============================================================================

# ============================= PHASE 1 — LiveISO ==============================
phase1() {
    check_root
    check_internet

    local suffix
    suffix=$(get_disk_suffix)
    BOOT_PARTITION="${DISK}${suffix}1"
    ROOT_PARTITION="${DISK}${suffix}2"

    info "Target disk:     $DISK"
    info "Boot partition:  $BOOT_PARTITION"
    info "Root partition:  $ROOT_PARTITION"
    info "Partition table: $PARTITION_TYPE"
    info "Init system:     $INIT_SYSTEM"
    info "Desktop:         $DESKTOP"
    info "Hostname:        $HOSTNAME"
    echo ""
    echo -e "\033[1;31m⚠  WARNING: ALL DATA ON $DISK WILL BE DESTROYED!\033[0m"
    echo -n "Type 'YES' to continue: "
    read -r confirmation
    [[ "$confirmation" == "YES" ]] || die "Aborted."

    # ----- Partitioning -----
    info "Partitioning $DISK with $PARTITION_TYPE layout..."
    if [[ "$UEFI" == "true" ]]; then
        parted --script "$DISK" \
            mklabel gpt \
            mkpart primary fat32 1MiB 512MiB \
            set 1 esp on \
            mkpart primary 512MiB 100%
    else
        parted --script "$DISK" \
            mklabel msdos \
            mkpart primary ext4 1MiB 100% \
            set 1 boot on
    fi
    sync
    sleep 2
    ok "Partitioning done."

    # ----- Formatting -----
    if [[ "$UEFI" == "true" ]]; then
        info "Formatting EFI partition ($BOOT_PARTITION) as FAT32..."
        mkfs.fat -F 32 "$BOOT_PARTITION"
    else
        info "Formatting boot partition ($BOOT_PARTITION) as ext4..."
        mkfs.ext4 -F "$BOOT_PARTITION"
    fi

    info "Formatting root partition ($ROOT_PARTITION) as ext4..."
    mkfs.ext4 -F "$ROOT_PARTITION"
    ok "Formatting done."

    # ----- Mounting -----
    info "Mounting partitions..."
    mount "$ROOT_PARTITION" /mnt/gentoo
    if [[ "$UEFI" == "true" ]]; then
        mount --mkdir "$BOOT_PARTITION" /mnt/gentoo/boot
    fi
    ok "Partitions mounted."

    # ----- Download and extract stage3 -----
    info "Fetching latest $STAGE3_BASE tarball URL..."
    local stage3_path stage3_url
    stage3_path=$(wget -qO- \
        "${GENTOO_MIRROR}/releases/amd64/autobuilds/latest-${STAGE3_BASE}.txt" \
        | grep -v '^#' | grep '\.tar\.xz$' | cut -d' ' -f1)

    stage3_url="${GENTOO_MIRROR}/releases/amd64/autobuilds/${stage3_path}"

    info "Downloading stage3: $stage3_url"
    wget -q --show-progress -O /mnt/gentoo/stage3.tar.xz "$stage3_url"

    info "Extracting stage3 (this may take a while)..."
    tar xpf /mnt/gentoo/stage3.tar.xz \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C /mnt/gentoo/
    rm -f /mnt/gentoo/stage3.tar.xz
    ok "Stage3 extracted."

    # ----- Copy installer script into chroot -----
    cp "$0" /mnt/gentoo/root/gentoo-installer.sh
    chmod +x /mnt/gentoo/root/gentoo-installer.sh

    # ----- Mount necessary filesystems -----
    info "Mounting pseudo-filesystems..."
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run

    # ----- Copy DNS info -----
    cp -L /etc/resolv.conf /mnt/gentoo/etc/

    ok "Phase 1 complete. Entering chroot..."
    chroot /mnt/gentoo /bin/bash -c "
        source /etc/profile
        export PS1='(chroot) \w \$ '
        export INIT_SYSTEM='$INIT_SYSTEM'
        export DESKTOP='$DESKTOP'
        export HOSTNAME='$HOSTNAME'
        export ROOT_PASSWORD='$ROOT_PASSWORD'
        export USERNAME='$USERNAME'
        export USER_PASSWORD='$USER_PASSWORD'
        export UEFI='$UEFI'
        export BOOT_PARTITION='$BOOT_PARTITION'
        export DISK='$DISK'
        cd /root
        echo 'Run the following to start Phase 2:'
        echo '  ./gentoo-installer.sh phase2'
        exec /bin/bash --login
    "

    # ----- Cleanup after chroot exit -----
    info "Unmounting and rebooting..."
    umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
    umount -R /mnt/gentoo 2>/dev/null || true
    ok "All partitions unmounted. You may now reboot."
}
# ==============================================================================

# ============================= PHASE 2 — Inside Chroot ========================
phase2() {
    check_root

    info "Configuring Gentoo system with $DESKTOP desktop ($INIT_SYSTEM)..."

    # ----- Set timezone -----
    info "Setting timezone to UTC..."
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    echo "UTC" > /etc/timezone

    # ----- Configure locale -----
    info "Configuring locale..."
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    eselect locale set en_US.UTF-8
    env-update && source /etc/profile

    # ----- Set hostname -----
    echo "$HOSTNAME" > /etc/hostname

    # ----- /etc/fstab generation -----
    info "Generating /etc/fstab..."
    cat > /etc/fstab <<FSTAB
# /etc/fstab: static file system information
# <fs>                  <mountpoint>    <type>  <opts>      <dump/pass>
$(blkid -s UUID -o value "$ROOT_PARTITION") /               ext4    noatime,discard 0 1
FSTAB
    if [[ "$UEFI" == "true" ]]; then
        cat >> /etc/fstab <<FSTAB
$(blkid -s UUID -o value "$BOOT_PARTITION") /boot           vfat    noatime,defaults 0 2
FSTAB
    fi
    ok "fstab generated."

    # ----- Portage configuration -----
    info "Configuring Portage..."
    mkdir -p /etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf

    # Parallel builds and optimized MAKEOPTS
    local ncores
    ncores=$(nproc)
    cat >> /etc/portage/make.conf <<MAKECONF

# --- Optimizations ---
MAKEOPTS="-j$((ncores + 1))"
EMERGE_DEFAULT_OPTS="--jobs=$ncores --load-average=$ncores --keep-going --with-bdeps=y"
FEATURES="\${FEATURES} parallel-fetch parallel-install"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
MAKECONF

    # Enable binary package host for faster installs
    mkdir -p /etc/portage/binrepos.conf
    cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<BINHOST
[gentoobinhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
BINHOST

    # Accept licenses and keywords for desktop
    mkdir -p /etc/portage/package.license
    cat > /etc/portage/package.license/accept <<LIC
# Accept all licenses for desktop use (firmware, codecs, etc.)
*/* * 
LIC

    cat > /etc/portage/package.accept_keywords/desktop <<KEY
# Desktop-related packages from ~arch
*/*::gentoo ~amd64
KEY

    # ----- Sync portage tree -----
    info "Syncing Portage tree..."
    emerge-webrsync 2>&1 | tail -5 || emerge --sync 2>&1 | tail -5

    # ----- Select profile -----
    info "Selecting profile..."
    # Map desktop names to Gentoo profile suffixes
    local profile_suffix
    case "$DESKTOP" in
        plasma) profile_suffix="desktop/plasma" ;;
        gnome)  profile_suffix="desktop/gnome" ;;
        xfce)   profile_suffix="desktop" ;;  # xfce under generic desktop
        lxqt)   profile_suffix="desktop" ;;
        budgie) profile_suffix="desktop" ;;
        sway)   profile_suffix="desktop" ;;  # Wayland/compositor
        *)      profile_suffix="desktop" ;;
    esac

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        profile_suffix="${profile_suffix}/systemd"
    fi

    # For XFCE, LXQt, Budgie, Sway — no specific subprofile, use desktop/systemd or desktop
    if [[ "$DESKTOP" =~ ^(xfce|lxqt|budgie|sway)$ ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            profile_suffix="desktop/systemd"
        else
            profile_suffix="desktop"
        fi
    fi

    eselect profile set "default/linux/amd64/17.1/${profile_suffix}"
    ok "Profile set to: $(eselect profile show)"

    # ----- Update @world with new profile -----
    info "Updating @world (this will compile the base desktop toolchain)..."
    emerge --update --deep --newuse @world 2>&1 | tail -10

    # ----- Install kernel -----
    info "Installing Linux kernel (gentoo-sources)..."
    emerge sys-kernel/gentoo-sources
    emerge sys-kernel/genkernel

    info "Configuring and building kernel with genkernel..."
    cd /usr/src/linux || die "Kernel sources not found!"
    genkernel all --kernel-config=/proc/config.gz 2>&1 | tail -10 || \
        genkernel all 2>&1 | tail -10
    ok "Kernel built."

    # ----- Install firmware -----
    info "Installing firmware..."
    emerge sys-kernel/linux-firmware

    # ----- Install system tools -----
    info "Installing system utilities..."
    emerge app-admin/sysklogd sys-process/cronie net-misc/dhcpcd net-wireless/iw \
           net-wireless/wpa_supplicant sys-apps/mlocate app-editors/vim \
           app-portage/eix app-portage/gentoolkit

    # Init system specific
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        emerge sys-fs/e2fsprogs sys-fs/dosfstools
        rc-update add sysklogd default
        rc-update add cronie default
        rc-update add dhcpcd default
        rc-update add elogind boot
    else
        systemctl enable sysklogd
        systemctl enable cronie
        systemctl enable dhcpcd
        systemctl enable systemd-networkd
    fi

    # ----- Install bootloader -----
    info "Installing bootloader..."
    if [[ "$UEFI" == "true" ]]; then
        emerge sys-boot/grub sys-boot/efibootmgr
        grub-install --target=x86_64-efi --efi-directory=/boot
    else
        emerge sys-boot/grub
        grub-install "$DISK"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
    ok "Bootloader installed."

    # ----- Configure networking (hostname) -----
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat > /etc/conf.d/hostname <<HOST
hostname="$HOSTNAME"
HOST
    fi

    # ----- Set root password -----
    info "Setting root password..."
    echo "root:${ROOT_PASSWORD}" | chpasswd

    # ----- Create user -----
    info "Creating user '$USERNAME'..."
    useradd -m -G wheel,users,audio,video,cdrom,usb,portage "$USERNAME"
    echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

    # sudo setup
    emerge app-admin/sudo
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
    chmod 0440 /etc/sudoers.d/wheel

    # ----- Install desktop environment -----
    case "$DESKTOP" in
        plasma)
            info "Installing KDE Plasma..."
            emerge --autounmask-continue @plasma 2>&1 | tail -10 || \
                emerge --autounmask-continue plasma-meta 2>&1 | tail -10
            # Install a few extra apps
            emerge kde-apps/kate kde-apps/dolphin kde-apps/konsole \
                   kde-apps/gwenview kde-apps/okular www-client/firefox
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add sddm default
                emerge x11-misc/sddm
            else
                systemctl enable sddm
            fi
            ;;
        gnome)
            info "Installing GNOME..."
            emerge --autounmask-continue gnome-base/gnome 2>&1 | tail -10
            emerge www-client/firefox
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add gdm default
                rc-update add elogind boot
            else
                systemctl enable gdm
            fi
            ;;
        xfce)
            info "Installing XFCE..."
            emerge --autounmask-continue xfce-base/xfce4-meta 2>&1 | tail -10
            emerge x11-terms/xfce4-terminal www-client/firefox \
                   xfce-extra/xfce4-notifyd
            # LightDM as display manager
            emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add lightdm default
            else
                systemctl enable lightdm
            fi
            ;;
        lxqt)
            info "Installing LXQt..."
            emerge --autounmask-continue lxqt-base/lxqt-meta 2>&1 | tail -10
            emerge x11-misc/sddm www-client/firefox
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add sddm default
            else
                systemctl enable sddm
            fi
            ;;
        budgie)
            info "Installing Budgie..."
            emerge --autounmask-continue budgie-desktop 2>&1 | tail -10
            emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter \
                   www-client/firefox
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add lightdm default
            else
                systemctl enable lightdm
            fi
            ;;
        sway)
            info "Installing Sway (Wayland tiling compositor)..."
            emerge --autounmask-continue gui-wm/sway 2>&1 | tail -10
            emerge gui-apps/waybar gui-apps/dunst gui-apps/wofi \
                   gui-apps/alacritty www-client/firefox
            # Sway doesn't need a DM — can start from ~/.bash_profile
            mkdir -p /home/$USERNAME/.config/sway
            cp /etc/sway/config /home/$USERNAME/.config/sway/config
            chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
            # Create a login manager override to start sway automatically
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                # systemd with `systemctl --user enable sway`
                :
            fi
            ;;
    esac

    # ----- Install audio (PipeWire) -----
    info "Installing PipeWire audio..."
    emerge --autounmask-continue media-video/pipewire media-sound/pulseaudio \
           media-sound/wireplumber
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add pipewire default 2>/dev/null || true
        rc-update add wireplumber default 2>/dev/null || true
    else
        systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
    fi

    # ----- Install fonts and theming -----
    info "Installing fonts and themes..."
    emerge media-fonts/noto media-fonts/noto-cjk media-fonts/dejavu \
           media-fonts/font-awesome media-fonts/liberation-fonts

    # ----- Update environment -----
    env-update && source /etc/profile

    # ----- Final @world update -----
    info "Final @world update..."
    emerge --update --deep --newuse @world 2>&1 | tail -5

    # ----- Cleanup -----
    info "Cleaning up..."
    emerge --depclean
    revdep-rebuild --quiet 2>/dev/null || true

    ok "================================================"
    ok "  Gentoo installation complete!"
    ok "  Hostname: $HOSTNAME"
    ok "  Desktop:  $DESKTOP"
    ok "  Init:     $INIT_SYSTEM"
    ok "  User:     $USERNAME / $USER_PASSWORD"
    ok "  Root:     root / $ROOT_PASSWORD"
    ok "================================================"
    ok "Type 'exit' to leave chroot, then reboot."
    ok "After reboot, log in as $USERNAME and enjoy!"
}
# ==============================================================================

# ============================= MAIN ===========================================
case "${1:-}" in
    phase1) phase1 ;;
    phase2) phase2 ;;
    *)
        echo "Usage: $0 {phase1|phase2}"
        echo ""
        echo "  phase1  — Run from LiveISO: partitions, downloads stage3, chroots"
        echo "  phase2  — Run inside chroot after phase1: configures & installs desktop"
        echo ""
        echo "Edit the configuration variables at the top of this script before running."
        exit 1
        ;;
esac

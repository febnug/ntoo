#!/bin/bash
#===============================================================================
# Gentoo Linux Full Desktop Installer — Two-Phase Automated Installer
#
# USAGE:
#   Phase 1 (from LiveISO):
#     chmod +x gentoo-installer.sh
#     ./gentoo-installer.sh phase1
#
#   Phase 2 (inside chroot after phase1):
#     ./gentoo-installer.sh phase2
#
# WARNING: This will COMPLETELY WIPE the target disk. All data will be lost.
#===============================================================================

set -euo pipefail

# ============================= CONFIGURATION ==================================
DISK="/dev/sda"               # Target disk (e.g., /dev/sda, /dev/nvme0n1)
HOSTNAME="gentoo-box"
ROOT_PASSWORD="gentoo"
USERNAME="user"
USER_PASSWORD="user"

# Desktop: plasma, gnome, xfce, lxqt, budgie, sway
DESKTOP="plasma"
# Init system: openrc or systemd
INIT_SYSTEM="openrc"

GENTOO_MIRROR="https://distfiles.gentoo.org"
# ==============================================================================

# ============================= AUTO-DETECTION =================================
[[ -d /sys/firmware/efi ]] && UEFI=true || UEFI=false

# Partition suffix logic: nvme0n1 -> "p", sdX -> ""
if [[ "$DISK" =~ nvme ]]; then
    PART_SUFFIX="p"
else
    PART_SUFFIX=""
fi

BOOT_PART="${DISK}${PART_SUFFIX}1"
ROOT_PART="${DISK}${PART_SUFFIX}2"

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    STAGE3_BASE="stage3-amd64-desktop-systemd"
else
    STAGE3_BASE="stage3-amd64-desktop-openrc"
fi
# ==============================================================================

# ============================= HELPERS ========================================
info()  { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[+]\033[0m $*"; }
err()   { echo -e "\033[1;31m[-]\033[0m $*" >&2; }
die()   { err "$*"; exit 1; }
# ==============================================================================

# ============================= PHASE 1 ========================================
phase1() {
    [[ $EUID -eq 0 ]] || die "Must be root."
    ping -c 1 -W 3 8.8.8.8 &>/dev/null || die "No internet."

    echo ""
    info "=================== Phase 1 ==================="
    info "Disk:            $DISK"
    info "Boot partition:  $BOOT_PART"
    info "Root partition:  $ROOT_PART"
    info "UEFI:            $UEFI"
    info "Init:            $INIT_SYSTEM"
    info "Desktop:         $DESKTOP"
    echo ""
    echo -e "\033[1;31m⚠  ALL DATA ON $DISK WILL BE DESTROYED!\033[0m"
    echo -n "Type 'YES' to continue: "
    read -r c
    [[ "$c" == "YES" ]] || die "Aborted."

    # ---- Partition using sfdisk (fast, reliable, scriptable) ----
    info "Wiping existing partition table on $DISK..."
    wipefs -af "$DISK" >/dev/null 2>&1 || true
    dd if=/dev/zero of="$DISK" bs=1M count=4 2>/dev/null || true
    sync
    sleep 1

    info "Creating partition table with sfdisk..."
    if [[ "$UEFI" == "true" ]]; then
        # GPT layout: 512MiB ESP + rest as root
        sfdisk "$DISK" <<SFEOF
label: gpt
unit: sectors
${BOOT_PART} : start=2048, size=$((512*1024*1024/512)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
${ROOT_PART} : start=$((2048 + 512*1024*1024/512)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
SFEOF
    else
        # MBR layout: whole disk as one primary bootable partition
        sfdisk "$DISK" <<SFEOF
label: dos
unit: sectors
${BOOT_PART} : start=2048, type=83, bootable
SFEOF
    fi
    sync
    udevadm settle || true
    sleep 2
    ok "Partitioning complete."
    lsblk "$DISK"

    # ---- Format ----
    if [[ "$UEFI" == "true" ]]; then
        info "Formatting ESP ($BOOT_PART) as FAT32..."
        mkfs.fat -F 32 "$BOOT_PART"
    else
        info "Formatting $BOOT_PART as ext4..."
        mkfs.ext4 -F "$BOOT_PART"
    fi
    info "Formatting $ROOT_PART as ext4..."
    mkfs.ext4 -F "$ROOT_PART"
    ok "Formatting complete."

    # ---- Mount ----
    info "Mounting partitions..."
    mkdir -p /mnt/gentoo
    mount "$ROOT_PART" /mnt/gentoo
    if [[ "$UEFI" == "true" ]]; then
        mkdir -p /mnt/gentoo/boot
        mount "$BOOT_PART" /mnt/gentoo/boot
    fi
    ok "Mounted."
    lsblk "$DISK"

    # ---- Stage3 ----
    info "Fetching latest $STAGE3_BASE URL..."
    stage3_path=$(wget -qO- \
        "${GENTOO_MIRROR}/releases/amd64/autobuilds/latest-${STAGE3_BASE}.txt" \
        | grep -v '^#' | grep '\.tar\.xz$' | cut -d' ' -f1)
    [[ -n "$stage3_path" ]] || die "Could not fetch stage3 path."

    stage3_url="${GENTOO_MIRROR}/releases/amd64/autobuilds/${stage3_path}"
    info "Downloading stage3 tarball..."
    wget -q --show-progress -O /mnt/gentoo/stage3.tar.xz "$stage3_url"

    info "Extracting stage3..."
    tar xpf /mnt/gentoo/stage3.tar.xz \
        --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo/
    rm -f /mnt/gentoo/stage3.tar.xz
    ok "Stage3 extracted."

    # ---- Copy self into chroot ----
    cp "$0" /mnt/gentoo/root/gentoo-installer.sh
    chmod +x /mnt/gentoo/root/gentoo-installer.sh

    # ---- Mount pseudo-fs ----
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run
    cp -L /etc/resolv.conf /mnt/gentoo/etc/

    ok "Phase 1 done. Entering chroot. Run:  ./gentoo-installer.sh phase2"
    echo ""

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
        export BOOT_PART='$BOOT_PART'
        export ROOT_PART='$ROOT_PART'
        export DISK='$DISK'
        export PART_SUFFIX='$PART_SUFFIX'
        cd /root
        exec /bin/bash --login
    "

    # Cleanup
    info "Unmounting..."
    umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
    umount -R /mnt/gentoo 2>/dev/null || true
    ok "Unmounted. You may reboot."
}

# ============================= PHASE 2 ========================================
phase2() {
    [[ $EUID -eq 0 ]] || die "Must be root."

    info "=================== Phase 2 ==================="

    # ---- Timezone ----
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    echo "UTC" > /etc/timezone

    # ---- Locale ----
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    eselect locale set en_US.UTF-8 2>/dev/null || true
    env-update && source /etc/profile

    # ---- Hostname ----
    echo "$HOSTNAME" > /etc/hostname

    # ---- fstab ----
    info "Generating /etc/fstab..."
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null)
    cat > /etc/fstab <<FSTAB
# /etc/fstab
UUID=${ROOT_UUID} / ext4 noatime,discard 0 1
FSTAB
    if [[ "$UEFI" == "true" ]]; then
        BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART" 2>/dev/null)
        echo "UUID=${BOOT_UUID} /boot vfat noatime,defaults 0 2" >> /etc/fstab
    fi
    cat /etc/fstab
    ok "fstab done."

    # ---- Portage setup ----
    info "Configuring Portage..."
    mkdir -p /etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf 2>/dev/null || true

    ncores=$(nproc)
    cat >> /etc/portage/make.conf <<MAKECONF

MAKEOPTS="-j$((ncores + 1))"
EMERGE_DEFAULT_OPTS="--jobs=$ncores --load-average=$ncores --keep-going --with-bdeps=y"
FEATURES="\${FEATURES} parallel-fetch parallel-install"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
MAKECONF

    mkdir -p /etc/portage/binrepos.conf
    cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<BINHOST
[gentoobinhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
BINHOST

    mkdir -p /etc/portage/package.license
    echo '*/* *' > /etc/portage/package.license/accept
    mkdir -p /etc/portage/package.accept_keywords
    echo '*/*::gentoo ~amd64' > /etc/portage/package.accept_keywords/desktop

    # ---- Sync ----
    info "Syncing portage tree..."
    emerge-webrsync 2>&1 | tail -5 || emerge --sync 2>&1 | tail -5

    # ---- Profile ----
    info "Setting profile..."
    case "$DESKTOP" in
        plasma) psfx="desktop/plasma" ;;
        gnome)  psfx="desktop/gnome" ;;
        *)      psfx="desktop" ;;
    esac
    [[ "$INIT_SYSTEM" == "systemd" ]] && psfx="${psfx}/systemd"
    eselect profile set "default/linux/amd64/17.1/${psfx}"
    ok "Profile: $(eselect profile show)"

    # ---- @world update ----
    info "Updating @world (this takes a while)..."
    emerge --update --deep --newuse @world 2>&1 | tail -10

    # ---- Kernel ----
    info "Installing kernel..."
    emerge sys-kernel/gentoo-sources sys-kernel/genkernel
    cd /usr/src/linux || die "No kernel sources"
    genkernel all 2>&1 | tail -10
    ok "Kernel built."

    # ---- Firmware ----
    emerge sys-kernel/linux-firmware

    # ---- System tools ----
    info "Installing system utilities..."
    emerge app-admin/sysklogd sys-process/cronie net-misc/dhcpcd \
           net-wireless/iw net-wireless/wpa_supplicant sys-apps/mlocate \
           app-editors/vim app-portage/eix app-portage/gentoolkit

    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add sysklogd default
        rc-update add cronie default
        rc-update add dhcpcd default
        rc-update add elogind boot
    else
        systemctl enable sysklogd cronie dhcpcd systemd-networkd
    fi

    # ---- Bootloader ----
    info "Installing GRUB..."
    if [[ "$UEFI" == "true" ]]; then
        emerge sys-boot/grub sys-boot/efibootmgr
        grub-install --target=x86_64-efi --efi-directory=/boot
    else
        emerge sys-boot/grub
        grub-install "$DISK"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
    ok "GRUB installed."

    # ---- Users ----
    echo "root:${ROOT_PASSWORD}" | chpasswd
    useradd -m -G wheel,users,audio,video,cdrom,usb,portage "$USERNAME"
    echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
    emerge app-admin/sudo
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    chmod 0440 /etc/sudoers.d/wheel

    # ---- Desktop ----
    case "$DESKTOP" in
        plasma)
            info "Installing KDE Plasma..."
            emerge --autounmask-continue plasma-meta 2>&1 | tail -10
            emerge kde-apps/{kate,dolphin,konsole,gwenview} www-client/firefox
            emerge x11-misc/sddm
            [[ "$INIT_SYSTEM" == "openrc" ]] && rc-update add sddm default || systemctl enable sddm
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
            emerge x11-terms/xfce4-terminal www-client/firefox xfce-extra/xfce4-notifyd
            emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter
            [[ "$INIT_SYSTEM" == "openrc" ]] && rc-update add lightdm default || systemctl enable lightdm
            ;;
        sway)
            info "Installing Sway..."
            emerge --autounmask-continue gui-wm/sway 2>&1 | tail -10
            emerge gui-apps/{waybar,dunst,wofi,alacritty} www-client/firefox
            mkdir -p /home/$USERNAME/.config/sway
            cp /etc/sway/config /home/$USERNAME/.config/sway/config 2>/dev/null || true
            chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
            ;;
        *)  die "Unknown desktop: $DESKTOP" ;;
    esac

    # ---- Audio ----
    info "Installing PipeWire..."
    emerge --autounmask-continue media-video/pipewire media-sound/wireplumber
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add pipewire default 2>/dev/null || true
        rc-update add wireplumber default 2>/dev/null || true
    else
        systemctl --global enable pipewire wireplumber 2>/dev/null || true
    fi

    # ---- Fonts ----
    emerge media-fonts/{noto,dejavu,font-awesome,liberation-fonts}

    # ---- Final update ----
    info "Final update..."
    emerge --update --deep --newuse @world 2>&1 | tail -5
    emerge --depclean 2>&1 | tail -5
    revdep-rebuild --quiet 2>/dev/null || true

    ok "================================================"
    ok "  Gentoo installation COMPLETE!"
    ok "  Hostname: $HOSTNAME"
    ok "  Desktop:  $DESKTOP / $INIT_SYSTEM"
    ok "  Login:    $USERNAME / $USER_PASSWORD"
    ok "  Root:     root / $ROOT_PASSWORD"
    ok "================================================"
    ok "Type 'exit' to leave chroot, then reboot."
}

# ============================= MAIN ===========================================
case "${1:-}" in
    phase1) phase1 ;;
    phase2) phase2 ;;
    *)
        echo "Usage: $0 {phase1|phase2}"
        echo "  phase1 — run from LiveISO (partitions, extracts stage3, chroots)"
        echo "  phase2 — run inside chroot (configures system, installs desktop)"
        exit 1
        ;;
esac

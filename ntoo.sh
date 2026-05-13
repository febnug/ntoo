#!/usr/bin/env bash
set -Eeuo pipefail

TARGET=/mnt/gentoo
DISTBASE="https://distfiles.gentoo.org/releases/amd64/autobuilds"
LOG=/tmp/gentoo-tui-installer.log

need_root() {
  [[ $EUID -eq 0 ]] || {
    echo "Run as root"
    exit 1
  }
}

need_cmds() {
  for c in dialog lsblk parted mkfs.fat mkfs.ext4 mount umount wget tar chroot blkid; do
    command -v "$c" >/dev/null 2>&1 || {
      echo "Missing command: $c"
      exit 1
    }
  done
}

msg() {
  dialog --backtitle "Gentoo TUI Installer" --title "$1" --msgbox "$2" 10 70
}

yesno() {
  dialog --backtitle "Gentoo TUI Installer" --title "$1" --yesno "$2" 10 70
}

input() {
  local title="$1"
  local text="$2"
  local default="${3:-}"
  dialog --backtitle "Gentoo TUI Installer" \
    --title "$title" \
    --inputbox "$text" 10 70 "$default" 3>&1 1>&2 2>&3
}

menu() {
  dialog --backtitle "Gentoo TUI Installer" \
    --title "$1" \
    --menu "$2" 18 72 10 "${@:3}" 3>&1 1>&2 2>&3
}

pick_disk() {
  local opts=()
  while read -r name size model; do
    opts+=("/dev/$name" "$size $model")
  done < <(lsblk -dpno NAME,SIZE,MODEL | awk '$1 !~ /loop|sr/ {print $1,$2,substr($0,index($0,$3))}' | sed 's#/dev/##')

  DISK=$(dialog --backtitle "Gentoo TUI Installer" \
    --title "Disk Target" \
    --menu "Pilih disk target. Semua data akan dihapus." 20 80 10 \
    "${opts[@]}" 3>&1 1>&2 2>&3)
}

pick_init() {
  INIT=$(menu "Init System" "Pilih stage3:" \
    "openrc" "Gentoo OpenRC" \
    "systemd" "Gentoo systemd")
}

pick_profile() {
  PROFILE=$(menu "Profile" "Pilih preset ringan:" \
    "minimal" "Minimal server/base" \
    "desktop" "Desktop-ready basic USE flags")
}

collect_config() {
  HOSTNAME=$(input "Hostname" "Masukkan hostname:" "gentoo")
  USERNAME=$(input "User" "Masukkan username biasa:" "febri")
  TIMEZONE=$(input "Timezone" "Contoh: Asia/Jakarta" "Asia/Jakarta")
  LOCALE=$(input "Locale" "Contoh: en_US.UTF-8 UTF-8" "en_US.UTF-8 UTF-8")
  ROOTPASS=$(input "Root Password" "Masukkan password root:" "")
  USERPASS=$(input "User Password" "Masukkan password user:" "")
}

confirm_config() {
  yesno "Confirm Install" "
Disk      : $DISK
Init      : $INIT
Profile   : $PROFILE
Hostname  : $HOSTNAME
User      : $USERNAME
Timezone  : $TIMEZONE
Locale    : $LOCALE

LANJUT? Disk akan dihapus total.
"
}

disk_parts() {
  if [[ "$DISK" =~ nvme|mmcblk ]]; then
    EFI="${DISK}p1"
    ROOT="${DISK}p2"
  else
    EFI="${DISK}1"
    ROOT="${DISK}2"
  fi
}

partition_disk() {
  disk_parts

  msg "Partition" "Membuat GPT: 512M EFI + sisa root ext4"

  umount -R "$TARGET" 2>/dev/null || true

  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
  parted -s "$DISK" set 1 esp on
  parted -s "$DISK" mkpart root ext4 513MiB 100%

  sleep 2
  partprobe "$DISK" || true
  sleep 2

  mkfs.fat -F32 "$EFI"
  mkfs.ext4 -F "$ROOT"
}

mount_target() {
  msg "Mount" "Mounting target ke $TARGET"

  mkdir -p "$TARGET"
  mount "$ROOT" "$TARGET"

  mkdir -p "$TARGET/boot"
  mount "$EFI" "$TARGET/boot"

  mkdir -p "$TARGET"/{proc,sys,dev,run}
  mount --types proc /proc "$TARGET/proc"
  mount --rbind /sys "$TARGET/sys"
  mount --make-rslave "$TARGET/sys"
  mount --rbind /dev "$TARGET/dev"
  mount --make-rslave "$TARGET/dev"
  mount --bind /run "$TARGET/run"
}

download_stage3() {
  local dir="current-stage3-amd64-${INIT}"
  local latest_url="$DISTBASE/$dir/latest-stage3-amd64-${INIT}.txt"

  msg "Stage3" "Downloading latest Gentoo stage3 metadata..."

  cd "$TARGET"

  wget -O latest-stage3.txt "$latest_url"

  STAGE3_FILE=$(awk '/stage3-amd64.*\.tar\.xz/ && !/CONTENTS|DIGESTS|asc|sha/ {print $1; exit}' latest-stage3.txt)

  if [[ -z "$STAGE3_FILE" ]]; then
    STAGE3_FILE=$(grep -o "stage3-amd64-${INIT}-[0-9T]*Z.tar.xz" latest-stage3.txt | head -n1)
  fi

  [[ -n "$STAGE3_FILE" ]] || {
    msg "Error" "Gagal parse stage3 filename."
    exit 1
  }

  wget -O "$STAGE3_FILE" "$DISTBASE/$dir/$STAGE3_FILE"

  msg "Stage3" "Extracting $STAGE3_FILE..."
  tar xpvf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner >> "$LOG" 2>&1
}

write_fstab() {
  local efi_uuid root_uuid
  efi_uuid=$(blkid -s UUID -o value "$EFI")
  root_uuid=$(blkid -s UUID -o value "$ROOT")

  cat > "$TARGET/etc/fstab" <<EOF
UUID=$root_uuid   /       ext4    noatime        0 1
UUID=$efi_uuid    /boot   vfat    defaults       0 2
EOF
}

write_make_conf() {
  local useflags=""
  if [[ "$PROFILE" == "desktop" ]]; then
    useflags='X wayland pipewire pulseaudio dbus elogind networkmanager'
  else
    useflags='-X'
  fi

  cat > "$TARGET/etc/portage/make.conf" <<EOF
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j$(nproc)"
ACCEPT_LICENSE="*"
USE="$useflags"
VIDEO_CARDS="intel amdgpu radeonsi nouveau"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"
EOF
}

copy_resolv() {
  cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
}

write_chroot_script() {
  cat > "$TARGET/root/install-chroot.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

echo "[*] Setting timezone"
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data || true

echo "[*] Locale"
echo "$LOCALE" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8 || true
env-update
source /etc/profile

echo "[*] Hostname"
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1       localhost
HOSTS

echo "[*] Sync Portage"
emerge-webrsync || emerge --sync

echo "[*] Installing base packages"
emerge --noreplace sys-kernel/linux-firmware
emerge --noreplace sys-kernel/installkernel
emerge --noreplace sys-kernel/gentoo-kernel-bin
emerge --noreplace sys-boot/grub
emerge --noreplace net-misc/dhcpcd
emerge --noreplace app-admin/sudo
emerge --noreplace app-shells/bash-completion
emerge --noreplace sys-process/htop
emerge --noreplace app-editors/vim

if [[ "$INIT" == "openrc" ]]; then
  emerge --noreplace net-misc/networkmanager || true
  rc-update add dhcpcd default || true
  rc-update add NetworkManager default || true
else
  emerge --noreplace net-misc/networkmanager || true
  systemctl enable NetworkManager || true
  systemctl enable systemd-networkd || true
  systemctl enable systemd-resolved || true
fi

echo "[*] Passwords"
echo "root:$ROOTPASS" | chpasswd

useradd -m -G wheel,audio,video,usb,users -s /bin/bash "$USERNAME" || true
echo "$USERNAME:$USERPASS" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers || true

echo "[*] Installing GRUB"
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
grub-mkconfig -o /boot/grub/grub.cfg

echo "[*] Done inside chroot"
EOF

  chmod +x "$TARGET/root/install-chroot.sh"
}

run_chroot() {
  msg "Chroot" "Masuk chroot dan install kernel + GRUB. Ini bisa lama."
  chroot "$TARGET" /bin/bash /root/install-chroot.sh 2>&1 | tee -a "$LOG"
}

cleanup() {
  sync
  umount -R "$TARGET" 2>/dev/null || true
}

main_menu() {
  while true; do
    choice=$(menu "Gentoo Installer" "Pilih aksi:" \
      "install" "Full install Gentoo" \
      "shell" "Drop to shell" \
      "quit" "Exit")

    case "$choice" in
      install)
        pick_disk
        pick_init
        pick_profile
        collect_config
        confirm_config || continue

        partition_disk
        mount_target
        download_stage3
        write_fstab
        write_make_conf
        copy_resolv
        write_chroot_script
        run_chroot

        msg "Finished" "Install selesai. Log: $LOG

Unmounting target. Setelah ini reboot."
        cleanup
        break
        ;;
      shell)
        clear
        bash
        ;;
      quit)
        clear
        exit 0
        ;;
    esac
  done
}

need_root
need_cmds
main_menu

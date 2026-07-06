#!/usr/bin/env bash
set -Eeu
# NOTE: sengaja tanpa pipefail biar tar warning gak bikin script abort

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
    opts+=("$name" "$size $model")
  done < <(lsblk -dpno NAME,SIZE,MODEL | awk '$1 !~ /loop|sr/ {print $1,$2,substr($0,index($0,$3))}')

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
  if [[ "$DISK" =~ nvme[0-9]+n[0-9]+|mmcblk[0-9]+ ]]; then
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

  mount -t proc /proc "$TARGET/proc" 2>/dev/null || true
  mount --rbind /sys "$TARGET/sys" 2>/dev/null || true
  mount --make-rslave "$TARGET/sys" 2>/dev/null || true
  mount --rbind /dev "$TARGET/dev" 2>/dev/null || true
  mount --make-rslave "$TARGET/dev" 2>/dev/null || true
  mount --bind /run "$TARGET/run" 2>/dev/null || true
  mount --make-rslave "$TARGET/run" 2>/dev/null || true
}

download_stage3() {
  local dir="current-stage3-amd64-${INIT}"
  local latest_url="$DISTBASE/$dir/latest-stage3-amd64-${INIT}.txt"

  msg "Stage3" "Downloading latest Gentoo stage3 metadata..."

  cd "$TARGET"

  wget -q -O latest-stage3.txt "$latest_url"

  # Parse filename dari format: stage3-amd64-openrc-20260705T170105Z.tar.xz 493607544
  STAGE3_FILE=$(grep -oP 'stage3-amd64-\w+-\d{8}T\d{6}Z\.tar\.xz' latest-stage3.txt | head -n1)

  if [[ -z "${STAGE3_FILE:-}" ]]; then
    STAGE3_FILE=$(grep -oP 'stage3-amd64-\w+-[0-9TZ]+\.tar\.xz' latest-stage3.txt | head -n1)
  fi

  [[ -n "${STAGE3_FILE:-}" ]] || {
    msg "Error" "Gagal parse nama file stage3 dari latest-stage3.txt"
    exit 1
  }

  msg "Stage3" "Downloading $STAGE3_FILE..."
  wget -O "$STAGE3_FILE" "$DISTBASE/$dir/$STAGE3_FILE"

  msg "Stage3" "Extracting $STAGE3_FILE..."
  tar xpf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner >> "$LOG" 2>&1 || {
    local rc=$?
    if [[ $rc -ge 2 ]]; then
      msg "Error" "tar gagal dengan exit code $rc, cek $LOG"
      exit 1
    fi
  }
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

  mkdir -p "$TARGET/etc/portage"

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
FEATURES="-test"
EOF
}

write_repos_conf() {
  mkdir -p "$TARGET/etc/portage/repos.conf"

  cat > "$TARGET/etc/portage/repos.conf/gentoo.conf" <<'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = webrsync
sync-uri = https://distfiles.gentoo.org/snapshots
auto-sync = yes
EOF
}

copy_resolv() {
  cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
}

write_chroot_script() {
  cat > "$TARGET/root/install-chroot.sh" <<'CHROOT_SCRIPT_INNER'
#!/usr/bin/env bash
set -Eeu
# NOTE: without pipefail to avoid profile.d sourcing issues

# These will be substituted by sed later
: "${INIT:=openrc}"
: "${HOSTNAME:=gentoo}"
: "${USERNAME:=febri}"
: "${TIMEZONE:=Asia/Jakarta}"
: "${LOCALE:=en_US.UTF-8 UTF-8}"
: "${ROOTPASS:=}"
: "${USERPASS:=}"

# Fix: pre-set all variables that debuginfod.sh might reference
export DEBUGINFOD_URLS=""
export DEBUGINFOD_IMA_CERT_PATH=""
export PORTAGE_TMPDIR=/var/tmp
export FEATURES="-test"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

safe_source() {
  set +u
  source /etc/profile 2>/dev/null || true
  set -u
}

# Prepare dirs
mkdir -p /etc/portage/package.use
mkdir -p /etc/portage/package.accept_keywords
mkdir -p /etc/portage/package.license
mkdir -p /var/tmp/portage
mkdir -p /var/cache/distfiles
mkdir -p /var/db/repos

# Kernel USE flags
cat > /etc/portage/package.use/kernel <<'PUSE'
sys-kernel/installkernel dracut
sys-kernel/gentoo-kernel-bin initramfs
sys-kernel/gentoo-kernel initramfs
sys-kernel/gentoo-sources initramfs
PUSE

echo "[*] Syncing Portage..."
emerge-webrsync 2>/dev/null || emerge --sync 2>/dev/null || true

echo "[*] Setting timezone..."
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data 2>/dev/null || true

echo "[*] Setting locale..."
grep -qxF "$LOCALE" /etc/locale.gen 2>/dev/null || echo "$LOCALE" >> /etc/locale.gen
locale-gen 2>/dev/null || true
eselect locale list 2>/dev/null | grep -i utf | head -1 | grep -oP '\[\d+\]' | tr -d '[]' | xargs -r eselect locale set 2>/dev/null || true
safe_source

echo "[*] Setting hostname..."
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1       localhost
HOSTS

emerge_retry() {
  local pkg="$1"
  echo "[*] Emerging $pkg"
  if emerge --noreplace "$pkg" 2>>"$LOG"; then
    return 0
  fi
  echo "[!] emerge gagal untuk $pkg, coba autounmask..."
  emerge --noreplace --autounmask-write --autounmask-use "$pkg" 2>/dev/null || true
  if command -v etc-update &>/dev/null; then
    echo "" | etc-update --automode 5 2>/dev/null || true
  fi
  safe_source
  echo "[*] Mencoba ulang $pkg..."
  emerge --noreplace "$pkg" 2>>"$LOG"
}

echo "[*] Installing firmware..."
emerge_retry sys-kernel/linux-firmware

echo "[*] Installing kernel (gentoo-kernel-bin preferred)..."
if emerge --noreplace sys-kernel/gentoo-kernel-bin 2>>"$LOG"; then
  echo "[+] gentoo-kernel-bin installed"
else
  echo "[!] gentoo-kernel-bin gagal, bersihin cache..."
  rm -rf /var/tmp/portage/sys-kernel/gentoo-kernel-bin-* 2>/dev/null || true
  rm -f /var/cache/distfiles/*gentoo-kernel-bin* 2>/dev/null || true
  if emerge --noreplace sys-kernel/gentoo-kernel-bin 2>>"$LOG"; then
    echo "[+] gentoo-kernel-bin installed after cleanup"
  else
    echo "[!] Fallback ke source-built sys-kernel/gentoo-kernel..."
    emerge_retry sys-kernel/gentoo-kernel
    echo "[+] gentoo-kernel installed"
  fi
fi

echo "[*] Installing packages..."
emerge_retry sys-boot/grub
emerge_retry net-misc/dhcpcd
emerge_retry app-admin/sudo
emerge_retry app-shells/bash-completion
emerge_retry sys-process/htop
emerge_retry app-editors/vim

if [[ "$INIT" == "openrc" ]]; then
  emerge_retry net-misc/networkmanager 2>/dev/null || true
  rc-update add dhcpcd default 2>/dev/null || true
  rc-update add NetworkManager default 2>/dev/null || true
else
  emerge_retry net-misc/networkmanager 2>/dev/null || true
  systemctl enable NetworkManager 2>/dev/null || true
  systemctl enable systemd-networkd 2>/dev/null || true
  systemctl enable systemd-resolved 2>/dev/null || true
fi

echo "[*] Setting passwords..."
echo "root:$ROOTPASS" | chpasswd
if ! id "$USERNAME" &>/dev/null; then
  useradd -m -G wheel,audio,video,usb,users -s /bin/bash "$USERNAME"
fi
echo "$USERNAME:$USERPASS" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || true
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers 2>/dev/null || true

echo "[*] Installing GRUB..."
mkdir -p /boot/EFI
if mountpoint -q /sys/firmware/efi/efivars 2>/dev/null && [[ -d /sys/firmware/efi/efivars ]]; then
  echo "[*] UEFI runtime detected"
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo 2>>"$LOG"
else
  echo "[*] Instalasi EFI fallback (removable)"
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --removable --no-nvram 2>>"$LOG"
fi
grub-mkconfig -o /boot/grub/grub.cfg 2>>"$LOG"

safe_source

echo "[+] Selesai! Gentoo siap boot."
CHROOT_SCRIPT_INNER

  # Substitute variables
  sed -i \
    -e "s|: \"\${INIT:=openrc}\"|: \"\${INIT:=$INIT}\"|" \
    -e "s|: \"\${HOSTNAME:=gentoo}\"|: \"\${HOSTNAME:=$HOSTNAME}\"|" \
    -e "s|: \"\${USERNAME:=febri}\"|: \"\${USERNAME:=$USERNAME}\"|" \
    -e "s|: \"\${TIMEZONE:=Asia/Jakarta}\"|: \"\${TIMEZONE:=$TIMEZONE}\"|" \
    -e "s|: \"\${LOCALE:=en_US.UTF-8 UTF-8}\"|: \"\${LOCALE:=$LOCALE}\"|" \
    -e "s|: \"\${ROOTPASS:=}\"|: \"\${ROOTPASS:=$ROOTPASS}\"|" \
    -e "s|: \"\${USERPASS:=}\"|: \"\${USERPASS:=$USERPASS}\"|" \
    "$TARGET/root/install-chroot.sh"

  chmod +x "$TARGET/root/install-chroot.sh"
}

run_chroot() {
  msg "Chroot" "Masuk chroot dan install kernel + GRUB. Ini bisa lama."
  chroot "$TARGET" /bin/env -i \
    HOME=/root TERM="$TERM" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash /root/install-chroot.sh 2>&1 | tee -a "$LOG"

  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    msg "Error" "Chroot script gagal dengan exit code $rc — cek $LOG"
    exit 1
  fi
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
        write_repos_conf
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

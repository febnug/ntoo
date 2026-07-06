#!/usr/bin/env bash
#===============================================================================
# Gentoo TUI Installer — fully rewritten, stable, tested logic
# 
# Jalankan sebagai root dari Gentoo LiveCD/ISO (UEFI mode)
#===============================================================================
set -Eeu
# SENG GA PAKE pipefail — biar tar/grep warning ga bikin mati

TARGET=/mnt/gentoo
DISTBASE="https://distfiles.gentoo.org/releases/amd64/autobuilds"
LOG=/tmp/gentoo-installer.log

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ HELPERS
need_root()   { [[ $EUID -eq 0 ]] || { echo "Jalanin sebagai root"; exit 1; }; }
need_cmds()   {
  for c in dialog lsblk parted mkfs.fat mkfs.ext4 mount umount wget tar chroot blkid; do
    command -v "$c" &>/dev/null || { echo "Command gak ada: $c"; exit 1; }
  done
}
msg()         { dialog --backtitle "Gentoo Installer" --title "$1" --msgbox "$2" 10 70; }
yesno()       { dialog --backtitle "Gentoo Installer" --title "$1" --yesno "$2" 10 70; }
input()       { dialog --backtitle "Gentoo Installer" --title "$1" --inputbox "$2" 10 70 "${3:-}" 3>&1 1>&2 2>&3; }
menu_sel()    { dialog --backtitle "Gentoo Installer" --title "$1" --menu "$2" 18 72 10 "${@:3}" 3>&1 1>&2 2>&3; }

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ UI STEP  
pick_disk() {
  local opts=()
  while read -r name size model; do
    opts+=("$name" "$size $model")
  done < <(lsblk -dpno NAME,SIZE,MODEL | awk '$1 !~ /loop|sr/ {print $1,$2,substr($0,index($0,$3))}')
  DISK=$(menu_sel "Disk Target" "Pilih disk — semua data akan dihapus!" "${opts[@]}")
}

pick_init() {
  INIT=$(menu_sel "Init System" "Pilih init system:" \
    "openrc"  "Gentoo OpenRC (tradisional)" \
    "systemd" "Gentoo systemd")
}

pick_profile() {
  PROFILE=$(menu_sel "Profile" "Pilih tipe:" \
    "minimal" "Server/base minimal" \
    "desktop" "Desktop dengan X/Wayland + NetworkManager")
}

collect_config() {
  HOSTNAME=$(input "Hostname"     "Hostname:"       "gentoo")
  USERNAME=$(input "Username"     "User biasa:"     "febri")
  TIMEZONE=$(input "Timezone"     "Contoh: Asia/Jakarta" "Asia/Jakarta")
  LOCALE=$(  input "Locale"       "Contoh: en_US.UTF-8 UTF-8" "en_US.UTF-8 UTF-8")
  ROOTPASS=$(input "Root Pass"    "Password root:"  "")
  USERPASS=$(input "User Pass"    "Password user:"  "")
}

confirm() {
  yesno "Confirm Install" "
Disk      : $DISK
Init      : $INIT
Profile   : $PROFILE
Hostname  : $HOSTNAME
User      : $USERNAME
Timezone  : $TIMEZONE
Locale    : $LOCALE

LANJUT? Semua data di $DISK akan DIHAPUS!
" || return 1
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ DISK  
disk_parts() {
  if [[ "$DISK" =~ nvme[0-9]+n[0-9]+|mmcblk[0-9]+ ]]; then
    EFI="${DISK}p1"; ROOT="${DISK}p2"
  else
    EFI="${DISK}1";  ROOT="${DISK}2"
  fi
}

partition_disk() {
  disk_parts
  msg "Partition" "Bikin partisi: 512MB EFI + sisanya ext4"
  umount -R "$TARGET" 2>/dev/null || true
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
  parted -s "$DISK" set 1 esp on
  parted -s "$DISK" mkpart root ext4 513MiB 100%
  sleep 2; partprobe "$DISK" 2>/dev/null || true; sleep 2
  mkfs.fat -F32 "$EFI"
  mkfs.ext4 -F "$ROOT"
}

mount_target() {
  msg "Mount" "Mount target ke $TARGET"
  mkdir -p "$TARGET"
  mount "$ROOT" "$TARGET"
  mkdir -p "$TARGET/boot"
  mount "$EFI" "$TARGET/boot"
  mkdir -p "$TARGET"/{proc,sys,dev,run}
  mount -t proc /proc     "$TARGET/proc" 2>/dev/null || true
  mount --rbind /sys      "$TARGET/sys"  2>/dev/null || true
  mount --make-rslave     "$TARGET/sys"  2>/dev/null || true
  mount --rbind /dev      "$TARGET/dev"  2>/dev/null || true
  mount --make-rslave     "$TARGET/dev"  2>/dev/null || true
  mount --bind /run       "$TARGET/run"  2>/dev/null || true
  mount --make-rslave     "$TARGET/run"  2>/dev/null || true
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ STAGE3
download_stage3() {
  local dir="current-stage3-amd64-${INIT}"
  local txt_url="$DISTBASE/$dir/latest-stage3-amd64-${INIT}.txt"

  msg "Stage3" "Download metadata stage3..."
  cd "$TARGET"
  wget -q -O latest-stage3.txt "$txt_url"

  # Ambil nama file .tar.xz dari baris pertama yang cocok
  STAGE3_FILE=$(grep -oP 'stage3-amd64-\w+-\d{8}T\d{6}Z\.tar\.xz' latest-stage3.txt | head -1)

  if [[ -z "${STAGE3_FILE:-}" ]]; then
    # Fallback: ambil apapun yang mirip .tar.xz
    STAGE3_FILE=$(grep -oP 'stage3-amd64-\w+-[\wTZ]+\.tar\.xz' latest-stage3.txt | head -1)
  fi

  if [[ -z "${STAGE3_FILE:-}" ]]; then
    msg "Error" "Gagal nemu nama file stage3. Isi latest-stage3.txt:\n$(cat latest-stage3.txt)"
    exit 1
  fi

  msg "Stage3" "Download $STAGE3_FILE ..."
  wget -O "$STAGE3_FILE" "$DISTBASE/$dir/$STAGE3_FILE"

  msg "Stage3" "Extract $STAGE3_FILE ..."
  tar xpf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner >> "$LOG" 2>&1 || {
    rc=$?
    if [[ $rc -ge 2 ]]; then
      msg "Error" "tar exit code $rc — cek $LOG"
      exit 1
    fi
  }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ KONFIG
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
  local useflags="-X"
  [[ "$PROFILE" == "desktop" ]] && useflags='X wayland pipewire pulseaudio dbus elogind networkmanager'

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

copy_resolv() { cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"; }

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ CHROOT
write_chroot_script() {
  # Semua variabel dari luar dimasukkan via sed setelah heredoc
  cat > "$TARGET/root/install-chroot.sh" <<'INNER'
#!/usr/bin/env bash
#==============================================
# Chroot script — jalan di dalem chroot
#==============================================
set -Eeu
# sengaja tanpa pipefail — /etc/profile.d/debuginfod.sh bermasalah

# Variabel bakal diisi oleh sed dari luar
: "${INIT:=openrc}"
: "${HOSTNAME:=gentoo}"
: "${USERNAME:=febri}"
: "${TIMEZONE:=Asia/Jakarta}"
: "${LOCALE:=en_US.UTF-8 UTF-8}"
: "${ROOTPASS:=changeme}"
: "${USERPASS:=changeme}"

export DEBUGINFOD_URLS=""
export DEBUGINFOD_IMA_CERT_PATH=""
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

safe_profile() {
  set +u
  source /etc/profile 2>/dev/null || true
  set -u
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ SETUP LOG
LOG=/tmp/gentoo-installer.log
touch "$LOG"

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ PREP DIRS
mkdir -p /etc/portage/package.use
mkdir -p /etc/portage/package.accept_keywords
mkdir -p /etc/portage/package.license
mkdir -p /var/tmp/portage
mkdir -p /var/cache/distfiles
mkdir -p /var/db/repos

cat > /etc/portage/package.use/kernel <<'PUSE'
sys-kernel/installkernel dracut
sys-kernel/gentoo-kernel-bin initramfs
sys-kernel/gentoo-kernel initramfs
sys-kernel/gentoo-sources initramfs
PUSE

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ SYNC
echo "[*] Sync portage tree..."
emerge-webrsync >> "$LOG" 2>&1 || emerge --sync >> "$LOG" 2>&1 || true

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ TIMEZONE
echo "[*] Timezone..."
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data >> "$LOG" 2>&1 || true

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ LOCALE
echo "[*] Locale..."
grep -qxF "$LOCALE" /etc/locale.gen 2>/dev/null || echo "$LOCALE" >> /etc/locale.gen
locale-gen >> "$LOG" 2>&1 || true
safe_profile

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ HOSTNAME
echo "[*] Hostname..."
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1       localhost
HOSTS

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ EMERGE HELPER
emerge_retry() {
  local pkg="$1"
  echo "[*] emerge $pkg ..."
  if emerge --noreplace "$pkg" >> "$LOG" 2>&1; then
    echo "[+] $pkg OK"
    return 0
  fi
  echo "[!] $pkg gagal, coba autounmask..."
  emerge --noreplace --autounmask-write --autounmask-use "$pkg" >> "$LOG" 2>&1 || true
  etc-update --automode 5 <<<"" >> "$LOG" 2>&1 || true
  safe_profile
  echo "[*] Coba lagi $pkg ..."
  emerge --noreplace "$pkg" >> "$LOG" 2>&1
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ FIRMWARE
echo "[*] Firmware..."
emerge_retry sys-kernel/linux-firmware

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ KERNEL
echo "[*] Kernel (gentoo-kernel-bin)..."
emerge --noreplace sys-kernel/gentoo-kernel-bin >> "$LOG" 2>&1 || {
  echo "[!] Kernel bin gagal, bersihin cache..."
  rm -rf /var/tmp/portage/sys-kernel/gentoo-kernel-bin-*
  rm -f /var/cache/distfiles/*kernel*x86*
  emerge --noreplace sys-kernel/gentoo-kernel-bin >> "$LOG" 2>&1 || {
    echo "[!] Fallback ke source kernel..."
    emerge_retry sys-kernel/gentoo-kernel
  }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ BASIC PKGS
echo "[*] Basic packages..."
emerge_retry sys-boot/grub
emerge_retry net-misc/dhcpcd
emerge_retry app-admin/sudo
emerge_retry app-shells/bash-completion
emerge_retry sys-process/htop
emerge_retry app-editors/vim
emerge_retry net-misc/networkmanager 2>/dev/null || true

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ NETWORK
if [[ "$INIT" == "openrc" ]]; then
  rc-update add dhcpcd default 2>/dev/null || true
  rc-update add NetworkManager default 2>/dev/null || true
else
  systemctl enable NetworkManager 2>/dev/null || true
  systemctl enable systemd-networkd 2>/dev/null || true
  systemctl enable systemd-resolved 2>/dev/null || true
fi

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ USERS
echo "[*] Users & passwords..."
echo "root:$ROOTPASS" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel,audio,video,usb,users -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || true

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ GRUB
echo "[*] GRUB..."
mkdir -p /boot/EFI
if [[ -d /sys/firmware/efi/efivars ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo >> "$LOG" 2>&1
else
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --removable >> "$LOG" 2>&1
fi
grub-mkconfig -o /boot/grub/grub.cfg >> "$LOG" 2>&1

safe_profile

echo "[+] SELESAI! Gentoo siap boot. Reboot dan lepas LiveCD."
INNER

  # Isi variabel dari outer script ke inner script
  sed -i \
    -e "s|: \"\${INIT:=openrc}\"|: \"\${INIT:=$INIT}\"|" \
    -e "s|: \"\${HOSTNAME:=gentoo}\"|: \"\${HOSTNAME:=$HOSTNAME}\"|" \
    -e "s|: \"\${USERNAME:=febri}\"|: \"\${USERNAME:=$USERNAME}\"|" \
    -e "s|: \"\${TIMEZONE:=Asia/Jakarta}\"|: \"\${TIMEZONE:=$TIMEZONE}\"|" \
    -e "s|: \"\${LOCALE:=en_US.UTF-8 UTF-8}\"|: \"\${LOCALE:=$LOCALE}\"|" \
    -e "s|: \"\${ROOTPASS:=changeme}\"|: \"\${ROOTPASS:=$ROOTPASS}\"|" \
    -e "s|: \"\${USERPASS:=changeme}\"|: \"\${USERPASS:=$USERPASS}\"|" \
    "$TARGET/root/install-chroot.sh"

  chmod +x "$TARGET/root/install-chroot.sh"
}

run_chroot() {
  msg "Chroot" "Install kernel, GRUB, packages — bisa memakan waktu lama.\nCek progress: tail -f $LOG"
  chroot "$TARGET" /bin/env -i \
    HOME=/root TERM="$TERM" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash /root/install-chroot.sh 2>&1 | tee -a "$LOG"

  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    msg "Error" "Chroot script exit code $rc — cek $LOG\nBaris error terakhir:\n$(tail -20 "$LOG")"
    exit 1
  fi
}

cleanup() { sync; umount -R "$TARGET" 2>/dev/null || true; }

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ MAIN
main_menu() {
  while true; do
    choice=$(menu_sel "Gentoo Installer" "Pilih aksi:" \
      "install" "Install Gentoo dari awal (full)" \
      "shell"   "Drop ke shell (bash)" \
      "quit"    "Keluar")
    case "$choice" in
      install)
        pick_disk
        pick_init
        pick_profile
        collect_config
        confirm || continue
        partition_disk
        mount_target
        download_stage3
        write_fstab
        write_make_conf
        write_repos_conf
        copy_resolv
        write_chroot_script
        run_chroot
        msg "Selesai!" "Install selesai! Log: $LOG\n\nUnmounting target. Reboot setelah ini."
        cleanup
        break
        ;;
      shell) clear; bash ;;
      quit)  clear; exit 0 ;;
    esac
  done
}

need_root
need_cmds
main_menu

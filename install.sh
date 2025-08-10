#!/usr/bin/env bash
set -euo pipefail

# Adjust these before running
DISK="/dev/nvme0n1"  # Target disk
HOSTNAME="hyprlinux"
USERNAME="loki"
PASSWORD="changeme"

# Warn & confirm
echo "WARNING: This will ERASE $DISK completely!"
read -rp "Type 'YES' to proceed: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

# Wipe partition table
sgdisk --zap-all "$DISK"

# Create partitions: EFI + LUKS container
sgdisk -n1:0:+512M -t1:ef00 "$DISK"
sgdisk -n2:0:0 -t2:8300 "$DISK"

EFI_PART="${DISK}p1"
CRYPT_PART="${DISK}p2"

# Encrypt
cryptsetup luksFormat --type luks2 "$CRYPT_PART"
cryptsetup open "$CRYPT_PART" cryptroot

# Create Btrfs filesystem
mkfs.btrfs /dev/mapper/cryptroot

# Create subvolumes
mount /dev/mapper/cryptroot /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@log
btrfs su cr /mnt/@pkg
btrfs su cr /mnt/@snapshots
umount /mnt

# Mount layout
mount -o compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o compress=zstd,subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount -o compress=zstd,subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots

# EFI mount
mkfs.fat -F32 "$EFI_PART"
mount --mkdir "$EFI_PART" /mnt/boot

# Install base system
pacstrap -K /mnt base linux linux-firmware btrfs-progs vim

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot and configure
arch-chroot /mnt bash <<EOF
ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime
hwclock --systohc
echo "$HOSTNAME" > /etc/hostname

# Locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Initramfs
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Root password
echo "root:$PASSWORD" | chpasswd

# Bootloader
pacman --noconfirm -S grub efibootmgr
mkdir -p /boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
UUID=\$(blkid -s UUID -o value $CRYPT_PART)
sed -i "s|GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# User
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Install snapper
pacman --noconfirm -S snapper

# Create snapper config for root
snapper -c root create-config /

# Fix .snapshots permissions
umount /.snapshots
rm -rf /.snapshots
mkdir /.snapshots
mount -a
chmod 750 /.snapshots

# Retention configuration
SNAPPER_CONF="/etc/snapper/configs/root"
sed -i 's/^TIMELINE_CREATE.*/TIMELINE_CREATE="yes"/' \$SNAPPER_CONF
sed -i 's/^TIMELINE_LIMIT_HOURLY.*/TIMELINE_LIMIT_HOURLY="48"/' \$SNAPPER_CONF
sed -i 's/^TIMELINE_LIMIT_DAILY.*/TIMELINE_LIMIT_DAILY="14"/' \$SNAPPER_CONF
sed -i 's/^TIMELINE_LIMIT_WEEKLY.*/TIMELINE_LIMIT_WEEKLY="8"/' \$SNAPPER_CONF
sed -i 's/^TIMELINE_LIMIT_MONTHLY.*/TIMELINE_LIMIT_MONTHLY="6"/' \$SNAPPER_CONF
sed -i 's/^TIMELINE_LIMIT_YEARLY.*/TIMELINE_LIMIT_YEARLY="0"/' \$SNAPPER_CONF
sed -i 's/^NUMBER_CLEANUP.*/NUMBER_CLEANUP="yes"/' \$SNAPPER_CONF
sed -i 's/^NUMBER_MIN_AGE.*/NUMBER_MIN_AGE="1800"/' \$SNAPPER_CONF
sed -i 's/^NUMBER_LIMIT.*/NUMBER_LIMIT="50"/' \$SNAPPER_CONF
sed -i 's/^EMPTY_PRE_POST_CLEANUP.*/EMPTY_PRE_POST_CLEANUP="yes"/' \$SNAPPER_CONF

# Enable snapshot timers
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer
EOF

echo "Installation complete. Reboot when ready."

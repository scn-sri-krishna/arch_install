#!/bin/bash
set -e

DISK="/dev/nvme0n1"
EFI="${DISK}p1"
CRYPT="${DISK}p2"
CRYPT_NAME="cryptroot"
MAPPER="/dev/mapper/$CRYPT_NAME"

# Set hostname and user
HOSTNAME="hostname"
USERNAME="username"
PASSWORD="password" # Use hashed for security or prompt

echo "[*] Partitioning disk..."
sgdisk -Z $DISK
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" $DISK
sgdisk -n 2:0:0 -t 2:8300 -c 2:"CRYPTROOT" $DISK

echo "[*] Encrypting and opening LUKS volume..."
echo -n "$PASSWORD" | cryptsetup luksFormat $CRYPT -
echo -n "$PASSWORD" | cryptsetup open $CRYPT $CRYPT_NAME -

echo "[*] Creating Btrfs filesystem..."
mkfs.btrfs $MAPPER
mount $MAPPER /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@swap
umount /mnt

echo "[*] Mounting subvolumes..."
mount -o compress=zstd,subvol=@ $MAPPER /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache,swap}
mount -o compress=zstd,subvol=@home $MAPPER /mnt/home
mount -o compress=zstd,subvol=@log $MAPPER /mnt/var/log
mount -o compress=zstd,subvol=@cache $MAPPER /mnt/var/cache
mount -o subvol=@swap $MAPPER /mnt/swap

echo "[*] Formatting EFI partition..."
mkfs.fat -F32 $EFI
mount --mkdir $EFI /mnt/boot

echo "[*] Installing base system..."
pacstrap -K /mnt base linux linux-firmware intel-ucode grub efibootmgr \
  btrfs-progs networkmanager iwd sudo neovim git i3 xorg xorg-xinit

echo "[*] Generating fstab..."
genfstab -U /mnt >>/mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF

echo "[*] Setting timezone, locale, hostname..."
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

echo "[*] Creating user and setting password..."
useradd -mG wheel $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "[*] Enabling NetworkManager..."
systemctl enable NetworkManager

echo "[*] Creating swapfile for hibernation..."
btrfs filesystem mkswapfile --size 16G /swap/swapfile
chmod 600 /swap/swapfile
mkswap /swap/swapfile
swapon /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

echo "[*] Detecting swap UUID and offset..."
RESUME_UUID=\$(findmnt -no UUID -T /swap/swapfile)
OFFSET=\$(btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '/^physical:/ {print \$2}')
echo "UUID=\$RESUME_UUID" > /etc/initramfs-resume.conf

echo "[*] Configuring mkinitcpio and grub..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont encrypt btrfs resume filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

GRUB_CMDLINE="cryptdevice=UUID=$(blkid -s UUID -o value $CRYPT):$CRYPT_NAME root=$MAPPER resume=UUID=\$RESUME_UUID resume_offset=\$OFFSET loglevel=3 quiet splash"
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo "[*] Configuring i3 to start on login..."
echo "exec i3" > /home/$USERNAME/.xinitrc
chown $USERNAME:$USERNAME /home/$USERNAME/.xinitrc

EOF

echo "[*] Installation complete. You can now reboot."

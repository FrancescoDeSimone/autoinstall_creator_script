#!/bin/bash
set -exu

trap cleanup SIGHUP SIGINT SIGTERM EXIT

cleanup() {
  umount "$WORK_DIR/extracted-iso" 2>/dev/null || true # Ignore errors if not mounted
  rm -rf "$WORK_DIR"
  rm -rf "$CONFIG_DIR"
}

ISO_URL="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
ORIGINAL_ISO_NAME=$(basename "$ISO_URL")
FINAL_ISO_NAME="ubuntu-autoinstall.iso"
WORK_DIR="iso-work"
CONFIG_DIR="autoinstall-project"
echo "### Starting Ubuntu Autoinstall ISO Build Script ###"
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit 1
fi
if [ -z "$1" ]; then
  echo "Error: You must provide the path to your user-data file as the first argument."
  echo "Usage: sudo $0 /path/to/your/user-data.yaml"
  exit 1
fi
USER_DATA_PATH="$1"
if [ ! -f "$USER_DATA_PATH" ]; then
  echo "Error: user-data file not found at '$USER_DATA_PATH'"
  exit 1
fi
echo "--- Checking for required tools ---"
for tool in wget xorriso rsync isoinfo fdisk dd; do
  if ! command -v "$tool" &>/dev/null; then
    echo "$tool is not installed. Installing..."
    apt-get update && apt-get install -y "$tool"
  fi
done
if [ ! -f "$ORIGINAL_ISO_NAME" ]; then
  echo "--- Downloading Ubuntu Server ISO from $ISO_URL ---"
  wget -O "$ORIGINAL_ISO_NAME" "$ISO_URL"
else
  echo "--- ISO '$ORIGINAL_ISO_NAME' already exists. Skipping download. ---"
fi

mkdir -p "$CONFIG_DIR" "$WORK_DIR/extracted-iso" "$WORK_DIR/new-iso"
cp "$USER_DATA_PATH" "$CONFIG_DIR/user-data"
touch "$CONFIG_DIR/meta-data"

mount -o loop "$ORIGINAL_ISO_NAME" "$WORK_DIR/extracted-iso"
rsync -aH "$WORK_DIR/extracted-iso/" "$WORK_DIR/new-iso/"
echo "ISO extracted successfully."

cp "$CONFIG_DIR/user-data" "$CONFIG_DIR/meta-data" "$WORK_DIR/new-iso/"
sed -i 's|^\(\s*linux\s*/casper/vmlinuz\)\(.*\)---|\1 autoinstall ds=nocloud\\;s=/cdrom/ \2---|' "$WORK_DIR/new-iso/boot/grub/grub.cfg"
sed -i 's|linux\s*/casper/vmlinuz\s*quiet\s*---|linux /casper/vmlinuz quiet autoinstall ds=nocloud\\\;s=/cdrom/ ---|g' "$WORK_DIR/new-iso/boot/grub/grub.cfg"

echo "--- Extracting MBR and EFI partition images from the original ISO ---"
mkdir -p "$WORK_DIR/new-iso/BOOT"

FDISK_OUTPUT=$(fdisk -l "$ORIGINAL_ISO_NAME")

# Get the first partition (assumed to be MBR image)
MBR_START=$(echo "$FDISK_OUTPUT" | awk '/^'$(basename "$ORIGINAL_ISO_NAME")'1/ {print $2}')
MBR_SIZE=$(echo "$FDISK_OUTPUT" | awk '/^'$(basename "$ORIGINAL_ISO_NAME")'1/ {print $4}')

# Get the EFI partition (second one)
EFI_START=$(echo "$FDISK_OUTPUT" | awk '/EFI System/ {print $2}')
EFI_SIZE=$(echo "$FDISK_OUTPUT" | awk '/EFI System/ {print $4}')

mkdir -p "$WORK_DIR/new-iso/BOOT"
if [ -n "$MBR_START" ] && [ -n "$MBR_SIZE" ]; then
  dd if=${ORIGINAL_ISO_NAME} of="${WORK_DIR}/new-iso/BOOT/1-Boot-NoEmul.img" \
    bs=512 skip=64 count=6264644 status=none
else
  echo "Error: Could not determine MBR image location from ISO"
  exit 1
fi

if [ -n "$EFI_START" ] && [ -n "$EFI_SIZE" ]; then
  dd if=${ORIGINAL_ISO_NAME} of="${WORK_DIR}/new-iso/BOOT/2-Boot-NoEmul.img" \
    bs=512 skip=6264708 count=10144 status=none
else
  echo "Error: Could not determine EFI image location from ISO"
  exit 1
fi

echo "MBR and EFI boot images extracted successfully."

pushd "$WORK_DIR/new-iso/"
xorriso -as mkisofs \
  -r -V "UBUNTU_AUTOINSTALL" \
  -o "../../$FINAL_ISO_NAME" \
  --grub2-mbr BOOT/1-Boot-NoEmul.img \
  -partition_offset 16 \
  --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b BOOT/2-Boot-NoEmul.img \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c boot.catalog \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:::' \
  -no-emul-boot \
  .

popd

echo "Your new autoinstall ISO has been created at: $(pwd)/$FINAL_ISO_NAME"

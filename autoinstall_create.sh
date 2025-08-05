#!/bin/bash
set -exu

trap cleanup SIGHUP SIGINT SIGTERM EXIT

cleanup() {
  umount "$WORK_DIR/extracted-iso"
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
if ! command -v wget &>/dev/null; then
  echo "wget could not be found. Installing it now..."
  apt-get update
  apt-get install -y wget
fi
if ! command -v xorriso &>/dev/null; then
  echo "xorriso could not be found. Installing it now..."
  apt-get update
  apt-get install -y xorriso
fi
if [ ! -f "/usr/lib/grub/i386-pc/boot_hybrid.img" ]; then
  echo "GRUB boot file not found. Installing grub-pc-bin..."
  apt-get update
  apt-get install -y grub-pc-bin
fi
if [ ! -f "$ORIGINAL_ISO_NAME" ]; then
  echo "--- Downloading Ubuntu Server ISO from $ISO_URL ---"
  wget -O "$ORIGINAL_ISO_NAME" "$ISO_URL"
else
  echo "--- Ubuntu Server ISO '$ORIGINAL_ISO_NAME' already exists. Skipping download. ---"
fi
umount "$WORK_DIR/extracted-iso" 2>/dev/null || true # Ignore errors if not mounted
rm -rf "$WORK_DIR"
rm -rf "$CONFIG_DIR"

mkdir -p "$CONFIG_DIR"
mkdir -p "$WORK_DIR/extracted-iso"
mkdir -p "$WORK_DIR/new-iso"
cp "$USER_DATA_PATH" "$CONFIG_DIR/user-data"
touch "$CONFIG_DIR/meta-data"

mount -o loop "$ORIGINAL_ISO_NAME" "$WORK_DIR/extracted-iso"
(cd "$WORK_DIR/extracted-iso" && tar cf - .) | (cd "$WORK_DIR/new-iso" && tar xf -)
echo "ISO extracted successfully."

cp "$CONFIG_DIR/user-data" "$CONFIG_DIR/meta-data" "$WORK_DIR/new-iso/"

sed -i 's|^\(\s*linux\s*/casper/vmlinuz\)\(.*\)---|\1 autoinstall ds=nocloud\\;s=/cdrom/ \2---|' "$WORK_DIR/new-iso/boot/grub/grub.cfg"
# maybe useless check
sed -i 's|linux\s*/casper/vmlinuz\s*quiet\s*---|linux /casper/vmlinuz quiet autoinstall ds=nocloud\\\;s=/cdrom/ ---|g' "$WORK_DIR/new-iso/boot/grub/grub.cfg"

pushd "$WORK_DIR/new-iso/"
xorriso -as mkisofs \
  -r -V "UBUNTU_AUTOINSTALL" \
  -o "../../$FINAL_ISO_NAME" \
  -J -l -b boot/grub/i386-pc/eltorito.img \
  -c boot.catalog \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  --grub2-boot-info \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -isohybrid-gpt-basdat \
  .
popd

echo "Your new autoinstall ISO has been created at: $(pwd)/$FINAL_ISO_NAME"

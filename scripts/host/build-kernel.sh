#!/bin/bash
## Build a vanilla kernel (defconfig + VBox/dm-crypt/loop opts) as .debs on the host.
## Usage: build-kernel.sh <version>   e.g. 6.1.190
set -e
VER="${1:?version}"; LV="-swaptest"
cd /home/debian/swaprepro/kbuild/linux-$VER
echo "[$(date +%T)] defconfig..."
make defconfig >/dev/null
./scripts/config \
  --enable BLK_DEV_DM --enable DM_CRYPT --enable CRYPTO_XTS --enable CRYPTO_AES \
  --enable CRYPTO_AES_NI_INTEL --module BLK_DEV_LOOP \
  --enable EXT4_FS --enable SATA_AHCI --enable BLK_DEV_SD \
  --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
  --enable VIRTIO --enable VIRTIO_PCI --enable VIRTIO_NET --enable VIRTIO_BLK \
  --disable MODULE_SIG --disable MODULE_SIG_FORCE --disable MODULE_SIG_ALL \
  --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --disable DEBUG_INFO --disable DEBUG_INFO_DWARF5 --disable DEBUG_INFO_DWARF4 \
  --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --enable DEBUG_INFO_NONE \
  --set-str LOCALVERSION "$LV" --disable LOCALVERSION_AUTO
make olddefconfig >/dev/null
echo "[$(date +%T)] building bindeb-pkg -j6 ..."
make -j6 bindeb-pkg KDEB_PKGVERSION=1 >build-$VER.log 2>&1
echo "[$(date +%T)] done rc=$?"
ls -1 /home/debian/swaprepro/kbuild/linux-image-${VER}${LV}_1_amd64.deb 2>/dev/null && echo "DEB-READY"

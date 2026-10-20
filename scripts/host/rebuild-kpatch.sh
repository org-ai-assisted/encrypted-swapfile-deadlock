#!/bin/bash
## Rebuild 6.12.113 with BOTH loop + dm-crypt REQ_SWAP PF_MEMALLOC patches,
## DM_CRYPT + BLK_DEV_LOOP as MODULES so loop.ko/dm-crypt.ko hot-swap for A/B.
## Progress appended to the --progress log so the supervisor sees liveness.
set -e
W=/home/debian/swaprepro
K="$W/kbuild/linux-6.12.113"
LOG="$W/rebuild-kpatch.log"
cd "$W/kbuild"

echo "[$(date +%T)] restore pristine loop.c + dm-crypt.c" | tee -a "$LOG"
tar -xJf linux-6.12.113.tar.xz --overwrite \
  linux-6.12.113/drivers/block/loop.c \
  linux-6.12.113/drivers/md/dm-crypt.c

echo "[$(date +%T)] apply patches" | tee -a "$LOG"
python3 "$W/edit_loop.py"     | tail -1 | tee -a "$LOG"
python3 "$W/edit_dmcrypt.py"  | tail -1 | tee -a "$LOG"

cd "$K"
echo "[$(date +%T)] defconfig + config (DM_CRYPT=m)" | tee -a "$LOG"
make defconfig >/dev/null
./scripts/config \
  --enable BLK_DEV_DM --module DM_CRYPT --enable CRYPTO_XTS --enable CRYPTO_AES \
  --enable CRYPTO_AES_NI_INTEL --module BLK_DEV_LOOP \
  --enable EXT4_FS --enable SATA_AHCI --enable BLK_DEV_SD \
  --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
  --enable VIRTIO --enable VIRTIO_PCI --enable VIRTIO_NET --enable VIRTIO_BLK \
  --disable MODULE_SIG --disable MODULE_SIG_FORCE --disable MODULE_SIG_ALL \
  --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --disable DEBUG_INFO --disable DEBUG_INFO_DWARF5 --disable DEBUG_INFO_DWARF4 \
  --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --enable DEBUG_INFO_NONE \
  --set-str LOCALVERSION "-swapfix" --disable LOCALVERSION_AUTO
make olddefconfig >/dev/null
echo "[$(date +%T)] verify config" | tee -a "$LOG"
grep -E "CONFIG_DM_CRYPT=|CONFIG_BLK_DEV_LOOP=" .config | tee -a "$LOG"

echo "[$(date +%T)] build bindeb-pkg -j6" | tee -a "$LOG"
make -j6 bindeb-pkg KDEB_PKGVERSION=1 >"$W/kbuild/build-swapfix.log" 2>&1 &
BP=$!
# heartbeat the progress log while the build runs
while kill -0 "$BP" 2>/dev/null; do
  sz=$(stat -c%s "$W/kbuild/build-swapfix.log" 2>/dev/null || echo 0)
  echo "[$(date +%T)] building... logbytes=$sz" >> "$LOG"
  sleep 20
done
wait "$BP"; rc=$?
echo "[$(date +%T)] build rc=$rc" | tee -a "$LOG"
ls -1 "$W/kbuild/linux-image-6.12.113-swapfix_1_amd64.deb" 2>/dev/null \
  && echo "DEB-READY" | tee -a "$LOG" \
  || { echo "BUILD-FAILED (tail):" | tee -a "$LOG"; tail -25 "$W/kbuild/build-swapfix.log" | tee -a "$LOG"; }

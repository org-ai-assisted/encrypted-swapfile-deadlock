#!/bin/bash
# Tear down any swap, then set up the requested swap mode.
#   enc-loop-fallocate : OLD swap-file-creator path (dm-crypt/plain over loop
#                        over fallocate'd file)              -> expected DEADLOCK
#   enc-loop-dd-dio    : same but file dd-filled + loop direct-io=on
#   enc-blockdev       : dm-crypt plain over a real block device (/dev/sdb)
#   zram               : compressed RAM swap (no disk)
#   plain-file         : plain (unencrypted) swap file
set -euo pipefail
MODE="${1:?mode}"
SIZE_MB="${2:-4096}"
SWAPFILE=/swapfile

# teardown
swapoff -a 2>/dev/null || true
cryptsetup close swap 2>/dev/null || true
for l in $(losetup -j "$SWAPFILE" 2>/dev/null | cut -d: -f1); do losetup -d "$l" || true; done
swapoff /dev/zram0 2>/dev/null || true
[ -b /dev/zram0 ] && (echo 1 > /sys/block/zram0/reset 2>/dev/null || true)
rm -f "$SWAPFILE"

echo "== mode=$MODE size=${SIZE_MB}MB =="
case "$MODE" in
  enc-loop-fallocate)
    fallocate -l "${SIZE_MB}M" "$SWAPFILE"; chmod 600 "$SWAPFILE"
    loop=$(losetup -f --show "$SWAPFILE")
    echo "loop=$loop (buffered)"
    cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom "$loop" swap
    mkswap /dev/mapper/swap >/dev/null; swapon /dev/mapper/swap ;;
  enc-loop-dd-dio)
    rm -f "$SWAPFILE"
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB" status=none
    chmod 600 "$SWAPFILE"
    loop=$(losetup -f --show --direct-io=on "$SWAPFILE")
    echo "loop line: $(losetup -l | grep "$loop")"
    cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom "$loop" swap
    mkswap /dev/mapper/swap >/dev/null; swapon /dev/mapper/swap ;;
  enc-blockdev)
    dev=/dev/sdb
    [ -b "$dev" ] || dev=/dev/vdb
    [ -b "$dev" ] || { echo "no second block device"; exit 3; }
    cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom "$dev" swap
    mkswap /dev/mapper/swap >/dev/null; swapon /dev/mapper/swap ;;
  zram)
    modprobe zram
    echo lzo-rle > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo "${SIZE_MB}M" > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null; swapon -p 100 /dev/zram0 ;;
  plain-file)
    fallocate -l "${SIZE_MB}M" "$SWAPFILE"; chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null; swapon "$SWAPFILE" ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac
echo "== swapon --show =="; swapon --show
echo "== lsblk =="; lsblk

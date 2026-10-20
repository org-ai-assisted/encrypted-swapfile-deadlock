#!/bin/bash
## Install a built kernel .deb into the VM, one-shot-boot into it, and test
## enc-loop-fallocate at the DEFAULT reserve (swappiness=1, 640MB). Runs on the
## OVH host as debian; drives the guest over ssh (NAT :2252).
## Usage: install-test-kernel.sh <version>    e.g. 6.1.190
## PASS(for "is this version safe") = RESPONSIVE/OOM-RECOVERED; FAIL = HARD-LOCKUP.
set -uo pipefail
W=/home/debian/swaprepro; VM=swaprepro; LV="-swaptest"
VER="${1:?version}"; MINFREE="${2:-}"; KREL="${VER}${LV}"
DEB="$W/kbuild/linux-image-${KREL}_1_amd64.deb"
SSH="ssh -i $W/id_repro -p 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@127.0.0.1"
SCP="scp -i $W/id_repro -P 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
G(){ timeout --kill-after=20 20 $SSH "$@"; }
wait_ssh(){ for i in $(seq 1 45); do G true 2>/dev/null && return 0; sleep 4; done; return 1; }

[ -f "$DEB" ] || { echo "MISSING DEB: $DEB"; exit 2; }
echo "############################################################"
echo "# TEST KERNEL $KREL  $(date -u +%H:%M:%S)"
echo "############################################################"

# boot current/default kernel to do the install
VBoxManage controlvm "$VM" poweroff 2>/dev/null || true; sleep 3
VBoxManage modifyvm "$VM" --memory 640
VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
wait_ssh || { echo "guest unreachable for install"; exit 1; }

echo "--- install $DEB ---"
$SCP "$DEB" root@127.0.0.1:/root/ >/dev/null
G "DEBIAN_FRONTEND=noninteractive dpkg -i /root/$(basename "$DEB") 2>&1 | tail -4"

echo "--- one-shot grub into $KREL ---"
G "cfg=/boot/grub/grub.cfg; sub=\$(grep -oP \"submenu '\\K[^']*\" \$cfg | head -1); ent=\$(grep -oP \"menuentry '\\K[^']*${KREL}[^']*\" \$cfg | grep -vi recovery | head -1); echo SUB=\"\$sub\"; echo ENT=\"\$ent\"; if [ -n \"\$ent\" ]; then grub-reboot \"\$sub>\$ent\"; echo grub-reboot-set; else echo NO-ENTRY; fi"
G "sync; systemctl reboot" 2>/dev/null || true
sleep 20
wait_ssh || { echo "guest unreachable after reboot"; exit 1; }
RUN=$(G "uname -r")
echo "--- booted kernel: $RUN (wanted $KREL) ---"
if [ "$RUN" != "$KREL" ]; then echo "WRONG KERNEL BOOTED ($RUN) -- grub selection failed"; exit 3; fi

echo "--- setup swap (min_free=${MINFREE:-default}) + launch filler ---"
MFSET=""; [ -n "$MINFREE" ] && MFSET="sysctl -w vm.min_free_kbytes=$MINFREE >/dev/null;"
G "sysctl -w vm.swappiness=1 >/dev/null; $MFSET sysctl -n vm.min_free_kbytes | sed 's/^/min_free_now=/'; swapoff -a 2>/dev/null; cryptsetup close swap 2>/dev/null; losetup -D 2>/dev/null; rm -f /swapfile; fallocate -l 4096M /swapfile; chmod 600 /swapfile; loop=\$(losetup -f --show /swapfile); cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom \$loop swap; mkswap /dev/mapper/swap >/dev/null; swapon /dev/mapper/swap; dmesg -C; swapon --show"
G "rm -f /root/fill.log; nohup python3 /root/filler.py >/dev/null 2>&1 & echo filler=\$!"

frozen=0; last=""; verdict="UNKNOWN"; t=0; MAXS=240
while [ "$t" -lt "$MAXS" ]; do
  out=$(timeout --kill-after=14 14 $SSH "tail -1 /root/fill.log 2>/dev/null; echo OOM=\$(dmesg 2>/dev/null|grep -ic 'Out of memory')" 2>/dev/null); rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then frozen=$((frozen+1)); echo "  t=${t}s FROZEN (x$frozen)"
  else
    frozen=0; last=$(echo "$out"|grep -E 'MemFree|SwapFree'|tail -1)
    oom=$(echo "$out"|sed -n 's/.*OOM=\([0-9]*\).*/\1/p'|tail -1)
    echo "  t=${t}s ${last} [oom=${oom:-?}]"
    [ "${oom:-0}" -gt 0 ] 2>/dev/null && { verdict="OOM-RECOVERED"; break; }
  fi
  [ "$frozen" -ge 3 ] && { verdict="HARD-LOCKUP"; echo "  -> HARD-LOCKUP"; break; }
  sleep 2; t=$((t+4))
done
alive=no; G true 2>/dev/null && alive=yes
[ "$verdict" = "UNKNOWN" ] && { [ "$alive" = yes ] && verdict="RESPONSIVE" || verdict="DEAD-AT-END"; }
echo "=========================================================="
echo "KERNEL $KREL min_free=${MINFREE:-default} : $verdict   last: $last  alive=$alive"
echo "=========================================================="

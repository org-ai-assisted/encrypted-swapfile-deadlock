#!/bin/bash
## A/B test the patched loop.ko. Runs on the OVH host as debian; drives the
## guest over ssh (NAT :2252). Arg1 = loop_swap_memalloc (0=control,1=fix).
## Reuses a dd-filled /swapfile + loop direct-IO (the only path the patch helps).
set -uo pipefail
W=/home/debian/swaprepro; VM=swaprepro
PARAM="${1:?param 0|1}"; SIZE="${2:-4096}"; MAXS="${3:-240}"; RAM="${4:-640}"
SSH="ssh -i $W/id_repro -p 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@127.0.0.1"
G(){ timeout --kill-after=20 20 $SSH "$@"; }

echo "############################################################"
echo "# KPATCH loop_swap_memalloc=$PARAM  RAM=${RAM}M swappiness=1  $(date -u +%H:%M:%S)"
echo "############################################################"
VBoxManage controlvm "$VM" poweroff 2>/dev/null || true; sleep 4
VBoxManage modifyvm "$VM" --memory "$RAM" 2>/dev/null
VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
echo "--- wait ssh (networkd auto-dhcp) ---"
up=no; for i in $(seq 1 40); do G "true" 2>/dev/null && { up=yes; break; }; sleep 4; done
[ "$up" = yes ] || { echo "guest ssh unreachable"; exit 1; }

echo "--- load patched loop, param=$PARAM ---"
G "swapoff -a 2>/dev/null; cryptsetup close swap 2>/dev/null; losetup -D 2>/dev/null; rmmod loop 2>/dev/null; insmod /root/lmod/loop.ko loop_swap_memalloc=$PARAM 2>&1; echo PARAM_NOW=\$(cat /sys/module/loop/parameters/loop_swap_memalloc)"
echo "--- prepare dd-filled swapfile + dio loop + dm-crypt ---"
G "sysctl -w vm.swappiness=1 >/dev/null; if [ ! -s /swapfile ] || [ \$(stat -c%s /swapfile 2>/dev/null) -ne \$((${SIZE}*1024*1024)) ]; then echo ddfilling...; dd if=/dev/zero of=/swapfile bs=1M count=$SIZE status=none; fi; chmod 600 /swapfile; loop=\$(losetup -f --show --direct-io=on /swapfile); echo loopline=\$(losetup -l|grep \$loop); cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom \$loop swap; mkswap /dev/mapper/swap >/dev/null; swapon /dev/mapper/swap; dmesg -C; swapon --show"
echo "--- launch filler ---"
G "rm -f /root/fill.log; nohup python3 /root/filler.py >/dev/null 2>&1 & echo filler=\$!"

frozen=0; last=""; verdict="UNKNOWN"; swapdetect="?"; t=0
while [ "$t" -lt "$MAXS" ]; do
  out=$(timeout --kill-after=14 14 $SSH "tail -1 /root/fill.log 2>/dev/null; echo OOM=\$(dmesg 2>/dev/null|grep -ic 'Out of memory'); echo SWAPDET=\$(dmesg 2>/dev/null|grep -c 'REQ_SWAP detected')" 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    frozen=$((frozen+1)); echo "  t=${t}s FROZEN (x$frozen)"
  else
    frozen=0
    last=$(echo "$out"|grep -E 'MemFree|SwapFree'|tail -1)
    oom=$(echo "$out"|sed -n 's/.*OOM=\([0-9]*\).*/\1/p'|tail -1)
    sd=$(echo "$out"|sed -n 's/.*SWAPDET=\([0-9]*\).*/\1/p'|tail -1)
    [ "${sd:-0}" -gt 0 ] 2>/dev/null && swapdetect="yes"
    echo "  t=${t}s ${last}  [oom=${oom:-?} swap_patch_hit=${sd:-?}]"
    [ "${oom:-0}" -gt 0 ] 2>/dev/null && { verdict="OOM-RECOVERED"; break; }
  fi
  [ "$frozen" -ge 3 ] && { verdict="HARD-LOCKUP"; echo "  -> HARD-LOCKUP"; break; }
  sleep 2; t=$((t+4))
done

alive=no; G "true" 2>/dev/null && alive=yes
[ "$verdict" = "UNKNOWN" ] && { [ "$alive" = yes ] && verdict="RESPONSIVE (no lockup ${MAXS}s)" || verdict="DEAD-AT-END"; }
sdfinal=$(G "dmesg 2>/dev/null|grep -c 'REQ_SWAP detected'" 2>/dev/null || echo "?")
echo "=========================================================="
echo "RESULT param=$PARAM : $verdict  (REQ_SWAP_patch_triggered: ${sdfinal})"
echo "  last: $last  alive=$alive"
echo "=========================================================="

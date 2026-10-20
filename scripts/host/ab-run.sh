#!/bin/bash
## One A/B run on the already-booted 6.12.113-swapfix kernel.
## Resets the VM, sets BOTH module params (loop + dm_crypt) to $1, sets up the
## dd-filled + direct-IO encrypted loop swap (the path the patch targets),
## drives the filler, classifies HARD-LOCKUP / OOM-RECOVERED / RESPONSIVE.
## Runs on the OVH host as debian; guest over ssh (NAT :2252), swappiness=1.
## Usage: ab-run.sh <param 0|1> [size_mb] [max_s] [ram_mb]
set -uo pipefail
W=/home/debian/swaprepro; VM=swaprepro
PARAM="${1:?param 0|1}"; SIZE="${2:-4096}"; MAXS="${3:-260}"; RAM="${4:-640}"
SSH="ssh -i $W/id_repro -p 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@127.0.0.1"
G(){ timeout --kill-after=20 20 $SSH "$@"; }
wait_ssh(){ for i in $(seq 1 45); do G true 2>/dev/null && return 0; sleep 4; done; return 1; }

echo "############################################################"
echo "# AB param(loop+dm_crypt)=$PARAM  RAM=${RAM}M swappiness=1 dd+dio  $(date -u +%H:%M:%S)"
echo "############################################################"
VBoxManage controlvm "$VM" poweroff 2>/dev/null || true; sleep 4
VBoxManage modifyvm "$VM" --memory "$RAM" 2>/dev/null
VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
wait_ssh || { echo "guest ssh unreachable"; exit 1; }
RUN=$(G "uname -r"); echo "--- booted: $RUN ---"
[ "$RUN" = "6.12.113-swapfix" ] || { echo "WRONG KERNEL ($RUN) -- run install-swapfix.sh"; exit 3; }

echo "--- teardown + set loop param + dd-fill + dio loop + dm-crypt + set dm_crypt param ---"
G "sysctl -w vm.swappiness=1 >/dev/null
swapoff -a 2>/dev/null; cryptsetup close swap 2>/dev/null; losetup -D 2>/dev/null
modprobe loop 2>/dev/null; echo $PARAM > /sys/module/loop/parameters/loop_swap_memalloc
echo loop_param=\$(cat /sys/module/loop/parameters/loop_swap_memalloc)
if [ ! -s /swapfile ] || [ \$(stat -c%s /swapfile 2>/dev/null) -ne \$((${SIZE}*1024*1024)) ]; then echo ddfilling; dd if=/dev/zero of=/swapfile bs=1M count=$SIZE status=none; fi
chmod 600 /swapfile
loop=\$(losetup -f --show --direct-io=on /swapfile); echo loopline=\$(losetup -l|grep \$loop)
cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom \$loop swap
echo $PARAM > /sys/module/dm_crypt/parameters/dm_crypt_swap_memalloc
echo dmcrypt_param=\$(cat /sys/module/dm_crypt/parameters/dm_crypt_swap_memalloc)
mkswap /dev/mapper/swap >/dev/null; swapon /dev/mapper/swap; dmesg -C; swapon --show"

echo "--- launch filler ---"
G "rm -f /root/fill.log; nohup python3 /root/filler.py >/dev/null 2>&1 & echo filler=\$!"

frozen=0; last=""; verdict="UNKNOWN"; t=0
while [ "$t" -lt "$MAXS" ]; do
  out=$(timeout --kill-after=14 14 $SSH "tail -1 /root/fill.log 2>/dev/null; echo OOM=\$(dmesg 2>/dev/null|grep -ic 'Out of memory'); echo LH=\$(dmesg 2>/dev/null|grep -c 'loop: REQ_SWAP'); echo DH=\$(dmesg 2>/dev/null|grep -c 'dm-crypt: REQ_SWAP')" 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then frozen=$((frozen+1)); echo "  t=${t}s FROZEN (x$frozen)"
  else
    frozen=0; last=$(echo "$out"|grep -E 'MemFree|SwapFree'|tail -1)
    oom=$(echo "$out"|sed -n 's/.*OOM=\([0-9]*\).*/\1/p'|tail -1)
    lh=$(echo "$out"|sed -n 's/.*LH=\([0-9]*\).*/\1/p'|tail -1)
    dh=$(echo "$out"|sed -n 's/.*DH=\([0-9]*\).*/\1/p'|tail -1)
    echo "  t=${t}s ${last}  [oom=${oom:-?} loop_hit=${lh:-?} dmcrypt_hit=${dh:-?}]"
    [ "${oom:-0}" -gt 0 ] 2>/dev/null && { verdict="OOM-RECOVERED"; break; }
  fi
  [ "$frozen" -ge 3 ] && { verdict="HARD-LOCKUP"; echo "  -> HARD-LOCKUP"; break; }
  sleep 2; t=$((t+4))
done
alive=no; G true 2>/dev/null && alive=yes
[ "$verdict" = "UNKNOWN" ] && { [ "$alive" = yes ] && verdict="RESPONSIVE (no lockup ${MAXS}s)" || verdict="DEAD-AT-END"; }
echo "=========================================================="
echo "RESULT param=$PARAM : $verdict"
echo "  last: $last  alive=$alive"
echo "=========================================================="

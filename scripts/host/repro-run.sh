#!/bin/bash
## Reset the guest, set up a swap mode, drive the memory filler, classify.
## Runs on the OVH host as `debian`.
## Usage: repro-run.sh <mode> [size_mb] [max_seconds] [swappiness]
set -uo pipefail
W=/home/debian/swaprepro; VM=swaprepro; PORT=3456
MODE="${1:?mode}"; SIZE="${2:-4096}"; MAXS="${3:-150}"; SWPNS="${4:-60}"; MGLRU="${5:-}"; MINFREE="${6:-}"; PCPFRAC="${7:-}"; THP="${8:-}"
pkill -f "socat.*TCP:127.0.0.1:$PORT" 2>/dev/null; sleep 1
S(){ python3 "$W/serialctl.py" --port "$PORT" "$@"; }

reset_vm(){
  VBoxManage controlvm "$VM" poweroff 2>/dev/null || true
  sleep 4
  VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
}
wait_shell(){ for i in $(seq 1 30); do S ping --timeout 10 --login-timeout 12 2>/dev/null|grep --quiet PONG && return 0; sleep 4; done; return 1; }

echo "############################################################"
echo "# MODE=$MODE SIZE=${SIZE}M MAXS=${MAXS}s swappiness=$SWPNS mglru=${MGLRU:-default}  $(date -u +%H:%M:%S)"
echo "############################################################"
echo "--- reset VM ---"; reset_vm
wait_shell || { echo "guest unreachable after reset"; exit 1; }

echo "--- setup ($MODE) ---"
MGPREP=""
[ -n "$MGLRU" ] && MGPREP="echo $MGLRU > /sys/kernel/mm/lru_gen/enabled; echo -n MGLRU_now=; cat /sys/kernel/mm/lru_gen/enabled;"
MFPREP="sysctl -n vm.min_free_kbytes | sed 's/^/min_free_now=/';"
[ -n "$MINFREE" ] && MFPREP="sysctl -w vm.min_free_kbytes=$MINFREE >/dev/null; $MFPREP"
[ -n "$PCPFRAC" ] && MFPREP="$MFPREP sysctl -w vm.percpu_pagelist_high_fraction=$PCPFRAC | sed 's/^/pcp_frac_set=/';"
MFPREP="$MFPREP echo -n 'thp_now='; cat /sys/kernel/mm/transparent_hugepage/enabled;"
[ -n "$THP" ] && MFPREP="echo $THP > /sys/kernel/mm/transparent_hugepage/enabled; $MFPREP"
S run "sysctl -w vm.swappiness=$SWPNS >/dev/null; $MFPREP $MGPREP bash /root/swapmode.sh '$MODE' '$SIZE' 2>&1; echo RC=\$?" --timeout 90 --login-timeout 25 | sed 's/^/  /'
S run "dmesg -C; free -m|sed -n 2p" --timeout 25 | sed 's/^/  /'

echo "--- launch filler ---"
S bg "python3 /root/filler.py" | sed 's/^/  /'

frozen=0; last=""; verdict="UNKNOWN"; t=0
while [ "$t" -lt "$MAXS" ]; do
  out=$(S run "tail -1 /root/fill.log 2>/dev/null; echo OOM=\$(dmesg 2>/dev/null|grep -ic 'Out of memory'); echo HUNG=\$(dmesg 2>/dev/null|grep -ic 'blocked for more than')" --timeout 12 --login-timeout 15 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    frozen=$((frozen+1)); echo "  t=${t}s FROZEN (x$frozen)"
  else
    frozen=0
    last=$(echo "$out"|grep -E 'MemFree|SwapFree'|tail -1)
    oom=$(echo "$out"|sed -n 's/.*OOM=\([0-9]*\).*/\1/p'|tail -1)
    hung=$(echo "$out"|sed -n 's/.*HUNG=\([0-9]*\).*/\1/p'|tail -1)
    echo "  t=${t}s ${last}  [oom=${oom:-?} hung=${hung:-?}]"
    if [ "${oom:-0}" -gt 0 ] 2>/dev/null; then verdict="OOM-RECOVERED"; break; fi
  fi
  if [ "$frozen" -ge 3 ]; then verdict="HARD-LOCKUP"; echo "  -> HARD-LOCKUP"; break; fi
  sleep 2; t=$((t+4))
done

echo "--- post ---"
alive=no; S ping --timeout 10 --login-timeout 15 2>/dev/null|grep --quiet PONG && alive=yes
post=""
if [ "$alive" = yes ]; then
  post=$(S run "pgrep -f filler.py>/dev/null && echo filler=running||echo filler=gone; swapon --show=NAME,SIZE,USED --noheadings|tr '\n' ';'; echo; echo OOMKILL=\$(dmesg|grep -ic 'Out of memory: Kill'); dmesg|grep -iE 'Out of memory: Kill|blocked for more than|oom-kill'|tail -3" --timeout 20 --login-timeout 15 2>/dev/null)
  S run "pkill -9 -f filler.py; swapoff -a 2>/dev/null; echo ok" --timeout 20 >/dev/null 2>&1
fi
[ "$verdict" = "UNKNOWN" ] && { [ "$alive" = yes ] && verdict="RESPONSIVE (no lockup in ${MAXS}s)" || verdict="DEAD-AT-END"; }

echo "=========================================================="
echo "RESULT mode=$MODE swappiness=$SWPNS : $verdict"
echo "  last: $last"
echo "  alive=$alive"
echo "$post"|sed 's/^/  /'
echo "=========================================================="

#!/bin/bash
## Stress the min_free_kbytes fix to EXHAUSTION, multiple reps / RAM / swappiness.
## PASS = system survives (OOM-RECOVERED or RESPONSIVE); FAIL = HARD-LOCKUP/DEAD.
W=/home/debian/swaprepro; VM=swaprepro
setram(){ VBoxManage controlvm "$VM" poweroff 2>/dev/null||true; sleep 3; VBoxManage modifyvm "$VM" --memory "$1"; }
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
echo "@@@@@ PHASE A: 640MB @@@@@"; setram 640
run enc-loop-fallocate 4096 400 1  "" ""       # CONTROL default -> expect LOCKUP
run enc-loop-fallocate 4096 400 1  "" 131072   # fix rep1 (to exhaustion)
run enc-loop-fallocate 4096 400 1  "" 131072   # fix rep2
run enc-loop-fallocate 4096 400 1  "" 131072   # fix rep3
run enc-loop-fallocate 4096 400 60 "" 131072   # swappiness 60
echo "@@@@@ PHASE B: 512MB @@@@@"; setram 512
run enc-loop-fallocate 4096 400 1  "" 131072   # harsher rep1
run enc-loop-fallocate 4096 400 1  "" 131072   # harsher rep2
setram 640
echo "##### STABILITY MATRIX DONE #####"

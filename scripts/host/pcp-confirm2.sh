#!/bin/bash
## Decisive: on 6.12 at DEFAULT reserve, pin pcp->high SMALL (large fraction =>
## high_max=high_min=managed/fraction, auto-tuning float OFF, ~ 6.1 behavior).
## If the deadlock vanishes, PCP high auto-tuning (v6.7) is the regression.
W=/home/debian/swaprepro; VM=swaprepro
VBoxManage controlvm "$VM" poweroff 2>/dev/null||true; sleep 3; VBoxManage modifyvm "$VM" --memory 640
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
run enc-loop-fallocate 4096 220 1 "" "" ""     # auto-tune ON (default) -> expect LOCKUP
run enc-loop-fallocate 4096 220 1 "" "" 512    # tiny fixed pcp (~1MB) -> expect SAFE
run enc-loop-fallocate 4096 220 1 "" "" 512    # rep
run enc-loop-fallocate 4096 220 1 "" "" 128    # small fixed pcp (~5MB) -> expect SAFE
echo "##### PCP CONFIRM2 DONE #####"

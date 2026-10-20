#!/bin/bash
## Test large-anon-folio/THP hypothesis at DEFAULT reserve on 6.12.
W=/home/debian/swaprepro; VM=swaprepro
VBoxManage controlvm "$VM" poweroff 2>/dev/null||true; sleep 3; VBoxManage modifyvm "$VM" --memory 640
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
run enc-loop-fallocate 4096 220 1 "" "" "" never    # THP off -> order-0 anon (6.1-like)
run enc-loop-fallocate 4096 220 1 "" "" "" never    # rep
run enc-loop-fallocate 4096 220 1 "" "" "" always   # THP forced on
echo "##### THP TEST DONE #####"

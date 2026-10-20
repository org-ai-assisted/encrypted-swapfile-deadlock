#!/bin/bash
W=/home/debian/swaprepro
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
run enc-loop-fallocate 4096 240 1 "" ""        # default reserve (control -> expect LOCKUP)
run enc-loop-fallocate 4096 240 1 "" 65536     # 64 MB
run enc-loop-fallocate 4096 240 1 "" 131072    # 128 MB (repeat)
echo "##### MINFREE CONFIRM DONE #####"

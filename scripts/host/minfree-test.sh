#!/bin/bash
W=/home/debian/swaprepro
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
# enc-loop-fallocate, swappiness=1, 640MB, default MGLRU, varying min_free_kbytes
run enc-loop-fallocate 4096 240 1 "" 131072
run enc-loop-fallocate 4096 240 1 "" 262144
echo "##### MINFREE TEST DONE #####"

#!/bin/bash
W=/home/debian/swaprepro
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
# enc-loop-fallocate, swappiness=1, 640MB, 300s; MGLRU off then on
run enc-loop-fallocate 4096 300 1 0
run enc-loop-fallocate 4096 300 1 1
echo "##### MGLRU TEST DONE #####"

#!/bin/bash
W=/home/debian/swaprepro
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
run enc-loop-fallocate 4096 140 60
run enc-blockdev        4096 140 60
run zram                3072 140 60
run plain-file          4096 140 60
run enc-loop-dd-dio     4096 140 60
echo "##### MATRIX DONE #####"

#!/bin/bash
## Harder confirmation: swappiness=1, 640MB RAM, 300s. Control (fallocate) must
## still freeze; candidate (dd+dio) must survive / OOM-recover (never freeze).
W=/home/debian/swaprepro; VM=swaprepro
VBoxManage controlvm "$VM" poweroff 2>/dev/null || true; sleep 4
VBoxManage modifyvm "$VM" --memory 640
VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
run(){ echo; bash "$W/repro-run.sh" "$@" 2>&1; echo; }
run enc-loop-fallocate 4096 300 1
run enc-loop-dd-dio     4096 300 1
run enc-loop-dd-dio     4096 300 1
echo "##### HARD MATRIX DONE #####"

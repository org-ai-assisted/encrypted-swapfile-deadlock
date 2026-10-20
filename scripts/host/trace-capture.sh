#!/bin/bash
W=/home/debian/swaprepro; VM=swaprepro; PORT=3456
S(){ python3 "$W/serialctl.py" --port "$PORT" "$@"; }
VBoxManage controlvm "$VM" poweroff 2>/dev/null || true; sleep 4
VBoxManage modifyvm "$VM" --memory 640
VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
for i in $(seq 1 30); do S ping --timeout 10 --login-timeout 12 2>/dev/null | grep --quiet PONG && break; sleep 4; done
S run "sysctl -w vm.swappiness=1 >/dev/null; sysctl -w kernel.hung_task_timeout_secs=20 >/dev/null; sysctl -w kernel.hung_task_panic=0 >/dev/null; bash /root/swapmode.sh enc-loop-fallocate 4096 >/dev/null 2>&1; dmesg -C; echo SETUP_DONE" --timeout 90 --login-timeout 25
S bg "python3 /root/filler.py"
S logcat --timeout 320 > "$W/trace.log" 2>&1
echo "##### TRACE DONE #####" >> "$W/trace.log"

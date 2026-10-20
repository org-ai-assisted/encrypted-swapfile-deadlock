#!/bin/bash
set -uo pipefail
W=/home/debian/swaprepro; VM=swaprepro
SSH="ssh -i $W/id_repro -p 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@127.0.0.1"
VBoxManage controlvm "$VM" poweroff 2>/dev/null || true; sleep 4
VBoxManage modifyvm "$VM" --memory 640 2>/dev/null
VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
up=no; for i in $(seq 1 40); do timeout --kill-after=20 20 $SSH true 2>/dev/null && { up=yes; break; }; sleep 4; done
echo "ssh_up=$up"
[ "$up" = yes ] || exit 1
timeout --kill-after=90 90 $SSH "swapoff -a 2>/dev/null; cryptsetup close swap 2>/dev/null; losetup -D 2>/dev/null; rmmod loop 2>/dev/null; insmod /root/lmod/loop.ko loop_swap_memalloc=1; sysctl -w vm.swappiness=1 >/dev/null; sysctl -w kernel.hung_task_timeout_secs=20 >/dev/null; sysctl -w kernel.hung_task_panic=0 >/dev/null; if [ ! -s /swapfile ] || [ \$(stat -c%s /swapfile) -ne 4294967296 ]; then dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none; fi; chmod 600 /swapfile; loop=\$(losetup -f --show --direct-io=on /swapfile); cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom \$loop swap; mkswap /dev/mapper/swap >/dev/null; swapon /dev/mapper/swap; dmesg -C; echo SETUP_OK"
timeout --kill-after=20 20 $SSH "nohup python3 /root/filler.py >/dev/null 2>&1 & echo filler=\$!"
pkill -f "socat.*TCP:127.0.0.1:3456" 2>/dev/null; sleep 1
python3 "$W/serialctl.py" --port 3456 logcat --timeout 320 > "$W/trace-dio.log" 2>&1
echo "##### TRACE-DIO DONE #####" >> "$W/trace-dio.log"

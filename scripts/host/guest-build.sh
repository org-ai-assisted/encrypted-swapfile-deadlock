#!/bin/bash
set -e
W=/home/debian/swaprepro
SSH="ssh -i $W/id_repro -p 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 root@127.0.0.1"
SCP="scp -i $W/id_repro -P 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
$SSH "mkdir -p /root/lmod; echo 'obj-m := loop.o' > /root/lmod/Makefile"
$SCP "$W/kbuild/linux-6.12.113/drivers/block/loop.c" root@127.0.0.1:/root/lmod/loop.c
echo "[*] apt install headers + build-essential..."
$SSH "export DEBIAN_FRONTEND=noninteractive; apt-get update -o Acquire::Languages=none >/dev/null 2>&1; apt-get install -y --no-install-recommends linux-headers-\$(uname -r) build-essential kmod 2>&1 | tail -3"
echo "[*] building loop.ko..."
$SSH "cd /root/lmod && make -C /lib/modules/\$(uname -r)/build M=/root/lmod modules 2>&1 | tail -20"
echo "[*] verify vermagic match:"
$SSH "echo -n 'built : '; modinfo /root/lmod/loop.ko 2>/dev/null | sed -n 's/^vermagic: *//p'; echo -n 'stock : '; modinfo loop 2>/dev/null | sed -n 's/^vermagic: *//p'; echo '--- params ---'; modinfo /root/lmod/loop.ko 2>/dev/null | grep -i 'parm:.*swap'"
echo "BUILD-DONE"

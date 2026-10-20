#!/bin/bash
## Install the patched 6.12.113-swapfix kernel into the guest and make it the
## PERSISTENT grub default (so a poweroff/start reset after a lockup still boots
## it). Runs on the OVH host as debian; drives the guest over ssh (NAT :2252).
set -uo pipefail
W=/home/debian/swaprepro; VM=swaprepro
KREL="6.12.113-swapfix"
DEB="$W/kbuild/linux-image-${KREL}_1_amd64.deb"
SSH="ssh -i $W/id_repro -p 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@127.0.0.1"
SCP="scp -i $W/id_repro -P 2252 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
G(){ timeout --kill-after=25 25 $SSH "$@"; }
wait_ssh(){ for i in $(seq 1 45); do G true 2>/dev/null && return 0; sleep 4; done; return 1; }

[ -f "$DEB" ] || { echo "MISSING DEB: $DEB"; exit 2; }
VBoxManage controlvm "$VM" poweroff 2>/dev/null || true; sleep 3
VBoxManage modifyvm "$VM" --memory 640
VBoxManage startvm "$VM" --type headless >/dev/null 2>&1 || true
wait_ssh || { echo "guest unreachable for install"; exit 1; }

echo "--- install $DEB ---"
$SCP "$DEB" root@127.0.0.1:/root/ >/dev/null
G "DEBIAN_FRONTEND=noninteractive dpkg -i /root/$(basename "$DEB") 2>&1 | tail -3"

echo "--- set $KREL as PERSISTENT grub default ---"
G "cfg=/boot/grub/grub.cfg; sub=\$(grep -oP \"submenu '\\K[^']*\" \$cfg | head -1); ent=\$(grep -oP \"menuentry '\\K[^']*${KREL}[^']*\" \$cfg | grep -vi recovery | head -1); echo SUB=\"\$sub\"; echo ENT=\"\$ent\"; if [ -n \"\$ent\" ]; then sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"saved\"/' /etc/default/grub; grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=\"saved\"' >> /etc/default/grub; update-grub >/dev/null 2>&1; grub-set-default \"\$sub>\$ent\"; echo default-set; else echo NO-ENTRY; fi"
G "sync; systemctl reboot" 2>/dev/null || true
sleep 20
wait_ssh || { echo "guest unreachable after reboot"; exit 1; }
RUN=$(G "uname -r")
echo "--- booted kernel: $RUN (wanted $KREL) ---"
[ "$RUN" = "$KREL" ] || { echo "WRONG KERNEL BOOTED ($RUN)"; exit 3; }
echo "--- module params present? ---"
G "grep -H . /sys/module/loop/parameters/loop_swap_memalloc /sys/module/dm_crypt/parameters/dm_crypt_swap_memalloc 2>&1 || echo '(dm_crypt not yet loaded -- loads with cryptsetup)'"
echo "INSTALL-OK booted=$RUN"

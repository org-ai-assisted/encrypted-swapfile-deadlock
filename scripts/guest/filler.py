#!/usr/bin/python3 -Bsu
# Gradually fill memory; log progress + mem/swap to a file and to the serial
# console so a hard lockup is visible as a stalled heartbeat.
import time, sys


def meminfo():
    d = {}
    for ln in open('/proc/meminfo'):
        k, v = ln.split(':')
        d[k] = v.strip()
    return d


log = open('/root/fill.log', 'w', buffering=1)
try:
    con = open('/dev/console', 'w', buffering=1)
except Exception:
    con = None
count = 0
mem = []
t0 = time.time()
while True:
    mem.append(bytearray(1024 * 1024))  # 1 MiB real pages (written)
    for i in range(0, len(mem[-1]), 4096):
        mem[-1][i] = 1
    count += 1
    mi = meminfo()
    line = "t=%.1f n=%dMiB MemFree=%s SwapFree=%s/%s" % (
        time.time() - t0, count, mi.get('MemFree'),
        mi.get('SwapFree'), mi.get('SwapTotal'))
    log.write(line + "\n")
    if con:
        try:
            con.write("FILL " + line + "\n")
        except Exception:
            pass
    time.sleep(0.05)

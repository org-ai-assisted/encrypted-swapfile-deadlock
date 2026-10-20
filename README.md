# encrypted-swapfile-deadlock

Reproduction, root-cause analysis, and kernel-patch experiments for a
whole-system hard lockup that happens when Linux swaps to an **encrypted swap
file** (dm-crypt over a loop device over a file on a normal filesystem) and RAM
is exhausted. Gigabytes of swap are still free; the machine simply freezes.

This is the failure that caused Kicksecure's `swap-file-creator` to stop setting
up an encrypted swap file in many configurations.

## The bug in one paragraph

Swapping to a file-backed stacked block device re-enters the filesystem (ext4)
during memory reclaim. Writing back the loop device's backing file needs to
allocate ext4 blocks and a journal transaction; under memory pressure that
allocation enters direct reclaim, which tries to page out anonymous memory to
the very same swap device, which goes back down through dm-crypt -> loop ->
ext4. Freeing memory needs the swap write to complete, and the swap write needs
memory: a circular wait. A plain swap file does not hit this because the kernel
builds a block-extent map at `swapon` and bypasses the filesystem for swap I/O;
dm-crypt on a raw block device does not hit it because there is no filesystem in
the writeback path.

Captured blocked-task stack (default reserve):

```
kworker/u4:7  (Workqueue: writeback wb_workfn flush-8:0)  state:D
  ext4_mb_new_blocks / jbd2_journal_get_write_access / jbd2_alloc
  __alloc_pages_slowpath -> try_to_free_pages -> shrink_node
  shrink_folio_list -> pageout -> swap_writepage -> submit_bio
  dm_submit_bio [dm_mod] -> __map_bio -> down -> __down_common
```

## What is in here

- `docs/findings.md` -- root cause, the full fix matrix, and the recommended
  mitigation (raise `vm.min_free_kbytes`).
- `docs/investigation.md` -- the "is it a kernel regression?" bisect. Answer:
  no regressing commit; the bug is latent in both 6.1 and 6.12.
- `docs/bug-report.md` -- a self-contained, reproducible bug write-up with data.
- `docs/kernel-patch.md` -- the targeted kernel-source patch experiments
  (PF_MEMALLOC / memalloc_noreclaim across the loop worker and dm-crypt kcryptd
  for REQ_SWAP) and their empirical A/B results.
- `scripts/host/` -- the test harness that runs on the VM host (serial console
  driver, VM reset + classify, kernel build, patch application, A/B runners).
- `scripts/guest/` -- what runs inside the guest (`filler.py` memory filler,
  `swapmode.sh` swap-mode setup for every mode tested).
- `cloud-init/` -- the `user-data` / `meta-data` that provision the guest.

## Reproducing it

The harness drives a nested Debian 13 VirtualBox VM. The shape is:

1. Provision a Debian 13 cloud image with `cloud-init/user-data` (installs
   `cryptsetup` + `python3`, drops `filler.py` and `swapmode.sh`).
2. Give the VM ~640 MB RAM and set `vm.swappiness=1`.
3. `scripts/guest/swapmode.sh enc-loop-fallocate` sets up the old encrypted
   swap-file path (dm-crypt plain aes-xts over a loop over a `fallocate`'d file).
4. Run `scripts/guest/filler.py`; it allocates 1 MiB/50 ms and logs MemFree /
   SwapFree to `/root/fill.log` and the serial console.
5. At the default `vm.min_free_kbytes` (~28 MB on 640 MB RAM) the heartbeat
   stalls and the whole VM wedges while swap is mostly free. Raise the reserve to
   >= 64 MB and the same workload swaps gigabytes and survives.

`swapmode.sh` also provides the known-safe modes for comparison:
`enc-loop-dd-dio`, `enc-blockdev`, `zram`, `plain-file`.

## The fix (validated)

Raise `vm.min_free_kbytes` on low-RAM systems, only ever upward, e.g.
`min_free_kbytes = max(current, 131072)` at boot. On a 640 MB VM, 64 MB was
enough and 128 MB gave comfortable margin (MemFree held ~160-190 MB while
swapping ~2.4 GB). On systems with several GB of RAM the default is already at or
above this, so it is a no-op there.

For a formal no-deadlock guarantee rather than a widened margin, use a swap
backend that keeps the filesystem out of writeback: zram, dm-crypt on a dedicated
block device, or a plain swap file on full-disk encryption. All three were
validated deadlock-free.

## Status of a kernel-code fix

A true in-kernel fix for "swap through a filesystem via loop + dm-crypt" is the
long-standing, upstream-disfavoured hard problem. The targeted patches tried
here and their measured A/B results are documented in `docs/kernel-patch.md`.

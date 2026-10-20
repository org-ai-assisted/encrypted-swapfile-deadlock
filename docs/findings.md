# Root cause and fix matrix

## TL;DR

- Swapping to an encrypted swap FILE (dm-crypt over a loop device over a
  `fallocate`'d file on a normal filesystem) hard-locks the whole machine under
  memory pressure, with gigabytes of swap still free. Reproduced on a throwaway
  Debian 13 / kernel 6.12.113 VM, with a captured kernel stack.
- Root cause: swapping to a file-backed stacked block device re-enters the
  filesystem (ext4) during memory reclaim; that re-entry needs memory which only
  completing the swap write could free, so the system deadlocks.
- Small, no-rebuild mitigation: raise `vm.min_free_kbytes`. The kernel's default
  reserve scales with RAM, so low-RAM systems (512-900 MB) get only ~28 MB, too
  small for the stacked-swap writeback path. Raising it to >= 64 MB closes the
  deadlock window in testing: the box then swaps gigabytes successfully.
- Robust alternatives that avoid the recursive path entirely (validated, no
  deadlock): zram, dm-crypt on a raw block device, plain swapfile on full-disk
  encryption.

## Kernel stack of the deadlock (fallocate path, default reserve)

```
kworker/u4:7  (Workqueue: writeback wb_workfn flush-8:0)  state:D
  ext4_map_blocks / ext4_mb_new_blocks        <- allocate blocks for the
  ext4_mb_mark_diskspace_used                    fallocate'd swapfile's
  jbd2_journal_get_write_access / jbd2_alloc     unwritten extents, in writeback
  __alloc_pages_slowpath                       <- no memory -> DIRECT RECLAIM
  try_to_free_pages / shrink_node
  shrink_folio_list / pageout
  swap_writepage / submit_bio
  dm_submit_bio [dm_mod] / __map_bio
  down / __down_common                         <- blocked (dm semaphore / tag)
```

Freeing memory needs the swap write to finish; the swap write goes
dm-crypt -> loop -> ext4 writeback, which needs memory, so there is a circular
wait. The dd + direct-IO variant locks even harder (total wedge, no console
output at all).

## Fix matrix (all on the identical 6.12.113 kernel)

Swap mechanism (same memory filler):

| mode                                              | result |
|---------------------------------------------------|--------|
| dm-crypt/loop/`fallocate` file (OLD, buffered)    | HARD LOCKUP |
| dm-crypt/loop/`dd`-filled file + loop direct-IO   | non-deterministic lockup ("works by chance") |
| dm-crypt on a raw block device                    | safe |
| zram (compressed RAM swap)                        | safe |
| plain (unencrypted) swapfile                      | safe |

`vm.min_free_kbytes` sweep (OLD fallocate path, swappiness=1, 640 MB RAM):

| min_free_kbytes      | result |
|----------------------|--------|
| ~28 MB (default)     | HARD LOCKUP (reliably, x3) |
| 64 MB   (65536)      | RESPONSIVE -- swapped ~GBs steadily |
| 128 MB  (131072)     | RESPONSIVE (x2) |
| 256 MB  (262144)     | RESPONSIVE |

At 128 MB, MemFree held ~160-190 MB and the box swapped ~2.4 GB to the encrypted
loop swapfile with no deadlock and no OOM-kill, a genuine fix rather than an
early OOM. MGLRU was ruled out (on and off both lock up).

## Recommended fixes

### Primary (small, no kernel rebuild): raise min_free_kbytes

Only ever RAISE it (a static sysctl would wrongly lower it on big-RAM boxes
where the default is already higher), e.g. set
`min_free_kbytes = max(current, 131072)` at boot. 128 MB gives margin; 64 MB was
already enough on a 640 MB VM. On systems with >= a few GB the default is already
near or above this, so it is a no-op there.

### Honest caveat

min_free_kbytes is a strong, validated mitigation (reclaim headroom), not a
formal guarantee; an adversarial burst could still exceed any fixed floor. For a
formal no-deadlock guarantee, use a mechanism that keeps the filesystem out of
swap writeback: zram, or dm-crypt on a dedicated block device. A plain swapfile
on full-disk encryption is already safe.

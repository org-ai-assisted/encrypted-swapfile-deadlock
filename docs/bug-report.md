# Bug report: hard lockup swapping to an encrypted swap FILE under memory pressure

Related upstream discussion: "Hard system lock-ups when using encrypted swap and
RAM is exhausted" (linux-mm / dm-devel). This document is a self-contained,
reproducible write-up of the same failure, plus the data gathered here. It is
reference material in this repository; it is not a message posted to any list.

## Summary

The deadlock is gated by `vm.min_free_kbytes`. On a low-RAM system the default
reserve is small enough that the swap-writeback -> dm-crypt -> loop -> ext4 ->
allocation recursion cannot make forward progress; raising the reserve avoids it.

## Setup (fresh repro, not distro-specific)

- Debian 13 VM, kernel 6.12.113, ext4 root, 640 MB RAM, swappiness=1.
- Encrypted swap file per the cryptsetup FAQ 2.3 pattern but on a file:
  `fallocate` 4G /swapfile; `losetup`; `cryptsetup` plain aes-xts-plain64;
  `mkswap`; `swapon`.
- Memory filler (anonymous pages) until the box swaps.

## Observed (same kernel, varying only vm.min_free_kbytes)

```
  28724 KB (default) -> hard lockup, reproducibly, ~0.9 GB swapped
  65536 KB           -> no lockup, swapped multiple GB
  131072 KB          -> no lockup (x2)
  262144 KB          -> no lockup
```

At 128 MB the box kept ~160-190 MB free and swapped ~2.4 GB to the encrypted
loop swapfile with no deadlock and no OOM kill.

## Captured blocked-task stack at the default reserve

```
  kworker/u4:7 (writeback wb_workfn flush-8:0) state:D
    ext4_mb_new_blocks / jbd2_journal_get_write_access / jbd2_alloc
    __alloc_pages_slowpath -> try_to_free_pages -> shrink_node
    shrink_folio_list -> pageout -> swap_writepage -> submit_bio
    dm_submit_bio [dm_mod] -> __map_bio -> down -> __down_common
```

The FS block-allocation + journal path, entered during direct reclaim while
writing back the loop device's backing file, is what blocks; a bigger reserve
keeps enough headroom that these allocations succeed without the
reclaim -> swap recursion closing.

## Kernel-patch attempts

See `docs/kernel-patch.md` for the targeted kernel-source patches tried
(PF_MEMALLOC / memalloc_noreclaim across the loop worker and the dm-crypt
kcryptd workers for REQ_SWAP) and their empirical results.

## Open questions

1. Is the default `vm.min_free_kbytes` scaling simply too small for any
   swap-through-a-stacked-block-device setup on low-RAM machines, and is a
   larger floor the expected mitigation?
2. Is there a bounded way to make the loop (and dm-crypt) swap-writeback path
   reclaim-safe (reserves across the whole chain), or is "use a dedicated block
   device / zram" the only supported answer?

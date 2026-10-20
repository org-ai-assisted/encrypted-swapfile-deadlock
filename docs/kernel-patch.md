# Kernel-source patch experiments

Goal: find a minimal in-kernel code change that makes swapping to the encrypted
swap FILE deadlock-free, rather than relying on the `vm.min_free_kbytes`
mitigation. Short answer: the targeted reserve-context patches tried here do NOT
fix it, and the reason they fail is itself informative.

## Hypothesis

The swap write crosses several thread contexts:

```
direct reclaim / kswapd   (has PF_MEMALLOC: may dip into memory reserves)
  -> dm-crypt kcryptd      (plain kernel worker: NO reserve access)
    -> loop worker         (plain kernel worker: NO reserve access)
      -> ext4 writeback / DIO on the backing file (allocates; may re-enter reclaim)
```

Each handoff to a workqueue drops the reclaim context, so an allocation in
kcryptd or the loop worker takes the normal path and can recurse into reclaim ->
swap -> this device. Hypothesis: restore reserve access (`PF_MEMALLOC` via
`memalloc_noreclaim_save()`) in those workers for `REQ_SWAP` bios and the chain
can complete.

## Patches

Two source patches, both runtime-toggleable via a module parameter so a single
build does a clean A/B (the appliers used here are in `scripts/host/`):

- `scripts/host/edit_loop.py` -- `drivers/block/loop.c`: in `loop_handle_cmd`,
  wrap `do_req_filebacked()` in `memalloc_noreclaim_save/restore` when
  `rq->cmd_flags & REQ_SWAP`. Toggle: module param `loop_swap_memalloc`.
- `scripts/host/edit_dmcrypt.py` -- `drivers/md/dm-crypt.c`: in `kcryptd_crypt`,
  wrap the read/write convert (page allocation + encryption) the same way when
  `io->base_bio->bi_opf & REQ_SWAP`. Toggle: module param
  `dm_crypt_swap_memalloc`.

Built on 6.12.113 with `DM_CRYPT=m` and `BLK_DEV_LOOP=m` so both `.ko` files
carry runtime-writable params (`/sys/module/.../parameters/...`). Test path:
dd-filled backing file + loop `--direct-io=on` (so the write happens in the loop
worker, not the writeback flusher), 640 MB RAM, swappiness=1, default reserve.

## A/B result (6.12.113-swapfix, dd+dio, default reserve, 640 MB)

| run       | loop param | dm_crypt param | REQ_SWAP seen in both layers | verdict      |
|-----------|-----------:|---------------:|:----------------------------:|--------------|
| control-1 | 0          | 0              | yes                          | HARD-LOCKUP  |
| fix-1     | 1          | 1              | yes                          | HARD-LOCKUP  |
| fix-2     | 1          | 1              | yes                          | HARD-LOCKUP  |
| fix-3     | 1          | 1              | yes                          | HARD-LOCKUP  |

The `REQ_SWAP` detection (`pr_info_once`) fired in BOTH the loop worker and the
dm-crypt kcryptd worker, confirming the patched code paths are exercised. With
the reserve wrapping on, the box drove MemFree BELOW the normal watermark (to
~10-15 MB, i.e. it was dipping into reserves). Some fix runs limped a little
further than the control (swapping tens of MB, with brief stalls and recoveries,
up to ~120 MB swapped) but every one still hard-locked, at essentially the same
near-exhaustion point. 0 of 3 fix runs survived.

(An earlier single-layer build -- loop worker only -- behaved the same: it
swapped a few hundred MB then hard-locked.)

## Why the patch does not help: size vs access

`PF_MEMALLOC` grants *access* to the existing reserve pool; it does not make the
pool *bigger*. The deadlock is not one allocation that just needs permission to
dip into reserves -- it is many concurrent in-flight swap writes whose
completion each needs a little memory, collectively exceeding the small default
reserve (~28 MB on 640 MB RAM). Giving every layer access to that same ~28 MB
pool lets them drain it faster and then block anyway.

Raising `vm.min_free_kbytes` works for exactly the complementary reason: it
enlarges the pool (to 64-128 MB) so the in-flight writes can all complete. That
is a *size* fix, and it is the one that empirically works (see `docs/findings.md`).

## Conclusion

A minimal, correct in-kernel code fix was NOT found. Making the full
reclaim -> dm-crypt -> loop -> ext4 chain deadlock-free by design is the
long-standing, upstream-disfavoured "swap over a filesystem" problem: it needs
either a dedicated, bounded reserve/mempool across every layer (including the
ext4 writeback/DIO path and the I/O completion path), or the swap-extent-map
bypass that a real swap file gets at `swapon` and that the loop device does not
implement. Neither is a small patch, and neither is attempted here.

The shippable, validated answers remain:

1. Enlarge the reserve: `vm.min_free_kbytes >= 64-128 MB` on low-RAM systems.
2. Avoid the recursive path entirely: zram, dm-crypt on a dedicated block
   device, or a plain swap file on full-disk encryption.

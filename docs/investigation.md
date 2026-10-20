# "Was it a kernel regression?" -- the empirical answer

Premise (from the LKML report): encrypted swap file deadlocked on Debian 13
(6.12) but not Debian 12 (6.1), suggesting "introduced by a kernel upgrade".
Goal: find the regressing change.

## Method

All on a nested VBox VM, Debian 13 userland, ext4, 640 MB, swappiness=1, the old
swap-file-creator config (dm-crypt plain aes-xts over a loop device over a 4 GB
`fallocate`'d file). Discriminator: that config at the DEFAULT reserve hard-locks
reliably. Kernel builds are fast (defconfig + no debuginfo + -j6 = ~3-4 min each
as .debs), so full custom kernels were built and boot-tested.

## Ruled out (no-build runtime toggles, all still HARD-LOCK at default reserve)

- MGLRU (Multi-Gen LRU): on (0x7) and off (0x0) both lock. Not it.
- PCP high auto-tuning (v6.7): pinned pcp->high tiny via
  `vm.percpu_pagelist_high_fraction=512` (high_max=high_min, = 6.1 behaviour),
  still locks. Not it. (It was the leading hypothesis but is empirically refuted.)
- Large anon folios / THP: `transparent_hugepage=never`, still locks. Not it.
- Default `vm.min_free_kbytes` formula: byte-identical in 6.1 and 6.12
  (`calculate_min_free_kbytes` = `int_sqrt(lowmem*16)`, clamp [128,262144]), so
  the same ~28 MB default for 640 MB. The regression is not the reserve value.

## The controlled experiment: same config, different kernel version

Built vanilla 6.1.190 AND 6.12.113 with the SAME defconfig (+ dm-crypt / loop /
virtio / serial). Mapped the deadlock threshold vs `vm.min_free_kbytes`:

| defconfig kernel | 28 MB (default) | 48 MB (3 runs)             | 64 MB |
|------------------|-----------------|----------------------------|-------|
| 6.1.190          | LOCK (always)   | LOCK,LOCK,SAFE (~2/3 lock)  | SAFE |
| 6.12.113         | LOCK (always)   | SAFE,SAFE,SAFE (0/3 lock)   | SAFE |

Near the reserve threshold the deadlock is stochastic. At 48 MB, 6.1 locks about
2 of 3 runs while 6.12 did not lock in 3 of 3. Both always lock at 28 MB and
always survive at 64 MB. Same config, same workload: 6.12 is equal-or-MORE
robust than 6.1.

## Conclusion: no regressing kernel commit

With the kernel-code variable isolated (identical config + workload), 6.12 does
not regress vs 6.1 -- it is at least as robust. The hard-lockup is a LATENT
design issue in "swap through a filesystem via loop + dm-crypt", present in BOTH
6.1 and 6.12 once memory pressure is high enough. The field observation
(bookworm ok / trixie broke) is therefore NOT explained by a kernel code change;
the real-world difference is Debian's config / environment / and the workload
sitting near the latent threshold, not a commit that can be reverted.

So there is no kernel-code revert. The actionable, validated mitigation is the
reserve sysctl, which BOTH kernels respond to: `vm.min_free_kbytes` raised to
>= ~64 MB on low-RAM systems closes the deadlock window.

## Residual open question (config-level, not code)

For a precise field trigger: compare Debian bookworm-6.1 vs trixie-6.12 kernel
config + default sysctls for memory/reclaim differences (e.g. does the Debian
trixie cloud kernel lock at 48 MB where defconfig-6.12 survived?). That is a
config bisect, not a code bisect, and does not change the fix.

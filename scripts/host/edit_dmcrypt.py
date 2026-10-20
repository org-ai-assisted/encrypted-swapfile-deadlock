#!/usr/bin/python3 -Bsu
# Patch drivers/md/dm-crypt.c: for REQ_SWAP bios, run the crypt work (page
# allocation + encryption) under PF_MEMALLOC (memalloc_noreclaim) so its
# allocations use reserves instead of recursing into direct reclaim -> swap ->
# this device. Completes the reserve chain the loop.c patch starts: the swap
# write crosses reclaim -> kcryptd (here) -> loop worker, and each handoff
# otherwise drops the reclaim context. Runtime-toggleable via module param.
import sys

p = "/home/debian/swaprepro/kbuild/linux-6.12.113/drivers/md/dm-crypt.c"
s = open(p).read()
orig = s

a1 = (
    "static void kcryptd_crypt(struct work_struct *work)\n"
    "{\n"
    "\tstruct dm_crypt_io *io = container_of(work, struct dm_crypt_io, work);\n"
    "\n"
    "\tif (bio_data_dir(io->base_bio) == READ)\n"
    "\t\tkcryptd_crypt_read_convert(io);\n"
    "\telse\n"
    "\t\tkcryptd_crypt_write_convert(io);\n"
    "}\n"
)
new1 = (
    "#include <linux/sched/mm.h>\n"
    "\n"
    "static bool dm_crypt_swap_memalloc = true;\n"
    "module_param(dm_crypt_swap_memalloc, bool, 0644);\n"
    "MODULE_PARM_DESC(dm_crypt_swap_memalloc,\n"
    "\t\"PF_MEMALLOC for REQ_SWAP crypt work to avoid reclaim deadlock (default on)\");\n"
    "\n"
    "static void kcryptd_crypt(struct work_struct *work)\n"
    "{\n"
    "\tstruct dm_crypt_io *io = container_of(work, struct dm_crypt_io, work);\n"
    "\tbool use_reserve = dm_crypt_swap_memalloc &&\n"
    "\t\t(io->base_bio->bi_opf & REQ_SWAP);\n"
    "\tunsigned int noreclaim_flag = 0;\n"
    "\n"
    "\tif (io->base_bio->bi_opf & REQ_SWAP)\n"
    "\t\tpr_info_once(\"dm-crypt: REQ_SWAP detected on crypt work\\n\");\n"
    "\tif (use_reserve)\n"
    "\t\tnoreclaim_flag = memalloc_noreclaim_save();\n"
    "\n"
    "\tif (bio_data_dir(io->base_bio) == READ)\n"
    "\t\tkcryptd_crypt_read_convert(io);\n"
    "\telse\n"
    "\t\tkcryptd_crypt_write_convert(io);\n"
    "\n"
    "\tif (use_reserve)\n"
    "\t\tmemalloc_noreclaim_restore(noreclaim_flag);\n"
    "}\n"
)
assert s.count(a1) == 1, "A1 anchor not unique/found"
s = s.replace(a1, new1, 1)

assert s != orig
open(p, "w").write(s)
print("DMCRYPT-PATCH-APPLIED")
i = s.index("static bool dm_crypt_swap_memalloc")
print(s[i:i + 1200])

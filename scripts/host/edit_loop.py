#!/usr/bin/python3 -Bsu
# Patch drivers/block/loop.c: for REQ_SWAP writeback, run the backing-file I/O
# under PF_MEMALLOC (memalloc_noreclaim) so its bounded allocations use reserves
# instead of recursing into direct reclaim -> swap -> this device (deadlock).
# Runtime-toggleable via module param loop_swap_memalloc (A/B on one build).
import sys

p = "/home/debian/swaprepro/kbuild/linux-6.12.113/drivers/block/loop.c"
s = open(p).read()
orig = s

# R1: module param, inserted before loop_handle_cmd definition.
a1 = "static void loop_handle_cmd(struct loop_cmd *cmd)\n{\n"
ins1 = (
    "static bool loop_swap_memalloc = true;\n"
    "module_param(loop_swap_memalloc, bool, 0644);\n"
    "MODULE_PARM_DESC(loop_swap_memalloc,\n"
    "\t\"PF_MEMALLOC for REQ_SWAP writeback to avoid reclaim deadlock (default on)\");\n"
    "\n"
)
assert s.count(a1) == 1, "R1 anchor not unique/found"
s = s.replace(a1, ins1 + a1, 1)

# R2: extra locals after old_memcg decl.
a2 = "\tstruct mem_cgroup *old_memcg = NULL;\n"
ins2 = (
    "\tstruct mem_cgroup *old_memcg = NULL;\n"
    "\tbool is_swap = rq->cmd_flags & REQ_SWAP;\n"
    "\tbool use_reserve = is_swap && loop_swap_memalloc;\n"
    "\tunsigned int noreclaim_flag = 0;\n"
)
assert s.count(a2) == 1, "R2 anchor not unique/found"
s = s.replace(a2, ins2, 1)

# R3: wrap do_req_filebacked with memalloc_noreclaim save/restore.
a3 = (
    "\tret = do_req_filebacked(lo, rq);\n"
    "\n"
    "\tif (cmd_blkcg_css)\n"
)
new3 = (
    "\tif (is_swap)\n"
    "\t\tpr_info_once(\"loop: REQ_SWAP detected on backing I/O\\n\");\n"
    "\tif (use_reserve)\n"
    "\t\tnoreclaim_flag = memalloc_noreclaim_save();\n"
    "\n"
    "\tret = do_req_filebacked(lo, rq);\n"
    "\n"
    "\tif (use_reserve)\n"
    "\t\tmemalloc_noreclaim_restore(noreclaim_flag);\n"
    "\n"
    "\tif (cmd_blkcg_css)\n"
)
assert s.count(a3) == 1, "R3 anchor not unique/found"
s = s.replace(a3, new3, 1)

assert s != orig
open(p, "w").write(s)
print("PATCH-APPLIED")
# show the patched function for verification
i = s.index("static bool loop_swap_memalloc")
print(s[i:i + 1700])

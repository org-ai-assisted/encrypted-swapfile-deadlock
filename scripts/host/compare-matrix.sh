#!/bin/bash
## Apples-to-apples: 6.1.190 vs 6.12.113, BOTH defconfig, deadlock threshold vs min_free.
W=/home/debian/swaprepro
t(){ echo; bash "$W/install-test-kernel.sh" "$@" 2>&1; echo; }
t 6.1.190  65536
t 6.1.190  49152
t 6.12.113 ""
t 6.12.113 49152
t 6.12.113 65536
echo "##### COMPARE MATRIX DONE #####"

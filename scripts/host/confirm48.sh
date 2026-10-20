#!/bin/bash
## Confirm the ordering at the discriminating reserve (48MB): is 6.12 reliably
## NOT-worse than 6.1? (stochastic deadlock -> repeats)
W=/home/debian/swaprepro
t(){ echo; bash "$W/install-test-kernel.sh" "$@" 2>&1; echo; }
t 6.1.190  49152
t 6.12.113 49152
t 6.1.190  49152
t 6.12.113 49152
echo "##### CONFIRM48 DONE #####"

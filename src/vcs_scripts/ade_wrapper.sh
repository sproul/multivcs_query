#!/bin/bash
# 
# if kerboros ticket expires, then initial output is
#       ade WARNING: Initial Kerberos ticket required
#
# 
. cache
ade $*
exit $?
$ct_root/src/vcs_scripts/ade_wrapper.sh describe -l PCBPEL_ICSMAIN_GENERIC_180505.0743.0980 -labelserver
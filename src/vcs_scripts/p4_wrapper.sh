#!/bin/bash
. cache
. p4.inc

$*

exit
bx $dp/git/change_tracker/src/vcs_scripts/p4_wrapper.sh 'nelsons-pc' 'NelsonS' 'x' '/scratch/change_tracker/p4/p4plumtree.us.oracle.com:1666/PT/portal/main/transformPortlet/src/com/plumtree/transform/utilities' p4_changes.sh //PT/portal/main/transformPortlet/src/com/plumtree/transform/utilities/...@121159,129832
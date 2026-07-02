#!/usr/bin/env bash
source ~/.crewboss.env
export CB_HOME=$HOME/cbnet GH_REPO=ruslan-shaydullin/crewboss
mkdir -p ~/cbnet/run/rework-logs
nohup bash ~/cbnet/rework-prep.sh 7 task/7-1781179662 > ~/cbnet/run/rework-logs/7.out 2>&1 &
echo "  dispatched #7 (animations, integrate) pid=$!"
nohup bash ~/cbnet/rework-prep.sh 6 task/6-1781179664 > ~/cbnet/run/rework-logs/6.out 2>&1 &
echo "  dispatched #6 (role form, integrate) pid=$!"
nohup bash ~/cbnet/rework-prep.sh 26 > ~/cbnet/run/rework-logs/26.out 2>&1 &
echo "  dispatched #26 (modal bug, fresh) pid=$!"

#!/usr/bin/env bash
done_set=""
while true; do
  all_term=1
  for n in 7 6 26; do
    case ",$done_set," in *",$n,"*) continue;; esac
    ph=$(jq -r .phase ~/cbnet/run/work/$n/status.json 2>/dev/null)
    if [ "$ph" = done ] || [ "$ph" = failed ]; then
      pr=$(jq -r ".pr // \"\"" ~/cbnet/run/work/$n/status.json 2>/dev/null)
      echo "rework #$n -> $ph  $pr"
      done_set="$done_set,$n"
    else
      all_term=0
    fi
  done
  [ "$all_term" = 1 ] && { echo "all rework terminal"; break; }
  sleep 20
done

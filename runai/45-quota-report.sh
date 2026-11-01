#!/bin/bash
# Quota monitoring in Slurm terms (sshare/sreport): for every department and
# group, per partition: guaranteed GPUs / limit / over-quota weight, GPUs
# allocated / requested (incl. pending), "+" when running over quota; then
# GPU use per user. Source: Run:ai's own accounting (org-unit status and
# workloads API) — the same numbers as the UI's Departments/Projects views.
#   WATCH=10 ./45-quota-report.sh   refresh every 10 s
set -euo pipefail
. "$(dirname "$0")/env.sh"
if [ -n "${WATCH:-}" ]; then
  while true; do clear; date; python3 "$RUNAI_SRC/lib/quota_report.py" "$RUNAI_SRC/org/cluster.yaml"; sleep "$WATCH"; done
fi
python3 "$RUNAI_SRC/lib/quota_report.py" "$RUNAI_SRC/org/cluster.yaml"

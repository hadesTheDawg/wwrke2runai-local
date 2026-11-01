#!/bin/bash
# Show Run:ai enforcing the org's quotas, with real users submitting as
# themselves (passwords from users.csv), then print 45-quota-report.sh:
#   rbianchi    bio-genomics   1   A100  within quota
#   lperez      phys-astro     0.5 A100  within quota (GPU fraction)
#   bharrington chem-comp      2   A100  over quota (0.75 guaranteed): runs on idle GPUs
#   odiallo     chem-materials 2   A100  above its limit (1): stays pending
#   skumar      cs-ml          2   H100  over quota (1 guaranteed): fills the partition
#   hkim        bio-imaging    0.5 H100  within its 0.5 guarantee, submitted last:
#                                        Run:ai reclaims from cs-ml's over-quota job
# KEEP=1 leaves the jobs running (watch: WATCH=10 45-quota-report.sh;
# remove: python3 lib/quota_demo.py /etc/runai/users.csv cleanup).
set -euo pipefail
. "$(dirname "$0")/env.sh"

python3 "$RUNAI_SRC/lib/quota_demo.py" "$RUNAI_DIR/users.csv" run
echo
"$RUNAI_SRC/45-quota-report.sh"
if [ -z "${KEEP:-}" ]; then
  echo
  python3 "$RUNAI_SRC/lib/quota_demo.py" "$RUNAI_DIR/users.csv" cleanup
fi

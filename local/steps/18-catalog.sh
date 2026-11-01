#!/bin/bash
# Workload catalog on the target: one Run:ai Environment per entry of
# $RUNAI_CATALOG, image = $TARGET_WORKLOAD_REGISTRY/workloads/<image> (pushed
# by 11-push.sh from the bundle), the pull credential and the
# "workload-registry" data source. RUNAI_PRUNE_ENVIRONMENTS=yes removes
# environments whose image the workload registry does not serve (Run:ai's
# internet-only built-ins), as runai/24-workload-catalog.sh does.
. "$(dirname "$0")/../lib/common.sh"
need TARGET_WORKLOAD_REGISTRY
PREFIX="$TARGET_WORKLOAD_REGISTRY/${TARGET_REGISTRY_PREFIX:+$TARGET_REGISTRY_PREFIX/}$WL_REG_PREFIX"
CA="${TARGET_REGISTRY_CA:--}"

$PY "$LIB/runai_api.py" catalog "$RUNAI_CATALOG" "$PREFIX" \
  "$TARGET_WORKLOAD_PULL_USER" "$TARGET_WORKLOAD_PULL_PASSWORD_FILE" "$CA" \
  "$(is_yes "$RUNAI_PRUNE_ENVIRONMENTS" && echo prune)"

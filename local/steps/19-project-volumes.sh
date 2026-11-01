#!/bin/bash
# Project volumes: shared, persistent storage per Run:ai project, from
# $PROJECT_VOLUMES (example: local/storage/project-volumes.yaml).
#   new volume       PVC from a StorageClass (weka-projects, cephfs-projects, ...)
#   existing:        static PV bound to an existing Weka directory / CephFS path
# Each becomes a PVC in the project's namespace and a project-scoped Run:ai
# PVC data source, so project members pick it in the UI/CLI and it is mounted
# at mountPath in every workload that selects it. Idempotent.
. "$(dirname "$0")/../lib/common.sh"
[ -f "$PROJECT_VOLUMES" ] || { say "no $PROJECT_VOLUMES: skipping"; exit 0; }
export KUBECTL
say "project volumes from $PROJECT_VOLUMES"
$PY "$LIB/runai_api.py" project-volumes "$PROJECT_VOLUMES"

# Local, scheduled deployment of the RKE2 + Run:ai stack (see local/README.md).
#
#   cp .env.example .env    # then edit: where things live, remote, target
#   make fetch              # remote system -> local artifact repo (RUNAI_REPO)
#   make bundle             # optional: one signed/encrypted file to carry
#   make deploy             # local artifact repo -> existing RKE2 GPU cluster
#
# Where things live (also settable in .env; the command line wins):
#   make fetch RKE2_DEPLOY_REPO=/srv/git/rke2_deploy_ww RUNAI_REPO=/data/runai-repo
# Steps per phase come from FETCH_STEPS / DEPLOY_STEPS in .env; any single
# step can be run by name (make push, make catalog, ...).

ENV_FILE ?= $(CURDIR)/.env
export ENV_FILE

RUN := local/steps/run.sh

FETCH := facts artifacts images features overlays verify bundle unbundle
DEPLOY := preflight push registries prometheus gpu storage control-plane cluster \
          catalog project-volumes verify-target ww-overlays

.PHONY: help env doctor fetch deploy all sync schedule unschedule schedule-show $(FETCH) $(DEPLOY)

help:
	@sed -n '1,12p' Makefile | sed 's/^# \{0,1\}//'
	@echo
	@echo "phases:  fetch  deploy  all (= fetch deploy)"
	@echo "fetch:   $(FETCH)"
	@echo "deploy:  $(DEPLOY)"
	@echo "other:   env doctor sync schedule unschedule schedule-show"

env:
	@if [ -f .env ]; then echo ".env exists"; else cp .env.example .env && chmod 600 .env && echo "created .env from .env.example"; fi

doctor:
	@local/steps/doctor.sh

fetch deploy:
	@$(RUN) $@

all:
	@$(RUN) fetch deploy

$(FETCH) $(DEPLOY):
	@$(RUN) $@

# what cron runs (SYNC_TARGETS, default: fetch)
sync:
	@local/steps/40-sync.sh

schedule:
	@local/steps/41-schedule.sh install
unschedule:
	@local/steps/41-schedule.sh remove
schedule-show:
	@local/steps/41-schedule.sh show

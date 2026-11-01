# Example derived workload image (26-build-image.sh ubuntu-dev). WL is the
# workload registry prefix, so bases are images the catalog already offers.
ARG WL
FROM ${WL}/ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates python3 python3-venv python3-pip vim less \
 && rm -rf /var/lib/apt/lists/*

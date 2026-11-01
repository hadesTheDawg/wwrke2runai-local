# HTD Researcher · MLflow: an MLflow tracking server workspace with the HTD
# shell (banner, prompt, helpers). Build and publish it as root on ww1:
#
#   runai/htd-images.py runai/images/mlflow/Dockerfile
#
# The #catalog lines below become its catalog entry (and so its Run:ai
# environment): the MLflow UI opens as a tool at
# https://<project>-<workload>.runai.htd.local behind Run:ai SSO. It runs as
# the submitting user, so runs and artifacts persist in their NFS home
# (~/mlflow). Override with MLFLOW_BACKEND_STORE_URI /
# MLFLOW_ARTIFACTS_DESTINATION (e.g. a Postgres + S3 for a shared server).
#
#catalog description: HTD Researcher · MLflow tracking server (runs in ~/mlflow)
#catalog uidGidSource: fromIdpToken
#catalog training: false
#catalog routingMethod: host-base
#catalog connections:
#catalog   - name: MLflow
#catalog     internalToolInfo:
#catalog       toolType: mlflow
#catalog       connectionType: ExternalUrl
#catalog       containerPort: 5000
#catalog       externalUrlInfo: {}
ARG WL
FROM ${WL}/ubuntu:24.04

ARG MLFLOW_VERSION=3.5.0
LABEL org.opencontainers.image.title="HTD Researcher · MLflow" \
      org.opencontainers.image.description="MLflow ${MLFLOW_VERSION} tracking server with the HTD Researcher shell" \
      org.opencontainers.image.vendor="HTD" \
      io.htd.image="mlflow" \
      io.htd.mlflow.version="${MLFLOW_VERSION}"

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/opt/mlflow PATH=/opt/mlflow/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    MLFLOW_PORT=5000 HTD_RUNAI_DOMAIN=runai.htd.local

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 python3-venv ca-certificates curl git jq less vim-tiny htop tmux \
      bash-completion sqlite3 tini \
 && rm -rf /var/lib/apt/lists/*

# Full mlflow (server + UI) brings scikit-learn, pandas and matplotlib for htd-demo.
# The UI tab title is rebranded; best effort, the UI may retitle pages itself.
RUN python3 -m venv "$VIRTUAL_ENV" \
 && pip install --upgrade pip \
 && pip install "mlflow==${MLFLOW_VERSION}" \
 && ui="$(python -c 'import mlflow, os; print(os.path.dirname(mlflow.__file__))')/server/js/build/index.html" \
 && { [ ! -f "$ui" ] || sed -i 's|<title>[^<]*</title>|<title>HTD Researcher · MLflow</title>|' "$ui"; }

COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/htd-* \
 && chmod 0644 /etc/profile.d/htd-*.sh \
 && cat /etc/bash.bashrc.htd >> /etc/bash.bashrc && rm /etc/bash.bashrc.htd \
 && printf 'NAME="HTD Researcher · MLflow"\nMLFLOW_VERSION=%s\nBUILT=%s\n' \
      "$MLFLOW_VERSION" "$(date -u +%FT%TZ)" > /etc/htd-release

EXPOSE 5000
WORKDIR /tmp
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/htd-start"]

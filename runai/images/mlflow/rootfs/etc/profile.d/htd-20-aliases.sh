# HTD Researcher shell helpers
[ -n "${PS1:-}" ] || return 0

alias ll='ls -alFh --color=auto'
alias la='ls -A --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias ..='cd ..'
alias gpu='command -v nvidia-smi >/dev/null && nvidia-smi || echo "no nvidia-smi; NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-none}"'

mlflow-ui()   { echo "in this pod : $MLFLOW_TRACKING_URI"; echo "in browser  : ${HTD_MLFLOW_URL:-open the MLflow tool from the Run:ai workload}"; }
mlflow-logs() { tail -f /tmp/htd-mlflow.log; }

htd-help() {
  cat <<'EOF'
HTD Researcher · MLflow workspace

  htd-info        who/where am I: user, project, resources, GPUs, MLflow status
  htd-demo        train a few scikit-learn models, logged to MLflow (experiment htd-demo)
  mlflow-ui       MLflow URLs (in-pod and browser)
  mlflow-logs     follow the tracking server log
  gpu             nvidia-smi (or what GPUs this pod was given)

  Python:  import mlflow; mlflow.autolog()   # MLFLOW_TRACKING_URI is preset
  Data:    ~/mlflow/mlflow.db (runs), ~/mlflow/artifacts (models, plots)
EOF
}

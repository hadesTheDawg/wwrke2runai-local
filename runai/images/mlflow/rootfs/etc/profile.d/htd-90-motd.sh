# HTD Researcher banner, once per interactive session (not in nested shells).
[ -n "${PS1:-}" ] && [ -z "${HTD_MOTD_SHOWN:-}" ] && [ -t 1 ] || return 0
export HTD_MOTD_SHOWN=1

__htd_motd() {
  local o=$'\e[1;38;5;208m' d=$'\e[2m' c=$'\e[36m' g=$'\e[32m' r=$'\e[31m' z=$'\e[0m' mlf
  if curl -fsS -m 1 "${MLFLOW_TRACKING_URI}/health" >/dev/null 2>&1; then
    mlf="${g}● running${z}"
  else
    mlf="${r}○ not running${z} ${d}(htd-start &)${z}"
  fi
  cat <<EOF

${o}  ██╗  ██╗████████╗██████╗ ${z}
${o}  ██║  ██║╚══██╔══╝██╔══██╗${z}
${o}  ███████║   ██║   ██║  ██║${z}   ${c}Researcher${z} · MLflow workspace
${o}  ██╔══██║   ██║   ██║  ██║${z}   ${d}$(. /etc/htd-release 2>/dev/null; echo "MLflow ${MLFLOW_VERSION:-?} · built ${BUILT:-?}")${z}
${o}  ██║  ██║   ██║   ██████╔╝${z}
${o}  ╚═╝  ╚═╝   ╚═╝   ╚═════╝ ${z}

  user      ${c}${HTD_USER}${z} ${d}(uid $(id -u))${z}    project ${c}${HTD_PROJECT:-local}${z}    workload ${c}${HTD_WORKLOAD:-?}${z}
  home      ${HTD_HOME}
  mlflow    ${mlf}  ${HTD_MLFLOW_URL:-$MLFLOW_TRACKING_URI}

  ${d}htd-help · htd-info · htd-demo${z}

EOF
}
__htd_motd
unset -f __htd_motd

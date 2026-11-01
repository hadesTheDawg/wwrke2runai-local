# Minimal Run:ai REST API helpers (sourced). Talks to the control plane
# through the ingress on ww1, trusting the site CA. Requires env.sh.
RUNAI_URL="https://${RUNAI_DOMAIN}"
_curl() {
  curl -sS --fail-with-body --cacert "$RUNAI_DIR/ca.crt" --resolve "${RUNAI_DOMAIN}:443:${WW_INTERNAL_IP}" "$@"
}

# Admin access token (password grant, /api/v2/token)
runai_login() {
  RUNAI_TOKEN=$(_curl -X POST "$RUNAI_URL/api/v2/token" \
      -d grant_type=password -d client_id=cli \
      --data-urlencode "username=$RUNAI_ADMIN_USER" \
      --data-urlencode "password@$RUNAI_DIR/admin-password" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
}

# runai_api <METHOD> <path> [json body]
runai_api() {
  local m=$1 p=$2; shift 2
  _curl -X "$m" -H "Authorization: Bearer $RUNAI_TOKEN" -H "Content-Type: application/json" \
    "$RUNAI_URL$p" ${1:+-d "$1"}
}

# jq-less field access: json_get '<python expr on d>' < json
json_get() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

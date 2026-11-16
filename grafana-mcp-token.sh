#!/bin/sh
# Gives the mcp-grafana sidecar its own Grafana credential, on the server, at
# every backend deploy — so GRAFANA_MCP_TOKEN is never a CI/CD variable.
#
#   grafana-mcp-token.sh <secrets-dir>
#
# Ensures a service account `mcp-grafana` with role Viewer exists in the local
# Grafana, mints it a fresh token, writes it to <secrets-dir>/1000/GRAFANA_MCP_TOKEN
# (through write-secrets.sh, next to this script) and revokes its older tokens.
# A token rotates on every deploy; the sidecar is recreated right after.
#
# It logs in as Grafana's admin (the user the grafana container was started
# with) with GRAFANA_ADMIN_PASSWORD. When Grafana refuses it, the password is
# set to GRAFANA_ADMIN_PASSWORD with `grafana cli` first: that variable, not
# whatever was typed in the UI, is the admin password. Fails (non-zero, file
# left as it was) when the variable is empty, Grafana is not healthy within
# 90s, or `mcp-grafana` exists with a role other than Viewer: the sidecar then
# keeps its previous token, or stays off.
#
# Env: GRAFANA_ADMIN_PASSWORD (required), GRAFANA_URL (http://127.0.0.1:3000),
# GRAFANA_CONTAINER (grafana).
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <secrets-dir>" >&2; exit 2; }
dir=$1
here=$(cd "$(dirname "$0")" && pwd)
url=${GRAFANA_URL:-http://127.0.0.1:3000}
container=${GRAFANA_CONTAINER:-grafana}
name=mcp-grafana
pass=${GRAFANA_ADMIN_PASSWORD:-}

fail() { echo "grafana-mcp-token: $*" >&2; exit 1; }

[ -n "$pass" ] || fail "GRAFANA_ADMIN_PASSWORD is empty: set it per environment (platform-infra make gitlab)"

i=0
until curl -fsS -o /dev/null "$url/api/health" 2>/dev/null; do
  i=$((i + 1))
  [ $i -lt 30 ] || fail "Grafana at $url is not healthy after 90s"
  sleep 3
done

user=$(sudo docker exec "$container" printenv GF_SECURITY_ADMIN_USER) || fail "cannot read the admin user from container $container"

# The credentials go through a 0600 curl config, never on a command line.
cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT
chmod 600 "$cfg"
quote() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }
printf 'user = "%s:%s"\n' "$(quote "$user")" "$(quote "$pass")" > "$cfg"

api() {
  method=$1 path=$2
  shift 2
  curl -fsS -K "$cfg" -X "$method" -H 'Content-Type: application/json' "$@" "$url$path"
}

login() { curl -sS -o /dev/null -w '%{http_code}' -K "$cfg" "$url/api/user" || true; }

status=$(login)
if [ "$status" = 401 ]; then
  printf '%s\n' "$pass" | sudo docker exec -i "$container" grafana cli admin reset-admin-password --password-from-stdin >/dev/null \
    || fail "cannot set Grafana's admin password"
  echo "==> set Grafana's admin password to GRAFANA_ADMIN_PASSWORD"
  status=$(login)
fi
[ "$status" = 200 ] || fail "Grafana refused the admin login (HTTP $status)"

json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); $1"; }

found=$(api GET "/api/serviceaccounts/search?perpage=1000&query=$name") || fail "cannot list Grafana service accounts"
sa=$(printf '%s' "$found" | json "
m=[a for a in d['serviceAccounts'] if a['name']=='$name']
print('%s %s' % (m[0]['id'], m[0]['role']) if m else '')")

if [ -z "$sa" ]; then
  id=$(api POST /api/serviceaccounts -d "{\"name\":\"$name\",\"role\":\"Viewer\",\"isDisabled\":false}" | json "print(d['id'])") \
    || fail "cannot create service account $name"
  echo "==> created Grafana service account $name (Viewer)"
else
  id=${sa% *} role=${sa#* }
  [ "$role" = Viewer ] || fail "service account $name has role $role, not Viewer: fix it in Grafana, no token minted"
fi

minted=$(api POST "/api/serviceaccounts/$id/tokens" -d "{\"name\":\"deploy-$(date +%Y%m%d%H%M%S)-$$\"}") \
  || fail "cannot mint a token for $name"
new_id=$(printf '%s' "$minted" | json "print(d['id'])")
GRAFANA_MCP_TOKEN=$(printf '%s' "$minted" | json "print(d['key'])")
export GRAFANA_MCP_TOKEN
sh "$here/write-secrets.sh" "$dir" 1000 GRAFANA_MCP_TOKEN

for old in $(api GET "/api/serviceaccounts/$id/tokens" | json "print(' '.join(str(t['id']) for t in d if t['id'] != $new_id))"); do
  api DELETE "/api/serviceaccounts/$id/tokens/$old" -o /dev/null || echo "grafana-mcp-token: could not revoke token $old" >&2
done
echo "==> mcp-grafana has a fresh Viewer token"

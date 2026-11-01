#!/bin/sh
# Keeps a product's deploy secrets, its environments and the platform's
# secrets template in step, from one list the product keeps.
#
#   secrets-check.sh lint <list> <template> <compose-file>...
#   secrets-check.sh set  <list>
#
# <list> (e.g. infra/secrets.list) names every secret the compose files mount
# from ./secrets/<uid>/<NAME>, one per line, as `NAME SOURCE [required]`:
#
#   platform  a CI/CD variable the platform's secrets template generates
#   product   a CI/CD variable this product sets by hand
#   derived   built by the deploy from other variables; never a CI/CD variable
#   required  the backend refuses to boot without it (platform or product only)
#
# lint fails when a compose secret is not listed, a listed one is mounted by no
# compose file, or a platform secret is missing from <template> (a
# NAME=... line, as in env.secrets.example). It runs on every pipeline, so a new
# secret is caught in the commit that adds it, not at the deploy.
#
# set fails when a required secret is empty in the environment. It runs in the
# deploy pipeline, in the deploy job's environment, before any server is
# touched.
set -eu

die() { echo "secrets-check: $*" >&2; exit 2; }

# Prints `NAME SOURCE REQUIRED` for each entry, validated.
entries() {
  sed -e 's/#.*//' "$1" | awk -v f="$1" '
    NF == 0 { next }
    {
      if ($1 !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { printf "%s:%d: not a variable name: %s\n", f, NR, $1 > "/dev/stderr"; bad=1; next }
      if ($2 != "platform" && $2 != "product" && $2 != "derived") { printf "%s:%d: %s: source must be platform, product or derived\n", f, NR, $1 > "/dev/stderr"; bad=1; next }
      req = ($3 == "required")
      if (NF > 3 || (NF == 3 && !req)) { printf "%s:%d: %s: only `required` may follow the source\n", f, NR, $1 > "/dev/stderr"; bad=1; next }
      if (req && $2 == "derived") { printf "%s:%d: %s: a derived secret cannot be required\n", f, NR, $1 > "/dev/stderr"; bad=1; next }
      if (seen[$1]++) { printf "%s:%d: %s listed twice\n", f, NR, $1 > "/dev/stderr"; bad=1; next }
      print $1, $2, req
    }
    END { exit bad }'
}

lint() {
  [ $# -ge 3 ] || die "usage: $0 lint <list> <template> <compose-file>..."
  list=$1 template=$2
  shift 2
  [ -f "$list" ] || die "no such list: $list"
  [ -f "$template" ] || die "no such template: $template"
  listed=$(entries "$list") || exit 1
  mounted=$(grep -ho '\./secrets/[0-9]*/[A-Za-z0-9_]*' "$@" | sed 's#.*/##' | sort -u)
  fail=0

  for name in $mounted; do
    echo "$listed" | grep -q "^$name " && continue
    echo "ERROR: $name is mounted from ./secrets/ but missing from $list"
    fail=1
  done
  echo "$listed" | while read -r name source _; do
    echo "$mounted" | grep -qx "$name" && continue
    echo "ERROR: $name is listed in $list but no compose file mounts it"
    exit 1
  done || fail=1
  echo "$listed" | while read -r name source _; do
    [ "$source" = platform ] || continue
    grep -q "^$name=" "$template" && continue
    echo "ERROR: $name is a platform secret but missing from $template — add it there so new environments get one"
    exit 1
  done || fail=1

  [ "$fail" = 0 ] || {
    echo "See the header of secrets-check.sh for what each source means."
    exit 1
  }
  echo "==> $(echo "$listed" | wc -l | tr -d ' ') secrets listed, mounted and, where platform, in the template — OK"
}

set_() {
  [ $# -eq 1 ] || die "usage: $0 set <list>"
  [ -f "$1" ] || die "no such list: $1"
  listed=$(entries "$1") || exit 1
  missing=$(echo "$listed" | while read -r name _ req; do
    [ "$req" = 1 ] || continue
    value=
    eval "value=\${$name-}"
    [ -n "$value" ] || echo "$name"
  done)
  [ -z "$missing" ] || {
    for name in $missing; do
      echo "ERROR: CI/CD variable $name is not set for this environment, and the backend will not boot without it"
    done
    exit 1
  }
  echo "==> every required secret is set — OK"
}

[ $# -ge 1 ] || die "usage: $0 lint|set ..."
cmd=$1
shift
case $cmd in
  lint) lint "$@" ;;
  set) set_ "$@" ;;
  *) die "unknown command: $cmd" ;;
esac

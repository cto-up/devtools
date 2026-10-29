#!/usr/bin/env bash
# DB-backed tests on a fresh clone of the local dev database. `make test` skips
# them (each needs a DSN) and still reports green. This clones the dev database
# (CREATE DATABASE ... TEMPLATE when it is idle, pg_dump in the Postgres
# container when it is not), so nothing ever writes to the database you develop
# against, then:
#   1. TestMigrationsApplyToClone, with $MIGRATION_ENV pointing at the clone:
#      the tree's migrations must apply to real data;
#   2. the *_Integration tests in $IT_PKGS (if any), against the migrated clone.
#
# Reads DATABASE_URL / DATABASE_USERNAME / DATABASE_PASSWORD the way the app
# does: .env (exported by the Makefile), overridden by .env.local. Settings: MIGRATION_ENV (required), IT_DB (default <db>_it),
# PG_CONTAINER (needed when the dev database is busy), IT_PKGS, IT_ENV_DSN + IT_ENV_TENANT + IT_TENANT_SUBDOMAIN (to hand the
# integration tests a DSN and a tenant id). Local databases only.
set -uo pipefail

: "${MIGRATION_ENV:?set MIGRATION_ENV, e.g. APP_MIGRATION_TEST_DSN}"

# The backend loads .env then .env.local (godotenv.Overload); clone what it uses.
local_val() { [ -f .env.local ] && sed -nE "s/^$1[[:space:]]*=[[:space:]]*//p" .env.local | tail -1; }
for k in DATABASE_URL DATABASE_USERNAME DATABASE_PASSWORD; do
  v=$(local_val "$k")
  [ -n "$v" ] && printf -v "$k" '%s' "$v"
done
host=${DATABASE_URL%%/*}
src=${DATABASE_URL#*/}; src=${src%%\?*}
IT_DB=${IT_DB:-${src}_it}

case "$host" in 127.0.0.1*|localhost*) ;; *) echo "test-it: refusing, $host is not a local database"; exit 1;; esac
[ "$src" != "$IT_DB" ] || { echo "test-it: IT_DB must differ from the dev database"; exit 1; }

admin="postgres://$DATABASE_USERNAME:$DATABASE_PASSWORD@$host/postgres?sslmode=disable"
dsn="postgres://$DATABASE_USERNAME:$DATABASE_PASSWORD@$host/$IT_DB?sslmode=disable"

exists=$(psql "$admin" -Atc "SELECT 1 FROM pg_database WHERE datname='$src'") || exit 1
[ "$exists" = "1" ] || { echo "test-it: source database $src does not exist on $host (DATABASE_URL in .env / .env.local)"; exit 1; }
busy=$(psql "$admin" -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname='$src'") || exit 1
psql "$admin" -q -c "DROP DATABASE IF EXISTS $IT_DB" || exit 1
if [ "$busy" = "0" ]; then
  # A file-level copy, seconds; only possible while nothing is connected.
  echo "test-it: cloning $src into $IT_DB"
  psql "$admin" -q -c "CREATE DATABASE $IT_DB TEMPLATE $src" || exit 1
else
  # Something holds the source open (a running backend, an IDE). Dump and
  # restore instead, inside the Postgres container so pg_dump matches the
  # server's major version.
  : "${PG_CONTAINER:?set PG_CONTAINER, the dev Postgres container pg_dump runs in}"
  echo "test-it: $src has $busy open connection(s); copying it with pg_dump in $PG_CONTAINER (slower)"
  psql "$admin" -q -c "CREATE DATABASE $IT_DB" || exit 1
  docker exec -e PGPASSWORD="$DATABASE_PASSWORD" "$PG_CONTAINER" sh -c \
    "pg_dump -U '$DATABASE_USERNAME' -d '$src' --no-owner | psql -q -v ON_ERROR_STOP=1 -U '$DATABASE_USERNAME' -d '$IT_DB' >/dev/null" || exit 1
fi

log=$(mktemp)
cd backend/src || exit 1
# -count=1 matters: the DSN is in go's test cache key, the database behind it is not.
env "$MIGRATION_ENV=$dsn" go test -count=1 -tags=testutils -run '^TestMigrationsApplyToClone$' -v ./cmd/full/ >"$log" 2>&1
rc=$?

if [ $rc -eq 0 ] && [ -n "${IT_PKGS:-}" ]; then
  extra=()
  if [ -n "${IT_ENV_DSN:-}" ]; then
    extra+=("$IT_ENV_DSN=$dsn")
  fi
  if [ -n "${IT_ENV_TENANT:-}" ]; then
    tenant=$(psql "$dsn" -Atc "SELECT tenant_id FROM core_tenants WHERE subdomain='${IT_TENANT_SUBDOMAIN:-corpa}' LIMIT 1")
    [ -n "$tenant" ] || { echo "test-it: no tenant with subdomain ${IT_TENANT_SUBDOMAIN:-corpa} in $IT_DB"; exit 1; }
    extra+=("$IT_ENV_TENANT=$tenant")
  fi
  # shellcheck disable=SC2086
  env ${extra[@]+"${extra[@]}"} go test -count=1 -tags=testutils -run '_Integration' -v $IT_PKGS >>"$log" 2>&1
  rc=$?
fi

grep -E '^(--- FAIL|FAIL|ok|panic)' "$log"
echo "test-it: $(grep -c '^--- PASS' "$log") passed, $(grep -c '^--- SKIP' "$log") skipped, $(grep -c '^--- FAIL' "$log") failed (full log: $log)"
exit $rc

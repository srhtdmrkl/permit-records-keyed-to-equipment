#!/usr/bin/env bash
# Runs every test against a real PostgreSQL server, one fresh database per test.
# Connect as a superuser: the tamper tests disable triggers on purpose.
#
#   PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres ./tests/run.sh
#
# Needs psql, createdb and dropdb. Without them, run it inside a postgres
# container instead; the README shows how.

set -uo pipefail
cd "$(dirname "$0")/.."

core=(sql/*.sql seed/p101_scenario.sql)
app=(sql/*.sql app/sql/*.sql tests/app/_helpers.sql)
failed=0
total=0

run() {
    local test=$1; shift
    total=$((total + 1))
    db="permit_test_$$_$total"
    createdb "$db" || exit 1
    if out=$(cat "$@" "$test" | psql -X -q -v ON_ERROR_STOP=1 -d "$db" 2>&1); then
        echo "ok    $test"
    else
        failed=$((failed + 1))
        echo "FAIL  $test"
        echo "$out" | sed 's/^/      /'
    fi
    dropdb "$db"
}

for test in tests/*.sql; do run "$test" "${core[@]}"; done
for test in tests/app/a*.sql; do run "$test" "${app[@]}"; done

echo
echo "$((total - failed))/$total passed on $(psql -X -At -d postgres -c 'SHOW server_version')"
[ "$failed" -eq 0 ]

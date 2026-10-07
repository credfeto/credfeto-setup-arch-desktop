#!/usr/bin/env bats
# Acceptance tests for settings/scripts/db/{dbappsettings,dbenv,querydb}.

load test_helper

DB_DIR="${SCRIPTS_DIR}/db"
DBENV="${DB_DIR}/dbenv"
DBAPPSETTINGS="${DB_DIR}/dbappsettings"
QUERYDB="${DB_DIR}/querydb"

setup() {
    # Isolate from the real machine's ~/.database and any ancestor .database
    # files - dbenv/querydb both walk up from PWD and read ~/.database.
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    cd "${BATS_TEST_TMPDIR}" || exit
}

@test "dbenv does not crash when ~/.database is absent" {
    run "${DBENV}" --server myserver --user myuser --password mypass
    [[ "${output}" == *"Server: myserver"* ]]
    [[ "${output}" != *"No such file or directory"* ]]
}

@test "dbenv dies when --server is not specified" {
    run "${DBENV}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--server not specified"* ]]
}

@test "dbenv dies when --user is not specified" {
    run "${DBENV}" --server myserver
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--user not specified"* ]]
}

@test "dbenv dies when --password is not specified" {
    run "${DBENV}" --server myserver --user myuser
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--password not specified"* ]]
}

@test "dbenv succeeds and reports settings when all required flags are given" {
    # No exit-status assertion: dbenv has no explicit `exit 0` - its status
    # is whatever its last statement returns, which is
    # `[ -n "$OUTPUT" ] && info ...`, an unrelated internal only set via the
    # repo-local .database walk-up, not by these cmdline flags. Not
    # meaningful as a success/failure signal here, so only the reported
    # settings are checked.
    run "${DBENV}" --server myserver --user myuser --password mypass --database mydb
    [[ "${output}" == *"Server: myserver"* ]]
    [[ "${output}" == *"User: myuser"* ]]
    [[ "${output}" == *"DB: mydb"* ]]
}

@test "dbenv with SERVER=localhost probes docker for the mssql container IP" {
    setup_fake_bin sudo
    seed_fake_output sudo <<< "172.18.0.5"
    run "${DBENV}" --server localhost --user myuser --password mypass --database mydb
    assert_fake_called '^sudo docker inspect'
    [[ "${output}" == *"172.18.0.5"* ]]
}

@test "dbappsettings dies when --database is not specified" {
    run "${DBAPPSETTINGS}" --server myserver --user myuser --password mypass
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--database not specified"* ]]
}

@test "dbappsettings creates appsettings-local.json for each project with appsettings.json" {
    mkdir -p "${BATS_TEST_TMPDIR}/repo/src/Foo"
    cd "${BATS_TEST_TMPDIR}/repo"
    printf '<Project Sdk="Microsoft.NET.Sdk"></Project>' > src/Foo/Foo.csproj
    printf '{}' > src/Foo/appsettings.json

    run "${DBAPPSETTINGS}" --server myserver --user myuser --password mypass --database mydb
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Creating"*"appsettings-local.json"* ]]
    [ -f src/Foo/appsettings-local.json ]

    run jq -r '.DatabaseConfiguration.Provider' src/Foo/appsettings-local.json
    [ "${output}" = "mssql" ]

    run jq -r '.DatabaseConfiguration.ConnectionString' src/Foo/appsettings-local.json
    [[ "${output}" == *"Database=mydb"* ]]
    [[ "${output}" == *"Server=myserver"* ]]
    [[ "${output}" == *"User ID=myuser"* ]]
    [[ "${output}" == *"Password=mypass"* ]]
}

@test "dbappsettings leaves an existing appsettings-local.json in place" {
    mkdir -p "${BATS_TEST_TMPDIR}/repo/src/Foo"
    cd "${BATS_TEST_TMPDIR}/repo"
    printf '<Project Sdk="Microsoft.NET.Sdk"></Project>' > src/Foo/Foo.csproj
    printf '{}' > src/Foo/appsettings.json
    printf '{"existing":true}' > src/Foo/appsettings-local.json

    run "${DBAPPSETTINGS}" --server myserver --user myuser --password mypass --database mydb
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Existing"* ]]
}

@test "querydb dies when SERVER is not set" {
    run "${QUERYDB}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"SERVER not set"* ]]
}

@test "querydb dies when DB is not set" {
    printf 'SERVER=myserver\n' > "${HOME}/.database"
    run "${QUERYDB}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"DB not set"* ]]
}

@test "querydb reads settings from a repo-local .database file and invokes sqlcmd" {
    setup_fake_bin sqlcmd
    mkdir -p "${BATS_TEST_TMPDIR}/repo/src"
    printf 'SERVER=myserver\nDB=mydb\nUSER=myuser\nPASSWORD=mypass\n' > "${BATS_TEST_TMPDIR}/repo/.database"
    cd "${BATS_TEST_TMPDIR}/repo/src"

    run "${QUERYDB}" -Q "SELECT 1"
    [ "${status}" -eq 0 ]
    assert_fake_called '^sqlcmd -S myserver -d mydb -U myuser -P mypass -Q SELECT 1'
}

@test "dbenv fails, naming the directory, when ~/.redgate cannot be created" {
    mkdir -p "${BATS_TEST_TMPDIR}/repo"
    printf 'SERVER=myserver\nDB=mydb\nUSER=myuser\nPASSWORD=mypass\n' > "${BATS_TEST_TMPDIR}/repo/.database"
    cd "${BATS_TEST_TMPDIR}/repo" || exit
    # A file where the directory should be, so mkdir cannot create it.
    : > "${HOME}/.redgate"

    run "${DBENV}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not create ${HOME}/.redgate"* ]]
}

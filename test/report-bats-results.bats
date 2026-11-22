#!/usr/bin/env bats
# Tests for the report-bats-results composite action's script: what it reports
# and whether it fails for a results stream that bats finished, failed in, or
# stopped in part way through a test. The script is kept inline in action.yml,
# so each test takes it from there and runs it under node with a stand-in for
# the github-script core object.

bats_require_minimum_version 1.5.0

load test_helper

ACTION_FILE="${REPO_DIR}/.github/actions/report-bats-results/action.yml"

setup() {
    command -v node > /dev/null || {
        echo "node is needed to run the report-bats-results script" >&2
        return 1
    }
    RESULTS_FILE="${BATS_TEST_TMPDIR}/results.tap"
    SCRIPT_FILE="${BATS_TEST_TMPDIR}/report.js"
    HARNESS_FILE="${BATS_TEST_TMPDIR}/harness.js"
    extract_script > "${SCRIPT_FILE}"
    [ -s "${SCRIPT_FILE}" ]
    write_harness
}

# Prints the github-script body: every line after the script key, which is
# the last key in action.yml, with the block's indentation taken off.
extract_script() {
    awk '
        in_script { sub(/^          /, ""); print; next }
        /^        script: \|$/ { in_script = 1 }
    ' "${ACTION_FILE}"
}

# Writes a node script that runs the extracted body as github-script does, as
# an async function given require and core, then prints what it reported:
# "FAILED: <message>" for setFailed, "INFO: <message>" for info, and the job
# summary it built after a "SUMMARY:" line.
write_harness() {
    cat > "${HARNESS_FILE}" <<'EOF'
const fs = require('fs');
const body = fs.readFileSync(process.argv[2], 'utf8');
const summaryParts = [];
const summary = {
  addHeading: (text, level) => { summaryParts.push(`h${level} ${text}`); return summary; },
  addTable: rows => { summaryParts.push(`table ${JSON.stringify(rows.map(row => row.map(cell => cell.data ?? cell)))}`); return summary; },
  addList: items => { items.forEach(item => summaryParts.push(`item ${item}`)); return summary; },
  write: async () => summary,
};
const core = {
  summary,
  error: message => console.log(`ERROR: ${message}`),
  info: message => console.log(`INFO: ${message}`),
  setFailed: message => console.log(`FAILED: ${message}`),
};
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
new AsyncFunction('require', 'core', body)(require, core).then(() => {
  console.log('SUMMARY:');
  summaryParts.forEach(part => console.log(part));
});
EOF
}

# Runs the report over the results stream read from stdin.
# Usage: run_report <bats-outcome> [<bats-exit-status>] <<'EOF' ... EOF
run_report() {
    cat > "${RESULTS_FILE}"
    run env RESULTS_FILE="${RESULTS_FILE}" BATS_OUTCOME="$1" BATS_EXIT_STATUS="${2:-}" node "${HARNESS_FILE}" "${SCRIPT_FILE}"
    [ "${status}" -eq 0 ]
}

# Prints the message the report failed with, failing when it did not fail.
failure_message() {
    local _line
    _line="$(grep -m 1 '^FAILED: ' <<< "${output}")" || return 1
    printf '%s\n' "${_line#FAILED: }"
}

@test "names the test that was running when timeout stopped bats" {
    run_report failure 124 <<'EOF'
1..3
suite /repo/test/a.bats
begin 1 first
ok 1 first
begin 2 second
ok 2 second
begin 3 third hangs
EOF
    message="$(failure_message)"
    [[ "${message}" == *"bats planned 3 test(s) but 2 reported a result"* ]]
    [[ "${message}" == *"bats timed out (exit 124) while running test 3: third hangs"* ]]
    [[ "${message}" != *"for a reason the test results do not show"* ]]
}

@test "reports a timeout that needed KILL as a timeout" {
    run_report failure 137 <<'EOF'
1..2
begin 1 first
ok 1 first
begin 2 second ignores TERM
EOF
    [[ "$(failure_message)" == *"bats timed out (exit 137) while running test 2: second ignores TERM"* ]]
}

@test "names the first test when bats crashed before any test reported a result" {
    run_report failure 2 <<'EOF'
1..2
suite /repo/test/a.bats
begin 1 first crashes
EOF
    message="$(failure_message)"
    [[ "${message}" == *"bats ran no tests"* ]]
    [[ "${message}" == *"bats crashed (exit 2) while running test 1: first crashes"* ]]
    [[ "${message}" != *"for a reason the test results do not show"* ]]
}

@test "says the exit status was not recorded when bats stopped without one" {
    run_report failure <<'EOF'
1..2
begin 1 first
ok 1 first
begin 2 second
EOF
    [[ "$(failure_message)" == *"bats stopped (exit status not recorded) while running test 2: second"* ]]
}

@test "reports a timeout between tests as no test running" {
    run_report failure 124 <<'EOF'
1..3
begin 1 first
ok 1 first
begin 2 second
ok 2 second
EOF
    message="$(failure_message)"
    [[ "${message}" == *"bats planned 3 test(s) but 2 reported a result"* ]]
    [[ "${message}" == *"bats timed out (exit 124) while no test was running"* ]]
}

@test "adds the interrupted test to the summary with its name escaped" {
    run_report failure 124 <<'EOF'
1..1
begin 1 renders <b> & more
EOF
    grep -qxF 'h3 Interrupted' <<< "${output}"
    grep -qxF 'item bats timed out (exit 124) while running test 1: renders &lt;b&gt; &amp; more' <<< "${output}"
}

@test "reports a failed test without naming an interruption" {
    run_report failure 1 <<'EOF'
1..2
begin 1 first
ok 1 first
begin 2 second
not ok 2 second
# (in test file /repo/test/a.bats, line 9)
EOF
    message="$(failure_message)"
    [ "${message}" = "❌ 1 of 2 test(s) failed" ]
    [[ "${output}" != *"Interrupted"* ]]
}

@test "passes a run in which every planned test passed" {
    run_report success 0 <<'EOF'
1..2
begin 1 first
ok 1 first
begin 2 second
ok 2 second
EOF
    [[ "${output}" != *"FAILED: "* ]]
    grep -qxF 'INFO: ✅ 2 test(s) passed, none skipped' <<< "${output}"
    [[ "${output}" != *"Interrupted"* ]]
}

@test "names no test for plain TAP results without begin lines" {
    run_report failure <<'EOF'
1..3
ok 1 first
ok 2 second
EOF
    [ "$(failure_message)" = "❌ bats planned 3 test(s) but 2 reported a result" ]
}

@test "still fails an unexplained failure outcome" {
    run_report failure 1 <<'EOF'
1..1
begin 1 first
ok 1 first
EOF
    [[ "$(failure_message)" == *"the bats step did not succeed (failure, exit 1) for a reason the test results do not show"* ]]
}

# Writes a suite whose second test sleeps far longer than the timeout given to
# it, then runs it the way the workflow runs the real suite, with the stream
# and the exit status the report is given.
#
# The test lines are printed rather than written out in a heredoc: bats finds
# tests by matching each line of a file, heredocs included.
@test "names the hung test from a real timed-out bats run" {
    local _suite="${BATS_TEST_TMPDIR}/hangs.bats" _stream="${BATS_TEST_TMPDIR}/stream.tap" _exit=0
    {
        printf '%s "%s" {\n    true\n}\n' '@test' 'quick'
        printf '%s "%s" {\n    sleep 60\n}\n' '@test' 'hangs'
        printf '%s "%s" {\n    true\n}\n' '@test' 'never starts'
    } > "${_suite}"
    timeout --kill-after=5 3 bats --formatter cat "${_suite}" > "${_stream}" 3>&- || _exit=$?
    run_report failure "${_exit}" < "${_stream}"
    [[ "$(failure_message)" == *"bats timed out (exit ${_exit}) while running test 2: hangs"* ]]
}

#!/usr/bin/env bats
# Throwaway proof that a skipped test fails the shell-tests CI check.

load test_helper

@test "throwaway proof: this test is skipped on a CI runner" {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        skip "deliberate skip to prove shell-tests fails on a skipped test"
    fi
}

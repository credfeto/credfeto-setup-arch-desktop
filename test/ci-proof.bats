#!/usr/bin/env bats
# Throwaway proof that a skipped test fails the shell-tests CI check.

load test_helper

@test "throwaway proof: this test fails on a CI runner" {
    [ -z "${GITHUB_ACTIONS:-}" ]
}

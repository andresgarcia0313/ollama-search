#!/usr/bin/env bash
set -euo pipefail

# --- Test Runner ---

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Ensure the script to be tested is executable
if [ ! -x ./ollama-cli.sh ]; then
  echo "Making ollama-cli.sh executable..."
  chmod +x ./ollama-cli.sh
fi

# Counters for test results
passed=0
failed=0

# Function to run a single test
# Usage: run_test "Test Description" "command_to_run" "check_type" "expected_pattern"
run_test() {
  local description="$1"
  local command="$2"
  local check_type="$3"
  local pattern="$4"
  
  echo -n -e "TEST: $description ... "
  
  # Execute the command and capture output and exit code
  local output
  output=$($command 2>&1) || true # allow non-zero exit codes
  
  local test_passed=0
  
  # Determine test result
  case "$check_type" in
    "contains")
      if [[ "$output" == *"$pattern"* ]]; then
        test_passed=1
      fi
      ;;
    "not_contains")
      if [[ "$output" != *"$pattern"* ]]; then
        test_passed=1
      fi
      ;;
    "is_empty")
      if [[ -z "$output" ]]; then
        test_passed=1
      fi
      ;;
    "is_not_empty")
      if [[ -n "$output" ]]; then
        test_passed=1
      fi
      ;;
  esac
  
  if [ $test_passed -eq 1 ]; then
    echo -e "${GREEN}PASS${NC}"
    passed=$((passed + 1))
  else
    echo -e "${RED}FAIL${NC}"
    echo "  - Command: $command"
    echo "  - Expected: $check_type '$pattern'"
    echo "  - Got output:"
    echo "$output"
    failed=$((failed + 1))
  fi
}

# --- Test Cases ---

echo "--- Running ollama-cli tests ---"

# Test 1: Broad search that was previously bugged
run_test "Search for 'llama3' should include 'llama3.1'" \
         "./ollama-cli.sh search llama3" \
         "contains" \
         "llama3.1"

# Test 2: Accurate search, excluding near matches
run_test "Search for 'tiny' should NOT include 'tulu'" \
         "./ollama-cli.sh search tiny" \
         "not_contains" \
         "tulu"

# Test 3: Search with no results should be empty
run_test "Search for a non-existent model should be empty" \
         "./ollama-cli.sh search nonexistantmodelxyz" \
         "is_empty" \
         ""

# Test 4: Check if scraping is working (looking for size units)
run_test "Search results should include file sizes (GB/MB)" \
         "./ollama-cli.sh search llama2" \
         "contains" \
         "GB"

# --- Summary ---
echo "--- Test Summary ---"
echo -e "Total tests: $((passed + failed))"
echo -e "${GREEN}Passed: $passed${NC}"
echo -e "${RED}Failed: $failed${NC}"

# Exit with a non-zero code if any test failed
if [ $failed -ne 0 ]; then
  exit 1
fi

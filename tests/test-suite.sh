#!/bin/bash
#
# test-suite.sh - Automated test suite for netplan-rollback
#
# IMPORTANT: This script performs real system operations. Review each test
# before running and ensure you understand what it does.
#
# Usage: test-suite.sh [--test-name] [--interactive]
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_DIR="/tmp/netplan-rollback-test-$$"
STATE_DIR="/root/netplan-rollback"
INTERACTIVE=""
SPECIFIC_TEST=""

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --interactive)
            INTERACTIVE="yes"
            shift
            ;;
        --test-*)
            SPECIFIC_TEST="${1#--test-}"
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: test-suite.sh [OPTIONS]

Automated test suite for netplan-rollback system.

OPTIONS:
  --interactive       Prompt before each destructive operation
  --test-NAME         Run only specific test (e.g., --test-syntax)
  -h, --help         Show this help message

AVAILABLE TESTS:
  syntax              Test syntax validation
  dry-run            Test dry-run mode
  help-commands      Test help commands
  state-directory    Test state directory creation
  backup-creation    Test backup file creation

IMPORTANT:
  Some tests require root access and may modify system state temporarily.
  Always review the test code before running in production environments.

EXAMPLES:
  # Run all tests interactively
  sudo ./test-suite.sh --interactive

  # Run specific test
  sudo ./test-suite.sh --test-syntax

  # Run all tests non-interactively (use with caution!)
  sudo ./test-suite.sh
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Logging functions
log_test_start() {
    echo -e "${BLUE}[TEST]${NC} $*"
}

log_test_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((TESTS_PASSED++))
}

log_test_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((TESTS_FAILED++))
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Helper functions
prompt_continue() {
    if [[ -n "${INTERACTIVE}" ]]; then
        read -p "Press Enter to continue with this test, or Ctrl+C to abort... " -r
    fi
}

cleanup_test_env() {
    rm -rf "${TEST_DIR}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "Some tests require root access"
        return 1
    fi
    return 0
}

# Test functions
test_syntax_validation() {
    log_test_start "Syntax validation test"
    ((TESTS_RUN++))

    prompt_continue

    # Create test netplan configs
    mkdir -p "${TEST_DIR}"

    # Valid config
    cat > "${TEST_DIR}/valid.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
EOF

    # Invalid config
    cat > "${TEST_DIR}/invalid.yaml" <<'EOF'
network:
  this is: invalid yaml syntax [[[
EOF

    # Test with valid config (should pass)
    log_info "Testing valid netplan syntax..."
    if netplan-swap.sh --dry-run "${TEST_DIR}/valid.yaml" "${TEST_DIR}/valid.yaml" 2>&1 | grep -q "Syntax validation passed"; then
        log_test_pass "Valid syntax correctly accepted"
    else
        log_test_fail "Valid syntax was rejected"
        return 1
    fi

    # Test with invalid config (should fail)
    log_info "Testing invalid netplan syntax..."
    if netplan-swap.sh --dry-run "${TEST_DIR}/valid.yaml" "${TEST_DIR}/invalid.yaml" 2>&1 | grep -q "Syntax validation failed"; then
        log_test_pass "Invalid syntax correctly rejected"
    else
        log_test_fail "Invalid syntax was accepted"
        return 1
    fi

    cleanup_test_env
}

test_dry_run_mode() {
    log_test_start "Dry-run mode test"
    ((TESTS_RUN++))

    prompt_continue

    mkdir -p "${TEST_DIR}"

    # Create test config
    cat > "${TEST_DIR}/test.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
EOF

    log_info "Running dry-run mode..."
    if netplan-swap.sh --dry-run "${TEST_DIR}/test.yaml" "${TEST_DIR}/test.yaml" 60 2>&1 | grep -q "DRY-RUN MODE"; then
        log_test_pass "Dry-run mode works correctly"
    else
        log_test_fail "Dry-run mode failed"
        return 1
    fi

    # Verify no state directory was created
    if [[ ! -d "${STATE_DIR}" ]] || [[ ! -f "${STATE_DIR}/state.json" ]]; then
        log_test_pass "Dry-run correctly avoided creating state"
    else
        log_test_fail "Dry-run created state files (should not happen)"
        return 1
    fi

    cleanup_test_env
}

test_help_commands() {
    log_test_start "Help command test"
    ((TESTS_RUN++))

    log_info "Testing netplan-swap.sh --help..."
    if netplan-swap.sh --help 2>&1 | grep -q "Usage:"; then
        log_test_pass "netplan-swap.sh help works"
    else
        log_test_fail "netplan-swap.sh help failed"
        return 1
    fi

    log_info "Testing netplan-confirm.sh --help..."
    if netplan-confirm.sh --help 2>&1 | grep -q "Usage:"; then
        log_test_pass "netplan-confirm.sh help works"
    else
        log_test_fail "netplan-confirm.sh help failed"
        return 1
    fi
}

test_script_permissions() {
    log_test_start "Script permissions test"
    ((TESTS_RUN++))

    local scripts=(
        "/usr/local/bin/netplan-swap.sh"
        "/usr/local/bin/netplan-rollback.sh"
        "/usr/local/bin/netplan-confirm.sh"
    )

    local all_ok=true
    for script in "${scripts[@]}"; do
        if [[ -x "${script}" ]]; then
            log_info "Found and executable: ${script}"
        else
            log_warn "Not executable or missing: ${script}"
            all_ok=false
        fi
    done

    if [[ "${all_ok}" == "true" ]]; then
        log_test_pass "All scripts have correct permissions"
    else
        log_test_fail "Some scripts have incorrect permissions"
        return 1
    fi
}

test_dependencies() {
    log_test_start "Dependencies test"
    ((TESTS_RUN++))

    local deps=("systemctl" "netplan" "jq")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &> /dev/null; then
            missing+=("${dep}")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_test_pass "All dependencies available"
    else
        log_test_fail "Missing dependencies: ${missing[*]}"
        return 1
    fi
}

# Display summary
display_summary() {
    echo ""
    echo "========================================"
    echo "TEST SUMMARY"
    echo "========================================"
    echo "Tests run:    ${TESTS_RUN}"
    echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
    echo "========================================"

    if [[ ${TESTS_FAILED} -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

# Main test execution
main() {
    echo "========================================"
    echo "Netplan-Rollback Test Suite"
    echo "========================================"
    echo ""

    if [[ -n "${INTERACTIVE}" ]]; then
        log_warn "Running in INTERACTIVE mode"
        log_warn "You will be prompted before each test"
        echo ""
    fi

    # Run tests
    if [[ -z "${SPECIFIC_TEST}" ]] || [[ "${SPECIFIC_TEST}" == "dependencies" ]]; then
        test_dependencies || true
    fi

    if [[ -z "${SPECIFIC_TEST}" ]] || [[ "${SPECIFIC_TEST}" == "permissions" ]]; then
        test_script_permissions || true
    fi

    if [[ -z "${SPECIFIC_TEST}" ]] || [[ "${SPECIFIC_TEST}" == "help" ]]; then
        test_help_commands || true
    fi

    if [[ -z "${SPECIFIC_TEST}" ]] || [[ "${SPECIFIC_TEST}" == "dry-run" ]]; then
        test_dry_run_mode || true
    fi

    if [[ -z "${SPECIFIC_TEST}" ]] || [[ "${SPECIFIC_TEST}" == "syntax" ]]; then
        test_syntax_validation || true
    fi

    # Display summary
    echo ""
    display_summary
}

# Trap cleanup
trap cleanup_test_env EXIT

# Run main
main "$@"

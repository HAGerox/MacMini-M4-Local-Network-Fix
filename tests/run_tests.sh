#!/bin/zsh

set -euo pipefail

repo_dir=${0:A:h:h}
source_script="$repo_dir/toggle_local_network.applescript"
test_dir=$(mktemp -d /tmp/toggle-local-network-tests.XXXXXX)
compiled_script="$test_dir/toggle_local_network.scpt"
mode=${1:-unit}

fail() {
	print -u2 -- "FAIL: $1"
	exit 1
}

require_source_text() {
	local pattern=$1
	local description=$2
	/usr/bin/grep -Fq -- "$pattern" "$source_script" || fail "$description"
}

reject_source_regex() {
	local pattern=$1
	local description=$2
	if /usr/bin/grep -Eq -- "$pattern" "$source_script"; then
		fail "$description"
	fi
}

print -- "Compiling AppleScript..."
/usr/bin/osacompile -o "$compiled_script" "$source_script"
print -- "compile: PASS"

print -- "Checking structural safety invariants..."
require_source_text 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension' 'modern Privacy & Security URL is missing'
require_source_text 'Local Network_Navigator' 'exact semantic navigator identifier is missing'
require_source_text 'candidateID contains "Local Network"' 'semantic Local Network fallback is missing'
require_source_text 'candidateID ends with "_Toggle"' 'semantic toggle suffix is missing'
require_source_text 'AXIsProcessTrustedWithOptions' 'native Accessibility prompt request is missing'
require_source_text 'display alert "Accessibility access is required"' 'Accessibility explanation is missing'
require_source_text 'button returned of permissionDialog is "Open Accessibility Settings"' 'Accessibility button handling is missing'
require_source_text 'Privacy_Accessibility' 'Accessibility settings URL is missing'
reject_source_regex 'click[[:space:]]+button[[:space:]]+[0-9]+|button[[:space:]]+[0-9]+[[:space:]]+of' 'positional button lookup returned'
reject_source_regex 'group[[:space:]]+[0-9]+' 'positional group lookup returned'
reject_source_regex 'repeat[[:space:]]+until' 'an unbounded repeat-until wait returned'
reject_source_regex 'com\.apple\.preference\.security' 'legacy Privacy & Security URL returned'
reject_source_regex 'window[[:space:]]+"Privacy & Security"' 'stale named-window lookup returned'
print -- "static_invariants: PASS"

print -- "Running helper unit tests..."
/usr/bin/osascript "$repo_dir/tests/unit_helpers.applescript" "$compiled_script"

if [[ "$mode" == "unit" ]]; then
	print -- "All unit/static tests passed."
	exit 0
fi

if [[ "$mode" != "integration" ]]; then
	fail "usage: tests/run_tests.sh [unit|integration]"
fi

if [[ "${RUN_UI_TESTS:-0}" != "1" ]]; then
	fail "integration tests control System Settings; run them explicitly with RUN_UI_TESTS=1"
fi

print -- "Running live toggle round-trip test..."
/usr/bin/osascript "$repo_dir/tests/integration_toggle_roundtrip.applescript" "$compiled_script"

print -- "All tests passed."

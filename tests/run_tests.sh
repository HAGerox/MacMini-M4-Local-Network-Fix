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
require_source_text 'errorNumber is -10000' 'transient AppleEvent failure handling is missing'
require_source_text 'checkboxes of UI element 1 of every row of outline 1' 'direct permission-row query is missing'
require_source_text 'on permissionScrollValue()' 'scroll-position verification helper is missing'
require_source_text 'perform action "AXPress" of toggleElement' 'non-scrolling checkbox action is missing'
require_source_text 'return my resolvedToggleAtRow(rowIndex)' 'resolved row access is missing'
require_source_text 'set deadline to (current date) + timeoutSeconds' 'bounded state-change wait is missing'
require_source_text 'set toggleResult to my readToggle(rowIndex, toggleElement)' 'stale toggle fallback is missing'
require_source_text 'if item 2 of confirmedResult is wantedValue then return toggleElement' 'stable-state confirmation is missing'
require_source_text 'pressToggleAndWait(rowIndex, toggleElement, 0, false)' 'disabled-state polling is missing'
require_source_text 'pressToggleAndWait(rowIndex, toggleElement, 1, true)' 'per-row enabled-state confirmation is missing'
require_source_text 'set nextRetry to (current date) + retrySeconds' 'slow Settings retry spacing is missing'
require_source_text 'my ensureRowsHaveValue(enabledRows, 1)' 'permission restoration is missing'
require_source_text 'AXIsProcessTrustedWithOptions' 'native Accessibility prompt request is missing'
require_source_text 'on nativeAccessibilityPromptWasRequested()' 'Accessibility prompt state check is missing'
require_source_text 'my rememberNativeAccessibilityPrompt()' 'native Accessibility prompt state recording is missing'
require_source_text 'my clearNativeAccessibilityPromptMemory()' 'Accessibility prompt state reset is missing'
require_source_text 'display alert "Accessibility access is required"' 'Accessibility fallback explanation is missing'
require_source_text 'button returned of permissionDialog is "Open Accessibility Settings"' 'Accessibility fallback button is missing'
require_source_text 'Privacy_Accessibility' 'Accessibility settings URL is missing'
require_source_text 'if errorNumber is -1743 then' 'Automation denial handling is missing'
require_source_text 'display alert "Automation access is required"' 'Automation explanation is missing'
require_source_text 'button returned of permissionDialog is "Open Automation Settings"' 'Automation button handling is missing'
require_source_text 'Privacy_Automation' 'Automation settings URL is missing'
reject_source_regex 'entire contents' 'recursive Accessibility scan returned'
reject_source_regex 'on[[:space:]]+showRow' 'unconditional row scrolling returned'
reject_source_regex 'set value of permissionScrollBar|set value of scroll bar' 'programmed Local Network scrolling returned'
reject_source_regex 'click[[:space:]]+toggleElement' 'scrolling checkbox click action returned'
reject_source_regex 'delay[[:space:]]+[12]([.][0-9]+)?([[:space:]]|$)' 'multi-second fixed delay returned'
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

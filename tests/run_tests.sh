#!/bin/zsh

set -euo pipefail

repo_dir=${0:A:h:h}
mode=${1:-unit}
test_output=$(mktemp -d /tmp/toggle-local-network-tests.XXXXXX)
trap '/bin/rm -rf -- "$test_output"' EXIT

if /usr/bin/grep -R -E -q \
	'NSAppleScript|NSAppleEventDescriptor|Privacy_Automation|System Events' \
	"$repo_dir/Sources" "$repo_dir/App/Info.plist"; then
	print -u2 -- "native sources contain an AppleScript or Automation dependency"
	exit 1
fi

# Unit, chaos and environment tests against a simulated System Settings.
# CHAOS_SEEDS raises the number of randomised chaos runs (default 500).
swift test --package-path "$repo_dir"
"$repo_dir/scripts/build_app.sh" "$test_output"
/usr/bin/plutil -lint "$test_output/Toggle Local Network.app/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$test_output/Toggle Local Network.app"
/usr/bin/lipo "$test_output/Toggle Local Network.app/Contents/MacOS/Toggle Local Network" \
	-verify_arch arm64 x86_64

if [[ "$mode" == "unit" ]]; then
	print -- "All unit and build tests passed."
	exit 0
fi

if [[ "$mode" != "integration" ]]; then
	print -u2 -- "usage: tests/run_tests.sh [unit|integration]"
	exit 1
fi

if [[ "${RUN_UI_TESTS:-0}" != "1" ]]; then
	print -u2 -- "integration tests control System Settings; run them explicitly with RUN_UI_TESTS=1"
	exit 1
fi

# The live suite runs inside the app bundle so it uses the app's own
# Accessibility permission. Sign with the same certificate as the approved
# copy (CODE_SIGN_IDENTITY) so macOS recognises it.
live_dir="$repo_dir/.build/live-test"
"$repo_dir/scripts/build_app.sh" "$live_dir"
report="$test_output/self-test.txt"
/usr/bin/open -W -n "$live_dir/Toggle Local Network.app" --args \
	--self-test --report "$report" --stress "${STRESS_ITERATIONS:-10}" \
	${SELF_TEST_ONLY:+--only "$SELF_TEST_ONLY"}
/bin/cat "$report"
/usr/bin/grep -q '^self-test: ALL PASSED$' "$report"

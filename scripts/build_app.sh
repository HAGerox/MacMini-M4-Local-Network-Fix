#!/bin/zsh

set -euo pipefail

repo_dir=${0:A:h:h}
output_dir=${1:-"$repo_dir/Release"}
app_path="$output_dir/Toggle Local Network.app"
zip_path="$output_dir/Toggle Local Network.zip"
contents_path="$app_path/Contents"
# Use a real certificate (e.g. "Apple Development: …") so Accessibility
# approval survives rebuilds. "-" signs ad hoc.
signing_identity=${CODE_SIGN_IDENTITY:--}

swift build --package-path "$repo_dir" -c release --arch arm64 --arch x86_64
binary_dir=$(swift build --package-path "$repo_dir" -c release --arch arm64 --arch x86_64 --show-bin-path)

/bin/rm -rf -- "$app_path"
/bin/mkdir -p -- "$contents_path/MacOS"
/bin/cp -- "$repo_dir/App/Info.plist" "$contents_path/Info.plist"
/bin/mkdir -p -- "$contents_path/Resources"
/bin/cp -- "$repo_dir/App/AppIcon.icns" "$contents_path/Resources/AppIcon.icns"
/bin/cp -- "$binary_dir/ToggleLocalNetwork" "$contents_path/MacOS/Toggle Local Network"
/usr/bin/codesign --force --options runtime --timestamp=none --sign "$signing_identity" "$app_path"
/bin/rm -f -- "$zip_path"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app_path" "$zip_path"

print -- "Built $app_path"
print -- "Built $zip_path"

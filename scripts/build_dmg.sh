#!/bin/zsh
# Builds the app and packages it as a DMG for testers.

set -euo pipefail

repo_dir=${0:A:h:h}
output_dir=${1:-"$repo_dir/Release"}
signing_identity=${CODE_SIGN_IDENTITY:--}
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$repo_dir/App/Info.plist")
label=${DMG_LABEL:-$version}
volume_name="Toggle Local Network $label"
dmg_path="$output_dir/Toggle Local Network $label.dmg"

"$repo_dir/scripts/build_app.sh" "$output_dir"

staging=$(/usr/bin/mktemp -d /tmp/toggle-local-network-dmg.XXXXXX)
trap '/bin/rm -rf -- "$staging"' EXIT
/usr/bin/ditto "$output_dir/Toggle Local Network.app" "$staging/Toggle Local Network.app"
/bin/ln -s /Applications "$staging/Applications"
/bin/cp "$repo_dir/App/Read Me First.txt" "$staging/Read Me First.txt"

/bin/rm -f -- "$dmg_path"
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -imagekey zlib-level=9 \
	-volname "$volume_name" -srcfolder "$staging" "$dmg_path"
/usr/bin/codesign --force --timestamp=none --sign "$signing_identity" "$dmg_path"
/usr/bin/hdiutil verify -quiet "$dmg_path"

print -- "Built $dmg_path"

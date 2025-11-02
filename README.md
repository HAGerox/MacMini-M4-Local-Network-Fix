load
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.toggle_local_network.plist

unload
launchctl bootout gui/$(id -u)/com.user.toggle_local_network
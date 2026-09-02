on run arguments
	if (count of arguments) is not 1 then error "Expected the compiled script path"
	set scriptUnderTest to load script POSIX file (item 1 of arguments)
	
	scriptUnderTest's closeSystemSettings()
	scriptUnderTest's openLocalNetworkPage()
	-- resetEnabledPermissions verifies 0 after the off-click and 1 after the
	-- on-click for every identifier it returns. Any failed transition throws.
	set resetIdentifiers to scriptUnderTest's resetEnabledPermissions()
	scriptUnderTest's closeSystemSettings()
	return "integration_toggle_roundtrip: PASS (" & (count of resetIdentifiers) & " enabled toggles verified off and back on)"
end run

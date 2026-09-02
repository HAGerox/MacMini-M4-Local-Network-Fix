on run arguments
	if (count of arguments) is not 1 then error "Expected the compiled script path"
	set scriptUnderTest to load script POSIX file (item 1 of arguments)
	try
		set testStartedAt to current date
		scriptUnderTest's closeSystemSettings()
		set navigationStartedAt to current date
		scriptUnderTest's openLocalNetworkPage()
		set togglingStartedAt to current date
		set scrollBeforeReset to scriptUnderTest's permissionScrollValue()
		set resetRows to scriptUnderTest's resetEnabledPermissions()
		set scrollAfterReset to scriptUnderTest's permissionScrollValue()
		if scrollAfterReset is not scrollBeforeReset then error "Reset changed the Local Network scroll position from " & scrollBeforeReset & " to " & scrollAfterReset
		set verificationStartedAt to current date
		repeat with rowIndexReference in resetRows
			set rowIndex to contents of rowIndexReference
			if scriptUnderTest's readableToggleValue(rowIndex) is not 1 then error "Local Network row " & rowIndex & " was not restored"
		end repeat
		scriptUnderTest's closeSystemSettings()
		set testFinishedAt to current date
		return "integration_toggle_roundtrip: PASS (" & (count of resetRows) & " enabled toggles; scroll unchanged at " & scrollAfterReset & "; navigation " & (togglingStartedAt - navigationStartedAt) & "s, toggling " & (verificationStartedAt - togglingStartedAt) & "s, total " & (testFinishedAt - testStartedAt) & "s)"
	on error errorMessage number errorNumber
		try
			scriptUnderTest's closeSystemSettings()
		end try
		error errorMessage number errorNumber
	end try
end run

on run arguments
	if (count of arguments) is not 1 then error "Expected the compiled script path"
	set scriptUnderTest to load script POSIX file (item 1 of arguments)
	try
		scriptUnderTest's closeSystemSettings()
		scriptUnderTest's openLocalNetworkPage()
		set resetIdentifiers to scriptUnderTest's resetEnabledPermissions()
		set finalToggles to scriptUnderTest's localNetworkToggles()
		set finalStates to {}
		repeat with toggleReference in finalToggles
			set toggleElement to contents of toggleReference
			tell application "System Events"
				try
					set toggleID to value of attribute "AXIdentifier" of toggleElement as text
					set end of finalStates to {toggleID, value of toggleElement}
				end try
			end tell
		end repeat
		repeat with resetIDReference in resetIdentifiers
			set resetID to contents of resetIDReference
			set restored to false
			repeat with stateReference in finalStates
				set toggleState to contents of stateReference
				if item 1 of toggleState is resetID then set restored to item 2 of toggleState is 1
			end repeat
			if not restored then error resetID & " was not restored"
		end repeat
		scriptUnderTest's closeSystemSettings()
		return "integration_toggle_roundtrip: PASS (" & (count of resetIdentifiers) & " enabled toggles verified off and back on)"
	on error errorMessage number errorNumber
		try
			scriptUnderTest's closeSystemSettings()
		end try
		error errorMessage number errorNumber
	end try
end run

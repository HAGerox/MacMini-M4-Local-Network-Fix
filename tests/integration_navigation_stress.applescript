on assertTrue(conditionValue, failureMessage)
	if conditionValue is not true then error failureMessage
end assertTrue

on run arguments
	if (count of arguments) < 1 then error "Expected the compiled script path"
	set scriptUnderTest to load script POSIX file (item 1 of arguments)
	if (count of arguments) is greater than 1 then
		set iterationCount to item 2 of arguments as integer
	else
		set iterationCount to 8
	end if
	
	try
		repeat with iterationNumber from 1 to iterationCount
			scriptUnderTest's closeSystemSettings()
			scriptUnderTest's openLocalNetworkPage()
			tell application "System Events" to tell process "System Settings" to set pageIsOpen to exists first window whose name is "Local Network"
			my assertTrue(pageIsOpen, "Iteration " & iterationNumber & " did not reach Local Network")
			set ignoredToggleSnapshot to scriptUnderTest's localNetworkToggles()
			scriptUnderTest's closeSystemSettings()
			tell application "System Events" to set settingsStillRunning to exists process "System Settings"
			my assertTrue(not settingsStillRunning, "Iteration " & iterationNumber & " left System Settings running")
		end repeat
		return "integration_navigation_stress: PASS (" & iterationCount & " bounded launch/navigation/quit cycles)"
	on error errorMessage number errorNumber
		try
			scriptUnderTest's closeSystemSettings()
		end try
		error errorMessage number errorNumber
	end try
end run

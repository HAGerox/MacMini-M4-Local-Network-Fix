on assertTrue(conditionValue, failureMessage)
	if conditionValue is not true then error failureMessage
end assertTrue

on run arguments
	if (count of arguments) is not 1 then error "Expected the compiled script path"
	set scriptUnderTest to load script POSIX file (item 1 of arguments)
	
	try
		scriptUnderTest's closeSystemSettings()
		do shell script "/usr/bin/open " & quoted form of scriptUnderTest's privacyURL
		tell application "System Settings" to activate
		set deadline to (current date) + scriptUnderTest's timeoutSeconds
		repeat
			set navigatorResult to scriptUnderTest's findLocalNetworkNavigator()
			if item 1 of navigatorResult is not missing value then exit repeat
			if (current date) is greater than or equal to deadline then error "Privacy & Security did not load"
			delay 0.1
		end repeat
		
		-- This deliberately retains the kind of reference used by the old script.
		tell application "System Events"
			tell process "System Settings"
				set staleWindow to window 1
			end tell
		end tell
		
		tell application "System Events" to click item 1 of navigatorResult
		set deadline to (current date) + scriptUnderTest's timeoutSeconds
		repeat
			tell application "System Events" to tell process "System Settings" to set pageIsOpen to exists first window whose name is "Local Network"
			if pageIsOpen then exit repeat
			if (current date) is greater than or equal to deadline then error "Did not reach Local Network"
			delay 0.1
		end repeat
		
		set reproducedOldFailure to false
		try
			tell application "System Events" to set ignoredName to name of staleWindow
		on error errorMessage number errorNumber
			if errorNumber is -1728 and errorMessage contains "Privacy & Security" then set reproducedOldFailure to true
		end try
		my assertTrue(reproducedOldFailure, "The stale-window control did not reproduce error -1728")
		
		-- The new code must still work because it reacquires the renamed window tree.
		set toggles to scriptUnderTest's localNetworkToggles()
		
		scriptUnderTest's closeSystemSettings()
		return "integration_stale_window: PASS (old -1728 reproduced; fresh lookup succeeded; " & (count of toggles) & " toggles found)"
	on error errorMessage number errorNumber
		try
			scriptUnderTest's closeSystemSettings()
		end try
		error errorMessage number errorNumber
	end try
end run

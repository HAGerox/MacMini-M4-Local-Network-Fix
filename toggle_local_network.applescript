-- Reset enabled Local Network permissions on macOS Sequoia.
-- System Settings replaces its Accessibility window during navigation, so no
-- reference to the Privacy & Security window is used after the navigation click.

property settingsProcess : "System Settings"
property privacyURL : "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
property localNetworkID : "Local Network_Navigator"
property timeoutSeconds : 15

on axIdentifier(uiElement)
	tell application "System Events"
		try
			return value of attribute "AXIdentifier" of uiElement as text
		on error
			return missing value
		end try
	end tell
end axIdentifier

on findByAXIdentifier(rootElement, wantedIdentifier)
	tell application "System Events"
		try
			set candidates to entire contents of rootElement
		on error
			return missing value
		end try
	end tell
	repeat with candidateReference in candidates
		set candidateElement to contents of candidateReference
		if my axIdentifier(candidateElement) is wantedIdentifier then return candidateElement
	end repeat
	return missing value
end findByAXIdentifier

-- Also return the identifiers seen, so a future macOS change produces a useful
-- error instead of falling back to a dangerous positional button number.
on findLocalNetworkNavigator()
	set broaderMatch to missing value
	set navigatorIDs to ""
	tell application "System Events"
		try
			tell process settingsProcess to set candidates to entire contents of window 1
		on error
			return {missing value, "(none)"}
		end try
	end tell
	repeat with candidateReference in candidates
		set candidateElement to contents of candidateReference
		set candidateID to my axIdentifier(candidateElement)
		if candidateID is not missing value and candidateID ends with "_Navigator" then
			if navigatorIDs is "" then
				set navigatorIDs to candidateID
			else
				set navigatorIDs to navigatorIDs & ", " & candidateID
			end if
			if candidateID is localNetworkID then return {candidateElement, navigatorIDs}
			if candidateID contains "Local Network" then set broaderMatch to candidateElement
		end if
	end repeat
	if navigatorIDs is "" then set navigatorIDs to "(none)"
	return {broaderMatch, navigatorIDs}
end findLocalNetworkNavigator

on closeSystemSettings()
	tell application "System Settings" to set wasRunning to it is running
	if not wasRunning then return
	tell application "System Settings" to quit
	set deadline to (current date) + timeoutSeconds
	repeat
		tell application "System Events" to set stillRunning to exists process settingsProcess
		if not stillRunning then exit repeat
		if (current date) is greater than or equal to deadline then error "System Settings did not finish quitting."
		delay 0.1
	end repeat
	-- Its settings extension can finish exiting just after the process disappears.
	delay 2
end closeSystemSettings

on openLocalNetworkPage()
	do shell script "/usr/bin/open " & quoted form of privacyURL
	tell application "System Settings" to activate
	set deadline to (current date) + timeoutSeconds
	repeat
		set navigatorResult to my findLocalNetworkNavigator()
		set localNetworkButton to item 1 of navigatorResult
		if localNetworkButton is not missing value then exit repeat
		if (current date) is greater than or equal to deadline then ¬
			error "Local Network navigation control not found. Available *_Navigator identifiers: " & item 2 of navigatorResult
		delay 0.1
	end repeat
	tell application "System Events" to click localNetworkButton

	-- Reacquire window 1 on every check; the pre-click window reference is stale.
	set deadline to (current date) + timeoutSeconds
	repeat
		tell application "System Events"
			try
				tell process settingsProcess to set pageIsOpen to name of window 1 is "Local Network"
			on error
				set pageIsOpen to false
			end try
		end tell
		if pageIsOpen then exit repeat
		if (current date) is greater than or equal to deadline then error "System Settings did not reach the Local Network page."
		delay 0.1
	end repeat
	delay 0.3
end openLocalNetworkPage

on localNetworkToggles()
	set toggles to {}
	tell application "System Events"
		tell process settingsProcess to set candidates to entire contents of first window whose name is "Local Network"
	end tell
	repeat with candidateReference in candidates
		set candidateElement to contents of candidateReference
		set candidateID to my axIdentifier(candidateElement)
		if candidateID is not missing value and candidateID ends with "_Toggle" then set end of toggles to candidateElement
	end repeat
	return toggles
end localNetworkToggles

-- Read through the existing UI object when possible, and reacquire it by its
-- identifier only if System Settings has invalidated that object.
on readToggle(toggleID, toggleElement)
	tell application "System Events"
		try
			return {toggleElement, value of toggleElement}
		end try
		tell process settingsProcess to set currentWindow to first window whose name is "Local Network"
	end tell
	set toggleElement to my findByAXIdentifier(currentWindow, toggleID)
	if toggleElement is missing value then return {missing value, missing value}
	tell application "System Events" to return {toggleElement, value of toggleElement}
end readToggle

on clickAndRead(toggleID, toggleElement)
	set toggleResult to my readToggle(toggleID, toggleElement)
	set toggleElement to item 1 of toggleResult
	if toggleElement is missing value then error "Could not find " & toggleID
	tell application "System Events" to click toggleElement
	delay 0.2
	return my readToggle(toggleID, toggleElement)
end clickAndRead

on resetEnabledPermissions()
	-- Record identifiers before clicking; a click may invalidate later UI objects.
	set enabledToggles to {}
	repeat with toggleReference in my localNetworkToggles()
		set toggleElement to contents of toggleReference
		set toggleID to my axIdentifier(toggleElement)
		if toggleID is not missing value then
			set toggleResult to my readToggle(toggleID, toggleElement)
			if item 2 of toggleResult is 1 then set end of enabledToggles to {toggleID, item 1 of toggleResult}
		end if
	end repeat

	set resetIDs to {}
	repeat with togglePair in enabledToggles
		set toggleID to item 1 of togglePair
		set toggleElement to item 2 of togglePair
		set toggleResult to my clickAndRead(toggleID, toggleElement)
		if item 2 of toggleResult is not 0 then error "Could not disable " & toggleID
		set toggleResult to my clickAndRead(toggleID, item 1 of toggleResult)
		if item 2 of toggleResult is 0 then
			-- A single safety restoration, only after observing a no-op on-click.
			set toggleResult to my clickAndRead(toggleID, item 1 of toggleResult)
		end if
		if item 2 of toggleResult is not 1 then error "Could not re-enable " & toggleID
		set end of resetIDs to toggleID
	end repeat
	return resetIDs
end resetEnabledPermissions

on run
	my closeSystemSettings()
	my openLocalNetworkPage()
	set resetIDs to my resetEnabledPermissions()
	my closeSystemSettings()
	return resetIDs
end run

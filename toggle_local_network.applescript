use framework "ApplicationServices"
use scripting additions

property settingsProcess : "System Settings"
property privacyURL : "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
property localNetworkID : "Local Network_Navigator"
property timeoutSeconds : 30
property settleSeconds : 0.05
property interStateSeconds : 0.15
property finalSettleSeconds : 0.3
property retrySeconds : 5

on localNetworkPageIsOpen()
	tell application "System Events"
		try
			tell process settingsProcess to return name of window 1 is "Local Network"
		on error errorMessage number errorNumber
			if errorNumber is -1719 or errorNumber is -1728 then return false
			error errorMessage number errorNumber
		end try
	end tell
end localNetworkPageIsOpen

on closeSystemSettings()
	tell application "System Settings" to set wasRunning to it is running
	if not wasRunning then return
	tell application "System Settings" to quit
	repeat with attempt from 1 to timeoutSeconds * 10
		tell application "System Events" to set stillRunning to exists process settingsProcess
		if not stillRunning then return
		delay 0.1
	end repeat
	error "System Settings did not finish quitting."
end closeSystemSettings

on openLocalNetworkPage()
	do shell script "/usr/bin/open " & quoted form of privacyURL
	tell application "System Settings" to activate

	repeat with attempt from 1 to timeoutSeconds * 10
		if my localNetworkPageIsOpen() then
			-- The title changes just before the permission rows finish rendering.
			delay 0.1
			return
		end if
		try
			tell application "System Events" to tell process settingsProcess
				-- Search only Privacy & Security's Security buttons instead of
				-- repeatedly walking the entire System Settings window.
				set securityButtons to buttons of group 4 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
				repeat with buttonReference in securityButtons
					set candidateButton to contents of buttonReference
					try
						if (value of attribute "AXIdentifier" of candidateButton as text) is localNetworkID then
							click candidateButton
							exit repeat
						end if
					end try
				end repeat
			end tell
		on error errorMessage number errorNumber
			if errorNumber is not -1719 and errorNumber is not -1728 then error errorMessage number errorNumber
		end try
		delay 0.1
	end repeat
	error "System Settings did not reach the Local Network page."
end openLocalNetworkPage

on localNetworkToggles()
	tell application "System Events" to tell process settingsProcess
		return checkboxes of UI element 1 of every row of outline 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
	end tell
end localNetworkToggles

on showRow(rowIndex)
	if rowIndex is less than or equal to 32 then
		set pageNumber to 0
	else
		set pageNumber to 1
	end if
	tell application "System Events" to tell process settingsProcess
		set value of scroll bar 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1 to pageNumber
	end tell
	delay 0.05
end showRow

on toggleValueAtRow(rowIndex)
	tell application "System Events" to tell process settingsProcess
		return value of checkbox 1 of UI element 1 of row rowIndex of outline 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
	end tell
end toggleValueAtRow

on reacquireToggle(rowIndex)
	my showRow(rowIndex)
	tell application "System Events" to tell process settingsProcess
		return checkbox 1 of UI element 1 of row rowIndex of outline 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
	end tell
end reacquireToggle

on readToggle(rowIndex, toggleElement)
	tell application "System Events"
		try
			return {toggleElement, value of toggleElement}
		end try
	end tell
	set toggleElement to my reacquireToggle(rowIndex)
	tell application "System Events" to return {toggleElement, value of toggleElement}
end readToggle

on readableToggleValue(rowIndex)
	my showRow(rowIndex)
	set deadline to (current date) + timeoutSeconds
	repeat
		try
			return my toggleValueAtRow(rowIndex)
		on error errorMessage number errorNumber
			if errorNumber is not -1719 and errorNumber is not -1728 then error errorMessage number errorNumber
		end try
		if (current date) is greater than or equal to deadline then error "System Settings did not expose Local Network row " & rowIndex & "."
		delay 0.05
	end repeat
end readableToggleValue

on pressToggleAndWait(rowIndex, toggleElement, wantedValue, confirmStable)
	tell application "System Events" to click toggleElement
	set deadline to (current date) + timeoutSeconds
	set nextRetry to (current date) + retrySeconds
	repeat
		try
			set toggleResult to my readToggle(rowIndex, toggleElement)
			set toggleElement to item 1 of toggleResult
			set currentValue to item 2 of toggleResult
			if currentValue is wantedValue then
				if not confirmStable then return toggleElement
				delay settleSeconds
				set confirmedResult to my readToggle(rowIndex, toggleElement)
				set toggleElement to item 1 of confirmedResult
				if item 2 of confirmedResult is wantedValue then return toggleElement
			else if (current date) is greater than or equal to nextRetry then
				tell application "System Events" to click toggleElement
				set nextRetry to (current date) + retrySeconds
			end if
		on error errorMessage number errorNumber
			if errorNumber is not -1719 and errorNumber is not -1728 then error errorMessage number errorNumber
		end try
		if (current date) is greater than or equal to deadline then error "System Settings did not finish changing Local Network row " & rowIndex & "."
		delay 0.05
	end repeat
end pressToggleAndWait

on changeToggleToValue(rowIndex, toggleElement, wantedValue)
	set toggleResult to my readToggle(rowIndex, toggleElement)
	set toggleElement to item 1 of toggleResult
	if item 2 of toggleResult is wantedValue then return toggleElement
	return my pressToggleAndWait(rowIndex, toggleElement, wantedValue, true)
end changeToggleToValue

on changeRowToValue(rowIndex, wantedValue)
	set toggleElement to my reacquireToggle(rowIndex)
	my changeToggleToValue(rowIndex, toggleElement, wantedValue)
end changeRowToValue

on ensureRowsHaveValue(rowIndexes, wantedValue)
	repeat with rowIndexReference in rowIndexes
		my changeRowToValue(contents of rowIndexReference, wantedValue)
	end repeat
end ensureRowsHaveValue

on resetEnabledPermissions()
	set enabledRows to {}
	set enabledToggles to {}
	set allToggles to my localNetworkToggles()
	try
		repeat with rowIndex from 1 to count of allToggles
			set toggleElement to contents of item rowIndex of allToggles
			set toggleResult to my readToggle(rowIndex, toggleElement)
			set toggleElement to item 1 of toggleResult
			if item 2 of toggleResult is 1 then
				set end of enabledRows to rowIndex
				set toggleElement to my pressToggleAndWait(rowIndex, toggleElement, 0, false)
				delay interStateSeconds
				tell application "System Events" to click toggleElement
				set end of enabledToggles to {rowIndex, toggleElement}
			end if
		end repeat
		delay finalSettleSeconds
		repeat with togglePairReference in enabledToggles
			set togglePair to contents of togglePairReference
			set rowIndex to item 1 of togglePair
			set toggleElement to item 2 of togglePair
			set toggleResult to my readToggle(rowIndex, toggleElement)
			if item 2 of toggleResult is not 1 then my changeToggleToValue(rowIndex, item 1 of toggleResult, 1)
		end repeat
	on error errorMessage number errorNumber
		-- A failure must not leave permissions disabled.
		try
			my ensureRowsHaveValue(enabledRows, 1)
		end try
		error errorMessage number errorNumber
	end try
	return enabledRows
end resetEnabledPermissions

on run
	if not (current application's AXIsProcessTrusted()) then
		set promptOptions to current application's NSDictionary's dictionaryWithObject:true forKey:(current application's kAXTrustedCheckOptionPrompt)
		current application's AXIsProcessTrustedWithOptions(promptOptions)
		if not (current application's AXIsProcessTrusted()) then
			set permissionDialog to display alert "Accessibility access is required" message "Allow this app to control System Settings. macOS may also ask for Automation access the first time it runs." buttons {"Cancel", "Open Accessibility Settings"} default button "Open Accessibility Settings" as critical
			if button returned of permissionDialog is "Open Accessibility Settings" then do shell script "/usr/bin/open 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility'"
		end if
		return
	end if
	my closeSystemSettings()
	try
		my openLocalNetworkPage()
		set resetIDs to my resetEnabledPermissions()
		my closeSystemSettings()
		return resetIDs
	on error errorMessage number errorNumber
		try
			my closeSystemSettings()
		end try
		error errorMessage number errorNumber
	end try
end run

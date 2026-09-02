use framework "ApplicationServices"
use scripting additions

property settingsProcess : "System Settings"
property privacyURL : "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
property accessibilityURL : "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
property automationURL : "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
property localNetworkID : "Local Network_Navigator"
property timeoutSeconds : 30
property settleSeconds : 0.05
property interStateSeconds : 0.15
property retrySeconds : 5
property accessibilityPromptKey : "AccessibilityNativePromptRequested"

on isTransientUIError(errorNumber)
	return errorNumber is -1719 or errorNumber is -1728 or errorNumber is -10000
end isTransientUIError

on localNetworkPageIsOpen()
	tell application "System Events"
		try
			tell process settingsProcess to return name of window 1 is "Local Network"
		on error errorMessage number errorNumber
			if my isTransientUIError(errorNumber) then return false
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
				if not my isTransientUIError(errorNumber) then error errorMessage number errorNumber
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

on permissionScrollValue()
	tell application "System Events" to tell process settingsProcess
		return value of scroll bar 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
	end tell
end permissionScrollValue

on directToggleAtRow(rowIndex)
	tell application "System Events" to tell process settingsProcess
		return checkbox 1 of UI element 1 of row rowIndex of outline 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
	end tell
end directToggleAtRow

on resolvedToggleAtRow(rowIndex)
	set toggleElement to my directToggleAtRow(rowIndex)
	-- Reading the value forces System Settings to resolve the row reference.
	tell application "System Events" to set ignoredValue to value of toggleElement
	return toggleElement
end resolvedToggleAtRow

on reacquireToggle(rowIndex)
	set deadline to (current date) + timeoutSeconds
	repeat
		try
			return my resolvedToggleAtRow(rowIndex)
		on error errorMessage number errorNumber
			if not my isTransientUIError(errorNumber) then error errorMessage number errorNumber
		end try
		if (current date) is greater than or equal to deadline then error "System Settings did not reveal Local Network row " & rowIndex & "."
		delay 0.05
	end repeat
end reacquireToggle

on toggleValueAtRow(rowIndex)
	set toggleElement to my reacquireToggle(rowIndex)
	tell application "System Events" to return value of toggleElement
end toggleValueAtRow

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
	set deadline to (current date) + timeoutSeconds
	repeat
		try
			return my toggleValueAtRow(rowIndex)
		on error errorMessage number errorNumber
			if not my isTransientUIError(errorNumber) then error errorMessage number errorNumber
		end try
		if (current date) is greater than or equal to deadline then error "System Settings did not expose Local Network row " & rowIndex & "."
		delay 0.05
	end repeat
end readableToggleValue

on pressToggleAndWait(rowIndex, toggleElement, wantedValue, confirmStable)
	try
		tell application "System Events" to perform action "AXPress" of toggleElement
	on error errorMessage number errorNumber
		if not my isTransientUIError(errorNumber) then error errorMessage number errorNumber
	end try
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
				tell application "System Events" to perform action "AXPress" of toggleElement
				set nextRetry to (current date) + retrySeconds
			end if
		on error errorMessage number errorNumber
			if not my isTransientUIError(errorNumber) then error errorMessage number errorNumber
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
				set toggleElement to my pressToggleAndWait(rowIndex, toggleElement, 1, true)
			end if
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

on showAutomationAccessHelp()
	set permissionDialog to display alert "Automation access is required" message "Open Automation settings. Under this app, enable System Events and System Settings if they are listed, then run the app again." buttons {"Cancel", "Open Automation Settings"} default button "Open Automation Settings" as critical
	if button returned of permissionDialog is "Open Automation Settings" then do shell script "/usr/bin/open " & quoted form of automationURL
end showAutomationAccessHelp

on showAccessibilityAccessHelp()
	set permissionDialog to display alert "Accessibility access is required" message "Enable this app in Privacy & Security > Accessibility, then run it again." buttons {"Cancel", "Open Accessibility Settings"} default button "Open Accessibility Settings" as critical
	if button returned of permissionDialog is "Open Accessibility Settings" then do shell script "/usr/bin/open " & quoted form of accessibilityURL
end showAccessibilityAccessHelp

on nativeAccessibilityPromptWasRequested()
	return (current application's NSUserDefaults's standardUserDefaults()'s boolForKey:(accessibilityPromptKey)) as boolean
end nativeAccessibilityPromptWasRequested

on rememberNativeAccessibilityPrompt()
	current application's NSUserDefaults's standardUserDefaults()'s setBool:true forKey:(accessibilityPromptKey)
	current application's NSUserDefaults's standardUserDefaults()'s synchronize()
end rememberNativeAccessibilityPrompt

on clearNativeAccessibilityPromptMemory()
	current application's NSUserDefaults's standardUserDefaults()'s removeObjectForKey:(accessibilityPromptKey)
	current application's NSUserDefaults's standardUserDefaults()'s synchronize()
end clearNativeAccessibilityPromptMemory

on run
	if not (current application's AXIsProcessTrusted()) then
		if my nativeAccessibilityPromptWasRequested() then
			my showAccessibilityAccessHelp()
			return
		end if
		set promptOptions to current application's NSDictionary's dictionaryWithObject:true forKey:(current application's kAXTrustedCheckOptionPrompt)
		current application's AXIsProcessTrustedWithOptions(promptOptions)
		my rememberNativeAccessibilityPrompt()
		return
	end if
	my clearNativeAccessibilityPromptMemory()
	try
		my closeSystemSettings()
		my openLocalNetworkPage()
		set resetIDs to my resetEnabledPermissions()
		my closeSystemSettings()
		return resetIDs
	on error errorMessage number errorNumber
		try
			my closeSystemSettings()
		end try
		if errorNumber is -1743 then
			my showAutomationAccessHelp()
			return
		end if
		error errorMessage number errorNumber
	end try
end run

use framework "ApplicationServices"
use scripting additions

property settingsProcess : "System Settings"
property privacyURL : "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
property localNetworkID : "Local Network_Navigator"
property timeoutSeconds : 15

on findLocalNetworkButton()
	set fallbackButton to missing value
	tell application "System Events" to tell process settingsProcess to set candidates to entire contents of window 1
	repeat with candidateReference in candidates
		set candidateElement to contents of candidateReference
		tell application "System Events"
			try
				set candidateID to value of attribute "AXIdentifier" of candidateElement as text
			on error
				set candidateID to ""
			end try
		end tell
		if candidateID is localNetworkID then return candidateElement
		if candidateID contains "Local Network" and candidateID ends with "_Navigator" then set fallbackButton to candidateElement
	end repeat
	return fallbackButton
end findLocalNetworkButton

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
	set localNetworkButton to missing value

	repeat with attempt from 1 to timeoutSeconds * 10
		if my localNetworkPageIsOpen() then return
		try
			set localNetworkButton to my findLocalNetworkButton()
		on error errorMessage number errorNumber
			if errorNumber is not -1719 and errorNumber is not -1728 then error errorMessage number errorNumber
		end try
		if localNetworkButton is not missing value then exit repeat
		delay 0.1
	end repeat
	if localNetworkButton is missing value then error "Local Network navigation control not found."

	tell application "System Events" to click localNetworkButton
	repeat with attempt from 1 to timeoutSeconds * 10
		if my localNetworkPageIsOpen() then return
		delay 0.1
	end repeat
	error "System Settings did not reach the Local Network page."
end openLocalNetworkPage

on localNetworkToggles()
	set toggles to {}
	tell application "System Events" to tell process settingsProcess to set candidates to entire contents of window 1
	repeat with candidateReference in candidates
		set candidateElement to contents of candidateReference
		tell application "System Events"
			try
				set candidateID to value of attribute "AXIdentifier" of candidateElement as text
			on error
				set candidateID to ""
			end try
		end tell
		if candidateID ends with "_Toggle" then set end of toggles to candidateElement
	end repeat
	return toggles
end localNetworkToggles

on resetEnabledPermissions()
	set resetIDs to {}
	repeat with toggleReference in my localNetworkToggles()
		set toggleElement to contents of toggleReference
		tell application "System Events"
			try
				set toggleID to value of attribute "AXIdentifier" of toggleElement as text
				set isEnabled to value of toggleElement is 1
			on error
				set isEnabled to false
			end try
			if isEnabled then
				click toggleElement
				delay 0.3
				if value of toggleElement is not 0 then error "Could not disable " & toggleID
				click toggleElement
				delay 2
				if value of toggleElement is 0 then
					click toggleElement
					delay 2
				end if
				if value of toggleElement is not 1 then error "Could not re-enable " & toggleID
				set end of resetIDs to toggleID
			end if
		end tell
	end repeat
	return resetIDs
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
	my openLocalNetworkPage()
	set resetIDs to my resetEnabledPermissions()
	my closeSystemSettings()
	return resetIDs
end run

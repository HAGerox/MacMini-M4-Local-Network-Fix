-- Close System Settings if it's already open
tell application "System Settings"
	if it is running then
		quit
		delay 0.1
	end if
end tell

-- Open System Settings to Privacy & Security
do shell script "open 'x-apple.systempreferences:com.apple.preference.security'"

tell application "System Settings"
	activate
end tell

delay 0.1

tell application "System Events"
	tell process "System Settings"
		repeat until exists window 1
			delay 0.1
		end repeat
		
		-- Navigate to Local Network
		set splitterGroup to splitter group 1 of group 1 of window 1
		click button 9 of group 4 of scroll area 1 of group 1 of group 2 of splitterGroup
		
		-- Get checkboxes from the main group
		set mainGroup to group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
		
		-- Toggle all apps that are currently enabled (value 1)
		set allElements to entire contents of mainGroup
		repeat with elem in allElements
			try
				if class of elem is checkbox then
					if value of elem is 1 then
						click elem
						delay 0.2
						click elem
					end if
				end if
			end try
		end repeat
	end tell
end tell

delay 0.2
tell application "System Settings" to quit

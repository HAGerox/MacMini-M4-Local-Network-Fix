on assertTrue(conditionValue, failureMessage)
	if conditionValue is not true then error failureMessage
end assertTrue

on run arguments
	if (count of arguments) is not 1 then error "Expected the compiled script path"
	set scriptUnderTest to load script POSIX file (item 1 of arguments)
	
	my assertTrue(scriptUnderTest's localNetworkID is "Local Network_Navigator", "Unexpected navigator identifier")
	my assertTrue(scriptUnderTest's accessibilityURL ends with "?Privacy_Accessibility", "Unexpected Accessibility settings URL")
	my assertTrue(scriptUnderTest's automationURL ends with "?Privacy_Automation", "Unexpected Automation settings URL")
	my assertTrue(scriptUnderTest's timeoutSeconds is 30, "Unexpected timeout")
	my assertTrue(scriptUnderTest's settleSeconds is 0.05, "Unexpected stable-state interval")
	my assertTrue(scriptUnderTest's interStateSeconds is 0.15, "Unexpected off-state settling interval")
	my assertTrue(scriptUnderTest's retrySeconds is 5, "Unexpected retry interval")
	my assertTrue(scriptUnderTest's accessibilityPromptKey is "AccessibilityNativePromptRequested", "Unexpected Accessibility prompt state key")
	
	return "unit_helpers: PASS"
end run

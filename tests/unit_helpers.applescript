on assertTrue(conditionValue, failureMessage)
	if conditionValue is not true then error failureMessage
end assertTrue

on run arguments
	if (count of arguments) is not 1 then error "Expected the compiled script path"
	set scriptUnderTest to load script POSIX file (item 1 of arguments)
	
	my assertTrue(scriptUnderTest's localNetworkID is "Local Network_Navigator", "Unexpected navigator identifier")
	my assertTrue(scriptUnderTest's timeoutSeconds is 15, "Unexpected timeout")
	
	return "unit_helpers: PASS"
end run

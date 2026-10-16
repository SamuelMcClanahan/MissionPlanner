-- Setup progress window for Mission Planner (Wine bundle).
-- The launcher writes "PERCENT|TEXT" to ~/Library/MissionPlannerWine/state/progress
-- and "done" when setup is finished. Built into "Setup Progress.app" with osacompile;
-- in a script app, the progress properties show as a window with a progress bar.
on run
	set f to (POSIX path of (path to home folder)) & "Library/MissionPlannerWine/state/progress"
	set progress total steps to 100
	set progress completed steps to 0
	set progress description to "Setting up Mission Planner"
	set progress additional description to "Starting"
	repeat
		set t to ""
		try
			set t to do shell script "cat " & quoted form of f
		end try
		if t is "done" then exit repeat
		if t contains "|" then
			set oldDelims to AppleScript's text item delimiters
			set AppleScript's text item delimiters to "|"
			try
				set progress completed steps to (text item 1 of t) as integer
				set progress additional description to (text item 2 of t)
			end try
			set AppleScript's text item delimiters to oldDelims
		end if
		delay 1
	end repeat
end run

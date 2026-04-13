set itemDelimiter to (character id 31)

tell application id "com.apple.Music"
	if not running then
		return "stopped" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "0" & itemDelimiter & "0"
	end if

	if player state is playing then
		set playerState to "playing"
	else if player state is paused then
		set playerState to "paused"
	else
		set playerState to "stopped"
	end if

	if playerState is "stopped" then
		return playerState & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "0" & itemDelimiter & "0"
	end if

	set trackName to ""
	set artistName to ""
	set albumName to ""
	set trackDuration to 0
	set playheadPosition to 0

	try
		set trackName to (name of current track)
		set artistName to (artist of current track)
		set albumName to (album of current track)
		set trackDuration to (duration of current track)
	end try

	try
		set playheadPosition to (player position)
	end try

	return playerState & itemDelimiter & trackName & itemDelimiter & artistName & itemDelimiter & albumName & itemDelimiter & (playheadPosition as string) & itemDelimiter & (trackDuration as string)
end tell

on run argv
    set targetID to item 1 of argv
    tell application id "com.googlecode.iterm2"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aSession in sessions of aTab
                    if (unique ID of aSession as text) is targetID then
                        select aTab
                        select aSession
                        set index of aWindow to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end repeat
        error "Terminal session is missing"
    end tell
end run

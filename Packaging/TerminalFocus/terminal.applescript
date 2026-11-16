on run argv
    set targetTTY to item 1 of argv
    tell application id "com.apple.Terminal"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                if (tty of aTab as text) is targetTTY then
                    set selected tab of aWindow to aTab
                    set index of aWindow to 1
                    activate
                    return
                end if
            end repeat
        end repeat
        error "Terminal tab is missing"
    end tell
end run

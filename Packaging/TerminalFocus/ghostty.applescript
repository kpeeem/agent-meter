on run argv
    set targetPath to item 1 of argv
    tell application id "com.mitchellh.ghostty"
        set matches to {}
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aSurface in terminals of aTab
                    if (working directory of aSurface as text) is targetPath then
                        set end of matches to contents of aSurface
                    end if
                end repeat
            end repeat
        end repeat
        if (count of matches) is not 1 then error "Terminal surface is ambiguous or missing"
        focus (item 1 of matches)
    end tell
end run

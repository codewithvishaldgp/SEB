#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
#ClipboardTimeout 2000

; Keep the resident helper alive between typing sessions.
Persistent(true)

; Keyboard Typer - AutoHotkey v2
; Version 5: keep the script resident; Ctrl+M remains available after typing.
; Also hide the GUI instead of exiting when its Close button is clicked.
; Modes: character-by-character or one-shot clipboard paste.
; Ctrl+M = show/hide GUI (ignored during typing). F2 = emergency stop. F3 = pause/resume.

InstallKeybdHook()

TypingActive := false
IsPaused := false
IsTypingStarted := false
CountdownRemaining := 0
PendingText := ""
CharacterIndex := 1
TypingInterval := 20
TypingMode := 1                 ; 1 = character-by-character, 2 = clipboard paste
TargetWindowHwnd := 0
TargetWindowName := ""
TargetWindowHandles := []
UseCurrentForegroundWindow := false
IsClipboardPasteCommitted := false
ClipboardOperationInProgress := false
BeginTypingInProgress := false

MainGui := Gui("", "Keyboard Typer")
MainGui.SetFont("s10", "Segoe UI")
MainGui.AddText("x20 y16 w720 h22", "Paste text below. Formatting is applied when you start typing:")
LineCountText := MainGui.AddText("x760 y16 w120 h22 Right", "Lines: 1")

TextInput := MainGui.AddEdit(
    "x20 y42 w860 h255 Multi WantTab VScroll",
    "Hello! This text will be typed automatically, one character at a time."
)

MainGui.AddText("x20 y310 w280 h22", "Formatting mode:")
FormatChoice := MainGui.AddDropDownList(
    "x20 y334 w280 Choose2",
    ["Remove indentation only", "Remove indentation + add blank lines"]
)

MainGui.AddText("x320 y310 w220 h22", "Typing method:")
TypingMethodChoice := MainGui.AddDropDownList(
    "x320 y334 w220 Choose1",
    ["Character-by-character", "Clipboard paste (Ctrl+V)"]
)

MainGui.AddText("x560 y310 w150 h22", "Typing interval:")
SpeedChoice := MainGui.AddDropDownList(
    "x560 y334 w150 Choose2",
    ["10 ms", "20 ms", "30 ms", "50 ms"]
)

MainGui.AddText("x730 y310 w150 h22", "Start countdown:")
DelayChoice := MainGui.AddDropDownList(
    "x730 y334 w150 Choose1",
    ["1 second", "3 seconds", "5 seconds", "10 seconds", "15 seconds", "30 seconds"]
)

MainGui.AddText("x20 y382 w700 h22", "Target window (select the application that should receive the text):")
TargetWindowChoice := MainGui.AddDropDownList(
    "x20 y406 w720 Choose1",
    ["Select a target window..."]
)
RefreshWindowsButton := MainGui.AddButton("x755 y404 w125 h28", "Refresh list")

StartButton := MainGui.AddButton("x20 y457 w145 h38 Default", "Start typing")
PauseButton := MainGui.AddButton("x175 y457 w145 h38 Disabled", "Pause")
StopButton := MainGui.AddButton("x330 y457 w145 h38 Disabled", "Stop typing")

StatusText := MainGui.AddText(
    "x20 y507 w860 h42",
    "Ready. Enter text, choose a typing method and target window, then click Start typing."
)
MainGui.AddText(
    "x20 y558 w860 h58",
    "Select a target window, or leave it unselected to use the window that is active when the countdown ends. "
    . "Place the caret in the desired text field. Ctrl+M = show/hide this GUI; F2 = emergency stop; F3 = pause/resume. "
    . "Clipboard mode pastes the complete normalized text in one Ctrl+V operation. "
    . "Closing this window hides it; use the AutoHotkey tray icon to exit the script."
)

StartButton.OnEvent("Click", StartTyping)
PauseButton.OnEvent("Click", TogglePause)
StopButton.OnEvent("Click", StopTyping)
RefreshWindowsButton.OnEvent("Click", RefreshTargetWindows)
TextInput.OnEvent("Change", UpdateLineCount)
TypingMethodChoice.OnEvent("Change", UpdateTypingModeControls)
MainGui.OnEvent("Close", HandleGuiClose)

; Register Ctrl+M unconditionally. The callback itself ignores the shortcut
; during typing, avoiding focus changes while still working after completion.
Hotkey("^m", ToggleMainGui, "On P100")

; F2/F3 are active only while a countdown or typing operation is in progress.
HotIf(IsTypingActive)
Hotkey("F2", EmergencyStop, "On P100")
Hotkey("F3", TogglePause, "On P100")
HotIf()

RefreshTargetWindows()
UpdateTypingModeControls()
; Start hidden so Ctrl+M can summon the GUI over any application.

HandleGuiClose(guiObj, *) {
    ; Clicking the GUI X button hides it; it must not terminate the script.
    guiObj.Hide()
    return true
}

ToggleMainGui(*) {
    global MainGui, TypingActive
    ; Do not show the GUI while text is being sent, because it would steal focus.
    if (TypingActive)
        return
    try {
        if (WinExist("ahk_id " MainGui.Hwnd) && DllCall("IsWindowVisible", "ptr", MainGui.Hwnd, "int"))
            MainGui.Hide()
        else
            MainGui.Show("w900 h630")
    }
}

StartTyping(*) {
    global TypingActive, IsPaused, IsTypingStarted, CountdownRemaining
    global PendingText, TypingInterval, TypingMode, TargetWindowHwnd, TargetWindowName
    global TextInput, FormatChoice, TypingMethodChoice, SpeedChoice, DelayChoice
    global TargetWindowChoice, TargetWindowHandles, UseCurrentForegroundWindow
    global StartButton, PauseButton, StopButton, StatusText
    global IsClipboardPasteCommitted, ClipboardOperationInProgress, BeginTypingInProgress
    global RefreshWindowsButton

    if (TypingActive)
        return

    ; Do not begin another operation while an interrupted clipboard/activation thread
    ; is still completing its cleanup.
    if (ClipboardOperationInProgress || BeginTypingInProgress) {
        StatusText.Text := "The previous operation is still finishing. Please try again in a moment."
        return
    }

    selectedIndex := TargetWindowChoice.Value
    UseCurrentForegroundWindow := (selectedIndex <= 1)
    if (UseCurrentForegroundWindow) {
        ; With no explicit target, capture the foreground application after the
        ; countdown, allowing the user to leave the caret wherever they want.
        TargetWindowHwnd := 0
        TargetWindowName := "current foreground window"
    } else {
        if (selectedIndex > TargetWindowHandles.Length + 1) {
            StatusText.Text := "The selected target is invalid. Click Refresh list and select it again."
            return
        }
        TargetWindowHwnd := TargetWindowHandles[selectedIndex - 1]
        TargetWindowName := TargetWindowChoice.Text
        if (!WinExist("ahk_id " TargetWindowHwnd)) {
            StatusText.Text := "The selected window no longer exists. Click Refresh list and select it again."
            return
        }
    }

    ; Keep the existing default formatting behavior: remove indentation and add blank lines.
    PendingText := NormalizeText(TextInput.Value, FormatChoice.Value = 2)
    if (PendingText = "") {
        StatusText.Text := "Please paste or type some non-empty text first."
        return
    }

    ; Show the exact normalized text that will be sent.
    TextInput.Value := PendingText
    UpdateLineCount()

    TypingMode := TypingMethodChoice.Value
    if (TypingMode = 1)
        TypingInterval := Integer(RegExReplace(SpeedChoice.Text, "\D"))

    CountdownRemaining := Integer(RegExReplace(DelayChoice.Text, "\D"))
    IsPaused := false
    IsTypingStarted := false
    IsClipboardPasteCommitted := false
    TypingActive := true

    TextInput.Enabled := false
    FormatChoice.Enabled := false
    TypingMethodChoice.Enabled := false
    SpeedChoice.Enabled := (TypingMode = 1)
    DelayChoice.Enabled := false
    TargetWindowChoice.Enabled := false
    RefreshWindowsButton.Enabled := false
    StartButton.Enabled := false
    PauseButton.Enabled := true
    PauseButton.Text := "Pause"
    StopButton.Enabled := true

    methodName := (TypingMode = 1) ? "character-by-character" : "clipboard paste"
    StatusText.Text := "Starting " methodName " for " TargetWindowName ". Typing in " CountdownRemaining " second(s)..."
    SetTimer(CountdownTick, 1000)
}

NormalizeText(rawText, addExtraBlankLines) {
    ; Normalize line endings and trim spaces/tabs around each source line.
    ; Mode 1 preserves the original line breaks without adding new blank lines.
    ; Mode 2 preserves existing blank lines and adds one extra blank line after
    ; every non-empty source line (the behavior of the previous version).
    rawText := StrReplace(rawText, "`r`n", "`n")
    rawText := StrReplace(rawText, "`r", "`n")

    lines := StrSplit(rawText, "`n")
    normalized := ""

    if (!addExtraBlankLines) {
        ; Rejoin with exactly the original number of line breaks.
        for index, line in lines {
            if (index > 1)
                normalized .= "`n"
            normalized .= Trim(line, " `t")
        }
        return normalized
    }

    ; Retain the existing extra-line formatting behavior.
    for line in lines {
        line := Trim(line, " `t")
        normalized .= line "`n"
        if (line != "")
            normalized .= "`n"
    }
    return normalized
}

UpdateLineCount(*) {
    global TextInput, LineCountText
    text := TextInput.Value
    ; Count displayed lines, including a final empty line after a trailing newline.
    lineCount := 1
    Loop Parse, text
        if (A_LoopField = "`n")
            lineCount += 1
    LineCountText.Text := "Lines: " lineCount
}

UpdateTypingModeControls(*) {
    global TypingMethodChoice, SpeedChoice
    SpeedChoice.Enabled := (TypingMethodChoice.Value = 1)
}

RefreshTargetWindows(*) {
    global TargetWindowChoice, TargetWindowHandles, MainGui, StatusText

    handles := []
    labels := ["Select a target window..."]

    for hwnd in WinGetList() {
        if (hwnd = MainGui.Hwnd)
            continue
        if (!DllCall("IsWindowVisible", "ptr", hwnd, "int"))
            continue

        try {
            title := Trim(WinGetTitle("ahk_id " hwnd))
            processName := WinGetProcessName("ahk_id " hwnd)
        } catch {
            continue
        }

        if (title = "")
            continue
        if (processName = "")
            processName := "Unknown process"

        handles.Push(hwnd)
        labels.Push(title " — " processName " (" Format("0x{:X}", hwnd) ")")
    }

    TargetWindowChoice.Delete()
    TargetWindowChoice.Add(labels)
    TargetWindowChoice.Choose(1)
    TargetWindowHandles := handles

    if (handles.Length = 0)
        StatusText.Text := "No eligible application windows were found. Open the target application and refresh the list."
    else
        StatusText.Text := "Window list refreshed. Select the application that should receive the text."
}

CountdownTick() {
    global TypingActive, IsPaused, CountdownRemaining, StatusText

    if (!TypingActive) {
        SetTimer(CountdownTick, 0)
        return
    }

    ; The repeating timer remains active while paused, but the countdown does not advance.
    if (IsPaused)
        return

    CountdownRemaining -= 1
    if (CountdownRemaining > 0) {
        StatusText.Text := "Typing in " CountdownRemaining " second(s)... Switch to the target app and place the caret."
        return
    }

    SetTimer(CountdownTick, 0)
    StatusText.Text := "Countdown complete. Activating the selected target window..."
    SetTimer(BeginTyping, -1)
}

BeginTyping() {
    global TypingActive, IsPaused, IsTypingStarted, TypingMode
    global CharacterIndex, StatusText, BeginTypingInProgress, TargetWindowName

    if (!TypingActive || IsPaused || BeginTypingInProgress)
        return

    BeginTypingInProgress := true
    try {
        activated := ActivateTargetWindow()

        ; F2 or F3 may have interrupted the activation wait.
        if (!TypingActive || IsPaused)
            return

        if (!activated) {
            FinishTyping("Could not activate the selected target window. Refresh the list and try again.")
            return
        }

        ; Make the transition from countdown/activation to typing atomic with
        ; respect to F2/F3, so a shortcut cannot start a duplicate activation.
        Critical("On")
        try {
            if (!TypingActive || IsPaused)
                return
            IsTypingStarted := true
        } finally {
            Critical("Off")
        }

        if (!TypingActive || !IsTypingStarted)
            return

        if (TypingMode = 2) {
            StatusText.Text := "Pasting the complete text into " TargetWindowName "..."
            SetTimer(PasteWholeText, -1)
        } else {
            CharacterIndex := 1
            StatusText.Text := "Typing into " TargetWindowName ". Press F2 to stop or F3 to pause."
            SetTimer(TypeNextCharacter, -1)
        }
    } finally {
        BeginTypingInProgress := false
    }
}

ActivateTargetWindow() {
    global TargetWindowHwnd, TargetWindowName, UseCurrentForegroundWindow, MainGui

    try {
        if (UseCurrentForegroundWindow) {
            ; Capture the foreground window only once, at countdown completion.
            ; Later checks must confirm that same window still has focus.
            if (!TargetWindowHwnd) {
                hwnd := WinGetID("A")
                if (!hwnd || hwnd = MainGui.Hwnd)
                    return false
                TargetWindowHwnd := hwnd
                TargetWindowName := WinGetTitle("ahk_id " hwnd)
                if (TargetWindowName = "")
                    TargetWindowName := "current foreground window"
                return true ; Keep the foreground window and its current caret.
            }
            return (WinExist("ahk_id " TargetWindowHwnd)
                && WinActive("ahk_id " TargetWindowHwnd) = TargetWindowHwnd)
        }

        if (!TargetWindowHwnd || !WinExist("ahk_id " TargetWindowHwnd))
            return false
        WinActivate("ahk_id " TargetWindowHwnd)
        return (WinWaitActive("ahk_id " TargetWindowHwnd, , 2) = TargetWindowHwnd)
    } catch {
        return false
    }
}

WaitWhilePaused() {
    global TypingActive, IsPaused

    while (TypingActive && IsPaused)
        Sleep(50)

    return TypingActive
}

TypeNextCharacter() {
    global TypingActive, IsPaused, PendingText, CharacterIndex, TypingInterval
    global TargetWindowHwnd, StatusText

    if (!TypingActive || IsPaused)
        return

    ; Never send text to whichever window happens to have focus. Stop if the
    ; selected target lost focus while character-by-character typing is running.
    if (WinActive("ahk_id " TargetWindowHwnd) != TargetWindowHwnd) {
        StopTyping()
        StatusText.Text := "Stopped because the target window lost focus. Select it again and restart."
        return
    }

    textLength := StrLen(PendingText)
    if (CharacterIndex > textLength) {
        FinishTyping("Completed. All normalized text has been sent to the selected window.")
        return
    }

    char := SubStr(PendingText, CharacterIndex, 1)

    if (char = "`r") {
        if (SubStr(PendingText, CharacterIndex + 1, 1) = "`n")
            CharacterIndex += 1
        Send("{Enter}")
    } else if (char = "`n") {
        Send("{Enter}")
    } else if (char = "`t") {
        Send("{Tab}")
    } else if (char = "`b") {
        Send("{Backspace}")
    } else {
        SendText(char)
    }

    CharacterIndex += 1
    if (TypingActive && !IsPaused)
        SetTimer(TypeNextCharacter, -TypingInterval)
}

PasteWholeText() {
    global TypingActive, PendingText, IsPaused, IsClipboardPasteCommitted
    global ClipboardOperationInProgress, StatusText, TargetWindowName, TargetWindowHwnd

    if (!TypingActive)
        return

    ClipboardOperationInProgress := true
    savedClipboard := ""
    clipboardCaptured := false
    clipboardPrepared := false
    pasteError := ""

    try {
        ; Preserve all clipboard formats, not just the previous plain text.
        savedClipboard := ClipboardAll()
        clipboardCaptured := true

        if (!WaitWhilePaused())
            return

        ; Mark this before assignment so the original clipboard is restored even
        ; if Windows rejects the temporary clipboard write.
        clipboardPrepared := true
        A_Clipboard := PendingText
        if (!ClipWait(2))
            throw Error("Windows did not make the text available on the clipboard.")

        ; Re-check pause state immediately before committing the paste. If F3
        ; arrives in the small gap before Critical is entered, loop and wait
        ; for Resume rather than silently abandoning the clipboard operation.
        loop {
            if (!WaitWhilePaused())
                return
            if (!ActivateTargetWindow())
                throw Error("The selected target window could not be activated.")
            if (!WaitWhilePaused())
                return

            retryAfterPause := false
            Critical("On")
            try {
                if (!TypingActive)
                    return
                if (IsPaused) {
                    retryAfterPause := true
                } else {
                    if (WinActive("ahk_id " TargetWindowHwnd) != TargetWindowHwnd)
                        throw Error("The selected target window lost focus before Ctrl+V could be sent.")

                    IsClipboardPasteCommitted := true
                    Send("^v")
                }
            } finally {
                Critical("Off")
            }

            if (!retryAfterPause)
                break
        }

        ; Give the destination application time to read the clipboard before
        ; restoring the user's previous clipboard contents.
        Sleep(500)
    } catch as err {
        pasteError := err.Message
    } finally {
        if (clipboardCaptured && clipboardPrepared) {
            try {
                A_Clipboard := savedClipboard
            } catch as restoreErr {
                if (pasteError = "")
                    pasteError := "The paste was sent, but the original clipboard could not be restored: " restoreErr.Message
            }
        }
        savedClipboard := ""
        ClipboardOperationInProgress := false
    }

    ; F2 may have stopped the operation while the clipboard restore delay was running.
    if (!TypingActive)
        return

    IsClipboardPasteCommitted := false
    if (pasteError != "")
        FinishTyping("Clipboard paste failed: " pasteError)
    else
        FinishTyping("Completed. The complete normalized text was pasted into " TargetWindowName ".")
}

TogglePause(*) {
    global TypingActive, IsPaused, IsTypingStarted, CountdownRemaining
    global TypingMode, IsClipboardPasteCommitted, BeginTypingInProgress
    global PauseButton, StatusText

    if (!TypingActive)
        return

    ; The whole-text paste is atomic. Once Ctrl+V has been issued, it cannot be
    ; paused halfway through, so do not falsely toggle the pause state.
    if (IsTypingStarted && TypingMode = 2 && IsClipboardPasteCommitted) {
        StatusText.Text := "The clipboard paste has already been sent; it cannot be paused mid-paste."
        return
    }

    if (!IsPaused) {
        IsPaused := true
        if (IsTypingStarted && TypingMode = 1)
            SetTimer(TypeNextCharacter, 0)

        PauseButton.Text := "Resume"
        if (IsTypingStarted)
            StatusText.Text := "Paused. Press F3 or click Resume to continue, or F2/Stop to cancel."
        else if (CountdownRemaining > 0)
            StatusText.Text := "Countdown paused with " CountdownRemaining " second(s) remaining. Press F3 to resume."
        else
            StatusText.Text := "Paused before typing. Press F3 to activate the target and continue."
        return
    }

    IsPaused := false
    PauseButton.Text := "Pause"

    if (IsTypingStarted) {
        ; Character mode needs its target reactivated before the next character.
        ; Clipboard mode performs activation in PasteWholeText after leaving its pause wait.
        if (TypingMode = 1) {
            if (!ActivateTargetWindow()) {
                if (TypingActive) {
                    StopTyping()
                    StatusText.Text := "Stopped: the selected target window could not be reactivated."
                }
                return
            }
            if (!TypingActive)
                return
            StatusText.Text := "Resumed. Press F2 to stop or F3 to pause again."
            SetTimer(TypeNextCharacter, -1)
        } else {
            StatusText.Text := "Resuming clipboard paste..."
        }
    } else if (CountdownRemaining > 0) {
        StatusText.Text := "Countdown resumed: typing in " CountdownRemaining " second(s)..."
    } else {
        StatusText.Text := "Resuming: activating the selected target window..."
        if (!BeginTypingInProgress)
            SetTimer(BeginTyping, -1)
    }
}

IsTypingActive(*) {
    global TypingActive
    return TypingActive
}

EmergencyStop(*) {
    global TypingActive, StatusText

    ; Do nothing unless the countdown or typing process is active.
    if (!TypingActive)
        return

    StopTyping()
    StatusText.Text := "Stopped by F2. The destination may contain partially typed text."
}

StopTyping(*) {
    global TypingActive, IsPaused, IsTypingStarted, StatusText
    global IsClipboardPasteCommitted

    if (!TypingActive) {
        StatusText.Text := "Nothing is currently typing. Ready."
        return
    }

    TypingActive := false
    IsPaused := false
    IsTypingStarted := false
    IsClipboardPasteCommitted := false
    SetTimer(CountdownTick, 0)
    SetTimer(BeginTyping, 0)
    SetTimer(TypeNextCharacter, 0)
    SetTimer(PasteWholeText, 0)
    ResetControls()
    StatusText.Text := "Stopped. The destination may contain partially typed text."
}

FinishTyping(message) {
    global TypingActive, IsPaused, IsTypingStarted, IsClipboardPasteCommitted
    global StatusText

    TypingActive := false
    IsPaused := false
    IsTypingStarted := false
    IsClipboardPasteCommitted := false
    SetTimer(CountdownTick, 0)
    SetTimer(BeginTyping, 0)
    SetTimer(TypeNextCharacter, 0)
    SetTimer(PasteWholeText, 0)
    ResetControls()
    StatusText.Text := message
}

ResetControls() {
    global TextInput, FormatChoice, TypingMethodChoice, SpeedChoice, DelayChoice
    global TargetWindowChoice, RefreshWindowsButton
    global StartButton, PauseButton, StopButton

    TextInput.Enabled := true
    FormatChoice.Enabled := true
    TypingMethodChoice.Enabled := true
    DelayChoice.Enabled := true
    TargetWindowChoice.Enabled := true
    RefreshWindowsButton.Enabled := true
    StartButton.Enabled := true
    PauseButton.Enabled := false
    PauseButton.Text := "Pause"
    StopButton.Enabled := false
    UpdateTypingModeControls()
}

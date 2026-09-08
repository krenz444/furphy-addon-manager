' Furphy Addon Manager launcher.
' Starts the local server hidden (if it is not already running), then opens
' the native WebView2 host window (host\bin\FurphyHost.exe) when it has been
' built, falling back to an Edge app window otherwise.
'
' Round 37 (fast launch, SPEC.md): this used to poll /api/ping for up to 15s
' after spawning the server before opening any window at all, so a slow
' first-time catalogue/snapshot fetch on a fresh install could blow past
' that budget and leave the player looking at nothing but a "server did not
' start" box. The server's own startup contract now guarantees /api/ping
' answers within 2s of the process starting on every kind of start (fresh,
' stale cache, warm), and host\bin\FurphyHost.exe waits out that short gap
' itself, showing "Starting Furphy Addon Manager..." - so this launcher's
' only job is to get the server running (if it is not already) and open a
' window right away, with no polling loop of its own.
Option Explicit
Dim sh, fso, root, port, url, http, running, text, re, matches
Dim serverScript, hostExe, edge

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)

' Port from settings.json (default 47831)
port = 47831
If fso.FileExists(root & "\settings.json") Then
    text = fso.OpenTextFile(root & "\settings.json", 1).ReadAll
    Set re = New RegExp
    re.Pattern = """port""\s*:\s*(\d+)"
    Set matches = re.Execute(text)
    If matches.Count > 0 Then port = CLng(matches(0).SubMatches(0))
End If
url = "http://localhost:" & port & "/"

serverScript = root & "\addon-server.ps1"
hostExe = root & "\host\bin\FurphyHost.exe"
edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

If Not fso.FileExists(serverScript) Then
    MsgBox "Furphy Addon Manager cannot find addon-server.ps1 in " & root & _
        ". Reinstall the app to fix this.", vbCritical, "Furphy Addon Manager"
    WScript.Quit 1
End If

' Single 800ms probe - just enough to skip spawning a second server when one
' is already answering (e.g. the tray already started it, or a previous
' window is still open). No retry loop: whether this probe hits or misses,
' the window opened below is what waits out the server's own startup gap.
running = Ping(url & "api/ping")
If Not running Then
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & serverScript & """", 0, False
End If

' E19: prefer the native WebView2 host (Furphy + CurseForge tabs in one
' window) when it has been built - it shows its own "Starting..." state and
' waits for the server itself, so it is launched immediately, win or lose
' on the probe above. Fall back to the plain Edge app window when the host
' has not been built (e.g. a machine without the C# host compiled); Edge
' has no such wait built in, but by the time a real install reaches this
' launcher the server is normally the older-established, already-running
' background piece, not the thing this script just spawned. If neither
' exists there is nothing left to show the app in.
'
' failure-modes:webview2-missing-no-fallback: the hostExe launch below
' waits for the process to exit (waitOnReturn=True) specifically so this
' script CAN observe host\FurphyHost.cs's own ExitCode=3 (set by
' HandleRuntimeMissing when the WebView2 Runtime is missing/broken on this
' PC) and fall back to the same Edge --app window used when the host build
' itself is missing - restoring the fallback ROADMAP.md always documented.
' Waiting here does not delay the window the player sees: the WebView2
' host still creates and shows its window immediately on a normal launch
' (it has its own "Starting..." wait built in, per the Round 37 comment
' above), so it is only this invisible wscript.exe process that blocks
' until the app closes, not anything on screen.
Dim exitCode
If fso.FileExists(hostExe) Then
    exitCode = sh.Run("""" & hostExe & """ --port " & port, 1, True)
    If exitCode = 3 Then
        If fso.FileExists(edge) Then
            sh.Run """" & edge & """ --app=" & url & " --window-size=1320,900", 1, False
        End If
        ' else: no Edge to fall back to either - the plain-language
        ' MessageBox HandleRuntimeMissing already showed before exiting is
        ' the player's only signal in that case, same as before this fix.
    End If
    ' Any other exit code (0 on a normal close, or an unexpected value) is
    ' already-handled/no-op - the host either closed normally or however
    ' it failed, it is not the one specific case (3) this fallback exists
    ' for, so nothing more to do here.
ElseIf fso.FileExists(edge) Then
    sh.Run """" & edge & """ --app=" & url & " --window-size=1320,900", 1, False
Else
    MsgBox "Furphy Addon Manager cannot find its window (host\bin\FurphyHost.exe) " & _
        "or a supported browser to show it in. Reinstall the app to fix this.", _
        vbCritical, "Furphy Addon Manager"
    WScript.Quit 1
End If

Function Ping(target)
    Ping = False
    On Error Resume Next
    Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    http.SetTimeouts 800, 800, 800, 800
    http.Open "GET", target, False
    http.Send
    If Err.Number = 0 Then
        If http.Status = 200 Then Ping = True
    End If
    Err.Clear
    On Error GoTo 0
End Function

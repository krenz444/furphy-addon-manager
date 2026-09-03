' Furphy Addon Manager launcher.
' Starts the local server hidden (if it is not already running) and opens the UI as an Edge app window.
Option Explicit
Dim sh, fso, root, port, url, http, running, i, text, re, matches, edge

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

running = Ping(url & "api/ping")
If Not running Then
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\addon-server.ps1""", 0, False
    For i = 1 To 30
        WScript.Sleep 500
        If Ping(url & "api/ping") Then
            running = True
            Exit For
        End If
    Next
End If

If Not running Then
    MsgBox "The Addon Manager server did not start. Check " & root & "\server.log", vbExclamation, "Furphy Addon Manager"
    WScript.Quit 1
End If

edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
If fso.FileExists(edge) Then
    sh.Run """" & edge & """ --app=" & url & " --window-size=1320,900", 1, False
Else
    sh.Run url, 1, False
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

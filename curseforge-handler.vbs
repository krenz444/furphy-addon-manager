' Furphy Addon Manager - curseforge:// install link handler.
' Usage: wscript curseforge-handler.vbs "curseforge://install?addonId=2382&fileId=8797977" [port]
' Parses the addon (project) id and optional file id, makes sure the local server is running,
' asks it to install (or install that specific version if the addon is already managed), then
' brings the Furphy window to the front. Everything it receives is logged to handler.log.
Option Explicit
Dim sh, fso, root, url, port, re, projectId, fileId, http, body, status, logf, matches, settingsText
Dim stateText, isTracked

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)

If WScript.Arguments.Count < 1 Then
    MsgBox "This script is launched by CurseForge install links; nothing to do.", vbInformation, "Furphy Addon Manager"
    WScript.Quit 0
End If
url = WScript.Arguments(0)

' Port: optional second argument, else settings.json, else 47831.
port = 47831
If WScript.Arguments.Count >= 2 Then
    port = CLng(WScript.Arguments(1))
ElseIf fso.FileExists(root & "\settings.json") Then
    settingsText = fso.OpenTextFile(root & "\settings.json", 1).ReadAll
    Set re = New RegExp
    re.Pattern = """port""\s*:\s*(\d+)"
    Set matches = re.Execute(settingsText)
    If matches.Count > 0 Then port = CLng(matches(0).SubMatches(0))
End If

Log "received: " & url

' Parse ids (case-insensitive, any order): addonId|projectId, fileId
projectId = ExtractParam(url, "(?:addonId|projectId)")
fileId = ExtractParam(url, "fileId")
If projectId = "" Then
    Log "no addon id in url"
    MsgBox "This CurseForge link did not contain an addon id." & vbCrLf & url, vbExclamation, "Furphy Addon Manager"
    WScript.Quit 1
End If

If Not EnsureServer() Then
    MsgBox "Furphy's local server did not start. Check " & root & "\server.log", vbExclamation, "Furphy Addon Manager"
    WScript.Quit 1
End If

' Already managed? Then install the requested version (if any) instead of adding twice.
stateText = HttpGet("http://localhost:" & port & "/api/state")
Set re = New RegExp
re.Pattern = """projectId""\s*:\s*" & projectId & "\b"
isTracked = re.Test(stateText)

If isTracked And fileId = "" Then
    Log "already tracked, no fileId - nothing to do"
    MsgBox "That addon is already managed by Furphy.", vbInformation, "Furphy Addon Manager"
    BringToFront
    WScript.Quit 0
End If

If isTracked Then
    body = "{""kind"":""install"",""projectId"":" & projectId & ",""fileId"":" & fileId & "}"
ElseIf fileId <> "" Then
    body = "{""kind"":""add"",""projectId"":" & projectId & ",""fileId"":" & fileId & "}"
Else
    body = "{""kind"":""add"",""projectId"":" & projectId & "}"
End If
status = HttpPost("http://localhost:" & port & "/api/jobs", body)
Log "POST /api/jobs " & body & " -> " & status
If status = 409 Then
    MsgBox "Furphy is busy with another task. Try the install link again in a moment.", vbInformation, "Furphy Addon Manager"
ElseIf status < 200 Or status >= 300 Then
    MsgBox "Furphy could not start the install (HTTP " & status & "). See handler.log.", vbExclamation, "Furphy Addon Manager"
End If
BringToFront
WScript.Quit 0

' ---------------------------------------------------------------- helpers
Function ExtractParam(s, namePattern)
    Dim r, mm
    Set r = New RegExp
    r.IgnoreCase = True
    r.Pattern = "[?&]" & namePattern & "=(\d+)"
    Set mm = r.Execute(s)
    If mm.Count > 0 Then
        ExtractParam = mm(0).SubMatches(0)
    Else
        ExtractParam = ""
    End If
End Function

Function Ping()
    Ping = (HttpGet("http://localhost:" & port & "/api/ping") <> "")
End Function

Function EnsureServer()
    Dim i
    If Ping() Then
        EnsureServer = True
        Exit Function
    End If
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\addon-server.ps1""", 0, False
    For i = 1 To 30
        WScript.Sleep 500
        If Ping() Then
            EnsureServer = True
            Exit Function
        End If
    Next
    EnsureServer = False
End Function

Function HttpGet(target)
    On Error Resume Next
    Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    http.SetTimeouts 1500, 1500, 4000, 4000
    http.Open "GET", target, False
    http.Send
    If Err.Number = 0 And http.Status = 200 Then
        HttpGet = http.ResponseText
    Else
        HttpGet = ""
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function HttpPost(target, payload)
    On Error Resume Next
    Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    http.SetTimeouts 2000, 2000, 8000, 8000
    http.Open "POST", target, False
    http.SetRequestHeader "Content-Type", "application/json"
    http.Send payload
    If Err.Number = 0 Then
        HttpPost = http.Status
    Else
        HttpPost = 0
    End If
    Err.Clear
    On Error GoTo 0
End Function

Sub BringToFront()
    Dim edge
    If Not sh.AppActivate("Furphy Addon Manager") Then
        edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
        If fso.FileExists(edge) Then
            sh.Run """" & edge & """ --app=http://localhost:" & port & "/ --window-size=1320,900", 1, False
        Else
            sh.Run "http://localhost:" & port & "/", 1, False
        End If
    End If
End Sub

Sub Log(msg)
    On Error Resume Next
    Set logf = fso.OpenTextFile(root & "\handler.log", 8, True)
    logf.WriteLine Now & "  " & msg
    logf.Close
    On Error GoTo 0
End Sub

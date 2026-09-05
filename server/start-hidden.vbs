' Launches run-server.cmd with no visible console window and returns immediately,
' so the scheduled task action finishes while the server keeps running.
Option Explicit
Dim sh, fso, here, target
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here   = fso.GetParentFolderName(WScript.ScriptFullName)
target = here & "\run-server.cmd"
If Not fso.FileExists(target) Then
  WScript.Quit 1
End If
sh.Run """" & target & """", 0, False
WScript.Quit 0

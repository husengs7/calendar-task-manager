Set WshShell = CreateObject("WScript.Shell")
userProfile = WshShell.ExpandEnvironmentStrings("%USERPROFILE%")
cmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & userProfile & "\.taskmanager\task.ps1"" sync 90"
WshShell.Run cmd, 0, False

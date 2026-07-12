' workers/run_hidden.vbs - uruchamia command line z pliku BEZ okna konsoli.
' wscript.exe to host GUI-subsystem: proces potomny (powershell/cmd/curl)
' dostaje okno ukryte OD RAZU (style 0 w STARTUPINFO) - zero blysku, w
' przeciwienstwie do "-WindowStyle Hidden", ktore chowa konsole dopiero
' po jej utworzeniu (user-caught kaskada na VM 2026-07-12).
'
' Command line czytany z PLIKU (arg 1), nie z argumentow - zero problemow
' z re-quotowaniem JSON-ow i sciezek ze spacjami. Plik kasowany po odczycie.
'
' Spawn: wscript.exe //B //Nologo run_hidden.vbs <cmdfile>

Dim fso, sh, f, cmd, p
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
p = WScript.Arguments(0)
Set f = fso.OpenTextFile(p, 1)
cmd = f.ReadAll
f.Close
On Error Resume Next
fso.DeleteFile p
On Error GoTo 0
sh.Run cmd, 0, False

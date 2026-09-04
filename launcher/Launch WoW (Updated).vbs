' Silently updates addons via Furphy Addon Manager, then launches WoW retail.
' Window style 0 = fully hidden, no console flash, no focus steal.
Set sh = CreateObject("WScript.Shell")
sh.Run "cmd /c ""C:\Program Files (x86)\World of Warcraft\_retail_\update-addons-and-launch.cmd""", 0, False

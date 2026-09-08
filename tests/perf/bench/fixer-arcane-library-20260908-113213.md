# Perf sample: fixer-arcane-library

Fixer repro/verify pass, theme=arcane-library, no WoW, window open+focused on My Addons.

Scope: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-theme-arcane-library-20260908-113051-361e72 [ScopeRoot parameter]
Window: 2026-09-08 11:31:13 -> 2026-09-08 11:32:13 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-theme-arcane-library-20260908-113051-361e72\server.log): 9

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 43932 | FurphyHost.exe | 30 | 0.109 | 56.15 | 55.97 | 0 | 0 | 0 |
| server | 15836 | powershell.exe | 30 | 0.938 | 144.61 | 125.24 | 0.09 | 0 | 0 |
| webview2-child | 1200 | msedgewebview2.exe | 30 | 0 | 47.07 | 20.8 | 0 | 0.03 | 0 |
| webview2-child | 15632 | msedgewebview2.exe | 30 | 0.031 | 88.65 | 49.4 | 0.18 | 0.01 | 0 |
| webview2-child | 32880 | msedgewebview2.exe | 30 | 0 | 18.86 | 9.32 | 0 | 0 | 0 |
| webview2-child | 38028 | msedgewebview2.exe | 30 | 0.078 | 39.75 | 24 | 0.02 | 0.03 | 0 |
| webview2-child | 43416 | msedgewebview2.exe | 30 | 0.266 | 36.11 | 21.39 | 0.04 | 0.26 | 0 |
| webview2-child | 43848 | msedgewebview2.exe | 30 | 0.672 | 118.08 | 67.03 | 0.22 | 0.12 | 0 |
| **TOTAL** | | | | **2.094** | | | **0.56** | **0.45** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\fixer-arcane-library-20260908-113213.json

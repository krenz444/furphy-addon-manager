# Perf sample: D2-window-my-addons-fake-wow-steadystate

State D re-run (P2 after), WoW started BEFORE the server so gameRunning is true from the servers very first cache read - avoids the 30s startup-cache race the initial run hit.

Window: 2026-09-05 08:07:40 -> 2026-09-05 08:08:40 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-080023-b3de27\server.log): 1

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 34836 | FurphyHost.exe | 30 | 0 | 46.29 | 44.54 | 0 | 0 | 0 |
| server | 25868 | powershell.exe | 30 | 0.578 | 308.62 | 299.68 | 0.22 | 0 | 0 |
| webview2-child | 10848 | msedgewebview2.exe | 30 | 0.016 | 92 | 90.49 | 0 | 0.03 | 0 |
| webview2-child | 25828 | msedgewebview2.exe | 30 | 0.109 | 78.1 | 77.1 | 0 | 0.07 | 0 |
| webview2-child | 31400 | msedgewebview2.exe | 30 | 0 | 49.05 | 48.8 | 0 | 0.06 | 0 |
| webview2-child | 36900 | msedgewebview2.exe | 30 | 0 | 42.9 | 42.55 | 0.02 | 0.03 | 0 |
| webview2-child | 38192 | msedgewebview2.exe | 30 | 0 | 23.94 | 23.82 | 0 | 0.01 | 0 |
| webview2-child | 40640 | msedgewebview2.exe | 30 | 0 | 22.24 | 18.33 | 0 | 0 | 0 |
| webview2-child | 40660 | msedgewebview2.exe | 30 | 0.094 | 123.38 | 121.88 | 0.21 | 0.13 | 0 |
| **TOTAL** | | | | **0.797** | | | **0.45** | **0.33** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\D2-window-my-addons-fake-wow-steadystate-20260905-080840.json

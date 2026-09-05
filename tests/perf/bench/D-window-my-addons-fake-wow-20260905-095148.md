# Perf sample: D-window-my-addons-fake-wow

State D: native host window open on My Addons, FAKE Wow.exe running. The SPA polls /api/state on its fixed interval while the window is open, regardless of WoW.

Window: 2026-09-05 09:50:48 -> 2026-09-05 09:51:48 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-094749-2e7c6a\server.log): 5

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 39464 | FurphyHost.exe | 30 | 0 | 47.12 | 44.75 | 0 | 0 | 0 |
| server | 51804 | powershell.exe | 30 | 1.188 | 215.05 | 214.28 | 1.08 | 0 | 0 |
| webview2-child | 10100 | msedgewebview2.exe | 30 | 0.047 | 123.1 | 120.96 | 0.1 | 0.13 | 0 |
| webview2-child | 29484 | msedgewebview2.exe | 30 | 0.016 | 88.18 | 86.76 | 0.01 | 0.05 | 0 |
| webview2-child | 32684 | msedgewebview2.exe | 30 | 0 | 22.23 | 18.31 | 0 | 0 | 0 |
| webview2-child | 43968 | msedgewebview2.exe | 30 | 0 | 44.07 | 43.81 | 0.02 | 0.02 | 0 |
| webview2-child | 47832 | msedgewebview2.exe | 30 | 0.031 | 104.49 | 101.16 | 0.01 | 0 | 0 |
| webview2-child | 47920 | msedgewebview2.exe | 30 | 0.062 | 53.66 | 51.13 | 0 | 0.03 | 0 |
| webview2-child | 51340 | msedgewebview2.exe | 30 | 0 | 23.19 | 23.17 | 0 | 0 | 0 |
| **TOTAL** | | | | **1.344** | | | **1.21** | **0.24** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\D-window-my-addons-fake-wow-20260905-095148.json

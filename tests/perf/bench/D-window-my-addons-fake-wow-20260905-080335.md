# Perf sample: D-window-my-addons-fake-wow

State D: native host window open on My Addons, FAKE Wow.exe running. The SPA polls /api/state on its fixed interval while the window is open, regardless of WoW.

Window: 2026-09-05 08:02:35 -> 2026-09-05 08:03:35 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-080023-b3de27\server.log): 5

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 48908 | FurphyHost.exe | 30 | 0 | 46.37 | 44.68 | 0 | 0 | 0 |
| server | 51616 | powershell.exe | 30 | 1.156 | 215.61 | 214.77 | 1.07 | 0 | 0 |
| webview2-child | 21820 | msedgewebview2.exe | 30 | 0.031 | 122.91 | 121.05 | 0.09 | 0.12 | 0 |
| webview2-child | 27092 | msedgewebview2.exe | 30 | 0 | 44.02 | 43.77 | 0.02 | 0.02 | 0 |
| webview2-child | 30788 | msedgewebview2.exe | 30 | 0 | 23.23 | 23.2 | 0 | 0 | 0 |
| webview2-child | 31952 | msedgewebview2.exe | 30 | 0.031 | 85.55 | 84.2 | 0.01 | 0.05 | 0 |
| webview2-child | 32108 | msedgewebview2.exe | 30 | 0.016 | 103.9 | 100.99 | 0.01 | 0 | 0 |
| webview2-child | 40600 | msedgewebview2.exe | 30 | 0 | 22.23 | 18.32 | 0 | 0 | 0 |
| webview2-child | 46488 | msedgewebview2.exe | 30 | 0 | 48.96 | 48.21 | 0 | 0.03 | 0 |
| **TOTAL** | | | | **1.234** | | | **1.2** | **0.23** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\D-window-my-addons-fake-wow-20260905-080335.json

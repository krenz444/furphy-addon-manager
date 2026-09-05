# Perf sample: D-window-my-addons-fake-wow

State D: native host window open on My Addons, FAKE Wow.exe running. The SPA polls /api/state on its fixed interval while the window is open, regardless of WoW.

Window: 2026-09-05 07:00:25 -> 2026-09-05 07:01:25 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-064557-626de2\server.log): 12

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 28308 | FurphyHost.exe | 30 | 0.016 | 41.15 | 41.12 | 0 | 0 | 0 |
| server | 38208 | powershell.exe | 30 | 1.219 | 214.94 | 214.41 | 2.41 | 0 | 0 |
| webview2-child | 31040 | msedgewebview2.exe | 30 | 0.016 | 102.91 | 99.44 | 0.01 | 0 | 0 |
| webview2-child | 31740 | msedgewebview2.exe | 30 | 0.016 | 22.23 | 18.32 | 0 | 0 | 0 |
| webview2-child | 44120 | msedgewebview2.exe | 30 | 0.031 | 42.59 | 42.33 | 0.02 | 0.04 | 0 |
| webview2-child | 45748 | msedgewebview2.exe | 30 | 0 | 49.02 | 48.29 | 0 | 0.03 | 0 |
| webview2-child | 47264 | msedgewebview2.exe | 30 | 0.109 | 124.78 | 122.73 | 0.11 | 0.14 | 0 |
| webview2-child | 48548 | msedgewebview2.exe | 30 | 0 | 23.23 | 23.2 | 0 | 0 | 0 |
| webview2-child | 49268 | msedgewebview2.exe | 30 | 0.141 | 84.44 | 82.92 | 0.01 | 0.06 | 0 |
| **TOTAL** | | | | **1.548** | | | **2.57** | **0.27** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\D-window-my-addons-fake-wow-20260905-070125.json

# Perf sample: C-window-get-new-addons-cf-no-wow

State C: native host window open on Get new addons > CurseForge (real curseforge.com site in the embedded WebView2 pane), no WoW running.

Window: 2026-09-05 06:50:23 -> 2026-09-05 06:51:23 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-064557-626de2\server.log): 12

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 26728 | FurphyHost.exe | 30 | 0 | 43.13 | 43.03 | 0.15 | 0.02 | 0 |
| server | 36792 | powershell.exe | 30 | 1.188 | 214.46 | 214.19 | 2.4 | 0 | 0 |
| webview2-child | 9732 | msedgewebview2.exe | 30 | 0.016 | 23.93 | 23.75 | 0.02 | 0.04 | 0 |
| webview2-child | 11320 | msedgewebview2.exe | 30 | 1.141 | 240.7 | 205.28 | 0.45 | 0.91 | 0 |
| webview2-child | 15392 | msedgewebview2.exe | 30 | 0.016 | 22.82 | 19.36 | 0 | 0 | 0 |
| webview2-child | 17268 | msedgewebview2.exe | 30 | 0.562 | 132.65 | 130.69 | 2.32 | 3.42 | 0 |
| webview2-child | 22800 | msedgewebview2.exe | 28 | 0 | 52.09 | 51.57 | 0 | 0.01 | 0 |
| webview2-child | 27668 | msedgewebview2.exe | 5 | 0 | 53.44 | 53.37 | 0 | 0 | 0 |
| webview2-child | 32836 | msedgewebview2.exe | 5 | 0 | 51.14 | 51.08 | 0 | 0 | 0 |
| webview2-child | 33656 | msedgewebview2.exe | 30 | 0.328 | 52.31 | 51.56 | 0.97 | 4.04 | 0 |
| webview2-child | 43624 | msedgewebview2.exe | 30 | 0.188 | 79.9 | 78.59 | 0.02 | 0.06 | 0 |
| webview2-child | 47264 | msedgewebview2.exe | 5 | 0 | 52.19 | 52.12 | 0 | 0 | 0 |
| webview2-child | 51168 | msedgewebview2.exe | 30 | 0.109 | 107.35 | 102.29 | 0.07 | 0.11 | 0 |
| **TOTAL** | | | | **3.548** | | | **6.4** | **8.62** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\C-window-get-new-addons-cf-no-wow-20260905-065123.json

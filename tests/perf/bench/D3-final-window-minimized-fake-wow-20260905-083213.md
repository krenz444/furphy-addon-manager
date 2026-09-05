# Perf sample: D3-final-window-minimized-fake-wow

State D3 final (P2 after, fixed exit-transition build): host window MINIMIZED for the whole window, fake Wow.exe running throughout.

Window: 2026-09-05 08:31:13 -> 2026-09-05 08:32:13 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-083029-b9cf49\server.log): 0

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 29384 | FurphyHost.exe | 30 | 0 | 46.96 | 45.8 | 0 | 0 | 0 |
| server | 41484 | powershell.exe | 30 | 0.016 | 193.02 | 192.81 | 0 | 0 | 0 |
| webview2-child | 3972 | msedgewebview2.exe | 30 | 0.016 | 121.48 | 54.47 | 0 | 0 | 0 |
| webview2-child | 18436 | msedgewebview2.exe | 30 | 0.031 | 76.04 | 26.44 | 0 | 0 | 0 |
| webview2-child | 33236 | msedgewebview2.exe | 30 | 0 | 88.93 | 38.55 | 0 | 0 | 0 |
| webview2-child | 35376 | msedgewebview2.exe | 30 | 0 | 23.21 | 10.27 | 0 | 0 | 0 |
| webview2-child | 44336 | msedgewebview2.exe | 30 | 0 | 22.29 | 18.93 | 0 | 0 | 0 |
| webview2-child | 46676 | msedgewebview2.exe | 30 | 0 | 42.24 | 18.8 | 0 | 0 | 0 |
| webview2-child | 51144 | msedgewebview2.exe | 30 | 0 | 50.13 | 17.01 | 0 | 0 | 0 |
| **TOTAL** | | | | **0.063** | | | **0** | **0** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\D3-final-window-minimized-fake-wow-20260905-083213.json

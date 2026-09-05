# Perf sample: D2-final-window-my-addons-fake-wow-steadystate

State D2 final (P2 after), foreground the whole time, WoW started before the server (steady state).

Window: 2026-09-05 08:32:41 -> 2026-09-05 08:33:41 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-083029-b9cf49\server.log): 1

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 50616 | FurphyHost.exe | 30 | 0 | 46.96 | 44.62 | 0 | 0 | 0 |
| server | 36784 | powershell.exe | 30 | 0.484 | 192.95 | 184.69 | 0.21 | 0 | 0 |
| webview2-child | 28504 | msedgewebview2.exe | 30 | 0.016 | 50.21 | 49.46 | 0 | 0.03 | 0 |
| webview2-child | 37468 | msedgewebview2.exe | 30 | 0 | 42.48 | 42.16 | 0.02 | 0.01 | 0 |
| webview2-child | 37612 | msedgewebview2.exe | 30 | 0 | 91.68 | 91.08 | 0 | 0 | 0 |
| webview2-child | 43236 | msedgewebview2.exe | 30 | 0 | 23.22 | 23.2 | 0 | 0 | 0 |
| webview2-child | 43696 | msedgewebview2.exe | 30 | 0 | 22.25 | 18.32 | 0 | 0 | 0 |
| webview2-child | 48988 | msedgewebview2.exe | 30 | 0.016 | 122.63 | 120.82 | 0.08 | 0.12 | 0 |
| webview2-child | 51492 | msedgewebview2.exe | 30 | 0 | 77.52 | 76.52 | 0 | 0.04 | 0 |
| **TOTAL** | | | | **0.516** | | | **0.32** | **0.2** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\D2-final-window-my-addons-fake-wow-steadystate-20260905-083341.json

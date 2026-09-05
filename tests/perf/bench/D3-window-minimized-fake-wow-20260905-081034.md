# Perf sample: D3-window-minimized-fake-wow

State D3 (new, P2): host window MINIMIZED (not foreground) for the whole window, fake Wow.exe running throughout. Verifies EnterBackgroundMode (CF suspend, SPA suspend since minimized, BelowNormal+EcoQoS) plus the SPA 60s poll backoff together.

Window: 2026-09-05 08:09:34 -> 2026-09-05 08:10:34 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-080023-b3de27\server.log): 0

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 51752 | FurphyHost.exe | 30 | 0.031 | 47.57 | 46.27 | 0 | 0 | 0 |
| server | 49572 | powershell.exe | 30 | 0.016 | 308.35 | 308.13 | 0 | 0 | 0 |
| webview2-child | 3708 | msedgewebview2.exe | 30 | 0 | 23.26 | 10.32 | 0 | 0 | 0 |
| webview2-child | 18700 | msedgewebview2.exe | 30 | 0.016 | 73.46 | 24.5 | 0 | 0 | 0 |
| webview2-child | 28748 | msedgewebview2.exe | 30 | 0 | 50.07 | 16.98 | 0 | 0 | 0 |
| webview2-child | 35752 | msedgewebview2.exe | 30 | 0 | 42.25 | 18.83 | 0 | 0 | 0 |
| webview2-child | 42912 | msedgewebview2.exe | 30 | 0 | 89.14 | 38.65 | 0 | 0 | 0 |
| webview2-child | 44376 | msedgewebview2.exe | 30 | 0 | 22.3 | 18.94 | 0 | 0 | 0 |
| webview2-child | 44804 | msedgewebview2.exe | 30 | 0.047 | 124.04 | 55.53 | 0 | 0 | 0 |
| **TOTAL** | | | | **0.11** | | | **0** | **0** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\D3-window-minimized-fake-wow-20260905-081034.json

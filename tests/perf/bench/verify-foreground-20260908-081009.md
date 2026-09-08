# Perf sample: verify-foreground

Throwaway verification run (scratch port 47904) - confirms the new foreground It correctly measures the pre-fix regression.

Window: 2026-09-08 08:09:09 -> 2026-09-08 08:10:09 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\verify-foreground-20260908-080859-64904a\server.log): 2

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 38868 | FurphyHost.exe | 30 | 0 | 51.43 | 49.66 | 0 | 0 | 0 |
| server | 32772 | powershell.exe | 30 | 0.188 | 192 | 189.46 | 0.01 | 0 | 0 |
| webview2-child | 2960 | msedgewebview2.exe | 30 | 0.016 | 18.94 | 15.02 | 0 | 0 | 0 |
| webview2-child | 3532 | msedgewebview2.exe | 30 | 0.594 | 119.96 | 116.34 | 0.2 | 0.21 | 0 |
| webview2-child | 11736 | msedgewebview2.exe | 30 | 0 | 69.69 | 68.74 | 0 | 0 | 0 |
| webview2-child | 12960 | msedgewebview2.exe | 30 | 0 | 28.18 | 28.18 | 0 | 0 | 0 |
| webview2-child | 15632 | msedgewebview2.exe | 30 | 0 | 78.59 | 78.41 | 0 | 0 | 0 |
| webview2-child | 15712 | msedgewebview2.exe | 30 | 0 | 48.61 | 47.84 | 0 | 0.03 | 0 |
| webview2-child | 29672 | msedgewebview2.exe | 30 | 0 | 20.71 | 20.71 | 0 | 0 | 0 |
| webview2-child | 40628 | msedgewebview2.exe | 30 | 0 | 40.55 | 40.23 | 0.02 | 0.01 | 0 |
| **TOTAL** | | | | **0.798** | | | **0.23** | **0.26** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\verify-foreground-20260908-081009.json

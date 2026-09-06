# Perf sample: snowday-bg-verify

snow-day theme, minimized/background, default 1056x720, verifier round-1 re-run against FINAL redo code (post 13:22 edit)

Window: 2026-09-06 13:53:40 -> 2026-09-06 13:54:10 (30s actual, 15 samples at 2s)
Server requests in window: server.log not found at C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\verify-1fl-app-20260906-134841-5aa9db\server.log

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| host-window | 26360 | FurphyHost.exe | 15 | 0.047 | 49.63 | 49.29 | 0 | 0 | 0 |
| server | 4376 | powershell.exe | 15 | 0.094 | 368.39 | 368.35 | 0.01 | 0 | 0 |
| webview2-child | 10704 | msedgewebview2.exe | 15 | 0 | 20.98 | 20.93 | 0 | 0 | 0 |
| webview2-child | 16752 | msedgewebview2.exe | 15 | 0 | 93.14 | 91.43 | 0 | 0 | 0 |
| webview2-child | 23344 | msedgewebview2.exe | 15 | 0 | 48.25 | 48.07 | 0 | 0.03 | 0 |
| webview2-child | 26032 | msedgewebview2.exe | 15 | 0 | 13.21 | 13.16 | 0 | 0 | 0 |
| webview2-child | 31104 | msedgewebview2.exe | 15 | 0.016 | 79.88 | 79.53 | 0 | 0 | 0 |
| webview2-child | 34232 | msedgewebview2.exe | 15 | 0 | 121.42 | 121.02 | 0.05 | 0.06 | 0 |
| webview2-child | 36912 | msedgewebview2.exe | 15 | 0 | 40.78 | 40.71 | 0 | 0 | 0 |
| **TOTAL** | | | | **0.157** | | | **0.07** | **0.1** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\snowday-bg-verify-20260906-135410.json

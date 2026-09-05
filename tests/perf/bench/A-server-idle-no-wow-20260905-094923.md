# Perf sample: A-server-idle-no-wow

State A: server running (port 47899), no window, no WoW. Idle baseline - nothing polling it.

Window: 2026-09-05 09:48:23 -> 2026-09-05 09:49:23 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-094749-2e7c6a\server.log): 0

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| server | 35880 | powershell.exe | 30 | 0.406 | 435.75 | 431.24 | 0 | 0 | 0 |
| **TOTAL** | | | | **0.406** | | | **0** | **0** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\A-server-idle-no-wow-20260905-094923.json

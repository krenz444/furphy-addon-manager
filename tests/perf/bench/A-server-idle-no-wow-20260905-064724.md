# Perf sample: A-server-idle-no-wow

State A: server running (port 47899), no window, no WoW. Idle baseline - nothing polling it.

Window: 2026-09-05 06:46:24 -> 2026-09-05 06:47:24 (60s actual, 30 samples at 2s)
Server requests in window (from C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\.tmp\perf-app-20260905-064557-626de2\server.log): 0

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| server | 38388 | powershell.exe | 30 | 0.062 | 433.46 | 432.44 | 0 | 0 | 0 |
| **TOTAL** | | | | **0.062** | | | **0** | **0** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\A-server-idle-no-wow-20260905-064724.json

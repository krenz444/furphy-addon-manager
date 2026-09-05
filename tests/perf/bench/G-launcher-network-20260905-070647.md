# Perf sample: G-launcher-network

State G (happy path): addon-sync.ps1 -Launcher -Flavor retail, network available - the exact command update-addons-and-launch.cmd runs before starting WoW via Battle.net.

Window: 2026-09-05 07:06:27 -> 2026-09-05 07:06:47 (20s actual, 10 samples at 2s)

| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |
|---|---|---|---|---|---|---|---|---|---|
| sync-cli-launcher | 35704 | powershell.exe | 1 | 0 | 13.75 | 13.75 | 0 | 0 | 0 |
| **TOTAL** | | | | **0** | | | **0** | **0** | **0** |

JSON: C:\Users\drops\AppData\Local\Temp\claude\C--Users-drops-Documents-3d\e63e63f2-6f4b-4497-8d16-50029ad3f751\scratchpad\AddonSync2\tests\perf\bench\G-launcher-network-20260905-070647.json

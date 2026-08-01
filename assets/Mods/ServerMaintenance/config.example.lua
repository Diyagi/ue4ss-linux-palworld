-- ServerMaintenance config — copy this file to config.lua in the mod
-- directory (next to Scripts/) to override defaults. All keys optional;
-- missing keys fall back to the defaults below. Changing this file while
-- the server is running has no effect until restart.
--
-- CFG.snapshots              = true    -- periodic RSS/swap/lua snapshots
-- CFG.snapshot_interval_sec  = 300     -- seconds between persisted snapshots
-- CFG.tick_ms                = 30000   -- LoopAsync scheduler tick
-- CFG.census                 = true    -- periodic UObject census on the game thread
-- CFG.census_interval_sec    = 300     -- seconds between census calls (v1.6; requires LoopInGameThreadWithDelay)
-- CFG.console_commands      = true    -- pso_memreport / pso_census / pso_trim
-- CFG.trim                   = true    -- enable the manual trim probe command

CFG = {
    snapshots             = true,
    snapshot_interval_sec = 300,
    tick_ms               = 30000,
    census                = true,
    census_interval_sec   = 300,
    console_commands      = true,
    trim                  = true,
}

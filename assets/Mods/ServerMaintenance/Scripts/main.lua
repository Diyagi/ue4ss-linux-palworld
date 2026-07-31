-- ServerMaintenance — diagnostics-first server telemetry mod (v1.5)
-- Purpose: measure the memory climb shape (four-signal discriminator):
--   RSS growth | Lua heap | swap | UObject census
-- Phase 1 is DIAGNOSTICS ONLY. No GC trigger, no entity cleanup.
--
-- v1.3 LESSON (crash evidence): calling GetObjectCount() from the LoopAsync
-- thread SIGSEGV'd the game (exit 139, sig=11, right at the first snapshot).
-- The fork's UObject-array API is NOT safe from the async thread — it races
-- the game thread's object-array mutations. v1.4:
--   * LoopAsync snapshots capture ONLY async-safe telemetry: /proc RSS/swap,
--     collectgarbage("count") (Lua heap), os.time. NO UE API calls.
--   * UObject census runs ONCE per world load from a game-thread hook
--     (RegisterInitGameStatePostHook — fires on the game thread, safe).
--   * TrimAllocator is manual-only (pso_trim console cmd, game thread).
--
-- v1.5: config file support. Drop config.lua next to this script to override
-- any of the defaults below (see config.example.lua). Every feature can be
-- disabled independently:
--   CFG.snapshots            (bool)  periodic RSS/swap/lua snapshots
--   CFG.snapshot_interval_sec (num)  seconds between persisted snapshots
--   CFG.tick_ms               (num)  LoopAsync scheduler tick
--   CFG.census               (bool)  game-thread UObject census per world init
--   CFG.console_commands     (bool)  pso_memreport / pso_census / pso_trim
--   CFG.trim                 (bool)  enable the manual trim probe command
--
-- Thread-safety rule for this fork: if it touches UE objects, it must run on
-- the game thread. Pure stdlib (io, os) is safe from LoopAsync.

local TAG = "[ServerMaintenance]"

-- ---------------------------------------------------------------------------
-- Configuration (defaults; overridden by config.lua in the mod directory)
-- ---------------------------------------------------------------------------
local CFG = {
    snapshots             = true,
    snapshot_interval_sec = 300,
    tick_ms               = 30000,
    census                = true,
    console_commands      = true,
    trim                  = true,
}

-- Absolute-in-container path (game cwd is /palworld/Pal/Binaries/Linux).
local MOD_DIR_CANDIDATES = {
    "/palworld/Pal/Binaries/Linux/ue4ss/Mods/ServerMaintenance",
    "/tmp/ServerMaintenance",
}

local function load_config()
    for _, dir in ipairs(MOD_DIR_CANDIDATES) do
        local path = dir .. "/config.lua"
        local ok, err = pcall(dofile, path)
        if ok then
            if type(CFG) ~= "table" then
                print(TAG .. " WARNING: config.lua replaced CFG with a non-table; ignoring")
                return false
            end
            print(TAG .. " config loaded from " .. path)
            return true
        end
        -- dofile error for a missing file is fine; other errors are config bugs
        if err and not tostring(err):find("cannot open") then
            print(TAG .. " WARNING: config error in " .. path .. ": " .. tostring(err))
        end
    end
    print(TAG .. " no config.lua found; using defaults")
    return false
end

load_config()

-- ---------------------------------------------------------------------------
-- Derived settings
-- ---------------------------------------------------------------------------
local TICK_MS = CFG.tick_ms
local SNAPSHOT_INTERVAL_SEC = CFG.snapshot_interval_sec

local SNAPSHOT_PATH_CANDIDATES = {}
for _, dir in ipairs(MOD_DIR_CANDIDATES) do
    table.insert(SNAPSHOT_PATH_CANDIDATES, dir .. "/mem-snapshots.log")
end
table.insert(SNAPSHOT_PATH_CANDIDATES, "/tmp/mem-snapshots.log")

local SNAPSHOT_PATH = nil

local last_snapshot = 0 -- 0 => force a startup snapshot on first tick
local census_taken = false

-- ---------------------------------------------------------------------------
-- Feature detection
-- ---------------------------------------------------------------------------
local function detect_features()
    local features = {}
    features.timer_loopasync = type(LoopAsync) == "function"
    features.obj_count = type(GetObjectCount) == "function"
    features.trim = type(TrimAllocator) == "function"
    features.init_state_hook = type(RegisterInitGameStatePostHook) == "function"
    features.console_handler = type(RegisterConsoleCommandGlobalHandler) == "function"
    print(TAG .. " features: LoopAsync=" .. tostring(features.timer_loopasync)
        .. " GetObjectCount=" .. tostring(features.obj_count)
        .. " TrimAllocator=" .. tostring(features.trim)
        .. " InitGameStatePostHook=" .. tostring(features.init_state_hook)
        .. " ConsoleHandler=" .. tostring(features.console_handler))
    print(TAG .. " config: snapshots=" .. tostring(CFG.snapshots)
        .. " interval=" .. SNAPSHOT_INTERVAL_SEC
        .. " census=" .. tostring(CFG.census)
        .. " console_commands=" .. tostring(CFG.console_commands)
        .. " trim=" .. tostring(CFG.trim))
    return features
end

-- ---------------------------------------------------------------------------
-- Telemetry primitives (ALL async-thread safe: pure stdlib only)
-- ---------------------------------------------------------------------------
local function read_proc_stat(field)
    local ok, f = pcall(io.open, "/proc/self/status", "r")
    if not ok or not f then return -1 end
    local val = -1
    for line in f:lines() do
        if line:sub(1, #field) == field then
            local num = line:match("(%d+)")
            if num then val = tonumber(num) end
            break
        end
    end
    f:close()
    return val
end

local function append_line(text)
    if not SNAPSHOT_PATH then
        for _, cand in ipairs(SNAPSHOT_PATH_CANDIDATES) do
            local ok, f = pcall(io.open, cand, "a")
            if ok and f then
                f:close()
                SNAPSHOT_PATH = cand
                print(TAG .. " snapshot path: " .. cand)
                break
            end
        end
    end
    if not SNAPSHOT_PATH then
        print(TAG .. " ERROR: no writable snapshot path found")
        return false
    end
    local ok, f = pcall(io.open, SNAPSHOT_PATH, "a")
    if not ok or not f then return false end
    f:write(text .. "\n")
    f:close()
    return true
end

local function take_snapshot(reason, objs)
    local rss = read_proc_stat("VmRSS:")
    local swap = read_proc_stat("VmSwap:")
    local lua_kb = collectgarbage("count")
    local line = string.format("%d rss_kb=%d swap_kb=%d lua_kb=%.0f objs=%s reason=%s",
        os.time(), rss, swap, lua_kb, tostring(objs or "n/a"), reason)
    print(TAG .. " snapshot: " .. line)
    append_line(line)
end

-- ---------------------------------------------------------------------------
-- Game-thread census (fires once per world load — safe: game thread)
-- ---------------------------------------------------------------------------
local function take_census(reason)
    if census_taken then return end
    census_taken = true
    local objs = "n/a"
    if type(GetObjectCount) == "function" then
        local ok, n = pcall(GetObjectCount)
        if ok then objs = tonumber(n) end
    end
    print(TAG .. " census: " .. os.time() .. " objs=" .. tostring(objs) .. " reason=" .. reason)
    append_line(os.time() .. " census objs=" .. tostring(objs) .. " reason=" .. reason)
end

-- ---------------------------------------------------------------------------
-- Scheduler — LoopAsync (PROVEN working on this fork build)
-- ---------------------------------------------------------------------------
local features = detect_features()

local function maintenance_tick()
    local now = os.time()
    if now - last_snapshot >= SNAPSHOT_INTERVAL_SEC then
        last_snapshot = now
        take_snapshot("tick")
    end
end

local function schedule_tick()
    if CFG.snapshots and features.timer_loopasync then
        LoopAsync(TICK_MS, function()
            maintenance_tick()
            return false
        end)
        print(TAG .. " using LoopAsync(" .. TICK_MS .. "ms) [proven dispatch path]")
    elseif not CFG.snapshots then
        print(TAG .. " snapshots disabled in config")
    else
        print(TAG .. " ERROR: no LoopAsync; telemetry disabled")
    end
end

-- ---------------------------------------------------------------------------
-- RCON console commands (game thread — safe)
-- ---------------------------------------------------------------------------
local function console_memreport()
    print(TAG .. " manual memreport requested")
    take_snapshot("console")
end

local function console_census()
    print(TAG .. " manual census requested")
    census_taken = false
    take_census("console")
end

local function console_trim()
    print(TAG .. " manual trim requested (NOT auto — game thread via RCON)")
    local before = read_proc_stat("VmRSS:")
    local ok = false
    if type(TrimAllocator) == "function" then
        ok = pcall(TrimAllocator)
    end
    local after = read_proc_stat("VmRSS:")
    local line = string.format("%d trim_probe before_kb=%d after_kb=%d delta_kb=%d ok=%s reason=%s",
        os.time(), before, after, (before - after), tostring(ok), "console")
    print(TAG .. " " .. line)
    append_line(line)
end

if CFG.console_commands and features.console_handler then
    RegisterConsoleCommandGlobalHandler("pso_memreport", function()
        console_memreport()
    end)
    RegisterConsoleCommandGlobalHandler("pso_census", function()
        console_census()
    end)
    if CFG.trim then
        RegisterConsoleCommandGlobalHandler("pso_trim", function()
            console_trim()
        end)
    end
    print(TAG .. " registered console commands: pso_memreport, pso_census"
        .. (CFG.trim and ", pso_trim" or ""))
end

-- One-time game-thread census at world init (safe path to the UE API)
if CFG.census and features.init_state_hook then
    RegisterInitGameStatePostHook(function()
        take_census("world-init")
    end)
    print(TAG .. " armed InitGameStatePostHook census")
end

schedule_tick()
print(TAG .. " loaded v1.5.0; diagnostics-only phase. Snapshots -> " .. SNAPSHOT_PATH_CANDIDATES[1])

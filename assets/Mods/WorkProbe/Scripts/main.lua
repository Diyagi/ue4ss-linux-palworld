-- WorkProbe — work-progress catch-up semantics probe (v1.0)
-- Purpose: answer the community's open question (no public data exists):
--   does a significance-scaled base-camp tick CREDIT full elapsed Δt to a
--   UPalWorkProgress (rate preserved → significance tuning is free), or DROP
--   the unticked time (rate lost → far-tier tuning costs output)?
--
-- Method: sample UPalWorkProgress objects on the game thread every
-- CFG.interval_sec (proven timer: LoopInGameThreadWithDelay rides the
-- EngineTick hook, fixed on this fork by the vtable-slot/AOB work; PSO's
-- 60s loops are the live proof).
--
-- Per object we log:
--   ProgressTimeSinceLastTick — Transient float; accumulates between
--     serviced ticks. If it climbs toward ~the gate interval (e.g. 10s)
--     between services, the gate credits elapsed time.
--   AutoWorkSelfAmountBySec — the declared per-second work rate.
--   TickProcessMinInterval — the work's own minimum service cadence.
--   GetRemainWorkAmount()  — BlueprintPure accessor; pcall'd UFunction
--     invocation (proven safe on the game thread; never on LoopAsync).
--
-- Analysis (offline): slope of remain-work vs wall-clock vs the declared
-- rate decides catch-up semantics; ProgressTimeSinceLastTick's reset
-- pattern corroborates. A/B: patch the far significance tier (pak) and
-- compare per-wall-hour output.
--
-- Thread-safety: UE objects and UFunction calls ONLY on the game thread
-- (async-thread UE API use SIGSEGVs on this fork — proven twice).

local TAG = "[WorkProbe]"

local CFG = {
    enabled         = true,
    interval_sec    = 60,
    max_objects     = 32,
    log_path        = "/palworld/Pal/Binaries/Linux/ue4ss/Mods/WorkProbe/workprobe.log",
    read_remain     = true,
}

local MOD_DIR_CANDIDATES = {
    "/palworld/Pal/Binaries/Linux/ue4ss/Mods/WorkProbe",
    "/tmp/WorkProbe",
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
        if err and not tostring(err):find("cannot open") then
            print(TAG .. " WARNING: config error in " .. path .. ": " .. tostring(err))
        end
    end
    print(TAG .. " no config.lua found; using defaults")
    return false
end

load_config()

-- ---------------------------------------------------------------------------
-- Logging (absolute path; game cwd is /palworld/Pal/Binaries/Linux)
-- ---------------------------------------------------------------------------
local LOG_PATH = nil
local LOG_PATH_CANDIDATES = { CFG.log_path, "/tmp/workprobe.log" }

local function append_line(text)
    if not LOG_PATH then
        for _, cand in ipairs(LOG_PATH_CANDIDATES) do
            local ok, f = pcall(io.open, cand, "a")
            if ok and f then
                f:close()
                LOG_PATH = cand
                print(TAG .. " log path: " .. cand)
                break
            end
        end
    end
    if not LOG_PATH then
        print(TAG .. " ERROR: no writable log path")
        return false
    end
    local ok, f = pcall(io.open, LOG_PATH, "a")
    if not ok or not f then return false end
    f:write(text .. "\n")
    f:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Feature detection
-- ---------------------------------------------------------------------------
print(TAG .. " features: gamethread_timer=" .. tostring(type(LoopInGameThreadWithDelay) == "function")
    .. " foreach=" .. tostring(type(ForEachUObject) == "function")
    .. " interval_sec=" .. tostring(CFG.interval_sec)
    .. " read_remain=" .. tostring(CFG.read_remain))

-- ---------------------------------------------------------------------------
-- Probe — GAME THREAD ONLY
-- ---------------------------------------------------------------------------
local progress_class = nil
local probe_runs = 0
local sample_count = 0

local function get_progress_class()
    if progress_class then return progress_class end
    local ok, cls = pcall(StaticFindObject, "/Script/Pal.PalWorkProgress")
    if ok and cls then
        progress_class = cls
        print(TAG .. " UPalWorkProgress class resolved")
    else
        print(TAG .. " WARNING: UPalWorkProgress class NOT found (game version changed?)")
    end
    return progress_class
end

local function is_valid(object)
    if not object then return false end
    local ok, valid = pcall(function()
        local addr = object:GetAddress()
        return addr ~= nil and addr ~= 0
    end)
    return ok and valid
end

-- Read a float property defensively (pusher machinery; safe on game thread)
local function read_float(obj, name)
    local ok, val = pcall(function() return tonumber(obj[name]) end)
    if not ok then return nil end
    return val
end

local function probe_tick()
    local class = get_progress_class()
    if not class then
        -- retry next tick; the class may not be loadable until the world exists
        print(TAG .. " class missing; skipping")
        return
    end

    probe_runs = probe_runs + 1
    local now = os.time()
    local rows = {}
    local seen = 0

    ForEachUObject(function(object)
        if seen >= CFG.max_objects then return end
        if not is_valid(object) then return end
        local ok, is_progress = pcall(function() return object:IsA(class) end)
        if not ok or not is_progress then return end

        seen = seen + 1
        local tick_since = read_float(object, "ProgressTimeSinceLastTick")
        local rate = read_float(object, "AutoWorkSelfAmountBySec")
        local min_interval = read_float(object, "TickProcessMinInterval")

        local remain = "n/a"
        if CFG.read_remain then
            local okc, rem = pcall(function() return object:GetRemainWorkAmount() end)
            if okc and rem then remain = string.format("%.1f", tonumber(rem) or -1) end
        end

        local row = string.format("%d obj=%-2d tick=%.2f rate=%.3f minint=%.2f remain=%s",
            now, seen, tick_since or -1, rate or -1, min_interval or -1, remain)
        rows[#rows + 1] = row
        sample_count = sample_count + 1
    end)

    local summary = string.format("%s probe: %d run(s) samples=%d seen_this_run=%d",
        TAG, probe_runs, sample_count, seen)
    print(summary)
    append_line(summary)
    for _, row in ipairs(rows) do
        append_line("  " .. row)
    end
end

-- Schedule on the game thread (EngineTick). Self-arms via the fork's
-- ensure_engine_tick_hooked inside LoopInGameThreadWithDelay.
local function schedule()
    if type(LoopInGameThreadWithDelay) ~= "function" then
        print(TAG .. " ERROR: LoopInGameThreadWithDelay unavailable; probe disabled")
        return
    end
    print(TAG .. " scheduling game-thread probe every " .. CFG.interval_sec .. "s")
    LoopInGameThreadWithDelay(CFG.interval_sec * 1000, function()
        probe_tick()
        -- re-arm (LoopInGameThreadWithDelay is a one-shot unless re-registered)
        schedule()
    end)
end

-- Defer the first probe ~10s so the world (and work objects) exist.
local function start()
    print(TAG .. " started")
    LoopInGameThreadWithDelay(10000, function()
        probe_tick()
        schedule()
    end)
end

start()

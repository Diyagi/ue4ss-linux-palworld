-- WorkProbe — work-progress catch-up semantics probe (v1.4)
-- v1.4: census widened — "Work" alone missed the base-camp system: the
-- manager (BP_PalBaseCampManager_C), worker controllers
-- (BP_MonsterAIController_BaseCamp_C) and action composites
-- (BP_AIActionComposite_BaseCamp_C) carry no "Work" substring. Match
-- Work|BaseCamp|MonsterAIController|PalAIAction so the census can say
-- whether the base-camp system is alive as UObjects at all vs plain C++
-- structs (the v1.3.1 result: zero live PalWork* instances while a player
-- stood in an actively working base).
-- v1.3.1: census now categorizes entries (Class CDO / Default__ CDO / live
-- instance) and logs EVERY live instance name — the v1.3 run found the 3
-- "work objects" are class default templates, not live state; whether ANY
-- live UPalWorkProgress instance exists in a working base is the open
-- question.
-- v1.3: identity via GetFullName() (the binding PSO proves works —
-- GetClass():GetName()/GetOuter():GetName() return nil on this fork).
-- Adds a NAME CENSUS: every object whose full name contains "Work" is
-- grouped by class name and counted, because the observed world has
-- visible working pals but ZERO live UPalWorkProgress state (2723 probes,
-- all slots idle) — the work objects must carry a different class in
-- this build (class dumps were 1.0.1-era kit; server is 1.0.2.101103).
-- v1.1: log object identity (address + class + outer) so idle singletons are
-- distinguishable from rotating work assignments (playerless worlds appear to
-- freeze work simulation entirely — all observed slots stay at zero).
-- v1.2 FIX: LoopInGameThreadWithDelay is AUTO-LOOPING on this fork
-- (LuaMod.cpp is_looping=true; the process path re-arms execute_at and keeps
-- the action Active). v1.1 re-armed from inside its own callback, doubling
-- timers exponentially (observed: 6 runs in 8s at run ~105). Single
-- registration, no re-arm.
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
local multi_class = nil
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

local function get_multi_class()
    if multi_class then return multi_class end
    local ok, cls = pcall(StaticFindObject, "/Script/Pal.PalWorkProgressMultiType")
    if ok and cls then
        multi_class = cls
        print(TAG .. " UPalWorkProgressMultiType class resolved")
    end
    return multi_class
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

local function census_match(name)
    return name:find("Work", 1, true)
        or name:find("BaseCamp", 1, true)
        or name:find("MonsterAIController", 1, true)
        or name:find("PalAIAction", 1, true)
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

    -- NAME CENSUS: group every object whose full name mentions Work by class
    -- name. This reveals what the work objects are actually called in THIS
    -- build (the class dumps were 1.0.1-era kit; the live server is
    -- 1.0.2.101103).
    -- Categorize: Class CDO ("Class /Script/..."), Default__ CDO
    -- ("Default__..."), or live instance (anything else). v1.3.1 logs ALL
    -- live instances — the v1.3 run's 3 matches were all Default__ CDOs.
    local by_class = {}
    local census_total = 0
    local census_class = 0
    local census_default = 0
    local census_live = 0
    local live_samples = {}
    local class_samples = {}
    ForEachUObject(function(object)
        if not is_valid(object) then return end
        local ok, full = pcall(function() return object:GetFullName() end)
        if not ok or not full then return end
        local name = tostring(full)
        if census_match(name) then
            census_total = census_total + 1
            if name:sub(1, 6) == "Class " then
                census_class = census_class + 1
                if #class_samples < 5 then class_samples[#class_samples + 1] = name end
            elseif name:find("Default__", 1, true) then
                census_default = census_default + 1
            else
                census_live = census_live + 1
                if #live_samples < 60 then live_samples[#live_samples + 1] = name end
            end
            local cls_name = name:match("Class (/Script/%S+)") or "?"
            by_class[cls_name] = (by_class[cls_name] or 0) + 1
        end
    end)

    local census_lines = {}
    for k, v in pairs(by_class) do
        census_lines[#census_lines + 1] = string.format("%s=%d", k, v)
    end
    table.sort(census_lines)
    append_line(string.format("%d census total=%d class=%d default=%d live=%d by_class=%s",
        now, census_total, census_class, census_default, census_live, table.concat(census_lines, " ")))
    for _, s in ipairs(class_samples) do
        append_line("  class: " .. s)
    end
    for _, s in ipairs(live_samples) do
        append_line("  live: " .. s)
    end

    ForEachUObject(function(object)
        if seen >= CFG.max_objects then return end
        if not is_valid(object) then return end
        local ok, is_progress = pcall(function()
            local c = get_multi_class()
            return object:IsA(class) or (c and object:IsA(c)) or false
        end)
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

        local addr = "?"
        local okc2, addr_v = pcall(function() return object:GetAddress() end)
        if okc2 and addr_v then addr = string.format("%x", addr_v) end
        local full = "?"
        local okc3, full_v = pcall(function() return object:GetFullName() end)
        if okc3 and full_v then full = tostring(full_v) end

        local row = string.format("%d obj=%-2d addr=%s name=%s tick=%.2f rate=%.3f minint=%.2f remain=%s",
            now, seen, addr, full, tick_since or -1, rate or -1, min_interval or -1, remain)
        rows[#rows + 1] = row
        sample_count = sample_count + 1
    end)

    local summary = string.format("%s probe: %d run(s) samples=%d seen_this_run=%d census_total=%d",
        TAG, probe_runs, sample_count, seen, census_total)
    print(summary)
    append_line(summary)
    for _, row in ipairs(rows) do
        append_line("  " .. row)
    end
end

-- Schedule on the game thread (EngineTick). LoopInGameThreadWithDelay is
-- AUTO-LOOPING on this fork (action.is_looping=true) — it must NOT be
-- re-armed from inside its own callback (that doubles timers exponentially;
-- observed avalanche: 6 runs in 8s at run ~105). A single registration is
-- the whole schedule.
local function schedule()
    if type(LoopInGameThreadWithDelay) ~= "function" then
        print(TAG .. " ERROR: LoopInGameThreadWithDelay unavailable; probe disabled")
        return
    end
    print(TAG .. " scheduling game-thread probe every " .. CFG.interval_sec .. "s (auto-looping, no re-arm)")
    LoopInGameThreadWithDelay(CFG.interval_sec * 1000, probe_tick)
end

-- Defer the first probe ~10s so the world (and work objects) exist; the
-- looping schedule then takes over on its own cadence.
local function start()
    print(TAG .. " started")
    ExecuteInGameThreadWithDelay(10000, probe_tick)
    schedule()
end

start()

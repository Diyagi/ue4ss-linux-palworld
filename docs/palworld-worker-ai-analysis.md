# Palworld Base-Camp Worker AI — Cost Path Analysis

**Server build:** v1.0.2.101103 (UE 5.1, Linux dedicated server)
**Date:** 2026-08-01
**Method:** pak asset extraction (repak + UAssetAPI + Mappings.usmap @42cf396) + community class dumps (localcc/PalworldModdingKit @62fad41, Dumper-7 SDK) + live binary RE (in progress)

---

## Executive summary

The base-camp worker cost path in Palworld has **two independent distance-scaling systems** and **three separate tick domains**:

| Tick domain | Frequency | Gated by | Feature impact if slowed |
|---|---|---|---|
| **Base camp manager/model update** (assignment, events, work service) | 0.1s → 10s by player distance | `BaseCampSignificanceInfoList` (significance tiers) | none — reaction latency only |
| **Per-worker AI controller tick** (PawnActions chain: Wait/Approach/Working actions) | **per-frame** (≤20Hz floor via `MinAIActionComponentTickInterval`) | **NOT significance-gated** | decision reaction latency |
| **Work progress accumulation** | per-second rate (`AutoWorkSelfAmountBySec`) on the work object's own accumulator | work's own `TickProcessMinInterval`; serviced by camp update | **unproven** — catch-up may credit or drop elapsed time |

**Bottom line:** worker AI ticks per-frame regardless of distance; significance scales only the *management* layer. The character-*importance* system (a second, separate LOD) gates worker *move-mode fidelity*, not tick frequency.

---

## 1. Architecture: two distance systems

### 1a. Base-camp significance (`BaseCampSignificanceInfoList`)
Location: `BP_PalBaseCampManager_C` CDO (`Pal/Content/Pal/Blueprint/System/BP_PalBaseCampManager`).

| Player distance | TickInterval | bUpdateSimple | bMergeDropItems |
|---|---|---|---|
| -1 (in base) | 0.1s | false | true |
| 500m | 1.5s | false | true |
| 2500m | 2.5s | false | true |
| 4500m | 5.0s | false | true |
| 6500m+ | 10.0s | **true** | true |

Struct: `PalBaseCampSignificanceInfo { DistanceInRangeFromPlayer, TickInterval, bMergeDropItems, bUpdateSimple }`.
Gates: base camp model update, worker-director assignment/events, per-frame budget `BaseCampTickInvokeMaxNumInOneTick = 5`.

### 1b. Character importance (separate LOD)
- `UPalGameSetting::BaseCampWorkerSimpleMoveThreshold` / `BaseCampWorkerMoveModeChangeThreshold` — both `EPalCharacterImportanceType`
- `UPalCharacterImportanceManager` buckets characters; `APalAIController::OnChangeChangeImportance` reacts
- Gates worker **move-mode fidelity** (simple move vs full) — NOT tick frequency

---

## 2. Per-worker AI tick path (the dominant cost)

**Controller:** `BP_MonsterAIController_BaseCamp_C : BP_MonsterAIControllerBase_C : APalAIController`
CDO (pak-verified): `MinAIActionComponentTickInterval = 0.05` (50ms → 20Hz floor), `bShouldCheckStuckByTick = true`, `DefaultActionClass = BP_AIAction_WanderingCage_C`, `CombatModuleClass = PalAICombatModule_BaseCamp`.

**Action component:** `UPalAIActionComponent : UPawnActionsComponent` (default subobject of the controller). UE `AAIController::bCanEverTick` defaults true → **per-frame Actor tick**; `UPawnActionsComponent::TickComponent` pushes active `UPawnAction::Tick` per component tick. No `SetActorTickInterval`/`SetTickInterval` anywhere in Pal dumps. The only rate control is `MinAIActionComponentTickInterval` (native default 0.0 = unthrottled; 0.05 on the BaseCamp BP CDO = 20Hz floor for the action stack — consumption path native-internal, to be confirmed by binary RE).

**Action selection (composite):** `BP_AIActionComposite_Worker_BaseCamp_C : PalAIActionCompositeWorkerBaseCamp` (native, plain UObject state machine — no tick fields):
- `WaitActionClass = BP_AIAction_BaseCampWorker_Wait_C` (native `PalAIActionWorkerWait`)
- `ApproachActionClass = BP_AIAction_BaseCampWorker_Approach_C`
- `WaitForWorkableActionClass = BP_AIAction_Work_WaitForWorkable_C` (native `PalAIActionWorkerWaitForWorkable`)
- `WorkingActionClass = BP_AIAction_Worker_Working_C` (native `PalAIActionWorkerWorking`, only `TurnSpeedToTarget`)
- `SpeedFlagName = "WorkWalkSpeed"`

**Idle behavior (dominant state):** `BP_AIAction_WanderingCage_C : PalAIActionBaseCampCage : PalAIActionBase` — `ConstWalkSpeed = 0.25`, graph: `ActionTick` / `ChangeNextMovePosition` / `ActionStart`. Wait action has `WalkAroundSettings` → `WalkAroundNextDistance = 2000.0` (2km wander radius).

**Per-worker cadence knobs found in `BP_PalGameSetting_C` CDO:**
- `Timeout_WorkerApproachToTarget = 5.0`
- `WorkerWaitingNotifyInterval = 1.0`
- `BaseCampWorkerEventTriggerInterval = 90.0` (worker events evaluated every 90s)
- `BaseCampWorkerEventTriggerProbability = 50.0`
- `BaseCampAreaRange = 3500.0` · `BaseCampExtraWorkAreaRange = 7000.0` · `BaseCampNeighborMinimumDistance = 1500.0` (PVP 8500)

---

## 3. Work progress — decoupled from the AI tick

`UPalWorkProgress` carries its **own** accumulator (structurally provable):
- `ProgressTimeSinceLastTick` + `TickProcessMinInterval` (transient floats)
- `AutoWorkSelfAmountBySec` (replicated rate field)

Rate knobs (`UPalGameSetting`): `WorkAmountBySecForPlayer`, `WorkAmountByManMonth`, `AddWorkSpeedPerStatusPoint`, `AddWorkSpeedPerWorkSpeedRank`. `WorkSpeedRate` is an INI key (single global multiplier; currently 1.0 on our servers).

`UPalWorkProgressMultiType` exposes only the add-API (`AddProgressForWorkType`) — something calls it with an amount; it isn't self-ticking. The servicer is **not visible in dumps** (native-only); candidates: `UPalBaseCampModel` (own `ProgressTimeSinceLastTick`, significance-gated) and the work objects.

**OPEN QUESTION (needs runtime measurement):** when the significance-gated camp update runs late, does the catch-up credit the **full** elapsed time (rate preserved → reducing camp tick does NOT slow output) or **drop** it (rate lost → output scales with camp tick)? This is the single most important open question for the "scale management tick without nerfing workers" goal.

---

## 4. Worker events & assignment

- `UPalBaseCampWorkerDirector : UObject` (plain, no timer): `WorkerEventTickCount`, `WorkerTasks[]`, `State`, `CurrentOrderType`, `WaitingWorkerIndividualIds`. Driven externally by the camp model update.
- Events evaluated on the **management cadence**: `BaseCampWorkerEventTriggerInterval` (90s) / `BaseCampWorkerDirectorTickForAssignWorkByCount`, NOT per-worker tick. Manager cap `WorkerEventTriggerTickMaxCount = INT_MAX`.
- `DT_BaseCampWorkerEventDataTable` (11 rows): sanity triggers 0-85, `TriggerSkipCount` 0-2 (DestroyBuilding/Trantrum/Escape/OverworkDeath flagged `Invalid=true` = disabled).
- `DT_BaseCampWorkerSickDataTable` (9 rows): WorkSpeed −5…−50, MoveSpeed −5…−50 (Cold/Sprain/Bulimia/GastricUlcer/Fracture/Weakness/DepressionSprain/DisturbingElement).
- Task assignment: `WorkerTasks` transient on director; requests via `RequiredAssignWorks` / `OrderCommand`; evaluated on director tick (significance-gated) at `BaseCampWorkerDirectorTickForAssignWorkByCount` cadence.

---

## 5. What does NOT scale with distance

1. **Per-worker AI controller tick** — per-frame whenever possessed/active (≤20Hz if the 0.05 CDO value is consumed).
2. **Worker movement** — per-frame via the action tick (walk-around wander, 2km radius) — only move *mode* is importance-gated.
3. **Character simulation** — each worker is a full pawn with components; importance LOD gates fidelity, not ticking.

---

## 6. Optimization levers (feature-preserving)

| Lever | What | Feature impact | Risk |
|---|---|---|---|
| **A. `MinAIActionComponentTickInterval`** (BaseCamp controller CDO: 0.05 → e.g. 0.2) | throttles the per-worker action stack to 5Hz | decision reaction latency only; work rate untouched (per-second rates) | consumption path unproven — needs binary RE + live test |
| **B. Significance tier tuning** (pak) | widen far-tier ranges / extend beyond 6500m | none (already 10s+simple at 6.5km) | marginal gain — far tier already aggressive |
| **C. `BaseCampWorkerEventTriggerInterval`** 90s → larger | fewer sanity/event evaluations | events rarer (sanity feedback slower) | mild — affects worker-event behavior |
| **D. Work-progress catch-up verification** | measure whether late camp ticks credit or drop elapsed time | if credits: free management scaling | measurement only, no change |
| **E. `bUpdateSimple` far tier** | already true at 6500m+ | pals "look idle while working" per mod comment; work continues | already shipped |

**NOT levers:** `BaseCampWorkerMaxNum` (ini no-op bug), `DT_BaseCampLevelData.WorkerMaxNum` (feature cut — user veto), `BaseCampAreaRange` reduction (feature cut).

---

## 7. Open questions

1. Does `MinAIActionComponentTickInterval` 0.05 get consumed natively (20Hz floor)? (binary RE in progress)
2. Work-progress catch-up: full credit vs drop? (runtime measurement — soak instrumentation)
3. Patch-level parity of dumps (pinned 1.0.1.100619) vs running 1.0.2.101103.
4. Defaults of `BaseCampWorkerDirectorTickForAssignWorkByCount` / `BaseCampWorkerSimpleMoveThreshold` (native EditAnywhere, not in pak CDO).

---

## 8. Evidence trail

- Pak assets extracted with repak `get` from `Pal-LinuxServer.pak` (test volume), converted with uassetjson wrapper (UAssetAPI v1.1.0, VER_UE5_1, usmap @42cf396), inspected via jq.
- Class dumps: localcc/PalworldModdingKit @62fad413 (Source/Pal mirror), goku19991998-cell/palworld-internal-dx11 (Dumper-7 SDK), MiauwWare/PalworldSDKHeaders; cross-checked against our pak CDO observations.
- Live binary RE: gdb on test container (`palworld-test`) — **pending, see addendum**.

---

## Addendum A — Soak measurements (2026-08-01, hours 0-6)

Four-signal soak (populated 683-pal world on test, fresh world on live; zero players; full mod set on the fixed EngineTick build b23ad7c):

**Test (populated world, objs flat at 357386):**
| hour | RSS | climb |
|---|---|---|
| 0 | 1923MB | — |
| ~4 (census boots) | 1941MB | sawtooth (autosave cycles) |
| +1 | 1944MB | +3MB |
| +2 | 1950MB | +6MB/hr |
| +3 | 1956MB | +6MB/hr |
| +4 | 1963MB | +6MB/hr |
| +5 | 1968MB | +6MB/hr |

**Live (fresh world, objs flat at 160112):**
| hour | RSS | climb |
|---|---|---|
| 0 | 1123MB | — |
| +1 | 1126MB | +3MB/hr |
| +2 | 1129MB | +3MB/hr |
| +3 | 1132MB | +3.5MB/hr |
| +4 | 1136MB | +4MB/hr |
| +5 | 1143MB | +6MB/hr |
| +6 | 1149MB | +6MB/hr |

**Interpretation:** objs completely flat while RSS climbs steadily (3→6MB/hr, slightly accelerating) — the climb is **allocator pools/fragmentation, not object growth**. This is the oracle's Trim signal: `TrimAllocator` (return free pages to the OS) is the correct lever; a GC trigger would do nothing for this class of growth. At 6MB/hr, 23GB buys weeks; the daily 20:00 UTC restart already bounds it. A periodic game-thread Trim (ServerMaintenance v1.7, pending) should flatten the curve further.

**Open question confirmed as measurement-able:** work-progress catch-up semantics (credit vs drop elapsed time on late camp ticks) — can be tested by comparing work output at different significance tiers.

---

## Addendum B — Character-side per-worker cost (pak-verified)

`BP_MonsterBase_C` (the worker pawn, parent `PalCharacter` native) CDO carries the full per-frame component set with **no tick throttling**:
`Mesh`, `CharacterMovement`, `CapsuleComponent`, `FootIKComponent`, `LookAtComponent`, `AroundInfoCollectorComponent`, `CharacterParameterComponent`, `DamageReactionComponent`, `StatusComponent`, `ActionComponent`, `AnimNotifyComponent`, `PassiveSkillComponent`, `VisualEffectComponent`, `LiftupObjectComponent`.

`ABP_MonsterBase` (anim instance, parent `PalAnimInstance`) — no CDO tick fields; the anim graph is huge (3.7MB JSON) but its update is animation-driven (importance LOD affects fidelity, not cadence).

**Cost model per worker (all per-frame unless throttled):**
1. AI controller tick → PawnActions chain → active action Tick (Wait/Approach/Working/WanderingCage)
2. Character components: movement, FootIK, LookAt, AroundInfoCollector, parameter updates
3. Anim instance update (importance-LOD-gated fidelity)
4. Stuck/block detection (`bShouldCheckStuckByTick`)

The only per-worker rate knobs in the whole path: `MinAIActionComponentTickInterval` (CDO 0.05) and the importance thresholds (native defaults, not pak-serialized).

---

## Addendum C — Conclusions: what the map means

### Q: "If worker AIs tick less often, do they do less work?"

**The per-worker AI tick is NOT actually slowed by the significance system at all.** The significance tiers (0.1s→10s) gate only the base camp *management* layer (model update, director assignment, events, per-frame budget of 5 invocations). Each worker's AI controller (PawnActions chain) ticks per-frame regardless of distance. So the current server configuration is already "workers at full decision rate everywhere" — the game's own distance scaling applies only to management.

**Work output is structurally protected** — work progress accumulates on per-second rates (`AutoWorkSelfAmountBySec`, `WorkAmountByManMonth`) with its own accumulator, decoupled from the AI tick. The single unproven link: whether the significance-gated camp update, when it runs late, *credits* the full elapsed time (rate preserved) or *drops* it (rate lost). Everything in the dump structure (accumulator pair `ProgressTimeSinceLastTick` + `TickProcessMinInterval` on the work object itself) points to credit-preserving catch-up, but this must be measured at runtime to be certain.

### Feature-preserving levers (the actual "optimize the game" menu)

1. **`MinAIActionComponentTickInterval` 0.05 → 0.2** (pak-patch `BP_MonsterAIController_BaseCamp` CDO): throttles the per-worker action stack to 5Hz instead of 20Hz. Reaction latency only; work rates untouched. **Pending rev-2 binary confirmation of the consumption path.**
2. **Significance tier tuning** (pak-patch `BaseCampSignificanceInfoList`): widen far-tier distances / extend beyond 6500m. Marginal — far tier already 10s+simple.
3. **`BaseCampWorkerEventTriggerInterval` 90s → 180s**: halves sanity/event evaluations. Mild behavioral cost (slower sanity feedback).
4. **Work-catch-up runtime test**: measure output at tier 5 vs tier 1; if credit-preserving, management scaling is free.

### What is NOT on the table (user constraints)
- `BaseCampWorkerMaxNum` ini — confirmed no-op bug; the real count lever (`DT_BaseCampLevelData.WorkerMaxNum`) is a feature cut → vetoed
- `BaseCampAreaRange` / base size reductions — feature cuts → vetoed
- Any per-worker movement/visibility reduction — feature cuts → vetoed

---

## Addendum D — Work-assign layer (palpak-verified)

Assignment configs are **inline in `BP_PalGameSetting` CDO** (no separate datatables). Each `WorkAssignDefineData_*` entry (BuildWork_0, FoliageWork_0, ReviveCharacterWork_0, TransportItemInBaseCamp_0, RepairBuildObject_0, ExtinguishBurn_0, CoolOverHeat_0, TreasureBoxUnlock→UnlockTreasureBox{Electric,Fire,Water}...) defines:

- `WorkSuitability` (Handcraft/Deforest/Transport/Watering/Anyone/GenerateElectricity/EmitFlame...)
- `WorkType` + `ActionType` (the AI action the worker takes)
- `WorkerMaxNum` — 0 (dynamic), 1 (fixed slot), -1 (unlimited)
- `AffectSanityValue` = **-0.08 per work tick** (the sanity drain that feeds the worker-event system)
- `bPlayerWorkable` / `bBaseCampWorkerWorkable` / `WorkableTribeIDs` / `WorkableSizeMin/Max` (assignment filters)
- `WorkSuitabilityRank`, `bUseMultiWorkType` (rank/multi-type matching)

**Cost relevance:** `AffectSanityValue` is the bridge between worker *work ticking* and the *sanity→event* system (DT_BaseCampWorkerEventDataTable triggers at sanity 40-85). This is the game's built-in "overwork" pressure — not a tuning target for us, but the connection explains why event evaluation rides the management cadence (90s interval), not per-worker.

The assignment *matching* runs on the director tick (significance-gated, count cadence per Addendum C) — the per-worker action only *executes* the chosen work type's action.

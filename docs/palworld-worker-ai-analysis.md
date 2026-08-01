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

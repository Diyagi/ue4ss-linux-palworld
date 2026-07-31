#!/usr/bin/env python3
"""
ServerTuning pak patch — applies the two friend mods' changes to the
extracted Palworld 1.0.2 JSON dumps:

  1. Super Stacks No Lag (Kroos, workshop 3770035710)
     - BP_PalBaseCampManager CDO: BaseCampSignificanceInfoList entries 0-3
       bMergeDropItems false->true (entry 4 already true). Vanilla already has
       the exact 5 entries the mod specifies (distances -1/500/2500/4500/6500,
       ticks 0.1/1.5/2.5/5.0/10.0) — only the flag flips are needed.
     - MergeDropItemRange is NOT serialized in the CDO (C++ default = 500 per
       mod author) — nothing to patch there.

  2. 10x Arena Points and Rewards (XDynis, workshop 3768396763)
     - BP_PalGameSetting CDO: Arena_RankPoint_WinToNPC 50->500,
       Arena_RankPoint_Lose -50->0
     - DT_ArenaSoloRewardTable: 10x Min/Max per tier/reward-type, matched by
       ItemName Key (Rate stays 100.0). Unmatched vanilla entries left intact.

Usage: python3 patch.py <gamedata-root>
Writes patched JSON back in place; then run uassetjson fromjson + repak pack.
"""
import json
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

def load(name):
    with open(name, encoding="utf-8") as f:
        return json.load(f)

def save(name, data):
    with open(name, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

# ---------------------------------------------------------------------------
# Arena reward values from XDArenaRewards.jsonc (10x), keyed by tier.
# Each entry: (ItemName.Key, Min, Max)  — Rate stays 100.0.
# ---------------------------------------------------------------------------
ARENA_REWARDS = {
    "Bronze": {
        "FirstClearReward":  [("PalSphere_Giga", 200, 200), ("BattleTicket", 50, 50)],
        "RepeatClearReward": [("PalSphere_Giga", 10, 20), ("BattleTicket", 10, 10)],
    },
    "Silver": {
        "FirstClearReward":  [("Blueprint_HandGun_Default_2", 10, 10), ("BattleTicket", 100, 100)],
        "RepeatClearReward": [("PalSphere_Tera", 10, 20), ("BattleTicket", 20, 20)],
    },
    "Gold": {
        "FirstClearReward":  [("Blueprint_IronArmorHeat_2", 10, 10), ("BattleTicket", 150, 150)],
        "RepeatClearReward": [("PalSphere_Master", 10, 20), ("BattleTicket", 40, 40)],
    },
    "Platinum": {
        "FirstClearReward":  [("Blueprint_Launcher_Meteor_5", 10, 10), ("BattleTicket", 200, 200)],
        "RepeatClearReward": [("PalSphere_Legend", 10, 20), ("BattleTicket", 60, 60)],
    },
    "Diamond": {
        "FirstClearReward":  [("PalRevive", 50, 50), ("BattleTicket", 250, 250)],
        "RepeatClearReward": [("PalSphere_Ultimate", 10, 20), ("BattleTicket", 80, 80)],
    },
    "Master": {
        "FirstClearReward":  [("BattleTicket", 1000, 1000)],
        "RepeatClearReward": [("PalSphere_Exotic", 10, 20), ("BattleTicket", 100, 200)],
    },
    "Legend": {
        "FirstClearReward":  [("BattleTicket", 2000, 2000)],
        "RepeatClearReward": [("PalSphere_Ancient_2", 10, 20), ("BattleTicket", 150, 250)],
    },
}

def find_prop(prop_list, name):
    for p in prop_list:
        if p.get("Name") == name:
            return p
    return None

def set_prop_value(prop, value):
    prop["Value"] = value

# ---------------------------------------------------------------------------
# 1. BP_PalBaseCampManager — enable drop merging at all significance ranges
# ---------------------------------------------------------------------------
def patch_base_camp(path):
    data = load(path)
    changed = 0
    for export in data.get("Exports", []):
        if export.get("ObjectName") != "Default__BP_PalBaseCampManager_C":
            continue
        lst = find_prop(export.get("Data", []), "BaseCampSignificanceInfoList")
        if not lst:
            print("  !! BaseCampSignificanceInfoList not found in CDO")
            continue
        for idx, entry in enumerate(lst.get("Value", [])):
            fields = entry.get("Value", [])
            merge = find_prop(fields, "bMergeDropItems")
            if merge is None:
                print(f"  !! entry {idx}: bMergeDropItems missing")
                continue
            if merge.get("Value") is False:
                merge["Value"] = True
                changed += 1
                print(f"  entry {idx}: bMergeDropItems false->true")
            else:
                print(f"  entry {idx}: bMergeDropItems already true")
    save(path, data)
    print(f"BaseCamp patch: {changed} flag(s) flipped")

# ---------------------------------------------------------------------------
# 2. BP_PalGameSetting — arena rank points
# ---------------------------------------------------------------------------
def patch_game_setting(path):
    data = load(path)
    changed = 0
    for export in data.get("Exports", []):
        if export.get("ObjectName") != "Default__BP_PalGameSetting_C":
            continue
        for prop in export.get("Data", []):
            if prop.get("Name") == "Arena_RankPoint_WinToNPC" and prop.get("Value") != 500:
                print(f"  Arena_RankPoint_WinToNPC: {prop.get('Value')} -> 500")
                prop["Value"] = 500
                changed += 1
            elif prop.get("Name") == "Arena_RankPoint_Lose" and prop.get("Value") != 0:
                print(f"  Arena_RankPoint_Lose: {prop.get('Value')} -> 0")
                prop["Value"] = 0
                changed += 1
    save(path, data)
    print(f"GameSetting patch: {changed} value(s) changed")

# ---------------------------------------------------------------------------
# 3. DT_ArenaSoloRewardTable — 10x rewards matched by ItemName Key
# ---------------------------------------------------------------------------
def patch_arena_table(path):
    data = load(path)
    matched, unmatched = 0, []
    table = data["Exports"][0]["Table"]["Data"]
    for row in table:
        tier = row.get("Name")
        if tier not in ARENA_REWARDS:
            continue
        wanted = ARENA_REWARDS[tier]
        for field in row.get("Value", []):
            fname = field.get("Name")
            if fname not in ("FirstClearReward", "RepeatClearReward"):
                continue
            for reward in field.get("Value", []):
                item_name = None
                for sub in reward.get("Value", []):
                    if sub.get("Name") == "ItemName":
                        for k in sub.get("Value", []):
                            if k.get("Name") == "Key":
                                item_name = k.get("Value")
                if item_name is None:
                    unmatched.append(f"{tier}.{fname}:<no-item-name>")
                    continue
                # find wanted spec for this item in this reward list
                spec = next((w for w in wanted[fname] if w[0] == item_name), None)
                if spec is None:
                    unmatched.append(f"{tier}.{fname}:{item_name} (not in mod spec)")
                    continue
                for sub in reward.get("Value", []):
                    if sub.get("Name") == "Min" and sub.get("Value") != spec[1]:
                        print(f"  {tier}.{fname}.{item_name} Min: {sub.get('Value')} -> {spec[1]}")
                        sub["Value"] = spec[1]
                    elif sub.get("Name") == "Max" and sub.get("Value") != spec[2]:
                        print(f"  {tier}.{fname}.{item_name} Max: {sub.get('Value')} -> {spec[2]}")
                        sub["Value"] = spec[2]
                matched += 1
    save(path, data)
    print(f"Arena table patch: {matched} reward(s) updated")
    if unmatched:
        print(f"  unmatched (left vanilla): {unmatched}")

if __name__ == "__main__":
    print("=== 1. BaseCamp (Super Stacks No Lag) ===")
    patch_base_camp(os.path.join(ROOT, "Pal/Content/Pal/Blueprint/System/BP_PalBaseCampManager.json"))
    print("=== 2. GameSetting (Arena points) ===")
    patch_game_setting(os.path.join(ROOT, "Pal/Content/Pal/Blueprint/System/BP_PalGameSetting.json"))
    print("=== 3. Arena reward table (10x) ===")
    patch_arena_table(os.path.join(ROOT, "Pal/Content/Pal/DataTable/Arena/DT_ArenaSoloRewardTable.json"))
    print("DONE")

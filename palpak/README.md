# palpak — Palworld Linux server pak-mod build toolchain

Reproducible builder for the live-server tuning pak **`ServerTuning_P.pak`**,
which applies two friend-requested mods as native engine-level data patches
(no hooks, no UE4SS, deterministic failure mode):

| Mod | Source | What it patches |
|---|---|---|
| Super Stacks No Lag (Kroos, WS 3770035710) | `patch.py` §1 | `BP_PalBaseCampManager` CDO: `BaseCampSignificanceInfoList[0..3].bMergeDropItems` false→true (entry 4 already true). Vanilla already ships the mod's exact 5 entries (distances -1/500/2500/4500/6500, ticks 0.1/1.5/2.5/5.0/10.0) — only the flags flip. `MergeDropItemRange` is **not serialized** in the CDO (C++ default 500), so nothing to patch there. |
| 10x Arena Points and Rewards (Fox/XDynis, WS 3768396763) | `patch.py` §2–3 | `BP_PalGameSetting` CDO: `Arena_RankPoint_WinToNPC` 50→500, `Arena_RankPoint_Lose` −50→0. `DT_ArenaSoloRewardTable`: all 7 tiers ×10 rewards (26 rows updated, matched by ItemName Key; vanilla rows not in the mod spec are left untouched). |

## Why paks instead of the original mods
Both workshop mods are **PalSchema config-only** (jsonc patches to BP defaults),
but PalSchema itself is a Windows-only UE4SS DLL (`dlls/main.dll` PE32+). The
Linux BlackBook fork loads Lua / Linux `.so` mods only, so the mods were inert
as shipped. A pak patch bakes the *same values* into the cooked uassets —
native engine loading, no hooks, no crash class, works on the Linux binary.

## Toolchain (pinned — see lib-1 research)
| Tool | Version | Notes |
|---|---|---|
| repak | v0.2.3 | `--version V11` is **mandatory** (default is V8B, wrong for UE5.1) |
| UAssetAPI | v1.1.0 (net8.0) | Library-only; build the 40-line `uassetjson` wrapper in `toolchain/uassetjson/` |
| Mappings.usmap | PalworldModding/UsefulFiles @ `42cf396` ("1.0") | Must match game build; 1.0.2.101103 hotfix has no struct changes |
| .NET | 8.0 | `dotnet-install.sh --channel 8.0` |

## Build
```bash
# once: install toolchain (see build.sh header for paths)
GAME_PAK=/path/to/Pal-LinuxServer.pak ./build.sh
# -> out/ServerTuning_P.pak
```

## Deploy
```bash
mkdir -p <server>/Pal/Content/Paks/~mods
cp out/ServerTuning_P.pak <server>/Pal/Content/Paks/~mods/   # chown 1000:1000
# restart the server — the game mounts the pak at boot (verify: atime on the
# pak jumps to boot time, or the process holds an fd on it)
```

## Verification
- Byte-identical roundtrip sanity: dump → `fromjson` → compare sha256. The
  `.uexp` must be byte-identical; `.uasset` may differ only in header
  normalization for CDO patches (documented UAssetAPI behavior — validate in-game).
- Mount proof: after restart, the game process holds an fd on
  `~mods/ServerTuning_P.pak` (or the pak's atime == boot time).
- Game version must match the build source: `repak list` the game pak's target
  assets and confirm the server REST `/v1/api/info` version matches the usmap.

## Rebuild after a game update
1. Re-check `PalworldModding/UsefulFiles` HEAD — mappings are regenerated per version.
2. Re-extract `gamedata/` from the new `Pal-LinuxServer.pak`.
3. Re-run `build.sh` — `patch.py` is value-based (matches by property name /
   ItemName Key), so it adapts unless Pocketpair renames things.

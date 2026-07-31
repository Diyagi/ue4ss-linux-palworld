#!/usr/bin/env bash
# =============================================================================
# palpak/build.sh — reproducible Palworld Linux pak-mod build pipeline
#
# Builds ServerTuning_P.pak: Super Stacks No Lag + 10x Arena Rewards,
# from the server's own Pal-LinuxServer.pak (no network game files needed).
#
# Pipeline: extract -> uassetjson tojson -> patch.py -> uassetjson fromjson
#           -> repak pack --version V11 -> out/ServerTuning_P.pak
#
# Requirements (one-time):
#   - repak v0.2.3  -> place binary at $TOOLCHAIN/repak
#   - dotnet 8      -> place at $TOOLCHAIN/dotnet/dotnet (or on PATH)
#   - UAssetAPI v1.1.0 -> $TOOLCHAIN/UAssetAPI (git clone --branch v1.1.0)
#   - uassetjson wrapper -> build once: see toolchain/uassetjson/
#   - Mappings.usmap (Palworld 1.0.x, PalworldModding/UsefulFiles) -> $TOOLCHAIN/../mappings/Mappings.usmap
#
# Usage:
#   GAME_PAK=/path/to/Pal-LinuxServer.pak ./build.sh [--keep]
#   --keep  keep intermediate JSON dumps under work/gamedata (for inspection)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN="${TOOLCHAIN:-$HERE/toolchain}"
GAME_PAK="${GAME_PAK:?set GAME_PAK=/path/to/Pal-LinuxServer.pak}"
USMAP="${USMAP:-$HERE/mappings/Mappings.usmap}"
KEEP="${1:-}"

UJ="$TOOLCHAIN/uassetjson/bin/Release/net8.0/uassetjson"
DOTNET="$TOOLCHAIN/dotnet/dotnet"
export PATH="$TOOLCHAIN/dotnet:$PATH"
export DOTNET_ROOT="$TOOLCHAIN/dotnet"

TARGETS=(
  "Pal/Content/Pal/Blueprint/System/BP_PalGameSetting"
  "Pal/Content/Pal/Blueprint/System/BP_PalBaseCampManager"
  "Pal/Content/Pal/DataTable/Arena/DT_ArenaSoloRewardTable"
)

echo "==> [1/5] extracting targets from $GAME_PAK"
rm -rf work; mkdir -p work/gamedata
"$TOOLCHAIN/repak" unpack -o work/gamedata \
  --include "Pal/Content/Pal/Blueprint/System/BP_PalGameSetting.*" \
  --include "Pal/Content/Pal/Blueprint/System/BP_PalBaseCampManager.*" \
  --include "Pal/Content/Pal/DataTable/Arena/DT_ArenaSoloRewardTable.*" \
  "$GAME_PAK" > /dev/null

echo "==> [2/5] dumping JSON (usmap: $USMAP)"
for t in "${TARGETS[@]}"; do
  "$UJ" tojson "work/gamedata/$t.uasset" "work/gamedata/$t.json" "$USMAP" > /dev/null
done

echo "==> [3/5] applying patches (patch.py)"
python3 "$HERE/patch.py" work/gamedata

echo "==> [4/5] writing back uassets"
mkdir -p staging/Pal/Content/Pal/Blueprint/System staging/Pal/Content/Pal/DataTable/Arena
for t in "${TARGETS[@]}"; do
  "$UJ" fromjson "work/gamedata/$t.json" "staging/$t.uasset" > /dev/null
done

echo "==> [5/5] packing ServerTuning_P.pak (V11 — mandatory for UE5.1)"
mkdir -p out
"$TOOLCHAIN/repak" pack --version V11 staging/ out/ServerTuning_P.pak
"$TOOLCHAIN/repak" list out/ServerTuning_P.pak

if [ "$KEEP" != "--keep" ]; then
  rm -rf work
fi

echo "DONE: out/ServerTuning_P.pak"
echo "Deploy: cp out/ServerTuning_P.pak <server>/Pal/Content/Paks/~mods/ && restart"

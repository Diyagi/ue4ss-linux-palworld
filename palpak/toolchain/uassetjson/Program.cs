using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// uassetjson — tiny headless wrapper over UAssetAPI (net8.0 library).
// CLI:
//   uassetjson tojson   <in.uasset> <out.json> [mappings.usmap]
//   uassetjson fromjson <in.json>   <out.uasset>
// Mappings path is optional; passed as a file path positional.
// Pattern verified from morgannito/palworld-mods (tools/UassetJson).

int Main(string[] args)
{
    if (args.Length < 3)
    {
        Console.Error.WriteLine("usage: uassetjson <tojson|fromjson> <in> <out> [mappings.usmap]");
        return 1;
    }

    var mode = args[0];
    try
    {
        if (mode == "tojson")
        {
            Usmap mappings = args.Length > 3 ? new Usmap(args[3]) : null;
            var asset = new UAsset(args[1], EngineVersion.VER_UE5_1, mappings);
            File.WriteAllText(args[2], asset.SerializeJson(true));
            Console.WriteLine($"tojson: {args[1]} -> {args[2]}");
        }
        else if (mode == "fromjson")
        {
            var asset = UAsset.DeserializeJson(File.ReadAllText(args[1]));
            asset.Write(args[2]);
            Console.WriteLine($"fromjson: {args[1]} -> {args[2]}");
        }
        else
        {
            Console.Error.WriteLine($"unknown mode: {mode}");
            return 1;
        }
    }
    catch (Exception e)
    {
        Console.Error.WriteLine($"ERROR: {e.Message}");
        return 1;
    }
    return 0;
}

return Main(args);

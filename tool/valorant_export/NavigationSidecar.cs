using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Assets.Exports.NavigationSystem;
using CUE4Parse.UE4.Objects.NavigationSystem.NavMesh;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

// CUE4Parse deliberately omits FRecastTileData.Tile from its ordinary JSON.
// Preserve the already-parsed geometry separately; do not patch the parser.
static class NavigationSidecar
{
    public static void Write(UObject[] objects, string output, string packagePath)
    {
        var meshes = new List<object>();
        foreach (var value in objects)
        {
            if (value is URecastNavMeshDataChunk chunk)
            {
                var properties = JObject.Parse(JsonConvert.SerializeObject(chunk))["Properties"];
                meshes.Add(new
                {
                    name = chunk.Name,
                    navigationDataName = properties?.Value<string>("NavigationDataName"),
                    version = (int)chunk.NavMeshVersion,
                    tiles = chunk.Tiles.Where(tile => tile.IsValid).Select(tile => tile.Tile).ToArray()
                });
            }
            else if (value is ARecastNavMesh mesh && mesh.RecastNavMeshImpl is { } impl)
            {
                meshes.Add(new
                {
                    name = mesh.Name,
                    navigationDataName = mesh.Name,
                    version = (int)mesh.NavMeshVersion,
                    parameters = impl.DetourNavMeshParams,
                    tiles = impl.DetourMeshTiles.Where(tile => tile.IsValid).Select(tile => tile.Tile).ToArray()
                });
            }
        }
        if (meshes.Count == 0) return;
        var path = Path.Combine(output, "navigation", Path.ChangeExtension(packagePath, ".json"));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonConvert.SerializeObject(new
        {
            schemaVersion = 1, packagePath,
            coordinates = "Unreal Recast coordinates in centimetres; convert (-x,-z,y) to Unreal (X,Y,Z).",
            meshes
        }, Formatting.Indented));
    }
}

using System.Reflection;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Assets.Exports.Component.StaticMesh;
using CUE4Parse.UE4.Objects.Core.Math;
using Newtonsoft.Json;

// Preserve the serialized matrix before the parser decomposes and approximately
// normalizes it. The independent verifier applies Unreal's physics transform.
internal static class InstanceTransformSidecar
{
    public static void Write(UObject[] objects, string output, string package)
    {
        var field = typeof(FInstancedStaticMeshInstanceData).GetField("Transform", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidDataException("Pinned parser no longer retains serialized instance matrices.");
        var records = new List<object>();
        for (var index = 0; index < objects.Length; index++)
        {
            if (objects[index] is not UInstancedStaticMeshComponent component || component.PerInstanceSMData is null) continue;
            var instances = component.PerInstanceSMData.Select(instance =>
            {
                var m = field.GetValue(instance) as FMatrix
                    ?? throw new InvalidDataException("Serialized instance matrix is unavailable.");
                return new[] { m.M00, m.M01, m.M02, m.M03, m.M10, m.M11, m.M12, m.M13,
                    m.M20, m.M21, m.M22, m.M23, m.M30, m.M31, m.M32, m.M33 };
            }).ToArray();
            records.Add(new { objectIndex = index, name = component.Name, instances });
        }
        var file = Path.Combine(output, "instance-transforms", Path.ChangeExtension(package, ".json"));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, JsonConvert.SerializeObject(records, Formatting.Indented));
    }
}

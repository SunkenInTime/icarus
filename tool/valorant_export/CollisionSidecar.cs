using System.Security.Cryptography;
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Objects.PhysicsEngine;
using Newtonsoft.Json;

// Preserve cooked collision bytes separately from the parser's metadata JSON.
// Geometry interpretation belongs to the offline verifier.
internal static class CollisionSidecar
{
    public static void Write(UObject[] objects, string output, string package)
    {
        var folder = Path.Combine(output, "collision", Path.ChangeExtension(package, null));
        var records = new List<object>();
        var bodies = objects.OfType<UBodySetup>().ToArray();
        Directory.CreateDirectory(folder);
        // Explicitly distinguish an inspected body with no cooked formats from
        // a missing export. Consumers must never infer this from absent files.
        File.WriteAllText(Path.Combine(folder, "bodies.json"), JsonConvert.SerializeObject(
            bodies.Select(body => new { body = body.Name,
                formats = body.CookedFormatData?.Formats.Keys.Select(format => format.Text).ToArray() ?? [] }),
            Formatting.Indented));
        foreach (var body in bodies)
        {
            if (body.CookedFormatData is null) continue;
            foreach (var (format, bulk) in body.CookedFormatData.Formats)
            {
                var bytes = bulk.Data ?? throw new InvalidDataException("Cooked collision payload is missing.");
                if (bytes.Length != bulk.Header.ElementCount)
                    throw new InvalidDataException("Cooked collision payload length differs from metadata.");
                var name = body.Name + "." + format.Text + ".bin";
                if (name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                    throw new InvalidDataException("Invalid collision object name.");
                Directory.CreateDirectory(folder);
                File.WriteAllBytes(Path.Combine(folder, name), bytes);
                records.Add(new { body = body.Name, format = format.Text, file = name,
                    bytes = bytes.Length, sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) });
            }
        }
        if (records.Count == 0) return;
        File.WriteAllText(Path.Combine(folder, "index.json"), JsonConvert.SerializeObject(records, Formatting.Indented));
    }

    public static void WriteConfiguration(DefaultFileProvider provider, string output)
    {
        // Record only the two collision-related sections, plus whole-file hashes.
        var names = new[] { "Engine/Config/BaseEngine.ini", "Engine/Config/Windows/BaseWindowsEngine.ini",
            "Engine/Config/Windows/WindowsEngine.ini", "ShooterGame/Config/DefaultEngine.ini",
            "ShooterGame/Config/Windows/WindowsEngine.ini" };
        var records = new List<object>();
        foreach (var name in names)
        {
            if (!provider.TrySaveAsset(name, out var bytes))
                throw new InvalidDataException("Missing collision configuration: " + name);
            var lines = new List<string>();
            var relevant = false;
            using var reader = new StreamReader(new MemoryStream(bytes));
            while (reader.ReadLine() is { } line)
            {
                if (line.TrimStart().StartsWith('['))
                    relevant = line.Trim() is "[/Script/Engine.PhysicsSettings]" or "[/Script/Engine.CollisionProfile]";
                if (relevant) lines.Add(line);
            }
            records.Add(new { source = name, sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)), lines });
        }
        File.WriteAllText(Path.Combine(output, "collision-configuration.json"),
            JsonConvert.SerializeObject(records, Formatting.Indented));
    }
}

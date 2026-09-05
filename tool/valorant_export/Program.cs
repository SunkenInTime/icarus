// Read-only game extraction. Raw game assets and settings stay outside the repo.
using System.Collections.Concurrent;
using System.Security.Cryptography;
using CUE4Parse;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Objects.Engine;
using CUE4Parse.UE4.Versions;
using CUE4Parse.UE4.Assets.Exports.Material;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using CUE4Parse_Conversion.Textures.BC;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Serilog;
using Serilog.Core;
using Serilog.Events;

if (args.Length != 5)
{
    Console.Error.WriteLine("Usage: ValorantExport SETTINGS.json MAPPING.usmap OODLE.dll SELECTION.json NEW_OUTPUT_DIRECTORY");
    return 64;
}
var settings = JObject.Parse(File.ReadAllText(args[0]));
var gameDirectory = Path.GetFullPath(settings.Value<string>("GameDirectory")!);
var output = Path.GetFullPath(args[4]);
if (output.StartsWith(gameDirectory, StringComparison.OrdinalIgnoreCase) ||
    (Directory.Exists(output) && Directory.EnumerateFileSystemEntries(output).Any()))
    throw new InvalidOperationException("Use a new, empty output directory outside the game installation.");
Directory.CreateDirectory(output);
var selection = JObject.Parse(File.ReadAllText(args[3]));
var sink = new AuditSink();
Log.Logger = new LoggerConfiguration().MinimumLevel.Warning().WriteTo.Sink(sink).CreateLogger();
CUE4ParseLog.UseLogger(Log.Logger);
var mappingPath = Path.GetFullPath(args[1]);
OodleHelper.Initialize(Path.GetFullPath(args[2]));
var detexPath = Path.Combine(output, "Detex.dll");
if (!await DetexHelper.LoadDllAsync(detexPath))
    throw new InvalidOperationException("Could not load the parser's embedded texture decoder.");
DetexHelper.Initialize(detexPath);
using var provider = new DefaultFileProvider(gameDirectory, SearchOption.TopDirectoryOnly,
    new VersionContainer(EGame.GAME_Valorant), StringComparer.OrdinalIgnoreCase);
provider.MappingsContainer = new FileUsmapTypeMappingsProvider(mappingPath);
provider.ReadShaderMaps = false;
provider.ReadNaniteData = true;
// Match FModel: inherited defaults can change visibility and material modes.
PropertyUtil.SearchPropertyInTemplate = true;
provider.Initialize();
// Read the key from FModel's existing local settings; never log or serialize it.
var localGame = settings["PerDirectory"]![settings.Value<string>("GameDirectory")!]!;
provider.SubmitKey(new FGuid(), new FAesKey(localGame["AesKeys"]!.Value<string>("mainKey")!));
provider.PostMount();
provider.LoadVirtualPaths(EGame.GAME_Valorant.GetVersion());
var initializationWarnings = sink.Warnings;
File.WriteAllLines(Path.Combine(output, "package-index.txt"), provider.Files.Keys.Order());
var results = new List<object>();
foreach (var token in selection["properties"] ?? new JArray())
{
    var packagePath = token.Value<string>()!;
    if (!packagePath.StartsWith("ShooterGame/Content/", StringComparison.Ordinal) || packagePath.Contains(".."))
        throw new InvalidDataException($"Invalid package path: {packagePath}");
    var before = sink.Errors;
    try
    {
        var objects = provider.LoadPackage(packagePath).GetExports().ToArray();
        var json = JsonConvert.SerializeObject(objects, Formatting.Indented);
        var file = Path.Combine(output, "properties", Path.ChangeExtension(packagePath, ".json"));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, json);
        results.Add(new { packagePath, objects = objects.Length, errors = sink.Errors - before, sha256 = Hash(file) });
        Console.WriteLine($"Properties: {packagePath}, {objects.Length} objects, {sink.Errors - before} errors");
    }
    catch (Exception ex)
    {
        sink.RecordFailure(packagePath, ex);
        results.Add(new { packagePath, failed = true, error = ex.Message });
        Console.WriteLine($"FAILED: {packagePath}");
    }
}
var streamed = new ConcurrentBag<object>();
var session = new ExportSession((levels, _) =>
{
    foreach (var level in levels.StreamingLevels)
        streamed.Add(new { parent = levels.WorldName, path = level.World.GetPathName(), selected = level.IsPersistent });
}) { MaxDegreeOfParallelism = Math.Min(8, Environment.ProcessorCount) };
foreach (var token in selection["worlds"] ?? new JArray())
{
    var packagePath = token.Value<string>()!;
    var world = provider.LoadPackage(packagePath).GetExports().OfType<UWorld>().Single();
    session.Add(world);
}
var exports = session.HasQueuedItems
    ? await session.RunAsync(Path.Combine(output, "Exports"), new ExportOptions(
        meshFormat: EMeshFormat.USD, naniteMeshFormat: ENaniteMeshFormat.NaniteOnly,
        materialDepth: EMaterialDepth.AllLayers, exportMaterials: true))
    : [];
var failures = exports.Count(e => !e.Success);
var report = new
{
    schemaVersion = 1,
    status = sink.Errors == 0 && failures == 0 ? "parsed-without-errors" : "parse-or-export-failure",
    gameplayVerified = false,
    expectedParserCommit = "91e1da69d3341f5777f2307bd712498b6bdc05dc",
    parserAssemblySha256 = Hash(typeof(DefaultFileProvider).Assembly.Location),
    conversionAssemblySha256 = Hash(typeof(ExportSession).Assembly.Location),
    toolAssemblySha256 = Hash(typeof(AuditSink).Assembly.Location),
    mapping = new { path = mappingPath, sha256 = Hash(mappingPath) },
    selectionSha256 = Hash(args[3]),
    archives = Directory.EnumerateFiles(gameDirectory, "*.utoc").Select(p => new { name = Path.GetFileName(p), sha256 = Hash(p) }).ToArray(),
    properties = results,
    streamedLevels = streamed.OrderBy(x => JsonConvert.SerializeObject(x)).ToArray(),
    exports = exports.Select(e => new { e.ObjectPath, e.Success, files = e.DiskFilePaths, error = e.Error?.Message }),
    exportCount = exports.Count, failedExports = failures,
    errorEntries = sink.Errors, warnings = sink.Warnings,
    initializationWarnings, extractionWarnings = sink.Warnings - initializationWarnings,
    diagnostics = sink.Entries.ToArray()
};
File.WriteAllText(Path.Combine(output, "extraction-audit.json"), JsonConvert.SerializeObject(report, Formatting.Indented));
Console.WriteLine($"Exported {exports.Count} items; failed {failures}; errors {sink.Errors}; warnings {sink.Warnings}");
return sink.Errors == 0 && failures == 0 ? 0 : 1;

static string Hash(string path)
{
    using var stream = File.OpenRead(path);
    return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
}

sealed class AuditSink : ILogEventSink
{
    private int errors, warnings;
    public int Errors => Volatile.Read(ref errors);
    public int Warnings => Volatile.Read(ref warnings);
    public ConcurrentQueue<object> Entries { get; } = new();
    public void Emit(LogEvent e)
    {
        if (e.Level >= LogEventLevel.Error) Interlocked.Increment(ref errors);
        else if (e.Level == LogEventLevel.Warning) Interlocked.Increment(ref warnings);
        Entries.Enqueue(new { level = e.Level.ToString(), message = e.RenderMessage(), exception = e.Exception?.ToString() });
    }
    public void RecordFailure(string package, Exception ex)
    {
        Interlocked.Increment(ref errors);
        Entries.Enqueue(new { level = "Error", package, exception = ex.ToString() });
    }
}

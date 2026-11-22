using System.Text.Json.Nodes;
using Gossip.Shell;
using Xunit;

/// <summary>The shared cases (schema/file-transfer-cases.json) that the Mac and Android rules pass too.</summary>
public class FileTransferRulesTests
{
    private static JsonObject Cases()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "schema", "file-transfer-cases.json"))) dir = dir.Parent;
        return JsonNode.Parse(File.ReadAllText(Path.Combine(dir!.FullName, "schema", "file-transfer-cases.json")))!.AsObject();
    }

    [Fact]
    public void Sanitize()
    {
        var list = Cases()["sanitize"]!.AsArray();
        Assert.NotEmpty(list);
        foreach (var c in list) Assert.Equal((string)c!["name"]!, FileTransferRules.SanitizeName((string)c["raw"]!));
    }

    [Fact]
    public void UniqueNames()
    {
        foreach (var c in Cases()["unique"]!.AsArray())
        {
            var taken = c!["taken"]!.AsArray().Select(x => (string)x!).ToHashSet();
            Assert.Equal((string)c["result"]!, FileTransferRules.UniqueName((string)c["name"]!, taken.Contains));
        }
    }

    [Fact]
    public void Chunks()
    {
        foreach (var c in Cases()["chunks"]!.AsArray())
        {
            var size = (long)c!["size"]!; var chunk = (int)c["chunkSize"]!;
            var count = FileTransferRules.ChunkCount(size, chunk);
            Assert.Equal((int)c["count"]!, count);
            if (count > 0) Assert.Equal((int)c["lastLength"]!, FileTransferRules.ChunkLength(size, chunk, count - 1));
        }
    }

    [Fact]
    public void Resume()
    {
        foreach (var c in Cases()["resume"]!.AsArray())
        {
            var received = c!["received"]!.AsArray().Select(x => (int)x!).ToHashSet();
            Assert.Equal((int)c["next"]!, FileTransferRules.NextIndex(received));
        }
    }

    [Fact]
    public void LongNamesKeepTheirExtension()
    {
        var name = FileTransferRules.SanitizeName(new string('a', 300) + ".pdf");
        Assert.Equal(FileTransferRules.MaxNameLength, name.Length);
        Assert.EndsWith(".pdf", name);
    }
}

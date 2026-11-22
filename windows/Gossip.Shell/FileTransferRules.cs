namespace Gossip.Shell;

/// <summary>The pure rules of file transfer (docs/plans/file-transfer.md), pinned by schema/file-transfer-cases.json and
/// mirrored by the Mac and Android apps.</summary>
public static class FileTransferRules
{
    public const int ChunkSize = 1_048_576;
    public const long MaxFileBytes = 2L * 1024 * 1024 * 1024;
    public const int MaxIncoming = 3;
    public const int MaxNameLength = 120;

    public static string SanitizeName(string raw)
    {
        var last = raw[(raw.LastIndexOfAny(new[] { '/', '\\' }) + 1)..];
        var cleaned = new string(last.Where(c => !char.IsControl(c)).ToArray()).Trim().TrimStart('.').TrimEnd('.', ' ').Trim();
        if (cleaned.Length == 0) return "file";
        if (cleaned.Length <= MaxNameLength) return cleaned;
        var dot = cleaned.LastIndexOf('.');
        var ext = dot > 0 && cleaned.Length - dot <= 16 ? cleaned[dot..] : "";
        return cleaned[..(MaxNameLength - ext.Length)] + ext;
    }

    public static string UniqueName(string name, Func<string, bool> isTaken)
    {
        if (!isTaken(name)) return name;
        var dot = name.LastIndexOf('.');
        var (stem, ext) = dot > 0 ? (name[..dot], name[dot..]) : (name, "");
        for (var n = 2; ; n++)
        {
            var candidate = $"{stem} ({n}){ext}";
            if (!isTaken(candidate)) return candidate;
        }
    }

    public static int ChunkCount(long size, int chunkSize = ChunkSize) => (int)((size + chunkSize - 1) / chunkSize);

    public static int ChunkLength(long size, int chunkSize, int index) =>
        (int)Math.Clamp(size - (long)index * chunkSize, 0, chunkSize);

    public static int NextIndex(ISet<int> received)
    {
        var i = 0;
        while (received.Contains(i)) i++;
        return i;
    }
}

using System.Text.Json;
using System.Text.Json.Nodes;
using uniffi.gossip_ffi;

namespace Gossip.Shell;

internal sealed record NotificationButton(int Index, string Title);

/// <summary>A live notification (progress, timer, call), drawn instead of static text.</summary>
internal sealed record NotificationLiveInfo(string Kind, int? Progress, int? Max, bool Indeterminate, long? ChronometerBase);

/// <summary>A `notification.posted` message, parsed. Everything past id/title/body is optional and older phones omit it.</summary>
internal sealed record MirroredNotification(
    string Id, string SourceDeviceId, string AppName, string Title, string Body, bool HasReply,
    string? IconBase64, string? AvatarBase64, string? PictureBase64,
    IReadOnlyList<NotificationButton> Buttons, IReadOnlyList<string> SmartReplies, NotificationLiveInfo? Live)
{
    public static MirroredNotification? Parse(string kind, string senderId, string payloadJson)
    {
        if (kind != "notification.posted") return null;
        try
        {
            using var doc = JsonDocument.Parse(payloadJson);
            var r = doc.RootElement;
            string? Str(string name) => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            var id = Str("id");
            if (string.IsNullOrEmpty(id)) return null;
            var title = Str("title") ?? "";
            var body = Str("body") ?? "";
            var live = ParseLive(r);
            if (title.Length == 0 && body.Length == 0 && live == null) return null;
            var buttons = new List<NotificationButton>();
            if (r.TryGetProperty("actions", out var acts) && acts.ValueKind == JsonValueKind.Array)
                foreach (var a in acts.EnumerateArray())
                    if (a.TryGetProperty("index", out var i) && i.TryGetInt32(out var index) && a.TryGetProperty("title", out var t) && t.ValueKind == JsonValueKind.String)
                        buttons.Add(new NotificationButton(index, t.GetString() ?? ""));
            var smart = new List<string>();
            if (r.TryGetProperty("smartReplies", out var sr) && sr.ValueKind == JsonValueKind.Array)
                smart.AddRange(sr.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).Where(x => x.Length > 0));
            return new MirroredNotification(id, senderId, Str("appName") ?? "", title, body,
                r.TryGetProperty("hasReplyAction", out var h) && h.ValueKind == JsonValueKind.True,
                Str("iconBase64"), Str("avatarBase64"), Str("pictureBase64"), buttons, smart, live);
        }
        catch (JsonException) { return null; }
    }

    private static NotificationLiveInfo? ParseLive(JsonElement root)
    {
        if (!root.TryGetProperty("live", out var l) || l.ValueKind != JsonValueKind.Object) return null;
        var kind = l.TryGetProperty("kind", out var k) && k.ValueKind == JsonValueKind.String ? k.GetString() : null;
        if (kind == null) return null;
        int? Int(string n) => l.TryGetProperty(n, out var v) && v.TryGetInt32(out var i) ? i : null;
        return new NotificationLiveInfo(kind, Int("progress"), Int("max"),
            l.TryGetProperty("indeterminate", out var ind) && ind.ValueKind == JsonValueKind.True,
            l.TryGetProperty("chronometerBase", out var c) && c.TryGetInt64(out var cb) ? cb : null);
    }

    /// <summary>The title line: "App: Title", or whichever of the two exists.</summary>
    public string Heading => AppName.Length > 0 && Title.Length > 0 ? $"{AppName}: {Title}" : AppName.Length > 0 ? AppName : Title;

    /// <summary>"42%" for a progress notification, or null.</summary>
    public string? ProgressText => Live is { Kind: "progress", Progress: { } p, Max: { } m } && m > 0 ? $"{Math.Clamp(p * 100 / m, 0, 100)}%" : null;
}

/// <summary>The payloads of the messages sent back to the phone. Each button press gets a fresh attempt id (the phone de-duplicates on it).</summary>
internal static class NotificationReplies
{
    public static string Reply(string id, string text) => GossipFfiMethods.NotificationReplyPayload(id, text, Guid.NewGuid().ToString());

    public static string Action(string id, int index) =>
        new JsonObject { ["id"] = id, ["index"] = index, ["attemptId"] = Guid.NewGuid().ToString() }.ToJsonString();

    public static string Dismiss(string id) => new JsonObject { ["id"] = id }.ToJsonString();
}

/// <summary>What a press on a toast means: the message to send back to the phone, if any.</summary>
internal static class ToastAnswers
{
    public readonly record struct Answer(string Kind, string RecipientId, string PayloadJson);

    /// <param name="args">The arguments baked into the toast and the pressed button (<c>id</c>, <c>src</c>, <c>action</c>, ...).</param>
    /// <param name="input">What the user typed into the toast's input boxes, by id.</param>
    public static Answer? Route(IReadOnlyDictionary<string, string> args, IReadOnlyDictionary<string, string> input)
    {
        if (!args.TryGetValue("id", out var id) || id.Length == 0 || !args.TryGetValue("src", out var src) || src.Length == 0) return null;
        switch (args.GetValueOrDefault("action"))
        {
            case "reply":
                return input.TryGetValue("reply", out var text) && text.Trim().Length > 0
                    ? new Answer("notification.reply", src, NotificationReplies.Reply(id, text))
                    : null;
            case "smart":
                return args.TryGetValue("text", out var smart) && smart.Length > 0
                    ? new Answer("notification.reply", src, NotificationReplies.Reply(id, smart))
                    : null;
            case "button":
                return args.TryGetValue("index", out var raw) && int.TryParse(raw, out var index)
                    ? new Answer("notification.action", src, NotificationReplies.Action(id, index))
                    : null;
            default:
                return null;
        }
    }
}

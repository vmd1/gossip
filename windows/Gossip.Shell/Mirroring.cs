using System.Text.Json;
using uniffi.gossip_ffi;

namespace Gossip.Shell;

/// <summary>Turns messages from the phone into things shown on this PC: notification balloons and battery levels.</summary>
internal static class Mirroring
{
    /// <summary>A `notification.posted` message as a title and a body, or null if it is not one or has nothing to show.</summary>
    public static (string Title, string Body)? NotificationText(string kind, string payloadJson)
    {
        if (kind != "notification.posted") return null;
        try
        {
            using var doc = JsonDocument.Parse(payloadJson);
            var root = doc.RootElement;
            string Get(string name) => root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
            var app = Get("appName");
            var title = Get("title");
            var body = Get("body");
            if (title.Length == 0 && body.Length == 0) return null;
            return (app.Length > 0 && title.Length > 0 ? $"{app}: {title}" : app.Length > 0 ? app : title, body);
        }
        catch (JsonException) { return null; }
    }

    /// <summary>The phone's battery as "87%" or "87% · charging", from its `battery.state` slot value.</summary>
    public static string? BatteryText(string? valueJson)
    {
        if (valueJson == null) return null;
        try
        {
            using var doc = JsonDocument.Parse(valueJson);
            var root = doc.RootElement;
            if (!root.TryGetProperty("level", out var level) || level.ValueKind != JsonValueKind.Number) return null;
            var charging = root.TryGetProperty("isCharging", out var c) && c.ValueKind == JsonValueKind.True;
            return $"{level.GetInt32()}%{(charging ? " · charging" : "")}";
        }
        catch (JsonException) { return null; }
    }
}

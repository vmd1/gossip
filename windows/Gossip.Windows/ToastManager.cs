using System.IO;
using System.Security.Cryptography;
using System.Text;
using Gossip.Shell;
using CommunityToolkit.WinUI.Notifications;
using Windows.UI.Notifications;

namespace Gossip.Windows;

/// <summary>
/// Shows the phone's notifications as Windows toasts and sends the user's answers back: an inline reply box, smart-reply
/// and action buttons, and dismissing a toast dismisses the original. A notification posted again with the same id
/// (progress, a timer) updates its toast in place without popping up again.
/// </summary>
internal sealed class ToastManager : IDisposable
{
    private const string Group = "gossip";
    private readonly Node _node;
    private readonly HashSet<string> _shown = new();
    private readonly object _gate = new();
    private readonly string _imageDir = Path.Combine(Path.GetTempPath(), "Gossip", "img");

    public ToastManager(Node node)
    {
        _node = node;
        Directory.CreateDirectory(_imageDir);
        ToastNotificationManagerCompat.OnActivated += OnActivated;
    }

    private static string Tag(string id) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..16];

    public void Show(MirroredNotification n)
    {
        bool update;
        lock (_gate) update = !_shown.Add(n.Id);

        var b = new ToastContentBuilder().AddArgument("id", n.Id).AddArgument("src", n.SourceDeviceId);
        if (n.Heading.Length > 0) b.AddText(n.Heading, hintMaxLines: 1);
        if (n.Body.Length > 0) b.AddText(n.Body);
        if (n.Live is { } live)
        {
            if (live.Kind == "progress" && live.Max is > 0)
                b.AddProgressBar(null, (double)(live.Progress ?? 0) / live.Max.Value, live.Indeterminate, n.ProgressText ?? "", null);
            else if (live.ChronometerBase is { } since)
                b.AddText($"{(live.Kind == "call" ? "Call" : "Timer")} · since {DateTimeOffset.FromUnixTimeMilliseconds(since).ToLocalTime():HH:mm:ss}");
        }
        if (SaveImage(n.AvatarBase64 ?? n.IconBase64) is { } logo) b.AddAppLogoOverride(logo, ToastGenericAppLogoCrop.Circle);
        if (SaveImage(n.PictureBase64) is { } picture) b.AddHeroImage(picture);

        if (n.HasReply) b.AddInputTextBox("reply", "Reply");
        var buttons = 0;
        if (n.HasReply) { b.AddButton(new ToastButton().SetContent("Reply").AddArgument("action", "reply").SetTextBoxId("reply")); buttons++; }
        foreach (var text in n.SmartReplies.Take(2))
        {
            if (!n.HasReply || buttons >= 4) break;
            b.AddButton(new ToastButton().SetContent(text).AddArgument("action", "smart").AddArgument("text", text)); buttons++;
        }
        foreach (var a in n.Buttons)
        {
            if (buttons >= 5) break;
            b.AddButton(new ToastButton().SetContent(a.Title).AddArgument("action", "button").AddArgument("index", a.Index)); buttons++;
        }

        b.Show(toast =>
        {
            toast.Tag = Tag(n.Id);
            toast.Group = Group;
            toast.SuppressPopup = update;
            toast.Dismissed += (_, e) =>
            {
                // Only a swipe or close by the user dismisses the phone's notification (not a timeout into the Action Center).
                if (e.Reason == ToastDismissalReason.UserCanceled) _node.Send("notification.dismiss", n.SourceDeviceId, NotificationReplies.Dismiss(n.Id));
            };
        });
    }

    /// <summary>The phone cleared the notification: take its toast away.</summary>
    public void Remove(string id)
    {
        lock (_gate) _shown.Remove(id);
        try { ToastNotificationManagerCompat.History.Remove(Tag(id), Group); } catch { }
    }

    private void OnActivated(ToastNotificationActivatedEventArgsCompat e)
    {
        var args = ToastArguments.Parse(e.Argument).ToDictionary(kv => kv.Key, kv => kv.Value);
        var input = e.UserInput.Where(kv => kv.Value is string).ToDictionary(kv => kv.Key, kv => (string)kv.Value);
        if (ToastAnswers.Route(args, input) is { } answer) _node.Send(answer.Kind, answer.RecipientId, answer.PayloadJson);
    }

    private Uri? SaveImage(string? base64)
    {
        if (string.IsNullOrEmpty(base64) || base64.Length > 4_000_000) return null;
        try
        {
            var bytes = Convert.FromBase64String(base64);
            var path = Path.Combine(_imageDir, Convert.ToHexString(SHA256.HashData(bytes))[..24] + ".png");
            if (!File.Exists(path)) File.WriteAllBytes(path, bytes);
            return new Uri(path);
        }
        catch { return null; }
    }

    public void Dispose()
    {
        ToastNotificationManagerCompat.OnActivated -= OnActivated;
        try { ToastNotificationManagerCompat.History.Clear(); } catch { }
    }
}

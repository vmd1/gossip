using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Gossip.Shell;
using uniffi.gossip_ffi;

namespace Gossip.Windows;

/// <summary>
/// Messages: the phone's SMS conversations on this PC (messages.* in schema/message-types.md). Queries are pure, so each
/// refresh just asks again and a reply is only used if it answers the latest request. A send keeps one attempt id and
/// is re-sent every 4 s (up to 4 times) until the phone's result arrives, which the phone dedupes.
/// </summary>
internal sealed class MessagesWindow : Window
{
    private sealed record Thread(string Id, string Address, string Title, string Snippet, bool Unread);

    private readonly Node _node;
    private readonly string _phoneId;
    private readonly ListBox _threads = new() { Width = 220 };
    private readonly ListBox _history = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox _address = new() { Margin = new Thickness(0, 0, 0, 6), ToolTip = "Phone number" };
    private readonly TextBox _body = new() { AcceptsReturn = true, Height = 56, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _status = new() { Foreground = System.Windows.Media.Brushes.Gray, Margin = new Thickness(0, 6, 0, 0) };
    private readonly DispatcherTimer _resync = new() { Interval = TimeSpan.FromSeconds(60) };
    private string _threadsRequest = "";
    private string _historyRequest = "";
    private string? _openThread;
    private List<Thread> _list = new();
    private string? _attemptId;
    private int _attempts;
    private readonly DispatcherTimer _retry = new() { Interval = TimeSpan.FromSeconds(4) };

    public MessagesWindow(Node node, string phoneId, string phoneName)
    {
        _node = node;
        _phoneId = phoneId;
        Title = $"Messages · {phoneName}";
        Width = 760;
        Height = 560;
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI");

        var send = new Button { Content = "Send", Padding = new Thickness(18, 6, 18, 6), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Bottom };
        send.Click += (_, _) => Send();
        var compose = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(send, Dock.Right);
        compose.Children.Add(send);
        compose.Children.Add(_body);
        var right = new DockPanel { Margin = new Thickness(12, 0, 0, 0) };
        var top = new StackPanel();
        top.Children.Add(new TextBlock { Text = "To (phone number)", Foreground = System.Windows.Media.Brushes.Gray, FontSize = 12 });
        top.Children.Add(_address);
        DockPanel.SetDock(top, Dock.Top);
        var bottom = new StackPanel();
        bottom.Children.Add(compose);
        bottom.Children.Add(_status);
        DockPanel.SetDock(bottom, Dock.Bottom);
        right.Children.Add(top);
        right.Children.Add(bottom);
        right.Children.Add(_history);
        var root = new DockPanel { Margin = new Thickness(14) };
        DockPanel.SetDock(_threads, Dock.Left);
        root.Children.Add(_threads);
        root.Children.Add(right);
        Content = root;

        _threads.SelectionChanged += (_, _) => { if (_threads.SelectedIndex >= 0 && _threads.SelectedIndex < _list.Count) OpenThread(_list[_threads.SelectedIndex]); };
        _node.Received += OnReceived;
        _node.StateChanged += OnState;
        _resync.Tick += (_, _) => RequestThreads();
        _resync.Start();
        _retry.Tick += (_, _) => Retry();
        Closed += (_, _) => { _node.Received -= OnReceived; _node.StateChanged -= OnState; _resync.Stop(); _retry.Stop(); };
        RequestThreads();
    }

    private void RequestThreads()
    {
        _threadsRequest = Guid.NewGuid().ToString();
        _node.Send("messages.threads_request", _phoneId, JsonSerializer.Serialize(new { requestId = _threadsRequest, limit = 50 }));
    }

    private void RequestHistory()
    {
        if (_openThread == null) return;
        _historyRequest = Guid.NewGuid().ToString();
        _node.Send("messages.history_request", _phoneId, JsonSerializer.Serialize(new { requestId = _historyRequest, threadId = _openThread, limit = 100 }));
    }

    private void OpenThread(Thread t)
    {
        _openThread = t.Id;
        _address.Text = t.Address;
        _history.Items.Clear();
        RequestHistory();
    }

    // The phone republishes counts on a new SMS: that is the cue to refetch.
    private void OnState(string deviceId, string slot, string? _)
    {
        if (deviceId == _phoneId && slot == "messages.state") Dispatcher.BeginInvoke(() => { RequestThreads(); RequestHistory(); });
    }

    private void OnReceived(Envelope env, byte[]? _)
    {
        if (env.SenderId != _phoneId) return;
        if (env.Kind != "messages.threads" && env.Kind != "messages.history" && env.Kind != "messages.send_result") return;
        Dispatcher.BeginInvoke(() =>
        {
            try { Handle(env.Kind, JsonDocument.Parse(env.PayloadJson).RootElement); } catch (Exception) { }
        });
    }

    private void Handle(string kind, JsonElement p)
    {
        switch (kind)
        {
            case "messages.threads":
                if (p.GetProperty("requestId").GetString() != _threadsRequest) return;
                if (!p.TryGetProperty("threads", out var threads)) { _status.Text = Reason(p); return; }
                _status.Text = "";
                _list = threads.EnumerateArray().Select(t =>
                {
                    var address = t.GetProperty("address").GetString() ?? "";
                    var name = t.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
                    return new Thread(t.GetProperty("id").ToString(), address, string.IsNullOrEmpty(name) ? address : name!,
                        t.GetProperty("snippet").GetString() ?? "", t.TryGetProperty("unread", out var u) && u.ValueKind == JsonValueKind.True);
                }).ToList();
                _threads.Items.Clear();
                foreach (var t in _list)
                    _threads.Items.Add(new TextBlock { Text = $"{(t.Unread ? "● " : "")}{t.Title}\n{t.Snippet}", TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(2, 4, 2, 4) });
                if (_openThread != null) _threads.SelectedIndex = _list.FindIndex(t => t.Id == _openThread);
                break;
            case "messages.history":
                if (p.GetProperty("requestId").GetString() != _historyRequest) return;
                if (!p.TryGetProperty("messages", out var messages)) { _status.Text = Reason(p); return; }
                _history.Items.Clear();
                foreach (var m in messages.EnumerateArray().Reverse())
                {
                    var outgoing = m.GetProperty("outgoing").GetBoolean();
                    _history.Items.Add(new TextBlock
                    {
                        Text = m.GetProperty("body").GetString(),
                        TextWrapping = TextWrapping.Wrap,
                        Margin = new Thickness(outgoing ? 60 : 0, 3, outgoing ? 0 : 60, 3),
                        HorizontalAlignment = outgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left,
                        Background = outgoing ? System.Windows.Media.Brushes.LightSkyBlue : System.Windows.Media.Brushes.Gainsboro,
                        Padding = new Thickness(10, 6, 10, 6),
                    });
                }
                if (_history.Items.Count > 0) _history.ScrollIntoView(_history.Items[^1]);
                break;
            case "messages.send_result":
                if (p.GetProperty("attemptId").GetString() != _attemptId) return;
                _retry.Stop();
                _attemptId = null;
                if (p.GetProperty("ok").GetBoolean()) { _status.Text = "Sent"; _body.Clear(); RequestThreads(); RequestHistory(); }
                else _status.Text = $"Not sent: {Reason(p)}";
                break;
        }
    }

    private static string Reason(JsonElement p) => (p.TryGetProperty("reason", out var r) ? r.GetString() : null) switch
    {
        "disabled" => "Messages is switched off on the phone.",
        "no_permission" => "The phone has not allowed SMS access to Gossip.",
        "invalid" => "That number or text isn't valid.",
        _ => "The phone could not do that.",
    };

    private void Send()
    {
        var address = _address.Text.Trim();
        var body = _body.Text.Trim();
        if (address.Length < 3 || body.Length == 0 || _attemptId != null) return;
        _attemptId = Guid.NewGuid().ToString();
        _attempts = 0;
        _status.Text = "Sending…";
        Retry();
        _retry.Start();
    }

    private void Retry()
    {
        if (_attemptId == null) return;
        if (_attempts++ >= 4) { _retry.Stop(); _attemptId = null; _status.Text = "No answer from the phone. Check it is connected."; return; }
        _node.Send("messages.send", _phoneId, JsonSerializer.Serialize(new { attemptId = _attemptId, address = _address.Text.Trim(), body = _body.Text.Trim() }));
    }
}

using System.IO;
using System.Windows.Threading;
using Gossip.Shell;
using Microsoft.Win32;
using uniffi.gossip_ffi;

namespace Gossip.Windows;

/// <summary>
/// Do Not Disturb sync. Windows has no public API for Do Not Disturb, so this reads and writes the setting the Settings
/// app's "Do not disturb" switch uses (<c>NOC_GLOBAL_SETTINGS_TOASTS_ENABLED</c>: 0 means toasts are off, i.e. DND on).
/// The core's <see cref="Dnd"/> decides everything else (echo suppression, first contact, what to publish).
/// </summary>
internal sealed class DndSync : IDisposable
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Notifications\Settings";
    private const string Value = "NOC_GLOBAL_SETTINGS_TOASTS_ENABLED";

    private readonly Node _node;
    private readonly Dispatcher _ui;
    private readonly string _persistPath;
    private readonly Dnd _dnd;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };
    private bool _last;

    public DndSync(Node node, Dispatcher ui, string dataDir)
    {
        _node = node;
        _ui = ui;
        _persistPath = Path.Combine(dataDir, "dnd.expected");
        bool? persisted = null;
        try { if (File.Exists(_persistPath)) persisted = File.ReadAllText(_persistPath).Trim() == "1"; } catch { }
        _dnd = new Dnd(persisted);
        _last = ReadLocal();
        _node.Received += OnReceived;
        _node.StateChanged += OnState;
        _timer.Tick += (_, _) => Poll();
        _timer.Start();
        Apply(_dnd.Start());
    }

    private static bool ReadLocal()
    {
        try { using var k = Registry.CurrentUser.OpenSubKey(Key); return k?.GetValue(Value) is int v && v == 0; }
        catch { return false; }
    }

    private static void WriteLocal(bool enabled)
    {
        try { using var k = Registry.CurrentUser.CreateSubKey(Key); k.SetValue(Value, enabled ? 0 : 1, RegistryValueKind.DWord); }
        catch { }
    }

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    // The setting has no change notification, so it is polled; the core ignores a repeat of a state it already knows.
    private void Poll()
    {
        var now = ReadLocal();
        if (now == _last) return;
        _last = now;
        Apply(_dnd.LocalChanged(now, Now()));
    }

    private void OnReceived(Envelope env, byte[]? _)
    {
        if (env.Kind != "dnd.set") return;
        _ui.BeginInvoke(() => { try { Apply(_dnd.OnSet(env.PayloadJson, Now())); } catch { } });
    }

    private void OnState(string deviceId, string slot, string? valueJson)
    {
        if (slot != GossipFfiMethods.DndSlot() || valueJson == null || deviceId == _node.DeviceId) return;
        _ui.BeginInvoke(() => { try { Apply(_dnd.OnPeerState(deviceId, valueJson, Now())); } catch { } });
    }

    private void Apply(IEnumerable<DndEffect> effects)
    {
        foreach (var effect in effects)
        {
            switch (effect)
            {
                case DndEffect.SetState s: _node.SetState(s.Slot, s.ValueJson); break;
                case DndEffect.ApplyLocal a: WriteLocal(a.Enabled); break; // the next poll sees the change and reports it to the core, which publishes it
                case DndEffect.Persist p:
                    try { if (p.Expected is { } e) File.WriteAllText(_persistPath, e ? "1" : "0"); else File.Delete(_persistPath); } catch { }
                    break;
            }
        }
    }

    public void Dispose()
    {
        _timer.Stop();
        _node.Received -= OnReceived;
        _node.StateChanged -= OnState;
        _dnd.Dispose();
    }
}

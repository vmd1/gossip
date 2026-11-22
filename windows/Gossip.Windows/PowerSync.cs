using System.Windows.Forms;
using System.Windows.Threading;
using Gossip.Shell;
using Microsoft.Win32;
using CommunityToolkit.WinUI.Notifications;
using uniffi.gossip_ffi;

namespace Gossip.Windows;

/// <summary>
/// Battery sync. Publishes this PC's own charge in the <c>battery.state</c> slot (a desktop without a battery publishes
/// nothing) and raises a toast when a peer's battery runs low. The core's <see cref="Battery"/> dedupes unchanged
/// readings and decides when to alert, so this class only reads the power status and shows the toast.
/// </summary>
internal sealed class PowerSync : IDisposable
{
    private readonly Node _node;
    private readonly Dispatcher _ui;
    private readonly Battery _battery = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(60) };
    private readonly string _slot = GossipFfiMethods.BatterySlot();

    public PowerSync(Node node, Dispatcher ui)
    {
        _node = node;
        _ui = ui;
        SystemEvents.PowerModeChanged += OnPowerMode;
        _node.StateChanged += OnState;
        _timer.Tick += (_, _) => Publish();
        _timer.Start();
        Publish();
    }

    private void OnPowerMode(object? sender, PowerModeChangedEventArgs e) => _ui.BeginInvoke(Publish);

    // A periodic re-read as well as the event, so a missed power event can never leave a stale value (the core ignores
    // readings that did not change, and re-sends the slot to every device that connects later).
    private void Publish()
    {
        var status = SystemInformation.PowerStatus;
        BatteryState? reading = null;
        if (!status.BatteryChargeStatus.HasFlag(BatteryChargeStatus.NoSystemBattery) && status.BatteryLifePercent is >= 0f and <= 1f)
            reading = new BatteryState((byte)Math.Round(status.BatteryLifePercent * 100), status.PowerLineStatus == PowerLineStatus.Online);
        if (_battery.Report(reading) is BatteryEffect.SetState set) _node.SetState(set.Slot, set.ValueJson);
    }

    private void OnState(string deviceId, string slot, string? valueJson)
    {
        if (slot != _slot || valueJson == null || deviceId == _node.DeviceId) return;
        try
        {
            foreach (var effect in _battery.OnUpdate(deviceId, valueJson))
            {
                if (effect is not BatteryEffect.LowBattery low) continue;
                var name = _node.Peers().FirstOrDefault(p => p.DeviceId == low.Sender)?.Name ?? "A device";
                new ToastContentBuilder().AddText($"{name} battery is low").AddText($"{low.Level}% left. Plug it in soon.").Show();
            }
        }
        catch (Exception) { }
    }

    public void Dispose()
    {
        _timer.Stop();
        SystemEvents.PowerModeChanged -= OnPowerMode;
        _node.StateChanged -= OnState;
        _battery.Dispose();
    }
}

using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Threading;
using Gossip.Shell;
using uniffi.gossip_ffi;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;

namespace Gossip.Windows;

/// <summary>
/// BLE proximity (docs/ble-proximity-protocol.md): scans for the rotating tags a trusted phone advertises, decides which
/// phones are nearby, and runs lock-on-leave. The core's <see cref="LockOnLeave"/> holds the edge-trigger and cooldown
/// logic; the thresholds here are the same as the Mac's (2 confirming advertisements at RSSI -75 or better to count as
/// nearby, 6 s without one to count as gone).
/// </summary>
internal sealed class ProximityMonitor : IDisposable
{
    private const int RssiThreshold = -75;
    private static readonly TimeSpan LossTimeout = TimeSpan.FromSeconds(6);

    [DllImport("user32.dll")] private static extern bool LockWorkStation();

    private readonly Node _node;
    private readonly Dispatcher _ui;
    private readonly string _keysPath;
    private readonly string _enabledPath;
    private readonly LockOnLeave _lock = new(Array.Empty<string>());
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly BluetoothLEAdvertisementWatcher _watcher = new() { ScanningMode = BluetoothLEScanningMode.Active };
    private readonly object _gate = new();
    private readonly Dictionary<string, byte[]> _keys = new();           // phone id -> beacon key
    private Dictionary<string, List<byte[]>> _tags = new();               // phone id -> tags accepted right now
    private long _tagsBuiltAtWindow = -1;
    private readonly Dictionary<string, int> _confirmations = new();
    private readonly Dictionary<string, DateTime> _lastSeen = new();
    private HashSet<string> _nearby = new();

    public bool LockOnLeaveEnabled { get; private set; }
    public event System.Action? Changed;

    public ProximityMonitor(Node node, Dispatcher ui, string dataDir)
    {
        _node = node;
        _ui = ui;
        _keysPath = Path.Combine(dataDir, "beacon-keys.json");
        _enabledPath = Path.Combine(dataDir, "lock-on-leave.enabled");
        LockOnLeaveEnabled = File.Exists(_enabledPath);
        try
        {
            var saved = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(_keysPath));
            if (saved != null) foreach (var (id, key) in saved) _keys[id] = Convert.FromBase64String(key);
        }
        catch { }
        foreach (var p in _node.Peers()) TakeKey(p.DeviceId, _node.GetState(p.DeviceId, GossipFfiMethods.BeaconKeySlot()));
        _node.StateChanged += OnState;
        _watcher.Received += OnAdvertisement;
        try { _watcher.Start(); } catch (Exception) { /* no Bluetooth radio: proximity simply never reports anyone */ }
        _timer.Tick += (_, _) => Evaluate();
        _timer.Start();
    }

    public bool IsNearby(string deviceId) { lock (_gate) return _nearby.Contains(deviceId); }

    public void SetLockOnLeave(bool enabled)
    {
        LockOnLeaveEnabled = enabled;
        try { if (enabled) File.WriteAllText(_enabledPath, "1"); else File.Delete(_enabledPath); } catch { }
    }

    private void OnState(string deviceId, string slot, string? valueJson)
    {
        if (slot == GossipFfiMethods.BeaconKeySlot()) TakeKey(deviceId, valueJson);
    }

    private void TakeKey(string deviceId, string? valueJson)
    {
        if (valueJson == null) return;
        try
        {
            using var doc = JsonDocument.Parse(valueJson);
            var key = Convert.FromBase64String(doc.RootElement.GetProperty("key").GetString() ?? "");
            if (key.Length != 32) return;
            lock (_gate) { _keys[deviceId] = key; _tagsBuiltAtWindow = -1; }
            try { File.WriteAllText(_keysPath, JsonSerializer.Serialize(_keys.ToDictionary(k => k.Key, k => Convert.ToBase64String(k.Value)))); } catch { }
        }
        catch { }
    }

    private void RebuildTags(long unixSeconds)
    {
        var window = (long)GossipFfiMethods.BleBeaconWindow((ulong)unixSeconds);
        if (window == _tagsBuiltAtWindow) return;
        var trusted = _node.Peers().Where(p => p.Type == "android-phone").Select(p => p.DeviceId).ToHashSet();
        var next = new Dictionary<string, List<byte[]>>();
        foreach (var (id, key) in _keys)
            if (trusted.Contains(id)) next[id] = GossipFfiMethods.BleAcceptableTags(key, (ulong)unixSeconds).ToList();
        _tags = next;
        _tagsBuiltAtWindow = window;
    }

    private void OnAdvertisement(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        foreach (var section in args.Advertisement.ManufacturerData)
        {
            if (section.CompanyId != 0xFFFF || section.Data.Length < 10) continue;
            var data = new byte[section.Data.Length];
            DataReader.FromBuffer(section.Data).ReadBytes(data);
            if (data[0] != 0x43 || data[1] != 0x6E) continue;
            var tag = data.AsSpan(2, 8).ToArray();
            lock (_gate)
            {
                RebuildTags(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                foreach (var (id, tags) in _tags)
                {
                    if (!tags.Any(t => tag.SequenceEqual(t))) continue;
                    if (args.RawSignalStrengthInDBm < RssiThreshold) break; // a weak reading never counts as being seen
                    _confirmations[id] = _confirmations.GetValueOrDefault(id) + 1;
                    _lastSeen[id] = DateTime.UtcNow;
                    break;
                }
            }
        }
    }

    private void Evaluate()
    {
        HashSet<string> now;
        lock (_gate)
        {
            RebuildTags(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            now = new HashSet<string>();
            foreach (var (id, seen) in _lastSeen)
            {
                if (DateTime.UtcNow - seen > LossTimeout) { _confirmations[id] = 0; continue; }
                if (_confirmations.GetValueOrDefault(id) >= 2) now.Add(id);
            }
            if (now.SetEquals(_nearby)) return;
            _nearby = now;
        }
        Changed?.Invoke();
        var armed = _node.Peers()
            .Where(p => _node.GetState(p.DeviceId, GossipFfiMethods.LockOnLeaveSlot()) is { } v && ArmedForMe(v))
            .Select(p => p.DeviceId).ToList();
        if (_lock.NearbyChanged(now.ToArray(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), LockOnLeaveEnabled, armed.ToArray()))
            LockWorkStation();
    }

    private bool ArmedForMe(string valueJson)
    {
        try { return GossipFfiMethods.LockOnLeaveIsArmedFor(valueJson, _node.DeviceId); } catch { return false; }
    }

    public void Dispose()
    {
        _timer.Stop();
        _node.StateChanged -= OnState;
        try { _watcher.Stop(); } catch { }
        _lock.Dispose();
    }
}

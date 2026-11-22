using Gossip.Shell;
using uniffi.gossip_ffi;

namespace Gossip.Windows;

/// <summary>
/// Media remote: shows what a phone (or other device) is playing and sends play/pause/next/previous to it. The core's
/// <see cref="MediaController"/> picks the effective device and builds the command (with its dedupe id).
/// </summary>
internal sealed class MediaRemote : IDisposable
{
    public const string Slot = "media.nowplaying";
    private readonly Node _node;
    private readonly MediaController _media = new();

    /// <summary>Raised (on a worker thread) when the now-playing state changes.</summary>
    public event System.Action? Changed;

    public MediaRemote(Node node)
    {
        _node = node;
        _node.StateChanged += OnState;
        // Pick up anything already published before this object existed.
        foreach (var p in _node.Peers()) Feed(p.DeviceId, _node.GetState(p.DeviceId, Slot));
    }

    private void Feed(string deviceId, string? valueJson)
    {
        try { if (valueJson == null) _media.Forget(deviceId); else _media.OnNowPlaying(deviceId, valueJson); } catch { }
    }

    private void OnState(string deviceId, string slot, string? valueJson)
    {
        if (slot != Slot || deviceId == _node.DeviceId) return;
        Feed(deviceId, valueJson);
        Changed?.Invoke();
    }

    public NowPlaying? Current => _media.NowPlaying();

    public string? DeviceName => _media.EffectiveDevice() is { } id ? _node.Peers().FirstOrDefault(p => p.DeviceId == id)?.Name : null;

    public void Command(MediaAction action)
    {
        var message = _media.Command(action, null, Guid.NewGuid().ToString());
        if (message != null) _node.Send(message.Kind, message.Recipient, message.PayloadJson);
    }

    public void Dispose()
    {
        _node.StateChanged -= OnState;
        _media.Dispose();
    }
}

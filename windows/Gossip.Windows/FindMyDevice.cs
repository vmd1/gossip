using System.IO;
using System.Media;
using System.Windows;
using System.Windows.Threading;
using Gossip.Shell;
using NAudio.CoreAudioApi;
using uniffi.gossip_ffi;

namespace Gossip.Windows;

/// <summary>
/// Find my device, both ways. The core's <see cref="Ring"/> holds every decision (idempotence, the recently-handled
/// ring-id cache, the 30 s auto-stop, the 35 s expiry of "peer is ringing"); this class does the Windows part: loop an
/// alarm at full volume with a Stop window, and send the messages the core asks for.
/// </summary>
internal sealed class FindMyDevice : IDisposable
{
    private readonly Node _node;
    private readonly Dispatcher _ui;
    private readonly Ring _ring = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private SoundPlayer? _player;
    private Window? _alert;
    private (bool Mute, float Volume)? _savedAudio;

    /// <summary>Raised on the UI thread when the set of peers this PC asked to ring changes.</summary>
    public event System.Action? PeersChanged;

    public FindMyDevice(Node node, Dispatcher ui)
    {
        _node = node;
        _ui = ui;
        _timer.Tick += (_, _) => Apply(_ring.Tick(Now()));
        _timer.Start();
        _node.Received += OnReceived;
    }

    public bool IsRinging(string peerId) => _ring.RingingPeers().Contains(peerId);

    /// <summary>The bell button on a device row: asks the peer to ring, or to stop if it already is.</summary>
    public void Toggle(string peerId) => _ui.BeginInvoke(() => Apply(_ring.Toggle(peerId, Guid.NewGuid().ToString(), Now())));

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private void OnReceived(Envelope env, byte[]? _)
    {
        if (env.Kind != "device.ring" && env.Kind != "device.ring_state") return;
        _ui.BeginInvoke(() =>
        {
            try
            {
                Apply(env.Kind == "device.ring"
                    ? _ring.OnRing(env.SenderId, env.PayloadJson, Now())
                    : _ring.OnRingState(env.SenderId, env.PayloadJson, Now()));
            }
            catch (Exception) { /* a malformed payload is ignored */ }
        });
    }

    private void Apply(IEnumerable<RingEffect> effects)
    {
        foreach (var effect in effects)
        {
            switch (effect)
            {
                case RingEffect.StartRinger: StartRinger(); break;
                case RingEffect.StopRinger: StopRinger(); break;
                case RingEffect.ShowAlert: ShowAlert(); break;
                case RingEffect.CloseAlert: CloseAlert(); break;
                case RingEffect.Send s: _node.Send(s.Message.Kind, s.Message.Recipient, s.Message.PayloadJson); break;
                case RingEffect.PeersChanged: PeersChanged?.Invoke(); break;
            }
        }
    }

    private void StartRinger()
    {
        try
        {
            using var device = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var volume = device.AudioEndpointVolume;
            _savedAudio ??= (volume.Mute, volume.MasterVolumeLevelScalar);
            volume.Mute = false;
            volume.MasterVolumeLevelScalar = 1f;
        }
        catch (Exception) { /* no audio device: the alert window is still shown */ }
        try
        {
            _player?.Dispose();
            _player = new SoundPlayer(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", "Alarm01.wav"));
            _player.PlayLooping();
        }
        catch (Exception) { SystemSounds.Exclamation.Play(); }
    }

    private void StopRinger()
    {
        _player?.Stop();
        _player?.Dispose();
        _player = null;
        if (_savedAudio is { } saved)
        {
            _savedAudio = null;
            try
            {
                using var device = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                device.AudioEndpointVolume.MasterVolumeLevelScalar = saved.Volume;
                device.AudioEndpointVolume.Mute = saved.Mute;
            }
            catch (Exception) { }
        }
    }

    private void ShowAlert()
    {
        if (_alert != null) return;
        var stop = new System.Windows.Controls.Button { Content = "Stop ringing", Padding = new Thickness(24, 10, 24, 10), FontSize = 16, Margin = new Thickness(0, 14, 0, 0) };
        stop.Click += (_, _) => Apply(_ring.StopRinging());
        _alert = new Window
        {
            Title = "Gossip",
            Width = 340,
            SizeToContent = SizeToContent.Height,
            Topmost = true,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ResizeMode = ResizeMode.NoResize,
            Content = new System.Windows.Controls.StackPanel
            {
                Margin = new Thickness(24),
                Children =
                {
                    new System.Windows.Controls.TextBlock { Text = "This PC is being found", FontSize = 20, FontWeight = FontWeights.SemiBold },
                    new System.Windows.Controls.TextBlock { Text = "One of your devices is ringing this PC.", Foreground = System.Windows.Media.Brushes.Gray, Margin = new Thickness(0, 4, 0, 0) },
                    stop,
                },
            },
        };
        _alert.Closed += (_, _) => { if (_alert != null) { _alert = null; Apply(_ring.StopRinging()); } };
        _alert.Show();
    }

    private void CloseAlert()
    {
        var alert = _alert;
        _alert = null;
        alert?.Close();
    }

    public void Dispose()
    {
        _timer.Stop();
        _node.Received -= OnReceived;
        StopRinger();
        CloseAlert();
        _ring.Dispose();
    }
}

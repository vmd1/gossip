using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading.Channels;
using uniffi.gossip_ffi;
using EngineAction = uniffi.gossip_ffi.Action;

namespace Gossip.Shell;

/// <summary>A device on the trust roster.</summary>
internal sealed record TrustedPeer(string DeviceId, string Name, string Type, byte[] NoisePublic);

/// <summary>An unknown device wants to pair; answer with <see cref="Node.ConfirmPairing"/>. <c>Code</c> is the 6-digit comparison code.</summary>
internal sealed record PairingRequest(ulong Conn, string DeviceName, string DeviceType, string Code);

/// <summary>
/// The Windows shell around <c>gossip-core</c>. The engine owns the protocol (Noise, framing, signing, mesh, trust,
/// reconciliation); this class owns what the engine is sans-IO about: TCP sockets, mDNS, the 1 s tick and the trust file.
/// Every engine call happens under <see cref="_gate"/>, which also keeps the bytes written to a socket in the order the
/// engine produced them (Noise nonces are implicit counters).
/// </summary>
internal sealed class Node : IDisposable
{
    private sealed class Link
    {
        public required ulong Conn;
        public required TcpClient Client;
        public required Channel<byte[]> Outbound;
        public bool Closed;
    }

    private readonly object _gate = new();
    private readonly DeviceIdentity _identity;
    private readonly string _trustPath;
    private readonly GossipCore _core;
    private readonly TcpListener _listener = new(IPAddress.Any, 0);
    private readonly Dictionary<ulong, Link> _links = new();
    private readonly HashSet<string> _dialing = new();
    private readonly CancellationTokenSource _cts = new();
    private Discovery? _discovery;
    private Timer? _tick;
    private ulong _nextConn = 1;
    private static readonly bool Trace = Environment.GetEnvironmentVariable("GOSSIP_TRACE") == "1";

    public string DeviceId => _identity.DeviceId;
    public string DeviceName { get; }
    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public event Action<string>? Log;
    public event Action<PairingRequest>? PairingRequested;
    public event Action<ulong>? PairingCancelled;
    public event System.Action? PeersChanged;
    /// <summary>A feature message addressed to this device (or broadcast). Raw is the raw follow-up frame, if any.</summary>
    public event Action<uniffi.gossip_ffi.Envelope, byte[]?>? Received;
    public event Action<string, string, string?>? StateChanged;
    public event Action<string>? CodePairingFinished;

    public Node(DeviceIdentity identity, string deviceName, string dataDirectory, string[]? disabledFeatures = null)
    {
        _identity = identity;
        DeviceName = deviceName;
        Directory.CreateDirectory(dataDirectory);
        _trustPath = Path.Combine(dataDirectory, "trust.json");
        var trust = File.Exists(_trustPath) ? File.ReadAllText(_trustPath) : null;
        _core = new GossipCore(identity.DeviceId, deviceName, "windows", identity.NoiseSecret, identity.SigningSeed, trust, disabledFeatures ?? [], null);
    }

    // MARK: lifecycle

    public void Start()
    {
        _listener.Start();
        _ = Task.Run(() => AcceptLoop(_cts.Token));
        _discovery = new Discovery(_identity.DeviceId, _identity.Fingerprint, DeviceName, Port);
        _discovery.Log += m => Log?.Invoke(m);
        _discovery.Found += OnDiscovered;
        _discovery.Start();
        _tick = new Timer(_ => { lock (_gate) Process(_core.Tick()); }, null, 1000, 1000);
        // Re-ask the network now and then so a device that started later is found.
        _ = Task.Run(async () =>
        {
            for (var i = 0; !_cts.IsCancellationRequested; i++)
            {
                await Task.Delay(TimeSpan.FromSeconds(i < 12 ? 5 : 20), _cts.Token).ConfigureAwait(false);
                _discovery?.Refresh();
            }
        });
        Log?.Invoke($"listening on port {Port} as {DeviceName} ({DeviceId})");
    }

    public void Dispose()
    {
        _cts.Cancel();
        _tick?.Dispose();
        _discovery?.Dispose();
        _listener.Stop();
        lock (_gate) foreach (var l in _links.Values.ToList()) CloseLink(l);
    }

    // MARK: roster

    public IReadOnlyList<TrustedPeer> Peers()
    {
        string json;
        lock (_gate) json = _core.TrustJson();
        using var doc = JsonDocument.Parse(json);
        var list = new List<TrustedPeer>();
        foreach (var d in doc.RootElement.GetProperty("devices").EnumerateArray())
        {
            list.Add(new TrustedPeer(
                d.GetProperty("device_id").GetString()!, d.GetProperty("device_name").GetString()!,
                d.GetProperty("device_type").GetString()!, Convert.FromBase64String(d.GetProperty("public_key").GetString()!)));
        }
        return list;
    }

    public bool IsConnected(string deviceId) { lock (_gate) return _core.IsConnected(deviceId); }
    public string[] ConnectedPeers() { lock (_gate) return _core.ConnectedPeers(); }

    public void Revoke(string deviceId) { lock (_gate) Process(_core.RevokeDevice(deviceId)); }

    // MARK: pairing

    /// <summary>Shows a pairing code (<c>ABCD-EFGH</c>) and advertises <c>pair=1</c> until it is used or <see cref="StopShowingCode"/>.</summary>
    public string StartShowingCode()
    {
        string code;
        lock (_gate) code = _core.StartCodePairing();
        _discovery?.SetPairingMode(true);
        return code;
    }

    public void StopShowingCode()
    {
        lock (_gate) _core.StopCodePairing();
        _discovery?.SetPairingMode(false);
    }

    public bool IsValidCode(string code) { lock (_gate) return _core.IsValidPairingCode(code); }

    public void ConfirmPairing(ulong conn, bool accepted) { lock (_gate) Process(_core.ConfirmPairing(conn, accepted)); }

    // Devices currently advertising pair=1 on the network, so the UI can offer them for a typed code.
    private readonly Dictionary<string, DiscoveredPeer> _pairable = new();
    public IReadOnlyList<DiscoveredPeer> PairableDevices() { lock (_gate) return _pairable.Values.ToList(); }

    /// <summary>The code shown on another device was typed here: dial it and run the code exchange.</summary>
    public async Task<bool> PairWithCodeAsync(DiscoveredPeer target, string code)
    {
        var link = await ConnectAsync(target).ConfigureAwait(false);
        if (link == null) return false;
        Log?.Invoke($"code dial: connection {link.Conn} to {link.Client.Client.RemoteEndPoint}");
        lock (_gate) Process(_core.DialCode(link.Conn, target.DeviceId, code));
        return true;
    }

    // MARK: sending

    /// <summary>Sends a message of <paramref name="kind"/> to one device (or everyone when <paramref name="recipient"/> is null).</summary>
    public void Send(string kind, string? recipient, string payloadJson)
    {
        lock (_gate) Process(_core.SendMessage(kind, recipient, payloadJson));
    }

    /// <summary>Like <see cref="Send"/> with a raw follow-up frame (a clipboard image's PNG bytes).</summary>
    public void SendWithRaw(string kind, string? recipient, string payloadJson, byte[] raw)
    {
        lock (_gate) Process(_core.SendMessageWithRaw(kind, recipient, payloadJson, raw));
    }

    public void SetState(string slot, string? valueJson) { lock (_gate) Process(_core.SetState(slot, valueJson)); }
    public string? GetState(string deviceId, string slot) { lock (_gate) return _core.GetState(deviceId, slot); }

    // MARK: sockets

    private async Task AcceptLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(ct).ConfigureAwait(false); }
            catch { return; }
            var link = NewLink(client);
            Log?.Invoke($"accepted connection {link.Conn} from {client.Client.RemoteEndPoint}");
            lock (_gate) Process(_core.ConnectionAccepted(link.Conn));
            _ = Task.Run(() => ReadLoop(link));
        }
    }

    private Link NewLink(TcpClient client)
    {
        client.NoDelay = true;
        Link link;
        lock (_gate)
        {
            link = new Link { Conn = _nextConn++, Client = client, Outbound = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true }) };
            _links[link.Conn] = link;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                var stream = client.GetStream();
                await foreach (var bytes in link.Outbound.Reader.ReadAllAsync().ConfigureAwait(false))
                    await stream.WriteAsync(bytes).ConfigureAwait(false);
            }
            catch (Exception ex) { if (Trace) Log?.Invoke($"conn {link.Conn}: write ended: {ex.GetType().Name} {ex.Message}"); CloseAndReport(link); }
        });
        return link;
    }

    private async Task ReadLoop(Link link)
    {
        var buffer = new byte[16 * 1024];
        try
        {
            var stream = link.Client.GetStream();
            while (true)
            {
                var n = await stream.ReadAsync(buffer).ConfigureAwait(false);
                if (n == 0) break;
                var chunk = buffer.AsSpan(0, n).ToArray();
                if (Trace) Log?.Invoke($"conn {link.Conn}: received {n}B");
                lock (_gate) { if (link.Closed) return; Process(_core.BytesReceived(link.Conn, chunk)); }
            }
        }
        catch (Exception ex) { if (Trace) Log?.Invoke($"conn {link.Conn}: read ended: {ex.GetType().Name} {ex.Message}"); }
        if (Trace) Log?.Invoke($"conn {link.Conn}: closed");
        CloseAndReport(link);
    }

    /// <summary>Connects to the first address that answers: all the usable ones are tried at once, so an unreachable address
    /// (a VPN interface, say) costs nothing while the LAN one is already up.</summary>
    private async Task<Link?> ConnectAsync(DiscoveredPeer peer)
    {
        var candidates = peer.Addresses.Where(a => !a.IsIPv6LinkLocal).DistinctBy(a => a.ToString()).ToList();
        if (candidates.Count == 0) return null;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
        cts.CancelAfter(TimeSpan.FromSeconds(5));
        var attempts = candidates.Select(async address =>
        {
            var client = new TcpClient(address.AddressFamily);
            try
            {
                await client.ConnectAsync(address, peer.Port, cts.Token).ConfigureAwait(false);
                return client;
            }
            catch
            {
                client.Dispose();
                return null;
            }
        }).ToList();
        TcpClient? winner = null;
        while (attempts.Count > 0)
        {
            var done = await Task.WhenAny(attempts).ConfigureAwait(false);
            attempts.Remove(done);
            var client = await done.ConfigureAwait(false);
            if (client == null) continue;
            winner = client;
            break;
        }
        cts.Cancel();
        // Any other attempt that also got through is closed so no half-open connection is left behind.
        foreach (var rest in attempts) _ = rest.ContinueWith(t => t.Result?.Dispose(), TaskContinuationOptions.OnlyOnRanToCompletion);
        if (winner == null) return null;
        var link = NewLink(winner);
        _ = Task.Run(() => ReadLoop(link));
        return link;
    }

    private readonly Dictionary<string, string> _lastSeen = new();

    private void OnDiscovered(DiscoveredPeer peer)
    {
        lock (_gate)
        {
            var signature = $"{peer.Pairing}|{peer.Port}|{string.Join(",", peer.Addresses)}";
            var changed = !_lastSeen.TryGetValue(peer.DeviceId, out var before) || before != signature;
            _lastSeen[peer.DeviceId] = signature;
            if (!changed && _core.IsConnected(peer.DeviceId)) return;
            if (peer.Pairing) _pairable[peer.DeviceId] = peer; else _pairable.Remove(peer.DeviceId);
        }
        _ = Task.Run(async () =>
        {
            TrustedPeer? trusted;
            lock (_gate)
            {
                trusted = PeersLocked().FirstOrDefault(p => p.DeviceId == peer.DeviceId);
                if (trusted == null || _core.IsConnected(peer.DeviceId) || !_core.ShouldDial(peer.DeviceId) || !_dialing.Add(peer.DeviceId)) return;
            }
            try
            {
                var link = await ConnectAsync(peer).ConfigureAwait(false);
                if (link == null) return;
                Log?.Invoke($"dial: connection {link.Conn} to {peer.DeviceId[..8]} at {link.Client.Client.RemoteEndPoint}");
                lock (_gate) Process(_core.Dial(link.Conn, peer.DeviceId, trusted.NoisePublic, null));
            }
            finally { lock (_gate) _dialing.Remove(peer.DeviceId); }
        });
    }

    private List<TrustedPeer> PeersLocked()
    {
        using var doc = JsonDocument.Parse(_core.TrustJson());
        return doc.RootElement.GetProperty("devices").EnumerateArray().Select(d => new TrustedPeer(
            d.GetProperty("device_id").GetString()!, d.GetProperty("device_name").GetString()!,
            d.GetProperty("device_type").GetString()!, Convert.FromBase64String(d.GetProperty("public_key").GetString()!))).ToList();
    }

    private void CloseAndReport(Link link)
    {
        lock (_gate)
        {
            if (link.Closed) return;
            CloseLink(link);
            Process(_core.ConnectionClosed(link.Conn));
        }
    }

    private void CloseLink(Link link)
    {
        link.Closed = true;
        _links.Remove(link.Conn);
        link.Outbound.Writer.TryComplete();
        try { link.Client.Close(); } catch { }
    }

    // MARK: engine actions (call with _gate held)

    private void Process(EngineAction[] actions)
    {
        foreach (var action in actions)
        {
            if (Trace) Log?.Invoke($"engine action: {action.GetType().Name}{(action is EngineAction.Send sd ? $" conn={sd.Conn} {sd.Bytes.Length}B" : "")}");
            switch (action)
            {
                case EngineAction.Send s:
                    if (_links.TryGetValue(s.Conn, out var sendLink)) sendLink.Outbound.Writer.TryWrite(s.Bytes);
                    break;
                case EngineAction.Close c:
                    // The engine already forgot this connection: close the socket without reporting it back.
                    if (_links.TryGetValue(c.Conn, out var closeLink)) CloseLink(closeLink);
                    break;
                case EngineAction.PeerConnected p:
                    Log?.Invoke($"connected: {p.Peer.DeviceName} ({p.Peer.DeviceType}){(p.NewlyPaired ? " [newly paired]" : "")}");
                    PeersChanged?.Invoke();
                    break;
                case EngineAction.PeerDisconnected d:
                    Log?.Invoke($"disconnected: {d.DeviceId}");
                    PeersChanged?.Invoke();
                    break;
                case EngineAction.PairingPrompt pp:
                    Log?.Invoke($"pairing request from {pp.Peer.DeviceName}, code {pp.Code}");
                    PairingRequested?.Invoke(new PairingRequest(pp.Conn, pp.Peer.DeviceName, pp.Peer.DeviceType, pp.Code));
                    break;
                case EngineAction.PairingPromptCancelled pc:
                    PairingCancelled?.Invoke(pc.Conn);
                    break;
                case EngineAction.Deliver dl:
                    Received?.Invoke(dl.Envelope, dl.Raw);
                    break;
                case EngineAction.TrustChanged t:
                    File.WriteAllText(_trustPath, t.SnapshotJson);
                    PeersChanged?.Invoke();
                    break;
                case EngineAction.DeviceRevoked r:
                    Log?.Invoke($"revoked: {r.DeviceId}");
                    PeersChanged?.Invoke();
                    break;
                case EngineAction.ReconcileDue due:
                    // Only trust gossip is scheduled by the engine for the apps; features keep their state in slots.
                    if (due.Task == "trust.roster_update") SendRoster(due.Peer);
                    break;
                case EngineAction.StateChanged st:
                    StateChanged?.Invoke(st.DeviceId, st.Slot, st.ValueJson);
                    break;
                case EngineAction.CodePairingSucceeded cs:
                    Log?.Invoke($"paired with {cs.Peer.DeviceName}");
                    _discovery?.SetPairingMode(false);
                    CodePairingFinished?.Invoke("ok");
                    break;
                case EngineAction.CodePairingWrongCode w:
                    CodePairingFinished?.Invoke($"wrong code, {w.AttemptsLeft} attempts left");
                    break;
                case EngineAction.CodePairingTooManyAttempts:
                    CodePairingFinished?.Invoke("too many attempts");
                    break;
                case EngineAction.CodePairingExpired:
                    CodePairingFinished?.Invoke("code expired");
                    break;
                case EngineAction.CodePairingRejected:
                    CodePairingFinished?.Invoke("the other device did not accept the code");
                    break;
                default:
                    break; // relay actions: the relay is not wired up on Windows yet
            }
        }
    }

    private void SendRoster(string? peer)
    {
        try { Process(_core.Send(_core.RosterUpdate(peer))); }
        catch (Exception ex) { Log?.Invoke($"roster send failed: {ex.Message}"); }
    }
}

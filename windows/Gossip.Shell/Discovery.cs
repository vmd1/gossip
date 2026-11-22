using System.Net;
using Makaretu.Dns;

namespace Gossip.Shell;

/// <summary>A Gossip device seen on the local network (<c>_gossip._tcp</c>).</summary>
internal sealed record DiscoveredPeer(string DeviceId, string Fingerprint, bool Pairing, IReadOnlyList<IPAddress> Addresses, int Port, string Instance);

/// <summary>
/// Advertises this PC as <c>_gossip._tcp</c> (TXT <c>deviceId</c>, <c>fp</c>, and <c>pair=1</c> while it shows a pairing
/// code) and browses for the others. The records are the same ones the Mac (Bonjour) and Android (NSD) apps publish.
/// </summary>
internal sealed class Discovery : IDisposable
{
    public const string ServiceType = "_gossip._tcp";

    private readonly MulticastService _mdns = new();
    private readonly ServiceDiscovery _sd;
    private readonly string _selfId;
    private readonly string _fingerprint;
    private readonly string _name;
    private readonly int _port;
    private ServiceProfile? _profile;
    private readonly object _gate = new();

    // What has been learned about each instance so far; a peer is reported once its SRV, TXT and an address are known.
    private readonly Dictionary<string, (string? Host, int Port, Dictionary<string, string>? Txt)> _instances = new();
    private readonly Dictionary<string, HashSet<IPAddress>> _hosts = new(StringComparer.OrdinalIgnoreCase);

    public event Action<DiscoveredPeer>? Found;
    public event Action<string>? Log;

    public Discovery(string selfId, string fingerprint, string deviceName, int port)
    {
        _selfId = selfId;
        _fingerprint = fingerprint;
        _name = deviceName;
        _port = port;
        _sd = new ServiceDiscovery(_mdns);
        _mdns.AnswerReceived += OnAnswer;
        _sd.ServiceInstanceDiscovered += (_, e) =>
        {
            if (Environment.GetEnvironmentVariable("GOSSIP_DEBUG") == "1") Log?.Invoke($"instance discovered: {e.ServiceInstanceName}");
            // Ask for the details of an instance we have only just heard the name of.
            _mdns.SendQuery(e.ServiceInstanceName, type: DnsType.SRV);
            _mdns.SendQuery(e.ServiceInstanceName, type: DnsType.TXT);
        };
    }

    public void Start()
    {
        _mdns.Start();
        Advertise(pairing: false);
        _sd.QueryServiceInstances(ServiceType);
    }

    /// <summary>Re-queries the network; call it now and then so a device that came up later is found.</summary>
    public void Refresh() => _sd.QueryServiceInstances(ServiceType);

    public void SetPairingMode(bool on) => Advertise(on);

    private void Advertise(bool pairing)
    {
        lock (_gate)
        {
            if (_profile != null) _sd.Unadvertise(_profile);
            var profile = new ServiceProfile(_name, ServiceType, (ushort)_port);
            profile.AddProperty("deviceId", _selfId);
            profile.AddProperty("fp", _fingerprint);
            if (pairing) profile.AddProperty("pair", "1");
            _profile = profile;
            _sd.Advertise(profile);
            _sd.Announce(profile);
        }
    }

    private void OnAnswer(object? sender, MessageEventArgs e)
    {
        try
        {
            var records = e.Message.Answers.Concat(e.Message.AdditionalRecords).ToList();
            if (Environment.GetEnvironmentVariable("GOSSIP_DEBUG") == "1")
                Log?.Invoke($"mdns answer from {e.RemoteEndPoint}: " + string.Join(" | ", records.Select(r => $"{r.Type} {r.Name}")));
            lock (_gate)
            {
                foreach (var a in records.OfType<AddressRecord>())
                {
                    var key = a.Name.ToString().TrimEnd('.');
                    if (!_hosts.TryGetValue(key, out var set)) _hosts[key] = set = new HashSet<IPAddress>();
                    set.Add(a.Address);
                }
                foreach (var srv in records.OfType<SRVRecord>().Where(r => r.Name.ToString().Contains(ServiceType)))
                {
                    var name = srv.Name.ToString();
                    var cur = _instances.GetValueOrDefault(name);
                    _instances[name] = (srv.Target.ToString().TrimEnd('.'), srv.Port, cur.Txt);
                    if (!_hosts.ContainsKey(srv.Target.ToString().TrimEnd('.'))) _mdns.SendQuery(srv.Target, type: DnsType.A);
                }
                // A responder can hold several TXT records for one instance (an old one and the updated one). Merge them,
                // newest last, and skip goodbyes (TTL 0). `pair` is absent in the old record, so it is cleared only by an
                // explicit record that has the other keys but no `pair`.
                foreach (var txt in records.OfType<TXTRecord>().Where(r => r.Name.ToString().Contains(ServiceType) && r.TTL > TimeSpan.Zero))
                {
                    var map = new Dictionary<string, string>();
                    foreach (var s in txt.Strings)
                    {
                        var i = s.IndexOf('=');
                        if (i > 0) map[s[..i]] = s[(i + 1)..];
                    }
                    if (!map.ContainsKey("deviceId")) continue;
                    var name = txt.Name.ToString();
                    var cur = _instances.GetValueOrDefault(name);
                    if (cur.Txt != null && !map.ContainsKey("pair") && cur.Txt.ContainsKey("pair") && records.OfType<TXTRecord>().Count(r => r.Name.ToString() == name) > 1)
                        map["pair"] = cur.Txt["pair"]; // the stale twin of an updated record: keep what the updated one said
                    _instances[name] = (cur.Host, cur.Port, map);
                }
                foreach (var (name, info) in _instances.ToList())
                {
                    if (info.Host == null || info.Txt == null) continue;
                    if (!info.Txt.TryGetValue("deviceId", out var id) || id == _selfId) continue;
                    if (!_hosts.TryGetValue(info.Host, out var addrs) || addrs.Count == 0) continue;
                    var ordered = addrs.OrderBy(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork ? 0 : 1).ToList();
                    if (Environment.GetEnvironmentVariable("GOSSIP_DEBUG") == "2") Log?.Invoke($"found {name} id={id[..8]} pair={info.Txt.GetValueOrDefault("pair")} at {string.Join(",", ordered)}:{info.Port}");
                    Found?.Invoke(new DiscoveredPeer(id, info.Txt.GetValueOrDefault("fp", ""), info.Txt.GetValueOrDefault("pair") == "1", ordered, info.Port, name));
                }
            }
        }
        catch (Exception ex)
        {
            Log?.Invoke($"discovery: {ex.Message}");
        }
    }

    public void Dispose()
    {
        try { if (_profile != null) _sd.Unadvertise(_profile); } catch { }
        _sd.Dispose();
        _mdns.Dispose();
    }
}

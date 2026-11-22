using Gossip.Shell;
using System.Linq;

// usage: Gossip.Headless [--name NAME] [--data DIR] [--plain]
// stdin commands: code | pair CODE | peers | pairable | accept | reject | say TEXT | sleep SECONDS | quit
string name = Environment.MachineName, data = Path.Combine(IdentityStore.DefaultDirectory, "headless");
bool plain = false;
for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--name") name = args[++i];
    else if (args[i] == "--data") data = args[++i];
    else if (args[i] == "--plain") plain = true; // no DPAPI (tests on a non-Windows host)
}

var identity = IdentityStore.LoadOrCreate(data, protect: !plain);
using var node = new Node(identity, name, data);
PairingRequest? pending = null;
node.Log += m => Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {m}");
node.PairingRequested += r => { pending = r; Console.WriteLine($"[pairing] {r.DeviceName} ({r.DeviceType}) wants to pair. Code {r.Code}. Type 'accept' or 'reject'."); };
node.CodePairingFinished += r => Console.WriteLine($"[code pairing] {r}");
node.Received += (e, raw) => Console.WriteLine($"[recv] {e.Kind} from {e.SenderId[..8]}: {e.PayloadJson}{(raw != null ? $" (+{raw.Length} raw bytes)" : "")}");
node.StateChanged += (id, slot, value) => Console.WriteLine($"[state] {id[..8]} {slot} = {value}");
node.Start();
Console.WriteLine($"ready: {name} {identity.DeviceId}");

string? line;
while ((line = Console.ReadLine()) != null)
{
    var parts = line.Trim().Split(' ', 2);
    switch (parts[0])
    {
        case "code": Console.WriteLine($"[code] {node.StartShowingCode()}"); break;
        case "pair":
            // Discovery can take a while on a busy network: wait up to a minute for a device that shows a code.
            DiscoveredPeer? target = null;
            for (var i = 0; i < 60 && (target = node.PairableDevices().FirstOrDefault()) == null; i++) await Task.Delay(1000);
            if (target == null) { Console.WriteLine("no device is showing a code"); break; }
            Console.WriteLine($"pairing with {target.DeviceId[..8]}: {(await node.PairWithCodeAsync(target, parts.ElementAtOrDefault(1) ?? ""))}");
            break;
        case "pairable": foreach (var p in node.PairableDevices()) Console.WriteLine($"  {p.DeviceId} {p.Instance} {string.Join(",", p.Addresses)}:{p.Port}"); break;
        case "peers":
            foreach (var p in node.Peers()) Console.WriteLine($"  {p.Name} [{p.Type}] {p.DeviceId[..8]} connected={node.IsConnected(p.DeviceId)}");
            break;
        case "accept": if (pending != null) node.ConfirmPairing(pending.Conn, true); break;
        case "reject": if (pending != null) node.ConfirmPairing(pending.Conn, false); break;
        case "say": node.Send("headless.say", null, System.Text.Json.JsonSerializer.Serialize(new { text = parts.ElementAtOrDefault(1) ?? "" })); break;
        case "sleep": await Task.Delay(TimeSpan.FromSeconds(int.Parse(parts.ElementAtOrDefault(1) ?? "1"))); break;
        case "quit": Environment.Exit(0); return; // exit now: disposing the mDNS service can keep a Windows process alive
    }
}

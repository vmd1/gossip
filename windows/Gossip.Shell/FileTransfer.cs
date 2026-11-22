using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Gossip.Shell;

public sealed record IncomingOffer(string TransferId, string PeerId, string PeerName, string Name, long Size);

public sealed record TransferInfo(string TransferId, string PeerId, string Name, long Size, bool Outgoing, string State, long Bytes);

/// <summary>
/// File transfer (docs/plans/file-transfer.md). The receiver must accept every offer; chunks are 1 MiB raw frames written
/// at offset index*chunkSize (so a repeat is harmless); <c>file.accept(next)</c> is both the answer and the resume request,
/// and the sender re-offers on every fresh connection and every 30 s while unanswered. All handlers are idempotent.
/// </summary>
internal sealed class FileTransferService : IDisposable
{
    private sealed class Outgoing
    {
        public required string Id, PeerId, Path, Name, Sha256;
        public required long Size;
        public string State = "offered";           // offered | sending | waiting | done | rejected | cancelled | failed
        public DateTime OfferedAt = DateTime.UtcNow, LastOffer = DateTime.UtcNow;
        public CancellationTokenSource? Sender;
        public long Sent;
    }

    private sealed class Incoming
    {
        public required string Id, PeerId, PeerName, Name, Sha256, PartPath;
        public required long Size;
        public required int ChunkSize;
        public bool Accepted;
        public HashSet<int> Received = new();
        public FileStream? Part;
        public readonly object Gate = new();
    }

    private static readonly TimeSpan ReofferEvery = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan GiveUpAfter = TimeSpan.FromMinutes(10);
    private const long MaxQueued = 8L * 1024 * 1024;
    private const long SpaceMargin = 100L * 1024 * 1024;

    private readonly Node _node;
    private readonly string _downloads, _partDir;
    private readonly Func<IncomingOffer, Task<bool>> _ask;
    private readonly ConcurrentDictionary<string, Outgoing> _out = new();
    private readonly ConcurrentDictionary<string, Incoming> _in = new();
    private readonly Queue<string> _finished = new();   // bounded cache of finished incoming ids
    private readonly CancellationTokenSource _cts = new();
    private readonly Timer _reconcile;

    public event Action<TransferInfo>? Changed;
    /// <summary>A message that could not be handled (a malformed or failed one): for logs only.</summary>
    public event Action<string>? Problem;

    public FileTransferService(Node node, string downloadsDir, string stateDir, Func<IncomingOffer, Task<bool>> ask)
    {
        _node = node;
        _downloads = downloadsDir;
        _partDir = System.IO.Path.Combine(stateDir, "incoming");
        Directory.CreateDirectory(_downloads);
        Directory.CreateDirectory(_partDir);
        _ask = ask;
        _node.Received += OnReceived;
        _node.PeerConnectedId += OnPeerConnected;
        _reconcile = new Timer(_ => Reoffer(null), null, ReofferEvery, ReofferEvery);
    }

    // MARK: sending

    /// <summary>Offers a file to a trusted device; returns the transfer id.</summary>
    public async Task<string> SendFileAsync(string peerId, string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException(path);
        if (info.Length > FileTransferRules.MaxFileBytes) throw new InvalidOperationException("Files over 2 GiB cannot be sent.");
        string sha;
        await using (var s = File.OpenRead(path)) sha = Convert.ToHexString(await SHA256.HashDataAsync(s)).ToLowerInvariant();
        var t = new Outgoing { Id = Guid.NewGuid().ToString(), PeerId = peerId, Path = path, Name = info.Name, Size = info.Length, Sha256 = sha };
        _out[t.Id] = t;
        Offer(t);
        Notify(t);
        return t.Id;
    }

    public void Cancel(string transferId)
    {
        if (_out.TryGetValue(transferId, out var t) && t.State is "offered" or "sending" or "waiting")
        {
            t.Sender?.Cancel();
            t.State = "cancelled";
            Send("file.cancel", t.PeerId, Json(("transferId", t.Id)));
            Notify(t);
        }
        else if (_in.TryRemove(transferId, out var i))
        {
            Discard(i);
            Send("file.cancel", i.PeerId, Json(("transferId", i.Id)));
        }
    }

    private void Offer(Outgoing t)
    {
        t.LastOffer = DateTime.UtcNow;
        Send("file.offer", t.PeerId, new JsonObject
        {
            ["transferId"] = t.Id, ["name"] = t.Name, ["size"] = t.Size, ["sha256"] = t.Sha256, ["chunkSize"] = FileTransferRules.ChunkSize,
        }.ToJsonString());
    }

    // Re-offers unfinished transfers: on a fresh connection to that peer, and every 30 s while the offer is unanswered.
    private void Reoffer(string? onlyPeer)
    {
        foreach (var t in _out.Values)
        {
            if (t.State is not ("offered" or "sending" or "waiting")) continue;
            if (onlyPeer != null && t.PeerId != onlyPeer) continue;
            if (DateTime.UtcNow - t.OfferedAt > GiveUpAfter && t.State == "offered") { t.State = "failed"; Notify(t); continue; }
            if (!_node.IsConnected(t.PeerId)) continue;
            if (onlyPeer == null && t.State != "offered" && t.State != "waiting") continue;
            Offer(t);
        }
    }

    private void OnPeerConnected(string peerId) => Task.Run(() => Reoffer(peerId));

    private async Task SendChunks(Outgoing t, int from, CancellationToken ct)
    {
        try
        {
            t.State = "sending";
            var count = FileTransferRules.ChunkCount(t.Size);
            await using var file = new FileStream(t.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            for (var i = from; i < count && !ct.IsCancellationRequested; i++)
            {
                while (_node.PendingOutboundBytes > MaxQueued)
                {
                    if (!_node.IsConnected(t.PeerId)) { t.State = "waiting"; Notify(t); return; }
                    await Task.Delay(20, ct);
                }
                if (!_node.IsConnected(t.PeerId)) { t.State = "waiting"; Notify(t); return; }
                var length = FileTransferRules.ChunkLength(t.Size, FileTransferRules.ChunkSize, i);
                var buffer = new byte[length];
                file.Position = (long)i * FileTransferRules.ChunkSize;
                await file.ReadExactlyAsync(buffer, ct);
                SendRaw("file.chunk", t.PeerId, Json(("transferId", t.Id), ("index", i)), buffer);
                t.Sent = Math.Max(t.Sent, (long)i * FileTransferRules.ChunkSize + length);
                if (i % 4 == 0) Notify(t);
            }
            if (!ct.IsCancellationRequested) { t.State = "waiting"; Notify(t); } // waiting for file.complete
        }
        catch (OperationCanceledException) { }
        catch (Exception) { t.State = "waiting"; }
    }

    // MARK: receiving

    private void OnReceived(uniffi.gossip_ffi.Envelope env, byte[]? raw)
    {
        if (!env.Kind.StartsWith("file.")) return;
        var kind = env.Kind; var sender = env.SenderId; var payload = env.PayloadJson;
        // The engine lock is held here: do the work elsewhere (disk, user prompts) so the network keeps flowing.
        Task.Run(async () =>
        {
            try
            {
                var p = JsonNode.Parse(payload)!.AsObject();
                switch (kind)
                {
                    case "file.offer": await OnOffer(sender, p); break;
                    case "file.accept": OnAccept(sender, p); break;
                    case "file.reject": OnReject(sender, p); break;
                    case "file.chunk": OnChunk(sender, p, raw); break;
                    case "file.complete": OnComplete(sender, p); break;
                    case "file.cancel": OnCancel(sender, p); break;
                }
            }
            catch (Exception ex) { Problem?.Invoke($"{kind} from {sender[..Math.Min(8, sender.Length)]}: {ex.GetType().Name}: {ex.Message}"); }
        });
    }

    private async Task OnOffer(string sender, JsonObject p)
    {
        var id = p["transferId"]!.GetValue<string>();
        bool wasFinished; lock (_finished) wasFinished = _finished.Contains(id);
        if (wasFinished) { Send("file.complete", sender, Json(("transferId", id), ("ok", true))); return; }
        if (_in.TryGetValue(id, out var known))
        {
            if (known.PeerId == sender && known.Accepted) SendAccept(known);
            return; // still waiting for the user: never prompt twice
        }
        var size = p["size"]!.GetValue<long>();
        var chunk = p["chunkSize"]?.GetValue<int>() ?? FileTransferRules.ChunkSize;
        if (size > FileTransferRules.MaxFileBytes || size < 0 || chunk is < 1024 or > 8 * 1024 * 1024) { Reject(sender, id, "too_large"); return; }
        if (_in.Count >= FileTransferRules.MaxIncoming) { Reject(sender, id, "busy"); return; }
        long free;
        try { free = new DriveInfo(System.IO.Path.GetPathRoot(System.IO.Path.GetFullPath(_downloads))!).AvailableFreeSpace; } catch { free = long.MaxValue; }
        if (free < size + SpaceMargin) { Reject(sender, id, "no_space"); return; }

        var name = FileTransferRules.SanitizeName(p["name"]?.GetValue<string>() ?? "file");
        var peerName = _node.Peers().FirstOrDefault(x => x.DeviceId == sender)?.Name ?? "A device";
        var t = new Incoming
        {
            Id = id, PeerId = sender, PeerName = peerName, Name = name, Size = size, ChunkSize = chunk,
            Sha256 = (p["sha256"]?.GetValue<string>() ?? "").ToLowerInvariant(), PartPath = System.IO.Path.Combine(_partDir, id + ".part"),
        };
        if (!_in.TryAdd(id, t)) return;

        var accepted = false;
        try
        {
            var answer = _ask(new IncomingOffer(id, sender, peerName, name, size));
            // Decline is the default after two minutes.
            accepted = await Task.WhenAny(answer, Task.Delay(TimeSpan.FromMinutes(2))) == answer && await answer;
        }
        catch { accepted = false; }
        if (!_in.ContainsKey(id)) return; // cancelled while the prompt was open
        if (!accepted) { _in.TryRemove(id, out _); Reject(sender, id, "declined"); return; }

        lock (t.Gate)
        {
            // Resume: whole chunks already in a leftover .part file (from before a dropped connection or restart) are kept.
            var have = 0;
            if (File.Exists(t.PartPath)) have = (int)Math.Min(new FileInfo(t.PartPath).Length / chunk, FileTransferRules.ChunkCount(size, chunk));
            t.Part = new FileStream(t.PartPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
            t.Part.SetLength(Math.Min(size, (long)have * chunk));
            for (var i = 0; i < have; i++) t.Received.Add(i);
            t.Accepted = true;
        }
        Notify(t);
        if (size == 0) { Finish(t); return; }
        SendAccept(t);
    }

    private void SendAccept(Incoming t) =>
        Send("file.accept", t.PeerId, Json(("transferId", t.Id), ("next", FileTransferRules.NextIndex(t.Received))));

    private void Reject(string peer, string id, string reason) =>
        Send("file.reject", peer, Json(("transferId", id), ("reason", reason)));

    private void OnChunk(string sender, JsonObject p, byte[]? raw)
    {
        if (raw == null) return;
        var id = p["transferId"]!.GetValue<string>();
        var index = p["index"]!.GetValue<int>();
        if (!_in.TryGetValue(id, out var t) || t.PeerId != sender || !t.Accepted) return; // unknown or finished: dropped
        bool done;
        lock (t.Gate)
        {
            if (t.Part == null) return;
            var expected = FileTransferRules.ChunkLength(t.Size, t.ChunkSize, index);
            if (index < 0 || expected == 0 || raw.Length != expected) return;
            t.Part.Position = (long)index * t.ChunkSize;
            t.Part.Write(raw);
            t.Received.Add(index);
            done = t.Received.Count == FileTransferRules.ChunkCount(t.Size, t.ChunkSize);
        }
        if (index % 4 == 0 || done) Notify(t);
        if (done) Finish(t);
    }

    private void Finish(Incoming t)
    {
        if (!_in.TryRemove(t.Id, out _)) return; // finished already (a duplicate last chunk)
        bool ok;
        string final = "";
        lock (t.Gate)
        {
            t.Part?.Flush();
            t.Part?.Dispose();
            t.Part = null;
            using (var s = File.OpenRead(t.PartPath)) ok = Convert.ToHexString(SHA256.HashData(s)).Equals(t.Sha256, StringComparison.OrdinalIgnoreCase);
            if (ok)
            {
                final = System.IO.Path.Combine(_downloads, FileTransferRules.UniqueName(t.Name, n => File.Exists(System.IO.Path.Combine(_downloads, n))));
                File.Move(t.PartPath, final);
            }
            else File.Delete(t.PartPath);
        }
        lock (_finished) { _finished.Enqueue(t.Id); while (_finished.Count > 128) _finished.Dequeue(); }
        Changed?.Invoke(new TransferInfo(t.Id, t.PeerId, ok ? System.IO.Path.GetFileName(final) : t.Name, t.Size, false, ok ? "done" : "failed", ok ? t.Size : 0));
        Send("file.complete", t.PeerId, Json(("transferId", t.Id), ("ok", ok), ("reason", ok ? null : "hash_mismatch")));
    }

    private void Discard(Incoming t)
    {
        lock (t.Gate) { t.Part?.Dispose(); t.Part = null; try { File.Delete(t.PartPath); } catch { } }
    }

    // MARK: sender-side replies

    private void OnAccept(string sender, JsonObject p)
    {
        if (!_out.TryGetValue(p["transferId"]!.GetValue<string>(), out var t) || t.PeerId != sender) return;
        if (t.State is "done" or "rejected" or "cancelled" or "failed") return;
        var next = Math.Clamp(p["next"]?.GetValue<int>() ?? 0, 0, FileTransferRules.ChunkCount(t.Size));
        t.Sender?.Cancel(); // a duplicate accept restarts from the same index
        var cts = new CancellationTokenSource();
        t.Sender = cts;
        if (t.Size == 0) return;
        _ = Task.Run(() => SendChunks(t, next, cts.Token));
    }

    private void OnReject(string sender, JsonObject p)
    {
        if (!_out.TryGetValue(p["transferId"]!.GetValue<string>(), out var t) || t.PeerId != sender || t.State is "done" or "cancelled") return;
        t.Sender?.Cancel();
        t.State = "rejected";
        Notify(t);
    }

    private void OnComplete(string sender, JsonObject p)
    {
        if (!_out.TryGetValue(p["transferId"]!.GetValue<string>(), out var t) || t.PeerId != sender || t.State is "done" or "cancelled") return;
        t.Sender?.Cancel();
        t.State = p["ok"]?.GetValue<bool>() == true ? "done" : "failed";
        if (t.State == "done") t.Sent = t.Size;
        Notify(t);
    }

    private void OnCancel(string sender, JsonObject p)
    {
        var id = p["transferId"]!.GetValue<string>();
        if (_in.TryGetValue(id, out var i) && i.PeerId == sender && _in.TryRemove(id, out _)) { Discard(i); Changed?.Invoke(new TransferInfo(id, sender, i.Name, i.Size, false, "cancelled", 0)); }
        if (_out.TryGetValue(id, out var t) && t.PeerId == sender && t.State is "offered" or "sending" or "waiting") { t.Sender?.Cancel(); t.State = "cancelled"; Notify(t); }
    }

    // MARK: helpers

    // Not being connected is normal (the peer left): the reconcile paths try again, so a failed send is not an error.
    private void Send(string kind, string? to, string json) { try { _node.Send(kind, to, json); } catch (uniffi.gossip_ffi.GossipException) { } }
    private void SendRaw(string kind, string? to, string json, byte[] raw) { try { _node.SendWithRaw(kind, to, json, raw); } catch (uniffi.gossip_ffi.GossipException) { } }

    private void Notify(Outgoing t) => Changed?.Invoke(new TransferInfo(t.Id, t.PeerId, t.Name, t.Size, true, t.State, t.Sent));
    private void Notify(Incoming t) { long b; lock (t.Gate) b = (long)t.Received.Count * t.ChunkSize; Changed?.Invoke(new TransferInfo(t.Id, t.PeerId, t.Name, t.Size, false, t.Accepted ? "receiving" : "offered", Math.Min(b, t.Size))); }

    private static string Json(params (string Key, object? Value)[] fields)
    {
        var o = new JsonObject();
        foreach (var (k, v) in fields) o[k] = v == null ? null : JsonValue.Create(v);
        return o.ToJsonString();
    }

    public void Dispose()
    {
        _node.Received -= OnReceived;
        _node.PeerConnectedId -= OnPeerConnected;
        _reconcile.Dispose();
        _cts.Cancel();
        foreach (var t in _out.Values) t.Sender?.Cancel();
        foreach (var i in _in.Values) lock (i.Gate) { i.Part?.Dispose(); i.Part = null; }
    }
}

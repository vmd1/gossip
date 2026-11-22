using System.Security.Cryptography;
using System.Text.Json;
using uniffi.gossip_ffi;

namespace Gossip.Shell;

/// <summary>This device's identity: a UUID, the Noise (X25519) secret and the Ed25519 signing seed.</summary>
internal sealed record DeviceIdentity(string DeviceId, byte[] NoiseSecret, byte[] SigningSeed, byte[] NoisePublic)
{
    /// <summary>The Bonjour <c>fp</c> value peers use to recognise this device: first 8 bytes of SHA-256 of the Noise public key, base64.</summary>
    public string Fingerprint => Convert.ToBase64String(SHA256.HashData(NoisePublic).AsSpan(0, 8));
}

/// <summary>
/// Persists the identity in <c>%APPDATA%\Gossip\identity.bin</c>, encrypted with DPAPI for the current Windows user (the
/// secrets never sit on disk in the clear). <paramref name="protect"/> is false only in tests on non-Windows hosts.
/// </summary>
internal static class IdentityStore
{
    private sealed record Stored(string DeviceId, string Noise, string Signing);

    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Gossip");

    public static DeviceIdentity LoadOrCreate(string? directory = null, bool protect = true)
    {
        directory ??= DefaultDirectory;
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "identity.bin");
        if (File.Exists(path))
        {
            try
            {
                var raw = File.ReadAllBytes(path);
                var json = protect ? ProtectedData.Unprotect(raw, null, DataProtectionScope.CurrentUser) : raw;
                var s = JsonSerializer.Deserialize<Stored>(json)!;
                var noise = Convert.FromBase64String(s.Noise);
                return new DeviceIdentity(s.DeviceId, noise, Convert.FromBase64String(s.Signing), GossipFfiMethods.NoisePublicKey(noise));
            }
            catch (Exception) when (!protect || OperatingSystem.IsWindows())
            {
                // Unreadable (corrupt, or protected by another user): fall through and make a fresh identity.
            }
        }
        var fresh = GossipFfiMethods.GenerateIdentity();
        var stored = JsonSerializer.SerializeToUtf8Bytes(new Stored(fresh.DeviceId, Convert.ToBase64String(fresh.NoiseSecret), Convert.ToBase64String(fresh.SigningSeed)));
        File.WriteAllBytes(path, protect ? ProtectedData.Protect(stored, null, DataProtectionScope.CurrentUser) : stored);
        return new DeviceIdentity(fresh.DeviceId, fresh.NoiseSecret, fresh.SigningSeed, fresh.NoisePublicKey);
    }
}

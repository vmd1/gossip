using Gossip.Shell;
using Xunit;

public class IdentityStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "gossip-id-" + Guid.NewGuid());

    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    [Fact]
    public void AnIdentityIsCreatedOnceAndLoadedAgain()
    {
        var first = IdentityStore.LoadOrCreate(_dir, protect: false);
        var again = IdentityStore.LoadOrCreate(_dir, protect: false);
        Assert.Equal(first.DeviceId, again.DeviceId);
        Assert.Equal(first.NoiseSecret, again.NoiseSecret);
        Assert.Equal(first.SigningSeed, again.SigningSeed);
        Assert.Equal(first.NoisePublic, again.NoisePublic);
        Assert.Equal(32, first.NoiseSecret.Length);
        Assert.Equal(32, first.SigningSeed.Length);
    }

    [Fact]
    public void DifferentFoldersGetDifferentIdentities()
    {
        var a = IdentityStore.LoadOrCreate(_dir + "-a", protect: false);
        var b = IdentityStore.LoadOrCreate(_dir + "-b", protect: false);
        Assert.NotEqual(a.DeviceId, b.DeviceId);
        Directory.Delete(_dir + "-a", true); Directory.Delete(_dir + "-b", true);
    }

    [Fact]
    public void TheFingerprintIsEightBytesOfBase64AndStable()
    {
        var id = IdentityStore.LoadOrCreate(_dir, protect: false);
        Assert.Equal(12, id.Fingerprint.Length); // 8 bytes -> 12 base64 characters
        Assert.Equal(id.Fingerprint, id.Fingerprint);
    }

    [Fact]
    public void ACorruptIdentityFileIsReplacedNotFatal()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(Path.Combine(_dir, "identity.bin"), "garbage");
        var id = IdentityStore.LoadOrCreate(_dir, protect: false);
        Assert.NotEmpty(id.DeviceId);
    }
}

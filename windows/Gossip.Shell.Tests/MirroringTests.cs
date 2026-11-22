using Gossip.Shell;
using Xunit;

public class MirroringTests
{
    [Fact]
    public void NotificationTextJoinsAppAndTitle()
    {
        var t = Mirroring.NotificationText("notification.posted", """{"appName":"Messages","title":"Mum","body":"Dinner at 7?"}""");
        Assert.Equal(("Messages: Mum", "Dinner at 7?"), t);
    }

    [Fact]
    public void NotificationTextFallsBackToWhatIsThere()
    {
        Assert.Equal(("Messages", "hi"), Mirroring.NotificationText("notification.posted", """{"appName":"Messages","title":"","body":"hi"}"""));
        Assert.Equal(("Mum", ""), Mirroring.NotificationText("notification.posted", """{"title":"Mum"}"""));
    }

    [Fact]
    public void NotificationTextIgnoresOtherKindsEmptyAndBrokenPayloads()
    {
        Assert.Null(Mirroring.NotificationText("clipboard.update", """{"title":"x"}"""));
        Assert.Null(Mirroring.NotificationText("notification.posted", """{"appName":"A","title":"","body":""}"""));
        Assert.Null(Mirroring.NotificationText("notification.posted", "not json"));
    }

    [Theory]
    [InlineData("""{"level":87,"isCharging":false}""", "87%")]
    [InlineData("""{"level":5,"isCharging":true}""", "5% · charging")]
    [InlineData("""{"isCharging":true}""", null)]
    [InlineData("garbage", null)]
    [InlineData(null, null)]
    public void BatteryText(string? json, string? expected) => Assert.Equal(expected, Mirroring.BatteryText(json));
}

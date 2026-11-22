using System.Text.Json.Nodes;
using Gossip.Shell;
using Xunit;

public class NotificationModelTests
{
    [Fact]
    public void ParsesAPlainNotification()
    {
        var n = MirroredNotification.Parse("notification.posted", "phone-1",
            """{"id":"n1","appName":"Messages","title":"Mum","body":"Dinner?","hasReplyAction":true}""")!;
        Assert.Equal("n1", n.Id);
        Assert.Equal("phone-1", n.SourceDeviceId);
        Assert.Equal("Messages: Mum", n.Heading);
        Assert.True(n.HasReply);
        Assert.Empty(n.Buttons);
        Assert.Null(n.Live);
    }

    [Fact]
    public void ParsesTheRicherFields()
    {
        var n = MirroredNotification.Parse("notification.posted", "p",
            """{"id":"n2","appName":"Mail","title":"Hi","body":"x","actions":[{"index":0,"title":"Archive"},{"index":1,"title":"Mark read"}],"smartReplies":["Yes","No",""],"avatarBase64":"AAA","live":{"kind":"progress","progress":30,"max":120}}""")!;
        Assert.Equal(new[] { "Archive", "Mark read" }, n.Buttons.Select(b => b.Title));
        Assert.Equal(new[] { "Yes", "No" }, n.SmartReplies);
        Assert.Equal("AAA", n.AvatarBase64);
        Assert.Equal("25%", n.ProgressText);
    }

    [Fact]
    public void ALiveNotificationNeedsNoText()
    {
        var n = MirroredNotification.Parse("notification.posted", "p", """{"id":"t","title":"","body":"","live":{"kind":"timer","chronometerBase":1700000000000}}""")!;
        Assert.Equal("timer", n.Live!.Kind);
        Assert.Equal(1700000000000, n.Live.ChronometerBase);
    }

    [Theory]
    [InlineData("clipboard.update", """{"id":"x","title":"t"}""")]
    [InlineData("notification.posted", """{"title":"no id"}""")]
    [InlineData("notification.posted", """{"id":"x","title":"","body":""}""")]
    [InlineData("notification.posted", "not json")]
    public void IgnoresWhatItCannotShow(string kind, string json) => Assert.Null(MirroredNotification.Parse(kind, "p", json));

    [Fact]
    public void ReplyAndActionPayloadsCarryAFreshAttemptEachTime()
    {
        var a = JsonNode.Parse(NotificationReplies.Reply("n1", "on my way"))!;
        var b = JsonNode.Parse(NotificationReplies.Reply("n1", "on my way"))!;
        Assert.Equal("n1", (string)a["id"]!);
        Assert.Equal("on my way", (string)a["text"]!);
        Assert.NotEqual((string)a["attemptId"]!, (string)b["attemptId"]!);

        var x = JsonNode.Parse(NotificationReplies.Action("n1", 2))!;
        var y = JsonNode.Parse(NotificationReplies.Action("n1", 2))!;
        Assert.Equal(2, (int)x["index"]!);
        Assert.NotEqual((string)x["attemptId"]!, (string)y["attemptId"]!);
        Assert.Equal("n1", (string)JsonNode.Parse(NotificationReplies.Dismiss("n1"))!["id"]!);
    }
}

public class ToastAnswersTests
{
    private static Dictionary<string, string> Args(params (string, string)[] kv) => kv.ToDictionary(x => x.Item1, x => x.Item2);

    [Fact]
    public void ATypedReplyBecomesANotificationReplyToThePhone()
    {
        var a = ToastAnswers.Route(Args(("id", "n1"), ("src", "phone"), ("action", "reply")), Args(("reply", "on my way")))!.Value;
        Assert.Equal("notification.reply", a.Kind);
        Assert.Equal("phone", a.RecipientId);
        Assert.Equal("on my way", (string)System.Text.Json.Nodes.JsonNode.Parse(a.PayloadJson)!["text"]!);
    }

    [Fact]
    public void AnEmptyReplyIsNotSent() =>
        Assert.Null(ToastAnswers.Route(Args(("id", "n1"), ("src", "phone"), ("action", "reply")), Args(("reply", "   "))));

    [Fact]
    public void ASmartReplySendsItsOwnText()
    {
        var a = ToastAnswers.Route(Args(("id", "n1"), ("src", "phone"), ("action", "smart"), ("text", "Yes")), Args())!.Value;
        Assert.Equal("Yes", (string)System.Text.Json.Nodes.JsonNode.Parse(a.PayloadJson)!["text"]!);
    }

    [Fact]
    public void AButtonSendsAnActionWithItsIndex()
    {
        var a = ToastAnswers.Route(Args(("id", "n1"), ("src", "phone"), ("action", "button"), ("index", "2")), Args())!.Value;
        Assert.Equal("notification.action", a.Kind);
        Assert.Equal(2, (int)System.Text.Json.Nodes.JsonNode.Parse(a.PayloadJson)!["index"]!);
    }

    [Theory]
    [InlineData("button", "x")]   // a button index that is not a number
    [InlineData("unknown", "0")]
    public void BadArgumentsSendNothing(string action, string index) =>
        Assert.Null(ToastAnswers.Route(Args(("id", "n1"), ("src", "phone"), ("action", action), ("index", index)), Args()));

    [Fact]
    public void WithoutAnIdOrSourceNothingIsSent() =>
        Assert.Null(ToastAnswers.Route(Args(("action", "reply")), Args(("reply", "hi"))));
}

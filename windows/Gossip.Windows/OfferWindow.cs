using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Gossip.Windows;

/// <summary>The accept prompt for an incoming file. Declining is the default: closing the window, or two minutes of silence, answers No.</summary>
internal sealed class OfferWindow : Window
{
    private readonly TaskCompletionSource<bool> _answer = new();
    private readonly DispatcherTimer _timeout = new() { Interval = TimeSpan.FromMinutes(2) };

    public Task<bool> Answer => _answer.Task;

    public OfferWindow(string peerName, string name, string size)
    {
        Title = "Receive a file";
        Width = 380;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI");

        var yes = new Button { Content = "Accept", Name = "AcceptButton", IsDefault = false, Padding = new Thickness(20, 6, 20, 6), Margin = new Thickness(0, 0, 8, 0) };
        var no = new Button { Content = "Decline", Name = "DeclineButton", IsDefault = true, IsCancel = true, Padding = new Thickness(20, 6, 20, 6) };
        yes.Click += (_, _) => { _answer.TrySetResult(true); Close(); };
        no.Click += (_, _) => { _answer.TrySetResult(false); Close(); };
        Content = new StackPanel
        {
            Margin = new Thickness(22),
            Children =
            {
                new TextBlock { Text = $"{peerName} wants to send you a file", FontSize = 16, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = name, Margin = new Thickness(0, 10, 0, 0), TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = $"{size} · saved to your Downloads folder", Foreground = System.Windows.Media.Brushes.Gray, Margin = new Thickness(0, 2, 0, 0) },
                new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 18, 0, 0), Children = { yes, no } },
            },
        };
        Closed += (_, _) => { _timeout.Stop(); _answer.TrySetResult(false); };
        _timeout.Tick += (_, _) => Close();
        _timeout.Start();
    }
}

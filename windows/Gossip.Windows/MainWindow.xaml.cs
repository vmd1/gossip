using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using Gossip.Shell;

namespace Gossip.Windows;

public sealed record DeviceRow(string Id, string Name, string Detail, Brush Dot);

public partial class MainWindow : Window
{
    private readonly Node _node;

    internal MainWindow(Node node)
    {
        InitializeComponent();
        _node = node;
        _node.PeersChanged += () => Dispatcher.BeginInvoke(Refresh);
        Refresh();
    }

    // Closing the window hides it; the app keeps running in the tray (Quit is in the tray menu).
    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }

    private void Refresh()
    {
        var rows = _node.Peers().Select(p =>
        {
            var online = _node.IsConnected(p.DeviceId);
            return new DeviceRow(p.DeviceId, p.Name, $"{Describe(p.Type)} · {(online ? "connected" : "not connected")}",
                online ? Brushes.SeaGreen : Brushes.LightGray);
        }).ToList();
        Devices.ItemsSource = rows;
        EmptyText.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var n = rows.Count(r => r.Dot == Brushes.SeaGreen);
        StatusText.Text = rows.Count == 0 ? $"{Environment.MachineName} · ready to pair" : $"{Environment.MachineName} · {n} of {rows.Count} connected";
    }

    private static string Describe(string type) => type switch
    {
        "mac" => "Mac",
        "android-phone" => "Android phone",
        "android-tablet" => "Android tablet",
        "windows" => "Windows PC",
        "linux" => "Linux PC",
        _ => "Device",
    };

    internal void ShowCode()
    {
        var code = _node.StartShowingCode();
        var dialog = new CodeWindow(code) { Owner = this };
        void Finished(string result) { if (result == "ok") Dispatcher.BeginInvoke(() => dialog.Close()); }
        _node.CodePairingFinished += Finished;
        dialog.ShowDialog();
        _node.CodePairingFinished -= Finished;
        _node.StopShowingCode();
        Refresh();
    }

    private void OnShowCode(object sender, RoutedEventArgs e) => ShowCode();

    private void OnEnterCode(object sender, RoutedEventArgs e)
    {
        new EnterCodeWindow(_node) { Owner = this }.ShowDialog();
        Refresh();
    }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        if (Devices.SelectedItem is not DeviceRow row) { MessageBox.Show(this, "Select a device to remove first.", "Gossip"); return; }
        if (MessageBox.Show(this, $"Remove {row.Name}? It will no longer be able to connect to this PC.", "Remove device",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        _node.Revoke(row.Id);
        Refresh();
    }
}

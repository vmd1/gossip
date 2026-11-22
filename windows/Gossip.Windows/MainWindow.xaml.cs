using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using Gossip.Shell;

namespace Gossip.Windows;

public sealed record DeviceRow(string Id, string Name, string Detail, Brush Dot);

public partial class MainWindow : Window
{
    private readonly Node _node;
    private readonly FindMyDevice _find;
    private readonly MediaRemote _media;
    private readonly ProximityMonitor _proximity;
    private readonly FileTransferService _files;

    internal MainWindow(Node node, FindMyDevice find, MediaRemote media, ProximityMonitor proximity, FileTransferService files)
    {
        InitializeComponent();
        _node = node;
        _find = find;
        _media = media;
        _proximity = proximity;
        _files = files;
        _files.Changed += t => Dispatcher.BeginInvoke(() =>
        {
            TransferText.Text = t.State is "done" ? $"{(t.Outgoing ? "Sent" : "Received")} {t.Name}"
                : t.State is "failed" or "rejected" or "cancelled" ? $"{t.Name}: {t.State}"
                : $"{(t.Outgoing ? "Sending" : "Receiving")} {t.Name}: {(t.Size == 0 ? 100 : t.Bytes * 100 / t.Size)}%";
        });
        Devices.AllowDrop = true;
        Devices.Drop += OnDropFiles;
        _proximity.Changed += () => Dispatcher.BeginInvoke(Refresh);
        LockCheck.IsChecked = _proximity.LockOnLeaveEnabled;
        _media.Changed += () => Dispatcher.BeginInvoke(RefreshMedia);
        RefreshMedia();
        _find.PeersChanged += () => Dispatcher.BeginInvoke(Refresh);
        _node.PeersChanged += () => Dispatcher.BeginInvoke(Refresh);
        _node.StateChanged += (_, slot, _) => { if (slot == uniffi.gossip_ffi.GossipFfiMethods.BatterySlot()) Dispatcher.BeginInvoke(Refresh); };
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
            var battery = Mirroring.BatteryText(_node.GetState(p.DeviceId, uniffi.gossip_ffi.GossipFfiMethods.BatterySlot()));
            return new DeviceRow(p.DeviceId, p.Name,
                $"{Describe(p.Type)} · {(online ? "connected" : "not connected")}{(_find.IsRinging(p.DeviceId) ? " · ringing" : "")}{(_proximity.IsNearby(p.DeviceId) ? " · nearby" : "")}{(battery != null ? $" · battery {battery}" : "")}",
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

    private void OnLockToggled(object sender, RoutedEventArgs e) => _proximity.SetLockOnLeave(LockCheck.IsChecked == true);

    private void RefreshMedia()
    {
        var now = _media.Current;
        MediaPanel.Visibility = now == null ? Visibility.Collapsed : Visibility.Visible;
        if (now == null) return;
        MediaTitle.Text = string.IsNullOrEmpty(now.Title) ? "Playing" : now.Title;
        MediaDetail.Text = $"{now.Artist}{(string.IsNullOrEmpty(_media.DeviceName) ? "" : $" · on {_media.DeviceName}")}".TrimStart(' ', '·');
        MediaPlay.Content = now.IsPlaying ? "Pause" : "Play";
    }

    private void OnMediaPrevious(object sender, RoutedEventArgs e) => _media.Command(uniffi.gossip_ffi.MediaAction.Previous);
    private void OnMediaNext(object sender, RoutedEventArgs e) => _media.Command(uniffi.gossip_ffi.MediaAction.Next);
    private void OnMediaPlay(object sender, RoutedEventArgs e) =>
        _media.Command(_media.Current?.IsPlaying == true ? uniffi.gossip_ffi.MediaAction.Pause : uniffi.gossip_ffi.MediaAction.Play);

    private async void SendFiles(string peerId, IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            try { await _files.SendFileAsync(peerId, path); }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Send a file"); }
        }
    }

    private void OnSendFile(object sender, RoutedEventArgs e)
    {
        if (Devices.SelectedItem is not DeviceRow row) { MessageBox.Show(this, "Select a device to send to first.", "Gossip"); return; }
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = $"Send to {row.Name}" };
        if (dialog.ShowDialog(this) == true) SendFiles(row.Id, dialog.FileNames);
    }

    // Dropping files on a device row sends them to that device.
    private void OnDropFiles(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        var item = (e.OriginalSource as FrameworkElement)?.DataContext as DeviceRow ?? Devices.SelectedItem as DeviceRow;
        if (item == null) { MessageBox.Show(this, "Drop the files on a device in the list.", "Gossip"); return; }
        SendFiles(item.Id, paths.Where(System.IO.File.Exists));
    }

    private void OnMessages(object sender, RoutedEventArgs e)
    {
        var phone = (Devices.SelectedItem is DeviceRow row ? _node.Peers().FirstOrDefault(p => p.DeviceId == row.Id) : null)
            ?? _node.Peers().FirstOrDefault(p => p.Type == "android-phone" && _node.IsConnected(p.DeviceId));
        if (phone == null || phone.Type != "android-phone") { MessageBox.Show(this, "Connect your phone, or select it in the list, to open its messages.", "Gossip"); return; }
        new MessagesWindow(_node, phone.DeviceId, phone.Name) { Owner = this }.Show();
    }

    private void OnRing(object sender, RoutedEventArgs e)
    {
        if (Devices.SelectedItem is not DeviceRow row) { MessageBox.Show(this, "Select a device to ring first.", "Gossip"); return; }
        _find.Toggle(row.Id);
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

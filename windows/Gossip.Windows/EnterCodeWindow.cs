using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Gossip.Shell;

namespace Gossip.Windows;

/// <summary>Pick a device that is showing a code, type the code, pair.</summary>
internal sealed class EnterCodeWindow : Window
{
    private readonly Node _node;
    private readonly ComboBox _devices = new() { Margin = new Thickness(0, 0, 0, 12) };
    private readonly TextBox _code = new() { FontSize = 22, FontFamily = new System.Windows.Media.FontFamily("Consolas"), CharacterCasing = CharacterCasing.Upper, Margin = new Thickness(0, 0, 0, 12), MaxLength = 12 };
    private readonly TextBlock _status = new() { Style = Theme.CaptionStyle, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12), MinHeight = 36 };
    private readonly Button _pair = new() { Style = Theme.AccentStyle, Content = "Pair", Padding = new Thickness(18, 6, 18, 6), IsDefault = true, IsEnabled = false };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private List<DiscoveredPeer> _found = new();

    public EnterCodeWindow(Node node)
    {
        _node = node;
        Title = "Enter a code";
        Width = 400; Height = 340; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI");
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = "On the other device, choose “Show a code”, then pick it here and type the code.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
        panel.Children.Add(new TextBlock { Text = "Device", Style = Theme.CaptionStyle });
        panel.Children.Add(_devices);
        panel.Children.Add(new TextBlock { Text = "Code", Style = Theme.CaptionStyle });
        panel.Children.Add(_code);
        panel.Children.Add(_status);
        panel.Children.Add(_pair);
        Content = panel;

        _code.TextChanged += (_, _) => UpdateButton();
        _pair.Click += async (_, _) => await PairAsync();
        _node.CodePairingFinished += OnFinished;
        _timer.Tick += (_, _) => RefreshDevices();
        _timer.Start();
        Closed += (_, _) => { _timer.Stop(); _node.CodePairingFinished -= OnFinished; };
        RefreshDevices();
    }

    private void RefreshDevices()
    {
        var list = _node.PairableDevices().ToList();
        if (list.Select(p => p.DeviceId).SequenceEqual(_found.Select(p => p.DeviceId))) return;
        var selected = (_devices.SelectedItem as ComboBoxItem)?.Tag as DiscoveredPeer;
        _found = list;
        _devices.Items.Clear();
        foreach (var p in list)
        {
            var item = new ComboBoxItem { Content = p.Instance.Split('.')[0].Replace("\\032", " ").Replace("\\8217", "’"), Tag = p };
            _devices.Items.Add(item);
            if (selected?.DeviceId == p.DeviceId) _devices.SelectedItem = item;
        }
        if (_devices.SelectedItem == null && _devices.Items.Count > 0) _devices.SelectedIndex = 0;
        _status.Text = list.Count == 0 ? "Looking for devices that are showing a code…" : "";
        UpdateButton();
    }

    private void UpdateButton() => _pair.IsEnabled = _devices.SelectedItem != null && _node.IsValidCode(_code.Text);

    private async Task PairAsync()
    {
        if ((_devices.SelectedItem as ComboBoxItem)?.Tag is not DiscoveredPeer target) return;
        _pair.IsEnabled = false;
        _status.Text = "Pairing…";
        if (!await _node.PairWithCodeAsync(target, _code.Text))
        {
            _status.Text = "Could not reach that device. Make sure both are on the same network.";
            UpdateButton();
        }
    }

    private void OnFinished(string result) => Dispatcher.BeginInvoke(() =>
    {
        if (result == "ok") { MessageBox.Show(this, "Paired.", "Gossip"); Close(); }
        else { _status.Text = $"Pairing failed: {result}."; UpdateButton(); }
    });
}

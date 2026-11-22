using System.Windows;
using Gossip.Shell;

namespace Gossip.Windows;

public partial class App : Application
{
    private Mutex? _single;
    private Node? _node;
    private TrayIcon? _tray;
    private MainWindow? _window;
    private ClipboardSync? _clipboard;
    private ToastManager? _toasts;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _single = new Mutex(true, "Gossip.Windows.SingleInstance", out var first);
        if (!first) { Shutdown(); return; }

        var dataDir = IdentityStore.DefaultDirectory;
        _node = new Node(IdentityStore.LoadOrCreate(dataDir), Environment.MachineName, dataDir);
        _node.PairingRequested += r => Dispatcher.Invoke(() => AskToPair(r));
        _node.PairingCancelled += _ => { };
        _node.Start();

        _window = new MainWindow(_node);
        _tray = new TrayIcon(
            open: () => Dispatcher.Invoke(ShowWindow),
            showCode: () => Dispatcher.Invoke(() => { ShowWindow(); _window!.ShowCode(); }),
            quit: () => Dispatcher.Invoke(Quit));
        _clipboard = new ClipboardSync(_node, Dispatcher);
        _toasts = new ToastManager(_node);
        _node.Received += (env, _) =>
        {
            if (env.Kind == "notification.removed")
            {
                try { using var d = System.Text.Json.JsonDocument.Parse(env.PayloadJson); if (d.RootElement.TryGetProperty("id", out var id)) _toasts.Remove(id.GetString() ?? ""); } catch { }
                return;
            }
            var n = MirroredNotification.Parse(env.Kind, env.SenderId, env.PayloadJson);
            if (n != null) _toasts.Show(n);
        };
        if (!e.Args.Contains("--minimized")) ShowWindow();
    }

    private void ShowWindow()
    {
        _window!.Show();
        _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    private void AskToPair(PairingRequest r)
    {
        ShowWindow();
        var ok = MessageBox.Show(_window,
            $"{r.DeviceName} wants to pair with this PC.\n\nMake sure this code is the same on both screens:\n\n{r.Code}",
            "Pair a new device", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
        _node!.ConfirmPairing(r.Conn, ok);
    }

    private void Quit()
    {
        _clipboard?.Dispose();
        _toasts?.Dispose();
        _tray?.Dispose();
        _node?.Dispose();
        Shutdown();
        Environment.Exit(0); // disposing the mDNS service can otherwise keep the process alive
    }
}

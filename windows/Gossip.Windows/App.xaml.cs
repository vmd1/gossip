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
    private FindMyDevice? _find;
    private PowerSync? _power;
    private DndSync? _dnd;
    private ProximityMonitor? _proximity;
    private FileTransferService? _files;
    private MediaRemote? _mediaRemote;

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

        _find = new FindMyDevice(_node, Dispatcher);
        _power = new PowerSync(_node, Dispatcher);
        _dnd = new DndSync(_node, Dispatcher, dataDir);
        _mediaRemote = new MediaRemote(_node);
        _proximity = new ProximityMonitor(_node, Dispatcher, dataDir);
        var downloads = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + @"\Downloads";
        _files = new FileTransferService(_node, downloads, dataDir, offer => Dispatcher.InvokeAsync(() =>
        {
            var prompt = new OfferWindow(offer.PeerName, offer.Name, FormatSize(offer.Size));
            prompt.Show();
            prompt.Activate();
            return prompt.Answer;
        }).Task.Unwrap());
        _files.Problem += m => { try { System.IO.File.AppendAllText(System.IO.Path.Combine(dataDir, "filetransfer.log"), $"{DateTime.Now:s} {m}\n"); } catch { } };
        _files.Changed += t =>
        {
            if (t.State is "done" or "failed" or "rejected")
                Dispatcher.BeginInvoke(() => _tray?.Notify(t.Outgoing ? "File sent" : "File received", t.State == "done" ? t.Name : $"{t.Name}: {t.State}"));
        };
        _window = new MainWindow(_node, _find, _mediaRemote, _proximity, _files);
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

    internal static string FormatSize(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} bytes",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB",
        < 1024L * 1024 * 1024 => $"{bytes / 1048576.0:0.#} MB",
        _ => $"{bytes / 1073741824.0:0.##} GB",
    };

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
        _files?.Dispose();
        _proximity?.Dispose();
        _dnd?.Dispose();
        _mediaRemote?.Dispose();
        _find?.Dispose();
        _power?.Dispose();
        _clipboard?.Dispose();
        _toasts?.Dispose();
        _tray?.Dispose();
        _node?.Dispose();
        Shutdown();
        Environment.Exit(0); // disposing the mDNS service can otherwise keep the process alive
    }
}

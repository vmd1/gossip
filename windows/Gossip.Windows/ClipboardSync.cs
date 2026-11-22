using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Gossip.Shell;
using uniffi.gossip_ffi;

namespace Gossip.Windows;

/// <summary>
/// Clipboard text sync. A local copy is published in the <c>clipboard.text</c> state slot; a peer's slot is written to this
/// PC's clipboard. The core's <see cref="ClipboardGuard"/> decides what may be sent (not sensitive, not too large, not an
/// echo of what a peer just sent us), so this class only does the Windows part: listening and reading/writing.
/// </summary>
internal sealed class ClipboardSync : IDisposable
{
    private const int WM_CLIPBOARDUPDATE = 0x031D;
    private static readonly IntPtr HWND_MESSAGE = new(-3);

    [DllImport("user32.dll", SetLastError = true)] private static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    private readonly Node _node;
    private readonly Dispatcher _ui;
    private readonly ClipboardGuard _guard = new();
    private readonly HwndSource _source;
    private readonly string _slot = GossipFfiMethods.ClipboardTextSlot();

    public ClipboardSync(Node node, Dispatcher ui)
    {
        _node = node;
        _ui = ui;
        _source = new HwndSource(new HwndSourceParameters("GossipClipboard") { ParentWindow = HWND_MESSAGE, Width = 0, Height = 0 });
        _source.AddHook(Hook);
        AddClipboardFormatListener(_source.Handle);
        _node.StateChanged += OnState;
        _node.Received += OnReceived;
        // Publish whatever is on the clipboard now, so a peer that connects later still gets it (the slot persists).
        _ = _ui.BeginInvoke(PublishCurrent);
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_CLIPBOARDUPDATE) PublishCurrent();
        return IntPtr.Zero;
    }

    private void PublishCurrent()
    {
        try
        {
            // Password managers and Windows' own clipboard history mark such content with this format: never sync it.
            Retry(() => Clipboard.GetDataObject()?.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing") == true, out var sensitive);
            if (Retry(() => Clipboard.ContainsText(), out var hasText) && hasText)
            {
                if (!Retry(() => Clipboard.GetText(), out var text) || string.IsNullOrEmpty(text)) return;
                var textValue = _guard.OutgoingText(_node.DeviceId, text, sensitive);
                if (textValue != null) _node.SetState(_slot, textValue);
                return;
            }
            if (Retry(() => Clipboard.ContainsImage(), out var hasImage) && hasImage)
            {
                if (!Retry(() => Clipboard.GetImage(), out var image) || image == null) return;
                var png = EncodePng(image);
                var message = _guard.OutgoingImage(_node.DeviceId, png, sensitive);
                if (message != null) _node.SendWithRaw(message.Kind, message.Recipient, message.PayloadJson, png);
                return;
            }
        }
        catch (Exception) { /* the clipboard is shared with every app: a failed read is simply skipped */ }
    }

    private static byte[] EncodePng(System.Windows.Media.Imaging.BitmapSource image)
    {
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    // An image from a peer: the core checks it is a sane PNG and not an echo of what we just sent.
    private void OnReceived(Envelope env, byte[]? raw)
    {
        if (env.Kind != "clipboard.update" || raw == null) return;
        try
        {
            if (!_guard.IncomingImage(env.PayloadJson, raw)) return;
            _ui.BeginInvoke(() =>
            {
                var decoder = new System.Windows.Media.Imaging.PngBitmapDecoder(new MemoryStream(raw),
                    System.Windows.Media.Imaging.BitmapCreateOptions.PreservePixelFormat, System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
                var frame = decoder.Frames[0];
                Retry(() => { Clipboard.SetImage(frame); return true; }, out _);
            });
        }
        catch (Exception) { }
    }

    private void OnState(string deviceId, string slot, string? valueJson)
    {
        if (slot != _slot || valueJson == null || deviceId == _node.DeviceId) return;
        string? text;
        try { text = _guard.IncomingText(valueJson); } catch { return; }
        if (text == null) return;
        _ui.BeginInvoke(() => Retry(() => { Clipboard.SetText(text); return true; }, out _));
    }

    /// <summary>The clipboard can be locked by another app for a moment (CLIPBRD_E_CANT_OPEN): try a few times.</summary>
    private static bool Retry<T>(Func<T> read, out T value)
    {
        for (var i = 0; i < 5; i++)
        {
            try { value = read(); return true; }
            catch (COMException) { Thread.Sleep(40); }
        }
        value = default!;
        return false;
    }

    public void Dispose()
    {
        _node.StateChanged -= OnState;
        _node.Received -= OnReceived;
        RemoveClipboardFormatListener(_source.Handle);
        _source.Dispose();
    }
}

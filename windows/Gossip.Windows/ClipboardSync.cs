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
            if (!Retry(() => Clipboard.ContainsText(), out var hasText) || !hasText) return;
            if (!Retry(() => Clipboard.GetText(), out var text) || string.IsNullOrEmpty(text)) return;
            // Password managers and Windows' own clipboard history mark such content with this format: never sync it.
            Retry(() => Clipboard.GetDataObject()?.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing") == true, out var sensitive);
            var value = _guard.OutgoingText(_node.DeviceId, text, sensitive);
            if (value != null) _node.SetState(_slot, value);
        }
        catch (Exception) { /* the clipboard is shared with every app: a failed read is simply skipped */ }
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
        RemoveClipboardFormatListener(_source.Handle);
        _source.Dispose();
    }
}

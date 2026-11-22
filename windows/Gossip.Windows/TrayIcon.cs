using System.Drawing;
using System.Windows.Forms;

namespace Gossip.Windows;

/// <summary>The notification-area icon: left click opens the window, the menu offers the code and quit.</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon _icon;

    public TrayIcon(Action open, Action showCode, Action quit)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open Gossip", null, (_, _) => open());
        menu.Items.Add("Show pairing code", null, (_, _) => showCode());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => quit());
        _icon = new NotifyIcon { Icon = SystemIcons.Application, Text = "Gossip", Visible = true, ContextMenuStrip = menu };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) open(); };
    }

    public void Notify(string title, string text) => _icon.ShowBalloonTip(5000, title, text, ToolTipIcon.None);

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}

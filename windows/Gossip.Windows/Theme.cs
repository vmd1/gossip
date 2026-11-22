using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace Gossip.Windows;

/// <summary>Follows the Windows light/dark setting: swaps the brushes in Theme.xaml and darkens every window's title bar.</summary>
internal static class Theme
{
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    public static Style CaptionStyle => (Style)Application.Current.Resources["Caption"];

    public static Style AccentStyle => (Style)Application.Current.Resources["AccentButton"];
    public static Style PlainItemStyle => (Style)Application.Current.Resources["PlainItem"];

    public static bool IsDark { get; private set; }

    public static void Start()
    {
        Apply();
        SystemEvents.UserPreferenceChanged += (_, _) => Application.Current.Dispatcher.BeginInvoke(() => { Apply(); foreach (Window w in Application.Current.Windows) Chrome(w); });
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler((s, _) => Chrome((Window)s)));
    }

    private static bool SystemIsDark()
    {
        try { return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int v && v == 0; }
        catch { return false; }
    }

    private static void Set(string key, string hex) =>
        Application.Current.Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));

    private static void Apply()
    {
        IsDark = SystemIsDark();
        if (IsDark)
        {
            Set("Window", "#202020"); Set("Card", "#2B2B2B"); Set("CardHover", "#323232"); Set("Border", "#3A3A3A");
            Set("Text", "#F3F3F3"); Set("Subtle", "#A3A3A3"); Set("Accent", "#4CC2FF"); Set("AccentHover", "#6BCDFF");
            Set("AccentText", "#003A5C"); Set("Selected", "#1E3A4D"); Set("Good", "#4CC27F"); Set("Idle", "#6A6A6A");
            Set("Danger", "#FF6B5E"); Set("BubbleOut", "#1F4B6E"); Set("BubbleIn", "#3A3A3A");
        }
        else
        {
            Set("Window", "#F3F3F3"); Set("Card", "#FFFFFF"); Set("CardHover", "#F6F6F6"); Set("Border", "#E3E3E3");
            Set("Text", "#1B1B1B"); Set("Subtle", "#6B6B6B"); Set("Accent", "#0067C0"); Set("AccentHover", "#1A78CB");
            Set("AccentText", "#FFFFFF"); Set("Selected", "#E6F0FA"); Set("Good", "#2E9E5B"); Set("Idle", "#B8B8B8");
            Set("Danger", "#C42B1C"); Set("BubbleOut", "#D6E8FA"); Set("BubbleIn", "#EAEAEA");
        }
    }

    public static void Chrome(Window w)
    {
        w.SetResourceReference(Control.BackgroundProperty, "Window");
        w.SetResourceReference(Control.ForegroundProperty, "Text");
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = IsDark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int)); // DWMWA_USE_IMMERSIVE_DARK_MODE
        var round = 2;
        DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int)); // DWMWA_WINDOW_CORNER_PREFERENCE: rounded
    }
}

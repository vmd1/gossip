using System.Windows;
using System.Windows.Controls;

namespace Gossip.Windows;

/// <summary>Shows a pairing code for another device to type in.</summary>
internal sealed class CodeWindow : Window
{
    public CodeWindow(string code)
    {
        Title = "Pairing code";
        Width = 380; Height = 230; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI");
        var panel = new StackPanel { Margin = new Thickness(24), VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock { Text = "On your other device, choose “Enter a code” and type:", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
        panel.Children.Add(new TextBlock { Text = code, FontSize = 36, FontWeight = FontWeights.SemiBold, FontFamily = new System.Windows.Media.FontFamily("Consolas"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 16) });
        var close = new Button { Content = "Done", Padding = new Thickness(18, 6, 18, 6), HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true };
        close.Click += (_, _) => Close();
        panel.Children.Add(close);
        Content = panel;
    }
}

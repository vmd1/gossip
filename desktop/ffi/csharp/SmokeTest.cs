using System;
using uniffi.gossip_ffi;

// Calls the real native core through the generated C# binding: exits non-zero if the binding or the library is broken.
public static class SmokeTest
{
    public static int Main()
    {
        var phone = GossipFfiMethods.ControlDefaultPixelSize("android-phone");
        var desktop = GossipFfiMethods.ControlDefaultPixelSize("windows");
        if (phone.Width != 1080 || phone.Height != 2400 || desktop.Width != 2000 || desktop.Height != 1200)
        {
            Console.Error.WriteLine($"unexpected sizes: {phone} {desktop}");
            return 1;
        }
        Console.WriteLine("C# binding OK");
        return 0;
    }
}

package dev.vmd1.gossip.features.screenmirror;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Runs at shell UID (launched by {@link ScrcpyServerSession} through Shizuku as
 * {@code CLASSPATH=<Gossip base.apk> app_process / dev.vmd1.gossip.features.screenmirror.ShellRelay <socket> <audio 0|1>}).
 *
 * <p>Why this exists: on Android 12 and 16 SELinux denies {@code untrusted_app -> shell
 * unix_stream_socket connectto} in both directions, so the Gossip app cannot connect to the scrcpy
 * server's abstract socket (forward mode) and the shell-UID server cannot connect to an abstract
 * socket the app listens on (reverse mode). Shizuku's stdio, however, is a binder pipe straight
 * to the app. So this relay — shell-to-shell connect is allowed — dials the scrcpy server's video
 * and control sockets and multiplexes them over its own stdin/stdout.
 *
 * <p>Plain Java, no Kotlin stdlib, so it runs from bare {@code app_process} with only the app's
 * APK on the classpath. Wire format over stdio, both directions: {@code [channel u8][len u32 BE][bytes]}.
 * Channels: {@link #VIDEO} (server->app), {@link #CONTROL} (app->server), {@link #DEVICE_MSG}
 * (server->app, control-socket reads), {@link #AUDIO} (server->app, only when audio is enabled). A frame with {@code len == 0} on {@link #CONTROL} is ignored.
 * The scrcpy forward-tunnel dummy byte is consumed here.
 */
public final class ShellRelay {
    public static final int VIDEO = 0;
    public static final int CONTROL = 1;
    public static final int DEVICE_MSG = 2;
    public static final int AUDIO = 3;

    private static final Object OUT_LOCK = new Object();

    public static void main(String[] args) throws Exception {
        String name = args[0];
        boolean audioEnabled = args.length > 1 && args[1].equals("1");
        // scrcpy accepts its sockets in a fixed order: video, [audio], control.
        LocalSocket video = connect(name);
        LocalSocket audio = audioEnabled ? connect(name) : null;
        LocalSocket control = connect(name);
        DataOutputStream out = new DataOutputStream(new java.io.BufferedOutputStream(System.out, 64 * 1024));
        // forward tunnel: server writes one dummy byte on the first socket once both are accepted
        InputStream vin = video.getInputStream();
        if (vin.read() < 0) throw new IOException("server closed before dummy byte");

        pump(vin, out, VIDEO, "relay-video");
        if (audio != null) pump(audio.getInputStream(), out, AUDIO, "relay-audio");
        pump(control.getInputStream(), out, DEVICE_MSG, "relay-devmsg");

        DataInputStream in = new DataInputStream(System.in);
        OutputStream controlOut = control.getOutputStream();
        try {
            while (true) {
                int channel = in.read();
                if (channel < 0) break;
                int len = in.readInt();
                byte[] buf = new byte[len];
                in.readFully(buf);
                if (channel == CONTROL && len > 0) {
                    controlOut.write(buf);
                    controlOut.flush();
                }
            }
        } finally {
            // app went away (stdin EOF): tear everything down so the scrcpy server exits too
            try { video.close(); } catch (IOException ignored) { }
            if (audio != null) { try { audio.close(); } catch (IOException ignored) { } }
            try { control.close(); } catch (IOException ignored) { }
            System.exit(0);
        }
    }

    private static LocalSocket connect(String name) throws Exception {
        long deadline = System.currentTimeMillis() + 10_000;
        IOException last = null;
        while (System.currentTimeMillis() < deadline) {
            LocalSocket s = new LocalSocket();
            try {
                s.connect(new LocalSocketAddress(name, LocalSocketAddress.Namespace.ABSTRACT));
                return s;
            } catch (IOException e) {
                last = e;
                try { s.close(); } catch (IOException ignored) { }
                Thread.sleep(100);
            }
        }
        throw new IOException("could not connect to " + name, last);
    }

    private static void pump(final InputStream src, final DataOutputStream out, final int channel, String threadName) {
        Thread t = new Thread(() -> {
            byte[] buf = new byte[64 * 1024];
            try {
                while (true) {
                    int n = src.read(buf);
                    if (n < 0) break;
                    synchronized (OUT_LOCK) {
                        out.writeByte(channel);
                        out.writeInt(n);
                        out.write(buf, 0, n);
                        out.flush();
                    }
                }
            } catch (IOException ignored) {
            }
            System.exit(0); // either socket closing ends the session
        }, threadName);
        t.setDaemon(true);
        t.start();
    }

    private ShellRelay() { }
}

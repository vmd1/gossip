package dev.vmd1.gossip.features.screenmirror;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;

/**
 * Runs at shell UID (launched by {@link RemoteUnlock} through Shizuku as
 * {@code CLASSPATH=<Gossip base.apk> app_process / dev.vmd1.gossip.features.screenmirror.KeyguardUnlocker}) and types
 * the lock-screen credential on the phone's own display, for "unlock from the Mac" before a whole-screen mirror.
 *
 * <p>The credential is read from stdin (one line), never from argv, so it doesn't show up in {@code ps} or
 * {@code /proc/<pid>/cmdline}, and it is never logged. Exactly one attempt is made:
 * <ol>
 *   <li>wake the screen and swipe up to raise the bouncer;</li>
 *   <li>confirm the bouncer is really showing (SystemUI's {@code KeyguardUpdateMonitor} dump, or a UI dump listing
 *       {@code keyguard_security_container} where that isn't available) — if it isn't, nothing is typed, so a missing
 *       first digit can never turn into a counted wrong attempt;</li>
 *   <li>clear the entry field with DEL presses (harmless on an empty field), type the credential with key events,
 *       and press ENTER only if the keyguard is still up (6-digit PINs submit themselves on the last digit; an ENTER
 *       on the then-empty field after a wrong PIN is not counted as an attempt).</li>
 * </ol>
 * The bouncer window is FLAG_SECURE, so the mirror can't show it, but it accepts injected key events.
 *
 * <p>Prints one line to stdout: {@code typed} or {@code no_bouncer}, or {@code error <reason>}. The caller judges
 * success itself from {@code KeyguardManager.isKeyguardLocked()}.
 *
 * <p>Plain Java, no Kotlin stdlib, so it runs from bare {@code app_process} with only the app's APK on the classpath
 * (like {@link ShellRelay}).
 */
public final class KeyguardUnlocker {
    private static final int INJECT_WAIT_FOR_FINISH = 2;
    private static final String DUMP = "/data/local/tmp/gossip-keyguard.xml";

    public static void main(String[] args) {
        String result;
        try {
            BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
            String secret = in.readLine();
            result = (secret == null || secret.isEmpty()) ? "error empty" : unlock(secret);
        } catch (Throwable t) {
            result = "error " + t.getClass().getSimpleName();
        }
        System.out.println(result);
        System.out.flush();
        System.exit(0);
    }

    private static String unlock(String secret) throws Exception {
        Method inject = injectMethod();
        Object im = inputManager();
        key(inject, im, KeyEvent.KEYCODE_WAKEUP);
        if (!waitForBouncer(300)) {
            int[] size = displaySize();
            swipeUp(inject, im, size[0], size[1]);
            if (!waitForBouncer(2000)) return "no_bouncer";
        }
        SystemClock.sleep(250); // let the bouncer finish appearing before the first key
        for (int i = 0; i < 20; i++) key(inject, im, KeyEvent.KEYCODE_DEL);
        KeyCharacterMap map = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
        KeyEvent[] events = map.getEvents(secret.toCharArray());
        if (events == null) return "error unsupported_characters";
        for (KeyEvent e : events) {
            KeyEvent timed = KeyEvent.changeTimeRepeat(e, SystemClock.uptimeMillis(), 0);
            timed.setSource(InputDevice.SOURCE_KEYBOARD);
            inject.invoke(im, timed, INJECT_WAIT_FOR_FINISH);
            if (e.getAction() == KeyEvent.ACTION_UP) SystemClock.sleep(40);
        }
        // A PIN that submits itself on its last digit unlocks within this window; anything else still needs ENTER.
        for (long end = SystemClock.uptimeMillis() + 700; SystemClock.uptimeMillis() < end; ) {
            if (!keyguardLocked()) return "typed";
            SystemClock.sleep(80);
        }
        key(inject, im, KeyEvent.KEYCODE_ENTER);
        return "typed";
    }

    /** Polls for the bouncer for up to [timeoutMs]. */
    private static boolean waitForBouncer(long timeoutMs) {
        long end = SystemClock.uptimeMillis() + timeoutMs;
        do {
            Boolean showing = bouncerFromSystemUi();
            if (showing == null) return bouncerFromUiDump(); // field not found on this build: fall back to the slow check
            if (showing) return true;
            SystemClock.sleep(100);
        } while (SystemClock.uptimeMillis() < end);
        return false;
    }

    /**
     * Fast check (~0.1 s): SystemUI's {@code KeyguardUpdateMonitor} dumpable reports
     * {@code mPrimaryBouncerIsOrWillBeShowing}. {@code null} when the field isn't there.
     */
    private static Boolean bouncerFromSystemUi() {
        try {
            Process p = new ProcessBuilder("dumpsys", "activity", "service",
                "com.android.systemui/.SystemUIService", "KeyguardUpdateMonitor").redirectErrorStream(true).start();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
            Boolean found = null;
            for (String line; (line = r.readLine()) != null; ) {
                int i = line.indexOf("mPrimaryBouncerIsOrWillBeShowing=");
                if (i >= 0 && found == null) found = line.substring(i + "mPrimaryBouncerIsOrWillBeShowing=".length()).trim().startsWith("true");
            }
            p.waitFor();
            return found;
        } catch (Exception e) {
            return null;
        }
    }

    /** Slow check (~2 s): dumps the visible UI and looks for the bouncer's container. */
    private static boolean bouncerFromUiDump() {
        try {
            new File(DUMP).delete();
            Process p = new ProcessBuilder("uiautomator", "dump", DUMP).redirectErrorStream(true).start();
            drain(p);
            p.waitFor();
            File f = new File(DUMP);
            if (!f.exists()) return false;
            byte[] buf = new byte[(int) f.length()];
            try (FileInputStream fin = new FileInputStream(f)) {
                int off = 0;
                while (off < buf.length) {
                    int n = fin.read(buf, off, buf.length - off);
                    if (n < 0) break;
                    off += n;
                }
            }
            f.delete();
            return new String(buf, StandardCharsets.UTF_8).contains("keyguard_security_container");
        } catch (Exception e) {
            return false;
        }
    }

    private static void drain(Process p) {
        try {
            byte[] b = new byte[4096];
            while (p.getInputStream().read(b) >= 0) { /* discard */ }
        } catch (Exception ignored) {
        }
    }

    private static void key(Method inject, Object im, int code) throws Exception {
        long now = SystemClock.uptimeMillis();
        inject.invoke(im, new KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0, 0,
            KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD), INJECT_WAIT_FOR_FINISH);
        inject.invoke(im, new KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, 0,
            KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD), INJECT_WAIT_FOR_FINISH);
    }

    /** A quick upward swipe through the middle of the screen, from 80% to 30% of its height. */
    private static void swipeUp(Method inject, Object im, int width, int height) throws Exception {
        float x = width / 2f;
        float y0 = height * 0.8f, y1 = height * 0.3f;
        long down = SystemClock.uptimeMillis();
        int steps = 10;
        motion(inject, im, down, down, MotionEvent.ACTION_DOWN, x, y0);
        for (int i = 1; i <= steps; i++) {
            SystemClock.sleep(15);
            motion(inject, im, down, SystemClock.uptimeMillis(), MotionEvent.ACTION_MOVE, x, y0 + (y1 - y0) * i / steps);
        }
        motion(inject, im, down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y1);
    }

    private static void motion(Method inject, Object im, long down, long t, int action, float x, float y) throws Exception {
        MotionEvent e = MotionEvent.obtain(down, t, action, x, y, 0);
        e.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        inject.invoke(im, e, INJECT_WAIT_FOR_FINISH);
        e.recycle();
    }

    /** The default display's logical size (what injected touch coordinates are in), from DisplayManagerGlobal. */
    private static int[] displaySize() throws Exception {
        Class<?> dmg = Class.forName("android.hardware.display.DisplayManagerGlobal");
        Object global = dmg.getMethod("getInstance").invoke(null);
        Object info = dmg.getMethod("getDisplayInfo", int.class).invoke(global, 0);
        int w = info.getClass().getField("logicalWidth").getInt(info);
        int h = info.getClass().getField("logicalHeight").getInt(info);
        return new int[] { w, h };
    }

    private static boolean keyguardLocked() {
        try {
            Class<?> wmg = Class.forName("android.view.WindowManagerGlobal");
            Object wm = wmg.getMethod("getWindowManagerService").invoke(null);
            return (Boolean) wm.getClass().getMethod("isKeyguardLocked").invoke(wm);
        } catch (Exception e) {
            return false;
        }
    }

    /** InputManagerGlobal on Android 14+, InputManager before; both have {@code injectInputEvent(InputEvent, int)}. */
    private static Object inputManager() throws Exception {
        try {
            Class<?> c = Class.forName("android.hardware.input.InputManagerGlobal");
            return c.getMethod("getInstance").invoke(null);
        } catch (ClassNotFoundException e) {
            Class<?> c = Class.forName("android.hardware.input.InputManager");
            return c.getMethod("getInstance").invoke(null);
        }
    }

    private static Method injectMethod() throws Exception {
        return inputManager().getClass().getMethod("injectInputEvent", InputEvent.class, int.class);
    }

    private KeyguardUnlocker() { }
}

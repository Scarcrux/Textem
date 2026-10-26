package dev.textem.probe;

import android.app.NotificationManager;
import android.content.ComponentName;
import android.content.Context;
import android.os.Build;
import android.provider.Settings;
import android.system.Os;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Separate private readiness diagnostics. Never writes permission settings. */
final class CaptureState {
    static final String FILE = "notification-summary.json";
    static boolean enabled(Context c) { return c.getSharedPreferences("notification-capture", 0).getBoolean("enabled", false); }
    static void enabled(Context c, boolean enabled) { c.getSharedPreferences("notification-capture", 0).edit().putBoolean("enabled", enabled).apply(); }
    static ComponentName component(Context c) { return new ComponentName(c, CaptureListener.class); }
    static boolean access(Context c) {
        try {
            if (Build.VERSION.SDK_INT >= 27) return c.getSystemService(NotificationManager.class).isNotificationListenerAccessGranted(component(c));
            String value = Settings.Secure.getString(c.getContentResolver(), "enabled_notification_listeners");
            if (value != null) for (String name : value.split(":")) if (component(c).equals(ComponentName.unflattenFromString(name))) return true;
        } catch (RuntimeException unavailable) { }
        return false;
    }
    static synchronized boolean record(Context c, NotificationReadiness.Report report, String origin) {
        return record(c, report, "NOTIFICATION_SAMPLE", origin, enabled(c), access(c), CaptureListener.connected());
    }
    static synchronized boolean record(Context c, NotificationReadiness.Report report, String kind, String origin,
                                       boolean enabled, boolean access, boolean connected) {
        AtomicFile target = new AtomicFile(new File(c.getFilesDir(), FILE)); FileOutputStream stream = null;
        try {
            if (!NotificationReadiness.valid(report, kind, origin, enabled, access, connected)) return false;
            byte[] data = report.json(kind, origin, enabled, access, connected).toString().getBytes(StandardCharsets.UTF_8);
            if (data.length > 4096) return false;
            stream = target.startWrite(); Os.fchmod(stream.getFD(), 0600); stream.write(data); target.finishWrite(stream);
            return true;
        } catch (Exception failure) { if (stream != null) target.failWrite(stream); return false; }
    }
    static synchronized JSONObject read(Context c) throws Exception {
        try (java.io.FileInputStream stream = new AtomicFile(new File(c.getFilesDir(), FILE)).openRead()) {
            byte[] data = new byte[4097]; int used = 0, count;
            while (used < data.length && (count = stream.read(data, used, data.length - used)) != -1) used += count;
            if (used > 4096) throw new IllegalStateException();
            return new JSONObject(new String(data, 0, used, StandardCharsets.UTF_8));
        }
    }
    static synchronized void clear(Context c) { new AtomicFile(new File(c.getFilesDir(), FILE)).delete(); }
}

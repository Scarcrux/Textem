package dev.textem.probe;

import android.content.Context;
import android.system.Os;
import android.util.AtomicFile;
import android.util.Base64;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import org.json.JSONObject;

/** One private latest preview. Does not change the share export, metadata or any source app. */
final class NotificationContentStore {
    private static final java.util.Map<String, Long> revisions = new java.util.HashMap<>();
    static final String FILE = "notification-content.json", STATE = "notification-content-state.json";
    static boolean enabled(Context c) { return c.getSharedPreferences("notification-content", 0).getBoolean("enabled", false); }
    static synchronized void enabled(Context c, boolean value) { advance(c); c.getSharedPreferences("notification-content", 0).edit().putBoolean("enabled", value).apply(); }
    static synchronized long revision(Context c) { return revisions.getOrDefault(c.getFilesDir().getAbsolutePath(), 0L); }
    private static void advance(Context c) { revisions.put(c.getFilesDir().getAbsolutePath(), revision(c) + 1); }
    static final class Identity {
        final String install; final byte[] secret;
        Identity(String install, byte[] secret) { this.install = install; this.secret = secret; }
    }
    private static AtomicFile file(Context c, String name) { return new AtomicFile(new File(c.getFilesDir(), name)); }
    private static void write(Context c, String name, byte[] data) throws Exception {
        AtomicFile target = file(c, name); FileOutputStream stream = null;
        try { stream = target.startWrite(); Os.fchmod(stream.getFD(), 0600); stream.write(data); target.finishWrite(stream); }
        catch (Exception error) { if (stream != null) target.failWrite(stream); throw error; }
    }
    static JSONObject read(Context c, String name, int maximum) throws Exception {
        if (!Arrays.asList(FILE, STATE, "notification-identity.json").contains(name)) throw new IllegalArgumentException();
        try (FileInputStream stream = file(c, name).openRead()) {
            byte[] data = new byte[maximum + 1]; int used = 0, count;
            while (used < data.length && (count = stream.read(data, used, data.length - used)) != -1) used += count;
            if (used > maximum) throw new IllegalArgumentException();
            return new JSONObject(new String(data, 0, used, StandardCharsets.UTF_8));
        }
    }
    static synchronized Identity identity(Context c) throws Exception {
        String name = "notification-identity.json";
        if (new File(c.getFilesDir(), name).exists() || new File(c.getFilesDir(), name + ".bak").exists()) {
            JSONObject j = read(c, name, 4096);
            String install = j.getString("install"); java.util.UUID.fromString(install);
            byte[] secret = Base64.decode(j.getString("secret"), Base64.NO_WRAP);
            if (j.length() != 2 || secret.length != 32) throw new IllegalArgumentException();
            return new Identity(install, secret);
        }
        byte[] secret = new byte[32]; new java.security.SecureRandom().nextBytes(secret);
        String install = java.util.UUID.randomUUID().toString(); JSONObject j = new JSONObject();
        j.put("install", install); j.put("secret", Base64.encodeToString(secret, Base64.NO_WRAP));
        write(c, name, j.toString().getBytes(StandardCharsets.UTF_8)); return new Identity(install, secret);
    }
    static synchronized boolean publish(Context c, NotificationContent.Result result, boolean synthetic) {
        return publish(c, result, synthetic, () -> true);
    }
    static synchronized boolean publish(Context c, NotificationContent.Result result, boolean synthetic, java.util.function.BooleanSupplier active) {
        try {
            if (!active.getAsBoolean()) return false;
            if (synthetic && !c.getFilesDir().equals(new File(c.getCacheDir(), "notification-content-controls"))) return false;
            if (result.document != null) {
                String expected = synthetic ? "SYNTHETIC_NOTIFICATION_CONTENT" : "NOTIFICATION_CONTENT";
                if (!result.state.equals("SAVED") || !expected.equals(result.document.getString("kind"))
                        || result.document.getBoolean("complete")) return false;
                byte[] data = result.document.toString().getBytes(StandardCharsets.UTF_8);
                if (data.length > NotificationContent.MAX_BYTES) return false;
                write(c, FILE, data);
            }
            status(c, result.state); return true;
        } catch (Exception failure) { status(c, "UNAVAILABLE"); return false; }
    }
    static synchronized void status(Context c, String value) {
        if (!Arrays.asList("OFF", "ACCESS_REQUIRED", "OTHER_APP_IGNORED", "MALFORMED", "SUMMARY_SKIPPED", "SOURCE_REQUIRED",
                "UNAVAILABLE", "URI_ONLY_UNSUPPORTED", "IMAGE_UNSUPPORTED", "NO_CONTENT", "SAVED", "CLEARED", "REDACTED").contains(value)) return;
        try {
            JSONObject j = new JSONObject(); j.put("schema", 1); j.put("state", value); j.put("recorded_at_ms", System.currentTimeMillis());
            write(c, STATE, j.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) { }
    }
    static synchronized void clear(Context c) { advance(c); file(c, FILE).delete(); status(c, "CLEARED"); }
}

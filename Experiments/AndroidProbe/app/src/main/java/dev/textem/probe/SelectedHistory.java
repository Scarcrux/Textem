package dev.textem.probe;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.system.Os;
import android.util.AtomicFile;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.json.*;

/** Explicit immutable exports of one chosen public-provider thread. No network-triggered reads. */
final class SelectedHistory {
    static final int ROWS = 500, MAX_BYTES = 2 * 1024 * 1024, LIBRARY_BYTES = 8 * 1024 * 1024;
    static final String FILE = "selected-history.json";
    interface Source { Cursor rows(boolean mms, long thread); Cursor parts(long message); }
    static Source provider(Context context) {
        return new Source() {
            private Cursor query(String uri, String[] columns, String selection, String[] args, String order) {
                if (!permission(context)) throw new SecurityException();
                return context.getContentResolver().query(Uri.parse(uri), columns, selection, args, order);
            }
            public Cursor rows(boolean mms, long thread) {
                if (thread <= 0) throw new IllegalArgumentException();
                ProviderSource.Query spec = spec(mms, thread);
                return query(spec.uri.toString(), spec.columns, spec.selection, spec.args, spec.order);
            }
            public Cursor parts(long message) {
                if (message <= 0) throw new IllegalArgumentException();
                return query("content://mms/" + message + "/part", new String[]{"ct", "text"}, null, null, null);
            }
        };
    }
    static ProviderSource.Query spec(boolean mms, long thread) {
        if (thread <= 0) throw new IllegalArgumentException();
        return new ProviderSource.Query(mms ? "content://mms" : "content://sms", mms
            ? new String[]{"_id", "date", "msg_box"} : new String[]{"_id", "date", "body", "type"},
            "thread_id = ?", new String[]{Long.toString(thread)}, "date DESC, _id DESC");
    }
    static boolean permission(Context c) { return c.checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED; }
    private static String key(byte[] secret, String input) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256"); mac.init(new SecretKeySpec(secret, "HmacSHA256"));
        StringBuilder out = new StringBuilder();
        for (byte b : mac.doFinal(input.getBytes(StandardCharsets.UTF_8))) out.append(String.format(Locale.ROOT, "%02x", b & 255));
        return out.toString();
    }
    static JSONObject capture(Source source, long thread, String participants,
            NotificationContentStore.Identity identity, boolean synthetic) throws Exception {
        if (thread <= 0 || participants == null) throw new IllegalArgumentException();
        String sourceKey = key(identity.secret, "provider-history:" + thread + ":" + participants);
        JSONObject result = new JSONObject();
        result.put("schema", 1); result.put("kind", synthetic ? "SYNTHETIC_SELECTED_HISTORY" : "SELECTED_PHONE_HISTORY");
        result.put("install_id", identity.install); result.put("source_key", sourceKey);
        result.put("captured_at_ms", System.currentTimeMillis()); result.put("complete", false);
        // An address label is intentionally not transferred. The owner compares actual text.
        ArrayList<JSONObject> messages = new ArrayList<>(); boolean limited = false;
        for (boolean mms : new boolean[]{false, true}) {
            String state = "OK"; int count = 0, bytes = 0;
            ArrayList<JSONObject> section = new ArrayList<>();
            try (Cursor c = source.rows(mms, thread)) {
                if (c == null) state = "UNAVAILABLE";
                else while (c.moveToNext()) {
                    if (count++ == ROWS) { limited = true; break; }
                    long id = ProbeEngine.number(c, "_id"), rawTime = ProbeEngine.number(c, "date");
                    if (id <= 0 || rawTime < 0 || (mms && rawTime > Long.MAX_VALUE / 1000)) throw new IllegalArgumentException();
                    long stamp = mms ? rawTime * 1000 : rawTime;
                    if (stamp > System.currentTimeMillis() + 300000) throw new IllegalArgumentException();
                    String text = ""; boolean truncated = false, partsComplete = true; int omitted = 0;
                    if (!mms) { int i = c.getColumnIndexOrThrow("body"); text = c.isNull(i) ? "" : c.getString(i); }
                    else {
                        try (Cursor parts = source.parts(id)) {
                            if (parts == null) partsComplete = false;
                            else {
                                int n = 0;
                                while (parts.moveToNext()) {
                                    if (n++ == 32) { partsComplete = false; break; }
                                    String type = ProbeEngine.text(parts, "ct");
                                    if ("text/plain".equalsIgnoreCase(type)) {
                                        int i = parts.getColumnIndexOrThrow("text"); String part = parts.isNull(i) ? "" : parts.getString(i);
                                        if (part.length() > ProbeEngine.TEXT_LIMIT || text.length() + part.length() + 1 > ProbeEngine.TEXT_LIMIT) truncated = true;
                                        text = ProbeEngine.bounded(text + (text.isEmpty() ? "" : "\n") + ProbeEngine.bounded(part));
                                    } else if (!"application/smil".equalsIgnoreCase(type)) omitted++;
                                }
                            }
                        } catch (RuntimeException denied) { partsComplete = false; }
                    }
                    if (text.length() > ProbeEngine.TEXT_LIMIT) truncated = true;
                    text = ProbeEngine.bounded(text);
                    int box = (int) ProbeEngine.number(c, mms ? "msg_box" : "type");
                    JSONObject message = new JSONObject();
                    message.put("id", key(identity.secret, sourceKey + ":" + mms + ":" + id));
                    message.put("timestamp_ms", stamp); message.put("text", text);
                    message.put("direction", box == 1 ? "RECEIVED" : box == 2 ? "SENT" : "OTHER");
                    message.put("truncated", truncated); message.put("attachments_omitted", omitted);
                    message.put("parts_complete", partsComplete);
                    int size = message.toString().getBytes(StandardCharsets.UTF_8).length + 1;
                    // Reserve equal per-provider budgets; SMS must not starve MMS.
                    if (bytes + size > (MAX_BYTES - 4096) / 2) { limited = true; break; }
                    bytes += size; section.add(message);
                }
            } catch (SecurityException denied) { state = "BLOCKED"; section.clear(); }
              catch (RuntimeException unavailable) { state = "ERROR"; section.clear(); }
            result.put(mms ? "mms" : "sms", state); messages.addAll(section);
        }
        messages.sort(Comparator.comparingLong((JSONObject m) -> m.optLong("timestamp_ms")).thenComparing(m -> m.optString("id")));
        result.put("limited", limited); result.put("messages", new JSONArray(messages));
        if (result.toString().getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) throw new IOException();
        return result;
    }
    private static AtomicFile file(Context c) { return new AtomicFile(new File(c.getFilesDir(), FILE)); }
    static synchronized void clear(Context c) { file(c).delete(); }
    static synchronized JSONObject read(Context c) throws Exception {
        try (FileInputStream in = file(c).openRead()) {
            byte[] bytes = new byte[LIBRARY_BYTES + 1]; int used = 0, n;
            while (used < bytes.length && (n = in.read(bytes, used, bytes.length - used)) != -1) used += n;
            if (used > LIBRARY_BYTES) throw new IOException();
            return new JSONObject(new String(bytes, 0, used, StandardCharsets.UTF_8));
        }
    }
    static synchronized void publish(Context c, JSONObject sample, boolean synthetic) throws Exception {
        if (synthetic && !c.getFilesDir().equals(new File(c.getCacheDir(), "notification-content-controls"))) throw new SecurityException();
        String kind = synthetic ? "SYNTHETIC_SELECTED_HISTORY" : "SELECTED_PHONE_HISTORY";
        if (!sample.getString("kind").equals(kind) || sample.getBoolean("complete")
                || sample.toString().getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) throw new SecurityException();
        JSONObject library;
        if (file(c).getBaseFile().exists() || new File(file(c).getBaseFile() + ".bak").exists()) library = read(c);
        else { library = new JSONObject(); library.put("schema", 1); library.put("kind", synthetic ? "SYNTHETIC_HISTORY_LIBRARY" : "PHONE_HISTORY_LIBRARY"); library.put("samples", new JSONArray()); }
        if (!library.getString("kind").equals(synthetic ? "SYNTHETIC_HISTORY_LIBRARY" : "PHONE_HISTORY_LIBRARY")) throw new SecurityException();
        ArrayList<JSONObject> kept = new ArrayList<>(); JSONArray old = library.getJSONArray("samples");
        if (old.length() > 8) throw new SecurityException();
        for (int i = 0; i < old.length(); i++) {
            JSONObject item = old.getJSONObject(i);
            if (!item.getString("install_id").equals(sample.getString("install_id"))) throw new SecurityException();
            if (!item.getString("source_key").equals(sample.getString("source_key"))
                && item.getLong("captured_at_ms") >= System.currentTimeMillis() - 7L * 86400000) kept.add(item);
        }
        kept.add(new JSONObject(sample.toString()));
        byte[] data;
        do {
            if (kept.size() > 8) kept.remove(0);
            library.put("samples", new JSONArray(kept)); data = library.toString().getBytes(StandardCharsets.UTF_8);
            if (data.length <= LIBRARY_BYTES) break;
            kept.remove(0);
        } while (!kept.isEmpty());
        FileOutputStream out = null;
        try { out = file(c).startWrite(); Os.fchmod(out.getFD(), 0600); out.write(data); file(c).finishWrite(out); }
        catch (Exception e) { if (out != null) file(c).failWrite(out); throw e; }
    }
}

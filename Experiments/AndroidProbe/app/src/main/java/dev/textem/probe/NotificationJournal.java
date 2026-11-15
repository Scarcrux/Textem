package dev.textem.probe;

import android.content.Context;
import android.system.Os;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

/** Bounded partial notification observations, not an RCS history provider. */
final class NotificationJournal {
    static final String FILE = "notification-journal.json";
    static final int MAX_BYTES = 8 * 1024 * 1024, MAX_SAMPLES = 32;
    private static AtomicFile file(Context c) { return new AtomicFile(new File(c.getFilesDir(), FILE)); }
    static synchronized void clear(Context c) { file(c).delete(); }
    static JSONObject read(Context c) throws Exception {
        try (FileInputStream in = file(c).openRead()) {
            byte[] data = new byte[MAX_BYTES + 1]; int used = 0, count;
            while (used < data.length && (count = in.read(data, used, data.length - used)) != -1) used += count;
            if (used > MAX_BYTES) throw new IllegalArgumentException();
            return new JSONObject(new String(data, 0, used, StandardCharsets.UTF_8));
        }
    }
    private static String signature(JSONObject sample) throws Exception {
        JSONObject copy = new JSONObject(sample.toString()); copy.remove("captured_at_ms"); copy.remove("origin");
        return copy.toString();
    }
    static synchronized void append(Context c, JSONObject sample, boolean synthetic) throws Exception {
        if (synthetic && !c.getFilesDir().equals(new File(c.getCacheDir(), "notification-content-controls"))) throw new IllegalArgumentException();
        String kind = synthetic ? "SYNTHETIC_NOTIFICATION_CONTENT" : "NOTIFICATION_CONTENT";
        if (!sample.getString("kind").equals(kind) || sample.getBoolean("complete")) throw new IllegalArgumentException();
        JSONObject journal;
        if (file(c).getBaseFile().exists() || new File(file(c).getBaseFile() + ".bak").exists()) journal = read(c);
        else {
            journal = new JSONObject(); journal.put("schema", 1);
            journal.put("kind", synthetic ? "SYNTHETIC_NOTIFICATION_JOURNAL" : "NOTIFICATION_JOURNAL");
            journal.put("epoch", java.util.UUID.randomUUID().toString()); journal.put("revision", 0);
            journal.put("dropped", 0); journal.put("samples", new JSONArray()); journal.put("complete", false);
        }
        if (journal.getInt("schema") != 1 || journal.getBoolean("complete")
                || !journal.getString("kind").equals(synthetic ? "SYNTHETIC_NOTIFICATION_JOURNAL" : "NOTIFICATION_JOURNAL")) throw new IllegalArgumentException();
        JSONArray prior = journal.getJSONArray("samples");
        if (prior.length() > MAX_SAMPLES) throw new IllegalArgumentException();
        String signature = signature(sample), source = sample.getString("source_key");
        for (int i = 0; i < prior.length(); i++) {
            JSONObject old = prior.getJSONObject(i);
            if (!old.getString("install_id").equals(sample.getString("install_id")) || !old.getString("kind").equals(kind)) throw new IllegalArgumentException();
            if (signature(old).equals(signature)) return;
        }
        java.util.ArrayList<JSONObject> kept = new java.util.ArrayList<>();
        long dropped = journal.getLong("dropped"), now = System.currentTimeMillis();
        for (int i = 0; i < prior.length(); i++) {
            JSONObject old = prior.getJSONObject(i);
            if (old.getLong("captured_at_ms") >= now - 7L * 86400000) kept.add(old); else dropped++;
        }
        kept.add(new JSONObject(sample.toString()));
        kept.sort(java.util.Comparator.comparingLong(j -> j.optLong("captured_at_ms")));
        int sourceCount = 0;
        for (JSONObject item : kept) if (item.getString("source_key").equals(source)) sourceCount++;
        while (sourceCount > 4) {
            for (int i = 0; i < kept.size(); i++) if (kept.get(i).getString("source_key").equals(source)) { kept.remove(i); dropped++; sourceCount--; break; }
        }
        while (kept.size() > MAX_SAMPLES) { kept.remove(0); dropped++; }
        journal.put("revision", Math.min(Integer.MAX_VALUE, journal.getLong("revision") + 1));
        journal.put("written_at_ms", now);
        byte[] bytes;
        do {
            journal.put("samples", new JSONArray(kept)); journal.put("dropped", Math.min(Integer.MAX_VALUE, dropped));
            bytes = journal.toString().getBytes(StandardCharsets.UTF_8);
            if (bytes.length <= MAX_BYTES) break;
            if (kept.size() <= 1) throw new IllegalArgumentException();
            kept.remove(0); dropped++;
        } while (true);
        FileOutputStream out = null;
        try { out = file(c).startWrite(); Os.fchmod(out.getFD(), 0600); out.write(bytes); file(c).finishWrite(out); }
        catch (Exception failure) { if (out != null) file(c).failWrite(out); throw failure; }
    }
}

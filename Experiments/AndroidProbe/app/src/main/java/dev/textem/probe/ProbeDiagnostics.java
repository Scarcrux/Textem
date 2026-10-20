package dev.textem.probe;

import android.content.Context;
import android.util.AtomicFile;
import android.system.Os;
import android.system.ErrnoException;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.json.JSONException;
import org.json.JSONObject;

/** Only whitelisted numeric/enum metadata is ever persisted, never Report.messages. */
final class ProbeDiagnostics {
    enum Kind { SYNTHETIC, SELECTED_HISTORY }
    static final int KEY_COUNT = 18;
    private static AtomicFile file(Context context) {
        return new AtomicFile(new File(context.getFilesDir(), "probe-summary.json"));
    }
    static boolean exists(Context context) { return file(context).getBaseFile().isFile(); }
    static void clear(Context context) { file(context).delete(); }

    static boolean record(Context context, Kind kind, ProbeEngine.Report r) {
        if (!valid(r)) { clear(context); return false; }
        FileOutputStream stream = null;
        AtomicFile target = file(context);
        try {
            JSONObject json = new JSONObject();
            json.put("schema", 1); json.put("kind", kind.name());
            json.put("recorded_at_ms", System.currentTimeMillis());
            json.put("sms", r.sms.name()); json.put("mms", r.mms.name());
            json.put("sms_rows", r.smsRows); json.put("mms_rows", r.mmsRows);
            json.put("text_messages", r.textMessages); json.put("links", r.links);
            json.put("image_parts", r.imageParts); json.put("readable_images", r.readableImages);
            json.put("unreadable_images", r.unreadableImages); json.put("oversized_images", r.oversizedImages);
            json.put("skipped_images", r.skippedImages); json.put("part_failures", r.partFailures);
            json.put("limited", r.limited); json.put("message_content_exported", false);
            json.put("provider_sample_complete", false);
            byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);
            if (bytes.length > 4096) { clear(context); return false; }
            stream = target.startWrite();
            Os.fchmod(stream.getFD(), 0600);
            stream.write(bytes);
            target.finishWrite(stream);
            return true;
        } catch (IOException | JSONException | ErrnoException | RuntimeException error) {
            if (stream != null) target.failWrite(stream);
            clear(context);
            return false;
        }
    }
    private static boolean valid(ProbeEngine.Report r) {
        return r != null && r.sms != null && r.mms != null
            && r.textMessages <= r.smsRows + r.mmsRows
            && r.readableImages + r.unreadableImages + r.oversizedImages <= 3
            && r.readableImages + r.unreadableImages + r.oversizedImages + r.skippedImages <= r.imageParts
            && within(r.smsRows, 20) && within(r.mmsRows, 20) && within(r.textMessages, 40)
            && within(r.links, 1_000_000) && within(r.imageParts, 640)
            && within(r.readableImages, 3) && within(r.unreadableImages, 3)
            && within(r.oversizedImages, 3) && within(r.skippedImages, 640)
            && within(r.partFailures, 20);
    }
    private static boolean within(int value, int maximum) { return value >= 0 && value <= maximum; }
    static JSONObject read(Context context) throws IOException, JSONException {
        byte[] bytes = file(context).readFully();
        if (bytes.length > 4096) throw new IOException("Diagnostic size limit");
        return new JSONObject(new String(bytes, StandardCharsets.UTF_8));
    }
}

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

/** Separate from history diagnostics. No source/content fields can reach this writer. */
final class ShareDiagnostics {
    static final int KEY_COUNT = 17;
    private static AtomicFile file(Context context) {
        return new AtomicFile(new File(context.getFilesDir(), "share-summary.json"));
    }
    static void clear(Context context) { file(context).delete(); }
    static boolean exists(Context context) { return file(context).getBaseFile().isFile(); }
    static boolean valid(ShareProbeEngine.Report r) {
        if (r == null || r.state == null || r.blockReason == null || r.uris < 0 || r.uris > 8 || r.links < 0 || r.links > 10_000) return false;
        if ((r.blockedUris == 0) != (r.blockReason == ShareProbeEngine.BlockReason.NONE)) return false;
        if (r.attemptedImages < 0 || r.attemptedImages > 3 || r.attemptedImages > r.uris) return false;
        if (r.readableImages < 0 || r.unreadableImages < 0 || r.oversizedImages < 0
                || r.blockedUris < 0 || r.skippedUris < 0) return false;
        if (r.readableImages + r.unreadableImages + r.oversizedImages > r.attemptedImages
                || r.blockedUris + r.skippedUris + r.readableImages + r.unreadableImages + r.oversizedImages > r.uris) return false;
        if (r.links > 0 && !r.textPresent) return false;
        int failures = r.blockedUris + r.unreadableImages + r.oversizedImages + r.skippedUris;
        switch (r.state) {
            case IMAGE_READABLE: return r.readableImages > 0 && failures == 0;
            case PARTIAL_IMAGE: return r.readableImages > 0 && failures > 0;
            case TEXT_OR_LINK_ONLY: return r.uris == 0 && r.textPresent;
            case EMPTY: return r.uris == 0 && !r.textPresent;
            case BLOCKED: return r.readableImages == 0 && r.blockedUris > 0;
            case UNREADABLE: return r.readableImages == 0 && r.blockedUris == 0
                && r.unreadableImages + r.oversizedImages > 0;
            case UNSUPPORTED: case MALFORMED: case ERROR:
                return r.attemptedImages == 0 && r.readableImages == 0;
            case TIMEOUT: return true;
            default: return false;
        }
    }
    static boolean record(Context context, boolean synthetic, ShareProbeEngine.Report r) {
        if (!valid(r)) { clear(context); return false; }
        AtomicFile target = file(context); FileOutputStream stream = null;
        try {
            JSONObject json = new JSONObject();
            json.put("schema", 1); json.put("kind", synthetic ? "SYNTHETIC_SHARE" : "SHARED_CONTENT");
            json.put("recorded_at_ms", System.currentTimeMillis()); json.put("state", r.state.name());
            json.put("block_reason", r.blockReason.name());
            json.put("uris", r.uris); json.put("attempted_images", r.attemptedImages);
            json.put("readable_images", r.readableImages); json.put("blocked_uris", r.blockedUris);
            json.put("unreadable_images", r.unreadableImages); json.put("oversized_images", r.oversizedImages);
            json.put("skipped_uris", r.skippedUris); json.put("links", r.links);
            json.put("text_present", r.textPresent); json.put("limited", r.limited);
            json.put("message_content_exported", false); json.put("full_card_proven", false);
            byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);
            if (bytes.length > 4096) { clear(context); return false; }
            stream = target.startWrite(); Os.fchmod(stream.getFD(), 0600); stream.write(bytes);
            target.finishWrite(stream); return true;
        } catch (IOException | JSONException | ErrnoException | RuntimeException error) {
            if (stream != null) target.failWrite(stream);
            clear(context); return false;
        }
    }
    static JSONObject read(Context context) throws IOException, JSONException {
        byte[] bytes = file(context).readFully();
        if (bytes.length > 4096) throw new IOException("Diagnostic size limit");
        return new JSONObject(new String(bytes, StandardCharsets.UTF_8));
    }
}

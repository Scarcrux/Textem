package dev.textem.probe;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.system.Os;
import android.util.AtomicFile;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FilterInputStream;
import java.io.InputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.UUID;
import org.json.JSONObject;

/** Explicit image handoff, separate from diagnostic-only Inspect. No network or source identifiers. */
final class ShareImageExport {
    static final String MANIFEST = "mac-image.json";
    private static final Object publication = new Object();
    private static Context syntheticContext(Context c) throws Exception {
        File directory = new File(c.getCacheDir(), "share-export-controls");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException();
        Os.chmod(directory.getPath(), 0700);
        return new android.content.ContextWrapper(c) { @Override public File getFilesDir() { return directory; } };
    }
    static void clear(Context c, boolean synthetic) {
        try { clear(synthetic ? syntheticContext(c) : c); } catch (Exception ignored) { }
    }
    static JSONObject manifest(Context c, boolean synthetic) throws Exception {
        return manifest(synthetic ? syntheticContext(c) : c);
    }
    private static AtomicFile file(Context c, String name) { return new AtomicFile(new File(c.getFilesDir(), name)); }
    static void clear(Context c) {
        synchronized (publication) {
            file(c, MANIFEST).delete(); file(c, "mac-image-0.png").delete(); file(c, "mac-image-1.png").delete();
        }
    }
    static JSONObject manifest(Context c) throws Exception {
        byte[] bytes = file(c, MANIFEST).readFully();
        if (bytes.length > 4096) throw new IOException();
        return new JSONObject(new String(bytes, StandardCharsets.UTF_8));
    }
    private static void write(Context c, String name, byte[] data) throws Exception {
        AtomicFile target = file(c, name); FileOutputStream stream = null;
        try {
            stream = target.startWrite(); Os.fchmod(stream.getFD(), 0600); stream.write(data); target.finishWrite(stream);
        } catch (Exception failure) { if (stream != null) target.failWrite(stream); throw failure; }
    }
    static boolean save(Context context, ShareProbeEngine.Input input, ShareProbeEngine.Source source, boolean synthetic) {
        return save(context, input, source, synthetic, () -> true);
    }
    static boolean save(Context context, ShareProbeEngine.Input input, ShareProbeEngine.Source source, boolean synthetic,
                        java.util.function.BooleanSupplier active) {
        if (input == null || input.uris.size() != 1) return false;
        ByteArrayOutputStream captured = new ByteArrayOutputStream();
        ShareProbeEngine.Source tee = new ShareProbeEngine.Source() {
            @Override public ShareSourceDiagnostics.Metadata describe(android.net.Uri u) { return source.describe(u); }
            @Override public boolean explicitGrant(android.net.Uri u) { return source.explicitGrant(u); }
            @Override public boolean privateMessagesProvider(android.net.Uri u) { return source.privateMessagesProvider(u); }
            @Override public InputStream open(android.net.Uri u) throws IOException {
                InputStream stream = source.open(u);
                if (stream == null) return null;
                return new FilterInputStream(stream) {
                    @Override public int read(byte[] b, int off, int len) throws IOException {
                        int n = in.read(b, off, len);
                        if (n > 0 && captured.size() + n <= ShareProbeEngine.BYTE_LIMIT) captured.write(b, off, n);
                        return n;
                    }
                };
            }
        };
        Bitmap bitmap = null;
        try {
            ShareProbeEngine.Report report = ShareProbeEngine.inspect(input, tee);
            if (report.state != ShareProbeEngine.State.IMAGE_READABLE || report.readableImages != 1
                    || Thread.currentThread().isInterrupted()) return false;
            byte[] raw = captured.toByteArray();
            BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(raw, 0, raw.length, options);
            options.inSampleSize = 1;
            while ((options.outWidth - 1) / options.inSampleSize + 1 > 2048
                    || (options.outHeight - 1) / options.inSampleSize + 1 > 2048)
                options.inSampleSize *= 2;
            options.inJustDecodeBounds = false;
            bitmap = BitmapFactory.decodeByteArray(raw, 0, raw.length, options);
            if (bitmap == null || bitmap.getWidth() > 2048 || bitmap.getHeight() > 2048) return false;
            ByteArrayOutputStream png = new ByteArrayOutputStream() {
                @Override public synchronized void write(byte[] b, int off, int len) {
                    if (count + len > ShareProbeEngine.BYTE_LIMIT) throw new IllegalStateException();
                    super.write(b, off, len);
                }
                @Override public synchronized void write(int b) {
                    if (count == ShareProbeEngine.BYTE_LIMIT) throw new IllegalStateException();
                    super.write(b);
                }
            };
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, png) || png.size() > ShareProbeEngine.BYTE_LIMIT
                    || Thread.currentThread().isInterrupted()) return false;
            byte[] bytes = png.toByteArray();
            Context target = synthetic ? syntheticContext(context) : context;
            synchronized (publication) {
            if (!active.getAsBoolean() || Thread.currentThread().isInterrupted()) return false;
            String previous = "";
            try { previous = manifest(target).optString("filename"); } catch (Exception absent) { }
            // Inactive fixed slot first, then atomic manifest: a failed save preserves the old pair.
            String filename = previous.equals("mac-image-0.png") ? "mac-image-1.png" : "mac-image-0.png";
            JSONObject metadata = new JSONObject();
            metadata.put("schema", 1); metadata.put("kind", synthetic ? "SYNTHETIC_IMAGE" : "SHARED_IMAGE");
            metadata.put("id", UUID.randomUUID().toString()); metadata.put("created_at_ms", System.currentTimeMillis());
            metadata.put("filename", filename); metadata.put("mime", "image/png");
            metadata.put("width", bitmap.getWidth()); metadata.put("height", bitmap.getHeight()); metadata.put("bytes", bytes.length);
            StringBuilder hash = new StringBuilder();
            for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) hash.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
            metadata.put("sha256", hash.toString());
            write(target, filename, bytes);
            if (!active.getAsBoolean() || Thread.currentThread().isInterrupted()) return false;
            write(target, MANIFEST, metadata.toString().getBytes(StandardCharsets.UTF_8));
            return true;
            }
        } catch (Exception failure) { return false; }
        finally { if (bitmap != null) bitmap.recycle(); }
    }
}

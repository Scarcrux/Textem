package dev.textem.probe;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import java.io.*;
import java.util.concurrent.*;

/** Only granted private Google image URIs; no network, provider queries or URI persistence. */
final class NotificationMedia {
    static final int MAX_BYTES = 6 * 1024 * 1024;
    private static final java.util.concurrent.atomic.AtomicInteger decodes = new java.util.concurrent.atomic.AtomicInteger();
    static int decodeAttempts() { return decodes.get(); }
    static boolean eligible(Uri uri, String mime) {
        return ShareProbeEngine.knownMediaUri(uri) && mime != null
            && (mime.equals("image/*") || mime.equals("image/png") || mime.equals("image/jpeg")
                || mime.equals("image/webp") || mime.equals("image/gif"));
    }
    static Bitmap read(Context context, Uri uri, String mime) throws IOException {
        java.util.function.BooleanSupplier allowed = () -> CaptureState.enabled(context)
            && CaptureState.access(context) && NotificationContentStore.enabled(context);
        if (!eligible(uri, mime) || !allowed.getAsBoolean()) return null;
        SharedImageSource source = new SharedImageSource(context);
        ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "textem-media-deadline"); thread.setDaemon(true); return thread;
        });
        ScheduledFuture<?> timeout = timer.schedule(source::cancel, 5, TimeUnit.SECONDS);
        try { return read(source, uri, mime, allowed); }
        finally { timeout.cancel(false); source.cancel(); timer.shutdownNow(); }
    }
    static Bitmap read(ShareProbeEngine.Source source, Uri uri, String mime) throws IOException {
        return read(source, uri, mime, () -> true);
    }
    static Bitmap read(ShareProbeEngine.Source source, Uri uri, String mime, java.util.function.BooleanSupplier allowed) throws IOException {
        if (!eligible(uri, mime) || !allowed.getAsBoolean() || Thread.currentThread().isInterrupted()) return null;
        if (!source.explicitGrant(uri) || !source.privateMessagesProvider(uri)) return null;
        try (InputStream in = source.open(uri)) {
            if (in == null) return null;
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192]; int count;
            long deadline = android.os.SystemClock.elapsedRealtime() + 5000;
            while (bytes.size() <= MAX_BYTES) {
                if (!allowed.getAsBoolean() || Thread.currentThread().isInterrupted() || android.os.SystemClock.elapsedRealtime() >= deadline) throw new InterruptedIOException();
                count = in.read(buffer, 0, Math.min(buffer.length, MAX_BYTES + 1 - bytes.size()));
                if (count < 0) break;
                if (count == 0) throw new IOException();
                bytes.write(buffer, 0, count);
            }
            if (bytes.size() > MAX_BYTES) return null;
            if (!allowed.getAsBoolean() || android.os.SystemClock.elapsedRealtime() >= deadline) return null;
            Bitmap result = decode(bytes.toByteArray());
            if (!allowed.getAsBoolean() || Thread.currentThread().isInterrupted() || android.os.SystemClock.elapsedRealtime() >= deadline) {
                if (result != null) result.recycle(); return null;
            }
            return result;
        }
    }
    static Bitmap decode(byte[] bytes) {
        BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        if (options.outWidth <= 0 || options.outHeight <= 0 || options.outWidth > 16384 || options.outHeight > 16384
                || (long) options.outWidth * options.outHeight > 64000000) return null;
        options.inSampleSize = 1;
        while (options.outWidth / options.inSampleSize > 2048 || options.outHeight / options.inSampleSize > 2048) options.inSampleSize *= 2;
        options.inJustDecodeBounds = false;
        if (Thread.currentThread().isInterrupted()) return null;
        decodes.incrementAndGet();
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
    }
}

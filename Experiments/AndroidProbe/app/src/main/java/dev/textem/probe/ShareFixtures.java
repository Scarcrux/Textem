package dev.textem.probe;

import android.content.Intent;
import android.net.Uri;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.io.IOException;
import java.io.InterruptedIOException;

/** Never consults a provider. External fixture flags cannot bypass the live source policy. */
final class ShareFixtures implements ShareProbeEngine.Source {
    static final java.util.concurrent.atomic.AtomicInteger allOpens = new java.util.concurrent.atomic.AtomicInteger();
    static final java.util.concurrent.atomic.AtomicInteger allDescriptions = new java.util.concurrent.atomic.AtomicInteger();
    static volatile java.util.concurrent.CountDownLatch waitStarted, waitClosed;
    final String mode;
    int opens, closes, bytesRead, descriptions;
    ShareFixtures(String mode) {
        this.mode = mode;
        if ("wait".equals(mode)) {
            waitStarted = new java.util.concurrent.CountDownLatch(1);
            waitClosed = new java.util.concurrent.CountDownLatch(1);
        }
    }
    static Uri uri(int i) { return Uri.parse("content://" + ShareProbeEngine.MEDIA_AUTHORITY + "/synthetic-" + i); }
    static Intent intent(String mode) {
        Intent intent = new Intent(Intent.ACTION_SEND).setType("image/png")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        if ("text".equals(mode)) intent.setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, "PRIVATE_SHARE_SENTINEL https://example.invalid/PRIVATE_PATH");
        else intent.putExtra(Intent.EXTRA_STREAM, "unknown".equals(mode)
            ? Uri.parse("content://unknown.invalid/PRIVATE_PATH?PRIVATE_QUERY") : uri(1));
        return intent;
    }
    @Override public ShareSourceDiagnostics.Metadata describe(Uri uri) {
        descriptions++;
        allDescriptions.incrementAndGet();
        if ("metadata-error".equals(mode)) throw new SecurityException("PRIVATE_ERROR_SENTINEL");
        if ("unresolved".equals(mode)) return ShareSourceDiagnostics.classify(null, ShareSourceDiagnostics.Grant.DENIED);
        android.content.pm.ProviderInfo info = new android.content.pm.ProviderInfo();
        info.packageName = "untrusted".equals(mode) ? "private.example" : "com.google.android.apps.messaging";
        info.exported = false; info.grantUriPermissions = true;
        return ShareSourceDiagnostics.classify(info, "denied".equals(mode)
            ? ShareSourceDiagnostics.Grant.DENIED : ShareSourceDiagnostics.Grant.GRANTED);
    }
    @Override public boolean explicitGrant(Uri uri) { return !"denied".equals(mode); }
    @Override public boolean privateMessagesProvider(Uri uri) { return !"untrusted".equals(mode); }
    @Override public InputStream open(Uri uri) throws IOException {
        opens++;
        allOpens.incrementAndGet();
        if ("wait".equals(mode)) return new InputStream() {
            @Override public int read() throws IOException {
                waitStarted.countDown();
                try { new java.util.concurrent.CountDownLatch(1).await(); }
                catch (InterruptedException cancelled) { Thread.currentThread().interrupt(); throw new InterruptedIOException(); }
                return -1;
            }
            @Override public void close() { waitClosed.countDown(); }
        };
        if ("timeout".equals(mode)) throw new InterruptedIOException();
        byte[] bytes = "oversized".equals(mode) ? new byte[ShareProbeEngine.BYTE_LIMIT + 1]
            : "corrupt".equals(mode) ? new byte[] {0, 1, 2}
            : "empty".equals(mode) ? new byte[0] : new FixtureSource().image(1);
        return new ByteArrayInputStream(bytes) {
            private boolean closed;
            @Override public synchronized int read(byte[] b, int offset, int count) {
                int n = super.read(b, offset, count); if (n > 0) bytesRead += n; return n;
            }
            @Override public void close() throws IOException { if (!closed) { closes++; closed = true; } super.close(); }
        };
    }
}

package dev.textem.probe;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import android.content.res.AssetFileDescriptor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.Process;
import java.io.InputStream;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.util.concurrent.atomic.AtomicInteger;

/** Opens only an explicitly granted, private Google Messages media URI. No query API. */
final class SharedImageSource implements ShareProbeEngine.Source {
    private static final AtomicInteger opens = new AtomicInteger();
    static int opens() { return opens.get(); }
    private final Context context;
    private final CancellationSignal cancellation = new CancellationSignal();
    private AssetFileDescriptor active;
    SharedImageSource(Context context) { this.context = context.getApplicationContext(); }
    @Override public boolean explicitGrant(Uri uri) {
        return ShareProbeEngine.knownMediaUri(uri) && context.checkUriPermission(uri, Process.myPid(), Process.myUid(),
            Intent.FLAG_GRANT_READ_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED;
    }
    @Override public boolean privateMessagesProvider(Uri uri) {
        if (!ShareProbeEngine.knownMediaUri(uri)) return false;
        ProviderInfo info = context.getPackageManager().resolveContentProvider(uri.getAuthority(), 0);
        return info != null && "com.google.android.apps.messaging".equals(info.packageName)
            && !info.exported && info.grantUriPermissions;
    }
    @Override public InputStream open(Uri uri) throws IOException {
        // Recheck immediately before opening, even if an injected caller skips the engine's guard.
        if (!explicitGrant(uri) || !privateMessagesProvider(uri)) throw new SecurityException();
        cancellation.throwIfCanceled();
        opens.incrementAndGet();
        AssetFileDescriptor descriptor = context.getContentResolver().openAssetFileDescriptor(uri, "r", cancellation);
        if (descriptor == null) return null;
        synchronized (this) {
            if (cancellation.isCanceled()) { descriptor.close(); throw new InterruptedIOException(); }
            active = descriptor;
        }
        return descriptor.createInputStream();
    }
    void cancel() {
        cancellation.cancel();
        synchronized (this) {
            if (active != null) try { active.close(); } catch (IOException ignored) { }
            active = null;
        }
    }
}

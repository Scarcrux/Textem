package dev.textem.probe;

import android.app.Notification;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Bitmap;
import android.net.Uri;
import java.io.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

final class NotificationMediaChecks {
    private static final Uri URI = Uri.parse("content://" + ShareProbeEngine.PROXY_AUTHORITY + "/synthetic-picture");
    private static final class Source implements ShareProbeEngine.Source {
        boolean grant = true, owner = true; int opens;
        byte[] bytes;
        Runnable onOpen = () -> {};
        Source(byte[] bytes) { this.bytes = bytes; }
        public ShareSourceDiagnostics.Metadata describe(Uri uri) { return null; }
        public boolean explicitGrant(Uri uri) { return grant; }
        public boolean privateMessagesProvider(Uri uri) { return owner; }
        public InputStream open(Uri uri) { opens++; onOpen.run(); return new ByteArrayInputStream(bytes); }
    }
    static void run(ProbeAutomation test) throws Exception {
        test.phase("notification media policy and decoder discriminate usable and refused images");
        Bitmap original = Bitmap.createBitmap(24, 16, Bitmap.Config.ARGB_8888); original.eraseColor(0xffff8800);
        ByteArrayOutputStream png = new ByteArrayOutputStream(); original.compress(Bitmap.CompressFormat.PNG, 100, png); original.recycle();
        byte[] data = png.toByteArray(); Source good = new Source(data);
        Bitmap decoded = NotificationMedia.read(good, URI, "image/png");
        test.check(decoded != null && decoded.getWidth() == 24 && decoded.getHeight() == 16 && good.opens == 1);
        decoded.recycle();
        byte[] bomb = data.clone(); java.nio.ByteBuffer header = java.nio.ByteBuffer.wrap(bomb);
        header.putInt(16, 20000); header.putInt(20, 16);
        java.util.zip.CRC32 crc = new java.util.zip.CRC32(); crc.update(bomb, 12, 17); header.putInt(29, (int) crc.getValue());
        android.graphics.BitmapFactory.Options bounds = new android.graphics.BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
        android.graphics.BitmapFactory.decodeByteArray(bomb, 0, bomb.length, bounds);
        test.check(bounds.outWidth == 20000);
        int before = NotificationMedia.decodeAttempts();
        test.check(NotificationMedia.read(new Source(bomb), URI, "image/png") == null && NotificationMedia.decodeAttempts() == before);
        Bitmap wide = Bitmap.createBitmap(4096, 32, Bitmap.Config.ARGB_8888); ByteArrayOutputStream widePNG = new ByteArrayOutputStream();
        wide.compress(Bitmap.CompressFormat.PNG, 100, widePNG); wide.recycle();
        Bitmap reduced = NotificationMedia.read(new Source(widePNG.toByteArray()), URI, "image/png");
        test.check(reduced != null && reduced.getWidth() <= 2048 && reduced.getHeight() <= 2048); reduced.recycle();
        for (String uri : new String[]{"https://example.invalid/image.png", "file:///private-picture", "content://unknown.invalid/image"}) {
            Source blocked = new Source(data); test.check(NotificationMedia.read(blocked, Uri.parse(uri), "image/png") == null && blocked.opens == 0);
        }
        Source mime = new Source(data); test.check(NotificationMedia.read(mime, URI, "text/plain") == null && mime.opens == 0);
        Source denied = new Source(data); denied.grant = false;
        test.check(NotificationMedia.read(denied, URI, "image/png") == null && denied.opens == 0);
        Source owner = new Source(data); owner.owner = false;
        test.check(NotificationMedia.read(owner, URI, "image/png") == null && owner.opens == 0);
        Source corrupt = new Source(new byte[]{1,2,3}); test.check(NotificationMedia.read(corrupt, URI, "image/png") == null && corrupt.opens == 1);
        Source oversized = new Source(new byte[NotificationMedia.MAX_BYTES + 1]);
        test.check(NotificationMedia.read(oversized, URI, "image/png") == null && oversized.opens == 1);
        Source interrupted = new Source(data); Thread.currentThread().interrupt();
        try { test.check(NotificationMedia.read(interrupted, URI, "image/png") == null && interrupted.opens == 0); }
        finally { Thread.interrupted(); }
        AtomicBoolean allowed = new AtomicBoolean(true); Source changed = new Source(data); changed.onOpen = () -> allowed.set(false);
        boolean refused = false;
        try { NotificationMedia.read(changed, URI, "image/png", allowed::get); } catch (InterruptedIOException expected) { refused = true; }
        test.check(refused && changed.opens == 1);

        test.phase("granted notification URI becomes a bounded PNG without retaining its URI");
        Context base = test.getTargetContext(); java.io.File directory = new java.io.File(base.getCacheDir(), "notification-content-controls");
        Context fixture = new ContextWrapper(base) { @Override public java.io.File getFilesDir() { return directory; } };
        Notification notification = new Notification.Builder(base, "synthetic-media").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setShortcutId("synthetic-media").setStyle(new Notification.MessagingStyle("Synthetic")
                .addMessage(new Notification.MessagingStyle.Message("Synthetic text", System.currentTimeMillis(), "Synthetic")
                    .setData("image/png", URI))).build();
        AtomicInteger reads = new AtomicInteger();
        NotificationContent.Result result = NotificationContent.mediaFixture(fixture, () -> notification, (uri, type) -> {
            reads.incrementAndGet(); return NotificationMedia.read(new Source(data), uri, type);
        });
        test.check(result.state.equals("SAVED") && reads.get() == 1);
        test.check(result.document.getString("image_state").equals("BITMAP_PREVIEW") && !result.document.isNull("image"));
        test.check(result.document.getInt("uri_attachments") == 0 && !result.document.toString().contains(URI.toString()));
        NotificationContent.Result unavailable = NotificationContent.mediaFixture(fixture, () -> notification, (uri, type) -> null);
        test.check(unavailable.state.equals("SAVED") && unavailable.document.getInt("uri_attachments") == 1
            && unavailable.document.getString("image_state").equals("UNAVAILABLE"));
        Bitmap embedded = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888);
        notification.extras.putParcelable(Notification.EXTRA_PICTURE, embedded); reads.set(0);
        NotificationContent.Result bitmap = NotificationContent.mediaFixture(fixture, () -> notification, (uri, type) -> { reads.incrementAndGet(); return null; });
        test.check(bitmap.state.equals("SAVED") && reads.get() == 0 && !embedded.isRecycled()); embedded.recycle();
        boolean ownerRefused = false;
        try { NotificationContent.mediaFixture(base, () -> notification, (uri, type) -> null); } catch (SecurityException expected) { ownerRefused = true; }
        test.check(ownerRefused);
    }
}

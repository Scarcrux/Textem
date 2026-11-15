package dev.textem.probe;

import android.app.Notification;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Bitmap;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.net.Uri;
import java.io.File;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

/** Only synthetic payloads and isolated cache. Never arms the owner's content opt-in. */
final class NotificationContentChecks {
    private static final String INSTALL = "57b2dd91-cfa8-4193-9a38-e2d6d6470625";
    private static final byte[] SECRET = new byte[32];
    private static Notification base(Context c) {
        Notification n = new Notification.Builder(c, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setShortcutId("PRIVATE_SHORTCUT").setContentTitle("PRIVATE_TITLE").build();
        n.extras.remove(Notification.EXTRA_TEXT); return n;
    }
    private static NotificationContent.Result inspect(Context c, Notification n) {
        return NotificationContent.inspect(c, NotificationReadiness.PACKAGE, () -> n, true, true, INSTALL, SECRET, 0, "ACTIVE_SCAN", true);
    }
    static void run(ProbeAutomation i) throws Exception {
        Context owner = i.getTargetContext(); boolean optedIn = NotificationContentStore.enabled(owner);
        i.phase("content opt-in/access/package guards never obtain a payload");
        AtomicInteger supplied = new AtomicInteger(); java.util.function.Supplier<Notification> source = () -> { supplied.incrementAndGet(); return base(owner); };
        i.check(NotificationContent.inspect(owner, NotificationReadiness.PACKAGE, source, false, true, INSTALL, SECRET, 0, "POSTED", true).state.equals("OFF"));
        i.check(NotificationContent.inspect(owner, NotificationReadiness.PACKAGE, source, true, false, INSTALL, SECRET, 0, "POSTED", true).state.equals("ACCESS_REQUIRED"));
        i.check(NotificationContent.inspect(owner, "other.example", source, true, true, INSTALL, SECRET, 0, "POSTED", true).state.equals("OTHER_APP_IGNORED"));
        i.check(supplied.get() == 0);
        i.phase("content source HMAC is stable, installation/user/shortcut scoped and never title based");
        String key = NotificationContent.source(SECRET, 0, "PRIVATE_SHORTCUT");
        i.check(key.matches("[0-9a-f]{64}") && key.equals(NotificationContent.source(SECRET, 0, "PRIVATE_SHORTCUT")));
        byte[] otherSecret = SECRET.clone(); otherSecret[0] = 1;
        i.check(!key.equals(NotificationContent.source(otherSecret, 0, "PRIVATE_SHORTCUT")));
        i.check(!key.equals(NotificationContent.source(SECRET, 1, "PRIVATE_SHORTCUT")));
        i.check(!key.equals(NotificationContent.source(SECRET, 0, "ANOTHER_SHORTCUT")));
        Notification missing = NotificationReadinessChecks.notification(); missing.extras.putString(Notification.EXTRA_TEXT, "PRIVATE_TEXT");
        i.check(inspect(owner, missing).state.equals("SOURCE_REQUIRED"));
        Notification empty = base(owner); i.check(inspect(owner, empty).state.equals("NO_CONTENT"));
        Notification summary = base(owner); summary.flags |= Notification.FLAG_GROUP_SUMMARY;
        i.check(inspect(owner, summary).state.equals("SUMMARY_SKIPPED"));
        i.check(inspect(owner, null).state.equals("MALFORMED"));
        Notification text = base(owner); text.extras.putString(Notification.EXTRA_TEXT, "PRIVATE_TEXT");
        NotificationContent.Result body = inspect(owner, text);
        i.phase("content text round trip and cap are actual previews, not full messages");
        i.check(body.state.equals("SAVED") && body.document.length() == 13 && !body.document.getBoolean("complete"));
        i.check(body.document.getJSONArray("messages").getJSONObject(0).getString("text").equals("PRIVATE_TEXT"));
        i.phase("Android sensitive-content placeholders are not recovered messages");
        Notification redacted = base(owner);
        redacted.extras.putCharSequence(Notification.EXTRA_TEXT, "Sensitive notification content hidden");
        NotificationContent.Result blockedContent = inspect(owner, redacted);
        i.check(blockedContent.state.equals("REDACTED") && blockedContent.document == null);
        Notification redactedStyle = new Notification.Builder(owner, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setShortcutId("PRIVATE_SHORTCUT").setStyle(new Notification.MessagingStyle("Synthetic user")
                .addMessage(new Notification.MessagingStyle.Message("Sensitive notification content hidden", 1700000000000L, "Synthetic sender"))).build();
        if (Build.VERSION.SDK_INT >= 30) i.check(inspect(owner, redactedStyle).state.equals("REDACTED"));
        i.check(inspect(owner, text).state.equals("SAVED"));
        i.check(!body.document.toString().contains("PRIVATE_SHORTCUT") && !body.document.toString().contains("secret"));
        text.extras.putString(Notification.EXTRA_TITLE, "ANOTHER_TITLE");
        i.check(inspect(owner, text).document.getString("source_key").equals(key));
        text.extras.putString(Notification.EXTRA_TEXT, new String(new char[4100]).replace('\0', 'x'));
        JSONObject longRow = inspect(owner, text).document.getJSONArray("messages").getJSONObject(0);
        i.check(longRow.getString("text").length() == 4000 && longRow.getBoolean("truncated"));
        Notification.MessagingStyle style = new Notification.MessagingStyle("Synthetic user");
        for (int n = 0; n < 12; n++) style.addMessage(new Notification.MessagingStyle.Message("PRIVATE_TEXT", 1700000000000L + n, "PRIVATE_SENDER")
            .setData("image/png", Uri.parse("content://unknown.invalid/PRIVATE_URI")));
        Notification messages = new Notification.Builder(owner, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setShortcutId("PRIVATE_SHORTCUT").setStyle(style).build();
        // Framework-generated notification titles may contain the sender label.
        // Deliver a distinct conversation title to test that sender fields/URIs aren't serialized separately.
        messages.extras.putCharSequence(Notification.EXTRA_CONVERSATION_TITLE, "PRIVATE_CONVERSATION_TITLE");
        NotificationContent.Result many = inspect(owner, messages);
        i.phase("content MessagingStyle cap, explicit conversation title and excluded URI/sender fields");
        if (Build.VERSION.SDK_INT >= 30) {
            i.check(many.document.getString("title").equals("PRIVATE_CONVERSATION_TITLE"));
            i.check(many.document.getJSONArray("messages").length() == 10 && many.document.getBoolean("truncated"));
            i.check(many.document.getInt("uri_attachments") == 10);
            i.check(!many.document.toString().contains("PRIVATE_URI") && !many.document.toString().contains("PRIVATE_SENDER"));
        } else i.check(many.state.equals("UNAVAILABLE"));
        Notification uriOnly = new Notification.Builder(owner, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setShortcutId("PRIVATE_SHORTCUT").setStyle(new Notification.MessagingStyle("Synthetic user")
                .addMessage(new Notification.MessagingStyle.Message("", 1700000000000L, "Synthetic sender")
                    .setData("image/png", Uri.parse("content://unknown.invalid/PRIVATE_URI")))).build();
        NotificationContent.Result uriResult = inspect(owner, uriOnly);
        i.phase("content valid empty-text URI-only control: " + uriResult.state);
        i.check(uriResult.state.equals(Build.VERSION.SDK_INT >= 30 ? "URI_ONLY_UNSUPPORTED" : "UNAVAILABLE"));
        Notification invalidMessages = base(owner);
        invalidMessages.extras.putParcelableArray(Notification.EXTRA_MESSAGES, new android.os.Parcelable[] {new android.os.Bundle()});
        i.check(inspect(owner, invalidMessages).state.equals(Build.VERSION.SDK_INT >= 30 ? "MALFORMED" : "UNAVAILABLE"));
        i.check(NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> invalidMessages, true, true).state
            .equals(Build.VERSION.SDK_INT >= 30 ? "MALFORMED" : "UNAVAILABLE"));
        i.phase("explicit bitmap preview encodes real PNG; avatar and URI/resource icons never become graphics");
        Bitmap bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888); bitmap.eraseColor(0xff339944);
        Notification picture = base(owner); picture.extras.putParcelable(Notification.EXTRA_PICTURE, bitmap);
        NotificationContent.Result image = inspect(owner, picture);
        JSONObject png = image.document.getJSONObject("image");
        byte[] encoded = android.util.Base64.decode(png.getString("data_base64"), android.util.Base64.NO_WRAP);
        i.check(image.state.equals("SAVED") && image.document.getString("image_state").equals("BITMAP_PREVIEW"));
        i.check(png.getInt("width") == 2 && png.getInt("height") == 2 && encoded.length == png.getInt("bytes"));
        i.check(NotificationContent.digest(encoded).equals(png.getString("sha256")));
        Bitmap decoded = android.graphics.BitmapFactory.decodeByteArray(encoded, 0, encoded.length);
        i.check(decoded != null && decoded.getPixel(0, 0) == 0xff339944); if (decoded != null) decoded.recycle();
        Notification avatar = new Notification.Builder(owner, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setShortcutId("PRIVATE_SHORTCUT").setLargeIcon(bitmap).build();
        i.check(inspect(owner, avatar).state.equals("NO_CONTENT"));
        if (Build.VERSION.SDK_INT >= 31) {
            Notification icon = base(owner); icon.extras.putParcelable(Notification.EXTRA_PICTURE_ICON, Icon.createWithBitmap(bitmap));
            i.check(inspect(owner, icon).document.getString("image_state").equals("BITMAP_PREVIEW"));
            icon.extras.putParcelable(Notification.EXTRA_PICTURE_ICON, Icon.createWithContentUri("content://unknown.invalid/PRIVATE_URI"));
            i.check(inspect(owner, icon).state.equals("URI_ONLY_UNSUPPORTED"));
            icon.extras.putParcelable(Notification.EXTRA_PICTURE_ICON, Icon.createWithResource(owner, android.R.drawable.ic_dialog_info));
            i.check(inspect(owner, icon).state.equals("IMAGE_UNSUPPORTED"));
        }
        picture.extras.putString(Notification.EXTRA_PICTURE, "PRIVATE_WRONG_TYPE");
        i.check(inspect(owner, picture).state.equals("MALFORMED")); bitmap.recycle();
        i.phase("content image dimension and byte caps are enforced by the real encoder");
        Bitmap wide = Bitmap.createBitmap(2050, 1, Bitmap.Config.ARGB_8888); wide.eraseColor(0xff339944);
        Notification wideNotification = base(owner); wideNotification.extras.putParcelable(Notification.EXTRA_PICTURE, wide);
        JSONObject resized = inspect(owner, wideNotification).document.getJSONObject("image");
        i.check(resized.getInt("width") == 2048 && resized.getInt("height") == 1); wide.recycle();
        Bitmap noise = Bitmap.createBitmap(1024, 1024, Bitmap.Config.ARGB_8888);
        int[] pixels = new int[1024 * 1024]; java.util.Random random = new java.util.Random(17);
        for (int n = 0; n < pixels.length; n++) pixels[n] = random.nextInt();
        noise.setPixels(pixels, 0, 1024, 0, 0, 1024, 1024);
        Notification tooLarge = base(owner); tooLarge.extras.putParcelable(Notification.EXTRA_PICTURE, noise);
        tooLarge.extras.putString(Notification.EXTRA_TEXT, "Synthetic text survives unsupported image");
        NotificationContent.Result boundedImage = inspect(owner, tooLarge);
        i.check(boundedImage.state.equals("SAVED") && boundedImage.document.isNull("image")
            && boundedImage.document.getString("image_state").equals("UNAVAILABLE")); noise.recycle();
        i.phase("content publication is atomic/private/synthetic-isolated; clear and cancellation cannot publish late");
        File directory = new File(owner.getCacheDir(), "notification-content-controls");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException();
        android.system.Os.chmod(directory.getPath(), 0700);
        Context fixture = new ContextWrapper(owner) { @Override public File getFilesDir() { return directory; } };
        NotificationContentStore.clear(fixture);
        i.check(NotificationContentStore.publish(fixture, body, true));
        i.check(!NotificationContentStore.publish(owner, body, true));
        String before = NotificationContentStore.read(fixture, NotificationContentStore.FILE, NotificationContent.MAX_BYTES).toString();
        String savedState = NotificationContentStore.read(fixture, NotificationContentStore.STATE, 4096).toString();
        long savedRevision = NotificationContentStore.revision(fixture);
        NotificationContentStore.missingSource(fixture);
        i.check(before.equals(NotificationContentStore.read(fixture, NotificationContentStore.FILE, NotificationContent.MAX_BYTES).toString()));
        i.check(savedState.equals(NotificationContentStore.read(fixture, NotificationContentStore.STATE, 4096).toString()));
        i.check(savedRevision == NotificationContentStore.revision(fixture));
        JSONObject expiredState = new JSONObject(savedState);
        expiredState.put("recorded_at_ms", System.currentTimeMillis() - 1800001);
        try (java.io.FileOutputStream stream = new java.io.FileOutputStream(new File(directory, NotificationContentStore.STATE))) {
            stream.write(expiredState.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        }
        NotificationContentStore.missingSource(fixture);
        i.check(NotificationContentStore.read(fixture, NotificationContentStore.STATE, 4096).getString("state").equals("SOURCE_REQUIRED"));
        i.check(before.equals(NotificationContentStore.read(fixture, NotificationContentStore.FILE, NotificationContent.MAX_BYTES).toString()));
        i.check((android.system.Os.stat(new File(directory, NotificationContentStore.FILE).getPath()).st_mode & 0777) == 0600);
        i.check(!NotificationContentStore.publish(fixture, body, false));
        i.check(!NotificationContentStore.publish(fixture, image, true, () -> false));
        i.check(before.equals(NotificationContentStore.read(fixture, NotificationContentStore.FILE, NotificationContent.MAX_BYTES).toString()));
        long revision = NotificationContentStore.revision(fixture), ownerRevision = NotificationContentStore.revision(owner); NotificationContentStore.clear(fixture);
        i.check(NotificationContentStore.revision(fixture) != revision && !new File(directory, NotificationContentStore.FILE).exists());
        NotificationContentStore.missingSource(fixture);
        i.check(NotificationContentStore.read(fixture, NotificationContentStore.STATE, 4096).getString("state").equals("SOURCE_REQUIRED"));
        i.check(NotificationContentStore.revision(owner) == ownerRevision);
        NotificationContentStore.Identity first = NotificationContentStore.identity(fixture), again = NotificationContentStore.identity(fixture);
        i.check(first.install.equals(again.install) && java.util.Arrays.equals(first.secret, again.secret));
        i.check((android.system.Os.stat(new File(directory, "notification-identity.json").getPath()).st_mode & 0777) == 0600);
        i.check(NotificationContentStore.enabled(owner) == optedIn);
        // Retain one explicitly SYNTHETIC codec fixture for automated host compatibility checks.
        // Its known cache path is never used by the real importer. Remove the fixture-only secret.
        i.check(NotificationContentStore.publish(fixture, image, true));
        new android.util.AtomicFile(new File(directory, "notification-identity.json")).delete();
        i.phase("installed content setup explains its separate opt-in without changing owner settings");
        java.util.concurrent.ExecutorService launcher = java.util.concurrent.Executors.newSingleThreadExecutor();
        CaptureSetupActivity activity;
        try { activity = launcher.submit(() -> (CaptureSetupActivity) i.startActivitySync(new android.content.Intent(owner, CaptureSetupActivity.class)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))).get(15, java.util.concurrent.TimeUnit.SECONDS); }
        finally { launcher.shutdownNow(); }
        i.runOnMainSync(() -> {
            android.view.View root = activity.findViewById(android.R.id.content);
            i.check(root.findViewWithTag("content-enable") != null && root.findViewWithTag("content-disable") != null
                && root.findViewWithTag("content-clear") != null);
            i.check(((android.widget.TextView) root.findViewWithTag("capture-status")).getText().toString().contains("Local content samples: "));
            activity.finish();
        });
        i.check(NotificationContentStore.enabled(owner) == optedIn);
    }
}

package dev.textem.probe;

import android.app.Notification;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Parcelable;
import android.content.Context;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.function.Supplier;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONArray;
import org.json.JSONObject;

/** Bounded notification preview, never a complete message/history claim. */
final class NotificationContent {
    interface MediaReader { Bitmap read(android.net.Uri uri, String mime) throws Exception; }
    static final int MAX_BYTES = 2 * 1024 * 1024, IMAGE_BYTES = 1024 * 1024;
    static final class Result {
        final String state; final JSONObject document;
        Result(String state, JSONObject document) { this.state = state; this.document = document; }
    }
    static String digest(byte[] value) throws Exception {
        return hex(MessageDigest.getInstance("SHA-256").digest(value));
    }
    private static String hex(byte[] value) {
        StringBuilder result = new StringBuilder();
        for (byte b : value) result.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
        return result.toString();
    }
    static String source(byte[] secret, int uid, String shortcut) throws Exception {
        if (secret.length != 32 || uid < 0 || shortcut == null || shortcut.isEmpty() || shortcut.length() > 1024) throw new IllegalArgumentException();
        Mac mac = Mac.getInstance("HmacSHA256"); mac.init(new SecretKeySpec(secret, "HmacSHA256"));
        return hex(mac.doFinal((NotificationReadiness.PACKAGE + "\u0000" + uid + "\u0000" + shortcut).getBytes(StandardCharsets.UTF_8)));
    }
    private static String bounded(CharSequence value, int limit) {
        if (value == null) return "";
        int end = Math.min(value.length(), limit);
        if (end > 0 && end < value.length() && Character.isHighSurrogate(value.charAt(end - 1))) end--;
        return value.subSequence(0, end).toString();
    }
    static Result inspect(Context context, String packageName, Supplier<Notification> supplier,
                          boolean enabled, boolean access, String install, byte[] secret, int uid,
                          String origin, boolean synthetic) {
        return inspect(context, packageName, supplier, enabled, access, install, secret, uid, origin, synthetic,
            (uri, mime) -> synthetic ? null : NotificationMedia.read(context, uri, mime));
    }
    static Result mediaFixture(Context context, Supplier<Notification> supplier, MediaReader reader) {
        if (!context.getFilesDir().equals(new java.io.File(context.getCacheDir(), "notification-content-controls"))) throw new SecurityException();
        return inspect(context, NotificationReadiness.PACKAGE, supplier, true, true,
            "57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32], 0, "POSTED", true, reader);
    }
    private static Result inspect(Context context, String packageName, Supplier<Notification> supplier,
                          boolean enabled, boolean access, String install, byte[] secret, int uid,
                          String origin, boolean synthetic, MediaReader reader) {
        if (!enabled) return new Result("OFF", null);
        if (!access) return new Result("ACCESS_REQUIRED", null);
        if (!NotificationReadiness.PACKAGE.equals(packageName)) return new Result("OTHER_APP_IGNORED", null);
        if (!Arrays.asList("POSTED", "ACTIVE_SCAN").contains(origin)) return new Result("MALFORMED", null);
        Bitmap scaled = null;
        Bitmap recovered = null;
        try {
            Notification n = supplier.get();
            if (n == null || n.extras == null) return new Result("MALFORMED", null);
            if ((n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return new Result("SUMMARY_SKIPPED", null);
            String shortcut = n.getShortcutId();
            if (uid < 0 || shortcut == null || shortcut.isEmpty() || shortcut.length() > 1024) return new Result("SOURCE_REQUIRED", null);
            java.util.UUID.fromString(install);
            String key = source(secret, uid, shortcut);
            boolean truncated = false; int uris = 0;
            android.net.Uri candidate = null; String candidateMime = null;
            JSONArray messages = new JSONArray();
            Parcelable[] raw = n.extras.getParcelableArray(Notification.EXTRA_MESSAGES);
            if (raw != null) {
                if (Build.VERSION.SDK_INT < 30) return new Result("UNAVAILABLE", null);
                truncated = raw.length > 10;
                Parcelable[] boundedMessages = Arrays.copyOfRange(raw, Math.max(0, raw.length - 10), raw.length);
                java.util.List<Notification.MessagingStyle.Message> decoded = Notification.MessagingStyle.Message.getMessagesFromBundleArray(boundedMessages);
                if (boundedMessages.length > 0 && decoded.isEmpty()) return new Result("MALFORMED", null);
                truncated |= decoded.size() < boundedMessages.length;
                for (Notification.MessagingStyle.Message m : decoded) {
                    CharSequence text = m.getText();
                    JSONObject row = new JSONObject();
                    long timestamp = m.getTimestamp();
                    row.put("timestamp_ms", timestamp >= 0 && timestamp <= System.currentTimeMillis() + 300000 ? timestamp : 0);
                    row.put("text", bounded(text, 4000)); row.put("truncated", text != null && text.length() > 4000);
                    messages.put(row);
                    if (m.getDataUri() != null) {
                        uris++;
                        if (NotificationMedia.eligible(m.getDataUri(), m.getDataMimeType())) {
                            candidate = m.getDataUri(); candidateMime = m.getDataMimeType();
                        }
                    }
                }
            } else {
                CharSequence text = n.extras.getCharSequence(Notification.EXTRA_BIG_TEXT);
                if (text == null) text = n.extras.getCharSequence(Notification.EXTRA_TEXT);
                if (text != null && text.length() > 0) {
                    JSONObject row = new JSONObject(); row.put("timestamp_ms", 0);
                    row.put("text", bounded(text, 4000)); row.put("truncated", text.length() > 4000); messages.put(row);
                }
            }
            // Android may replace OTP-bearing content before delivering it to
            // an untrusted listener. This is an OS placeholder, not recovery.
            for (int index = 0; index < messages.length(); index++) {
                if (messages.getJSONObject(index).getString("text").trim()
                        .equals("Sensitive notification content hidden")) return new Result("REDACTED", null);
            }
            CharSequence title = n.extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE);
            if (title == null || title.length() == 0) title = n.extras.getCharSequence(Notification.EXTRA_TITLE);
            String imageState = "ABSENT"; Bitmap picture = null;
            Object bitmap = n.extras.get(Notification.EXTRA_PICTURE);
            if (bitmap instanceof Bitmap) picture = (Bitmap) bitmap;
            else if (bitmap != null) return new Result("MALFORMED", null);
            if (Build.VERSION.SDK_INT >= 31) {
                Object value = n.extras.get(Notification.EXTRA_PICTURE_ICON);
                if (value instanceof Icon) {
                    Icon icon = (Icon) value;
                    if (picture == null && icon.getType() == Icon.TYPE_BITMAP) {
                        // Only an explicit picture bitmap. Never load URI/resource/avatar icons.
                        android.graphics.drawable.Drawable drawable = icon.loadDrawable(context);
                        if (drawable instanceof BitmapDrawable) picture = ((BitmapDrawable) drawable).getBitmap();
                        else imageState = "UNSUPPORTED";
                    } else if (picture == null) imageState = "UNSUPPORTED";
                    if (icon.getType() == Icon.TYPE_URI || icon.getType() == Icon.TYPE_URI_ADAPTIVE_BITMAP) {
                        uris++;
                        if (candidate == null && NotificationMedia.eligible(icon.getUri(), "image/*")) {
                            candidate = icon.getUri(); candidateMime = "image/*";
                        }
                    }
                } else if (value != null) return new Result("MALFORMED", null);
            }
            JSONObject image = null;
            if (picture == null && candidate != null) {
                try {
                    recovered = reader.read(candidate, candidateMime); picture = recovered;
                    if (recovered == null) imageState = "UNAVAILABLE";
                } catch (Exception unavailable) { imageState = "UNAVAILABLE"; }
            }
            if (picture != null) {
                try {
                if (picture.isRecycled() || picture.getWidth() <= 0 || picture.getHeight() <= 0) return new Result("MALFORMED", null);
                double ratio = Math.min(1, 2048.0 / Math.max(picture.getWidth(), picture.getHeight()));
                Bitmap output = picture;
                if (ratio < 1) {
                    scaled = Bitmap.createScaledBitmap(picture, Math.max(1, (int) (picture.getWidth() * ratio)),
                        Math.max(1, (int) (picture.getHeight() * ratio)), true); output = scaled;
                }
                ByteArrayOutputStream png = new ByteArrayOutputStream() {
                    @Override public synchronized void write(byte[] b, int off, int len) {
                        if (count + len > IMAGE_BYTES) throw new IllegalStateException(); super.write(b, off, len);
                    }
                    @Override public synchronized void write(int b) {
                        if (count == IMAGE_BYTES) throw new IllegalStateException(); super.write(b);
                    }
                };
                if (output.compress(Bitmap.CompressFormat.PNG, 100, png)) {
                    byte[] bytes = png.toByteArray(); image = new JSONObject();
                    image.put("mime", "image/png"); image.put("width", output.getWidth()); image.put("height", output.getHeight());
                    image.put("bytes", bytes.length); image.put("sha256", digest(bytes));
                    image.put("data_base64", Base64.encodeToString(bytes, Base64.NO_WRAP)); imageState = "BITMAP_PREVIEW";
                } else imageState = "UNAVAILABLE";
                } catch (RuntimeException unavailable) { image = null; imageState = "UNAVAILABLE"; }
            }
            // A reference is resolved only after its bounded PNG was produced.
            if (recovered != null && image != null) uris--;
            boolean textPresent = false;
            for (int index = 0; index < messages.length(); index++) textPresent |= !messages.getJSONObject(index).getString("text").isEmpty();
            if (!textPresent && image == null) return new Result(uris > 0 ? "URI_ONLY_UNSUPPORTED"
                : !imageState.equals("ABSENT") ? "IMAGE_UNSUPPORTED" : "NO_CONTENT", null);
            JSONObject document = new JSONObject(); document.put("schema", 1);
            document.put("kind", synthetic ? "SYNTHETIC_NOTIFICATION_CONTENT" : "NOTIFICATION_CONTENT");
            document.put("captured_at_ms", System.currentTimeMillis()); document.put("origin", origin);
            document.put("install_id", install); document.put("source_key", key);
            document.put("title", bounded(title, 256)); document.put("messages", messages);
            document.put("truncated", truncated || (title != null && title.length() > 256));
            document.put("image", image == null ? JSONObject.NULL : image); document.put("image_state", imageState);
            document.put("uri_attachments", uris); document.put("complete", false);
            return new Result("SAVED", document);
        } catch (Exception malformed) { return new Result("MALFORMED", null); }
        finally { if (scaled != null) scaled.recycle(); if (recovered != null) recovered.recycle(); }
    }
}

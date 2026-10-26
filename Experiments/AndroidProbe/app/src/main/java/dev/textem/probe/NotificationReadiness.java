package dev.textem.probe;

import android.app.Notification;
import android.graphics.Bitmap;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Parcelable;
import java.util.Arrays;
import java.util.function.Supplier;
import org.json.JSONObject;

/** Count shapes only. Never retain text, identifiers, URI strings or pixel bytes. */
final class NotificationReadiness {
    static final String PACKAGE = "com.google.android.apps.messaging";
    static final int MESSAGE_LIMIT = 10, TEXT_LIMIT = 4000;
    static final class Report {
        String state = "EMPTY";
        int notifications, messages, textValues, textChars, pictures, pictureIcons, uriAttachments;
        int shortcutIds, conversationTitles, summaries;
        boolean limited, messagingStyle;
        JSONObject json(String kind, String origin, boolean enabled, boolean access, boolean connected) throws Exception {
            JSONObject j = new JSONObject();
            j.put("schema", 1); j.put("kind", kind); j.put("recorded_at_ms", System.currentTimeMillis());
            j.put("origin", origin); j.put("state", state); j.put("capture_enabled", enabled);
            j.put("notification_access", access); j.put("listener_connected", connected);
            j.put("notifications", notifications); j.put("messages", messages);
            j.put("text_values", textValues); j.put("text_chars", textChars);
            j.put("bitmap_pictures", pictures); j.put("bitmap_picture_icons", pictureIcons);
            j.put("uri_attachments", uriAttachments); j.put("shortcut_ids", shortcutIds);
            j.put("conversation_titles", conversationTitles); j.put("summaries_skipped", summaries);
            j.put("limited", limited); j.put("messaging_style", messagingStyle);
            j.put("content_exported", false); j.put("graphics_decoded", false);
            return j;
        }
        String summary() {
            return "Notification state: " + state + "\nNotifications: " + notifications + "; messages: " + messages
                + "\nText values: " + textValues + "; characters: " + textChars
                + "\nBitmap pictures/icons: " + pictures + "/" + pictureIcons + "; URI attachments: " + uriAttachments
                + "\nStable shortcut present: " + shortcutIds + "; conversation title present: " + conversationTitles
                + (limited ? "\nSample capped." : "")
                + "\nCounts/types only. No message content exported; no graphics decoded.";
        }
    }
    static Report inspect(String packageName, Supplier<Notification> payload, boolean enabled, boolean access) {
        Report r = new Report();
        if (!enabled) { r.state = "OFF"; return r; }
        if (!access) { r.state = "ACCESS_REQUIRED"; return r; }
        if (!PACKAGE.equals(packageName)) { r.state = "OTHER_APP_IGNORED"; return r; }
        try {
            Notification n = payload.get();
            if (n == null || n.extras == null) { r.state = "MALFORMED"; return r; }
            if ((n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) { r.state = "SUMMARY_SKIPPED"; r.summaries = 1; return r; }
            r.notifications = 1;
            String shortcut = n.getShortcutId();
            r.shortcutIds = shortcut != null && !shortcut.isEmpty() ? 1 : 0;
            r.conversationTitles = n.extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) != null ? 1 : 0;
            Parcelable[] raw = n.extras.getParcelableArray(Notification.EXTRA_MESSAGES);
            if (raw != null) {
                // The public bounded message decoder was added in API 30. Do not
                // guess private Bundle keys on older Android releases.
                if (Build.VERSION.SDK_INT < 30) { Report unsupported = new Report(); unsupported.state = "UNAVAILABLE"; return unsupported; }
                r.messagingStyle = true; r.limited = raw.length > MESSAGE_LIMIT;
                Parcelable[] bounded = Arrays.copyOfRange(raw, Math.max(0, raw.length - MESSAGE_LIMIT), raw.length);
                java.util.List<Notification.MessagingStyle.Message> messages = Notification.MessagingStyle.Message.getMessagesFromBundleArray(bounded);
                for (Notification.MessagingStyle.Message message : messages) {
                    r.messages++; text(r, message.getText());
                    if (message.getDataUri() != null) r.uriAttachments++;
                }
            } else {
                CharSequence value = n.extras.getCharSequence(Notification.EXTRA_BIG_TEXT);
                if (value == null) value = n.extras.getCharSequence(Notification.EXTRA_TEXT);
                if (value != null && value.length() > 0) { r.messages = 1; text(r, value); }
            }
            Object picture = n.extras.get(Notification.EXTRA_PICTURE);
            if (picture instanceof Bitmap) r.pictures = 1;
            else if (picture != null) throw new IllegalArgumentException();
            if (Build.VERSION.SDK_INT >= 31) {
                Object icon = n.extras.get(Notification.EXTRA_PICTURE_ICON);
                if (icon instanceof Icon) {
                    int type = ((Icon) icon).getType();
                    if (type == Icon.TYPE_BITMAP || type == Icon.TYPE_ADAPTIVE_BITMAP) r.pictureIcons = 1;
                    else if (type == Icon.TYPE_URI || type == Icon.TYPE_URI_ADAPTIVE_BITMAP) r.uriAttachments++;
                } else if (icon != null) throw new IllegalArgumentException();
            }
            r.state = r.textValues + r.pictures + r.pictureIcons + r.uriAttachments > 0 ? "SHAPES_PRESENT" : "EMPTY";
            return r;
        } catch (RuntimeException malformed) { Report failed = new Report(); failed.state = "MALFORMED"; return failed; }
    }
    private static void text(Report r, CharSequence value) {
        if (value == null || value.length() == 0) return;
        r.textValues++; r.textChars += Math.min(TEXT_LIMIT, value.length());
        if (value.length() > TEXT_LIMIT) r.limited = true;
    }
    static boolean valid(Report r, String kind, String origin, boolean enabled, boolean access, boolean connected) {
        if (!Arrays.asList("NOTIFICATION_SAMPLE", "SYNTHETIC").contains(kind)
                || !Arrays.asList("STATE", "ACTIVE_SCAN", "POSTED", "SYNTHETIC").contains(origin)
                || kind.equals("SYNTHETIC") != origin.equals("SYNTHETIC")
                || !Arrays.asList("OFF", "ACCESS_REQUIRED", "OTHER_APP_IGNORED", "MALFORMED", "SUMMARY_SKIPPED", "EMPTY", "SHAPES_PRESENT", "LISTENING", "WAITING_FOR_LISTENER", "UNAVAILABLE").contains(r.state)) return false;
        if (kind.equals("NOTIFICATION_SAMPLE") && (origin.equals("POSTED") || origin.equals("ACTIVE_SCAN")) && !connected) return false;
        if (r.notifications < 0 || r.notifications > 1 || r.messages < 0 || r.messages > MESSAGE_LIMIT
                || r.textValues < 0 || r.textValues > r.messages || r.textChars < r.textValues || r.textChars > r.textValues * TEXT_LIMIT
                || r.pictures < 0 || r.pictures > 1 || r.pictureIcons < 0 || r.pictureIcons > 1
                || r.uriAttachments < 0 || r.uriAttachments > r.messages + 1
                || r.shortcutIds < 0 || r.shortcutIds > r.notifications || r.conversationTitles < 0 || r.conversationTitles > r.notifications
                || r.summaries < 0 || r.summaries > 1) return false;
        int shapes = r.textValues + r.pictures + r.pictureIcons + r.uriAttachments;
        if (kind.equals("NOTIFICATION_SAMPLE") && origin.equals("STATE")
                && Arrays.asList("SHAPES_PRESENT", "EMPTY", "SUMMARY_SKIPPED", "MALFORMED", "OTHER_APP_IGNORED").contains(r.state)) return false;
        if (r.state.equals("SHAPES_PRESENT")) return enabled && access && r.notifications == 1 && shapes > 0 && r.summaries == 0;
        if (r.state.equals("EMPTY")) return enabled && access && shapes == 0 && r.summaries == 0;
        if (r.messages + shapes + r.notifications + r.shortcutIds + r.conversationTitles != 0 || r.messagingStyle || r.limited) return false;
        if (r.state.equals("SUMMARY_SKIPPED")) return enabled && access && r.summaries == 1;
        if (r.summaries != 0) return false;
        if (r.state.equals("OFF")) return !enabled;
        if (r.state.equals("ACCESS_REQUIRED")) return enabled && !access;
        if (r.state.equals("LISTENING")) return enabled && access && connected;
        if (r.state.equals("WAITING_FOR_LISTENER")) return enabled && access && !connected;
        return enabled && access;
    }
}

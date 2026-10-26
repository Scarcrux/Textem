package dev.textem.probe;

import android.app.Notification;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.view.View;
import android.view.WindowManager;
import android.widget.TextView;
import java.io.File;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

/** Synthetic reports use isolated cache. Never changes the real capture opt-in or OS access. */
final class NotificationReadinessChecks {
    private static String savedReport(Context c) {
        try { return CaptureState.read(c).toString(); } catch (Exception absent) { return null; }
    }
    static Notification notification() { Notification n = new Notification(); n.extras = new Bundle(); return n; }
    static void run(ProbeAutomation i) throws Exception {
        i.phase("notification access and exact-package guards precede payload supplier");
        Context owner = i.getTargetContext();
        boolean enabledBefore = CaptureState.enabled(owner), accessBefore = CaptureState.access(owner);
        String reportBefore = savedReport(owner);
        AtomicInteger supplied = new AtomicInteger();
        java.util.function.Supplier<Notification> source = () -> { supplied.incrementAndGet(); return notification(); };
        i.check(NotificationReadiness.inspect(NotificationReadiness.PACKAGE, source, false, true).state.equals("OFF"));
        i.check(NotificationReadiness.inspect(NotificationReadiness.PACKAGE, source, true, false).state.equals("ACCESS_REQUIRED"));
        i.check(NotificationReadiness.inspect("untrusted.example", source, true, true).state.equals("OTHER_APP_IGNORED"));
        i.check(supplied.get() == 0);
        i.check(NotificationReadiness.inspect(NotificationReadiness.PACKAGE, source, true, true).state.equals("EMPTY"));
        i.check(supplied.get() == 1);

        i.phase("notification shape controls discriminate text, pictures, URI-only and empty");
        Notification text = notification(); text.extras.putCharSequence(Notification.EXTRA_BIG_TEXT, "PRIVATE_TEXT_SENTINEL");
        NotificationReadiness.Report textReport = NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> text, true, true);
        i.check(textReport.state.equals("SHAPES_PRESENT") && textReport.textValues == 1 && textReport.messages == 1);
        i.check(textReport.pictures == 0 && textReport.uriAttachments == 0);
        Notification summary = notification(); summary.flags |= Notification.FLAG_GROUP_SUMMARY;
        summary.extras.putCharSequence(Notification.EXTRA_TEXT, "PRIVATE_SUMMARY_SENTINEL");
        NotificationReadiness.Report skipped = NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> summary, true, true);
        i.check(skipped.state.equals("SUMMARY_SKIPPED") && skipped.textValues == 0 && skipped.notifications == 0);
        Bitmap bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888); bitmap.eraseColor(0xff22bb44);
        Notification picture = notification(); picture.extras.putParcelable(Notification.EXTRA_PICTURE, bitmap);
        NotificationReadiness.Report image = NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> picture, true, true);
        i.check(image.pictures == 1 && image.textValues == 0 && image.state.equals("SHAPES_PRESENT"));
        if (Build.VERSION.SDK_INT >= 31) {
            i.phase("notification bitmap-icon control");
            Notification icon = notification(); icon.extras.putParcelable(Notification.EXTRA_PICTURE_ICON, Icon.createWithBitmap(bitmap));
            i.check(NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> icon, true, true).pictureIcons == 1);
            icon.extras.putParcelable(Notification.EXTRA_PICTURE_ICON, Icon.createWithContentUri("content://unknown.invalid/PRIVATE_PATH"));
            NotificationReadiness.Report uri = NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> icon, true, true);
            i.phase("notification URI-icon control: " + uri.state + "; URI count=" + uri.uriAttachments);
            i.check(uri.uriAttachments == 1);
        }
        i.phase("notification malformed and null payload controls");
        Notification malformed = notification(); malformed.extras.putString(Notification.EXTRA_PICTURE, "PRIVATE_BAD_TYPE");
        i.check(NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> malformed, true, true).state.equals("MALFORMED"));
        i.check(NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> null, true, true).state.equals("MALFORMED"));
        Notification.MessagingStyle style = new Notification.MessagingStyle("Synthetic user");
        String longText = new String(new char[NotificationReadiness.TEXT_LIMIT + 10]).replace('\0', 'x');
        for (int n = 0; n < 12; n++) style.addMessage(new Notification.MessagingStyle.Message(longText, 1_700_000_000_000L + n, "PRIVATE_SENDER")
            .setData("image/png", Uri.parse("content://unknown.invalid/PRIVATE_PATH")));
        // Android itself normalizes Message text (1024 characters on API35/36).
        // Assert the delivered fixture, not the pre-framework source string.
        int deliveredLength = style.getMessages().get(0).getText().length();
        i.check(deliveredLength > 0 && deliveredLength <= longText.length());
        Notification messages = new Notification.Builder(owner, "synthetic-controls").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setShortcutId("PRIVATE_SHORTCUT_SENTINEL").setStyle(style).build();
        messages.extras.putCharSequence(Notification.EXTRA_CONVERSATION_TITLE, "PRIVATE_TITLE_SENTINEL");
        NotificationReadiness.Report capped = NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> messages, true, true);
        i.phase("notification bounded MessagingStyle control: " + capped.summary());
        if (Build.VERSION.SDK_INT >= 30) {
            i.check(capped.messagingStyle && capped.messages == 10 && capped.textValues == 10
                && capped.textChars == 10 * Math.min(NotificationReadiness.TEXT_LIMIT, deliveredLength) && capped.limited);
            i.check(capped.uriAttachments == 10 && capped.shortcutIds == 1 && capped.conversationTitles == 1);
        } else i.check(capped.state.equals("UNAVAILABLE") && capped.messages == 0 && capped.textChars == 0);
        i.check(capped.pictures == 0 && capped.pictureIcons == 0);
        Notification longFallback = notification(); longFallback.extras.putCharSequence(Notification.EXTRA_TEXT, longText);
        NotificationReadiness.Report boundedText = NotificationReadiness.inspect(NotificationReadiness.PACKAGE, () -> longFallback, true, true);
        i.phase("notification direct fallback text cap control");
        i.check(boundedText.state.equals("SHAPES_PRESENT") && boundedText.textValues == 1
            && boundedText.textChars == NotificationReadiness.TEXT_LIMIT && boundedText.limited);

        i.phase("notification diagnostics have fixed schema, private permissions and synthetic isolation");
        File directory = new File(owner.getCacheDir(), "notification-readiness-controls");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException();
        android.system.Os.chmod(directory.getPath(), 0700);
        Context fixture = new ContextWrapper(owner) { @Override public File getFilesDir() { return directory; } };
        i.check(CaptureState.record(fixture, capped, "SYNTHETIC", "SYNTHETIC", true, true, false));
        JSONObject json = CaptureState.read(fixture);
        i.check(json.length() == 22 && json.getString("kind").equals("SYNTHETIC"));
        i.check(!json.toString().contains("PRIVATE") && !json.toString().contains("content://"));
        i.check(!json.getBoolean("content_exported") && !json.getBoolean("graphics_decoded"));
        i.check((android.system.Os.stat(new File(directory, CaptureState.FILE).getPath()).st_mode & 0777) == 0600);
        NotificationReadiness.Report invalid = new NotificationReadiness.Report(); invalid.textChars = 99;
        i.check(!CaptureState.record(fixture, invalid, "SYNTHETIC", "SYNTHETIC", true, true, false));
        i.check(!CaptureState.record(fixture, capped, "NOTIFICATION_SAMPLE", "SYNTHETIC", true, true, false));
        i.check(!CaptureState.record(fixture, capped, "PRIVATE_KIND", "SYNTHETIC", true, true, false));
        i.check(!CaptureState.record(fixture, textReport, "NOTIFICATION_SAMPLE", "STATE", true, true, true));
        i.check(!CaptureState.record(fixture, textReport, "NOTIFICATION_SAMPLE", "POSTED", true, true, false));
        try (java.io.FileOutputStream oversized = new java.io.FileOutputStream(new File(directory, CaptureState.FILE))) {
            oversized.write(new byte[4097]);
        }
        boolean rejectedOversized = false;
        try { CaptureState.read(fixture); } catch (Exception expected) { rejectedOversized = true; }
        i.check(rejectedOversized);
        CaptureState.clear(fixture); i.check(!new File(directory, CaptureState.FILE).exists());
        bitmap.recycle();

        i.phase("actual setup Activity explains access and never grants it during controls");
        java.util.concurrent.ExecutorService launcher = java.util.concurrent.Executors.newSingleThreadExecutor();
        CaptureSetupActivity activity;
        try { activity = launcher.submit(() -> (CaptureSetupActivity) i.startActivitySync(new Intent(owner, CaptureSetupActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)))
                .get(15, java.util.concurrent.TimeUnit.SECONDS); }
        finally { launcher.shutdownNow(); }
        i.runOnMainSync(() -> {
            View root = activity.findViewById(android.R.id.content);
            i.check((activity.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_SECURE) != 0);
            i.check(root.findViewWithTag("capture-enable") != null && root.findViewWithTag("capture-disable") != null
                && root.findViewWithTag("capture-refresh") != null && root.findViewWithTag("capture-clear") != null);
            i.check(((TextView) root.findViewWithTag("capture-status")).getText().length() > 0);
            activity.finish();
        });
        i.check(CaptureState.enabled(owner) == enabledBefore && CaptureState.access(owner) == accessBefore);
        i.check(java.util.Objects.equals(reportBefore, savedReport(owner)));
    }
}

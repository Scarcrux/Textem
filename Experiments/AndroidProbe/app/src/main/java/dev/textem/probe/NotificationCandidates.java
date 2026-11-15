package dev.textem.probe;

import android.app.Notification;
import android.service.notification.StatusBarNotification;

/** A saved preview belongs to an identified conversation, not any Google event. */
final class NotificationCandidates {
    static boolean hasSource(StatusBarNotification item) {
        if (android.os.Build.VERSION.SDK_INT < 29 || item == null
                || !NotificationReadiness.PACKAGE.equals(item.getPackageName()) || item.getUid() < 0) return false;
        Notification n = item.getNotification();
        if (n == null || (n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return false;
        String shortcut = n.getShortcutId();
        return shortcut != null && !shortcut.isEmpty() && shortcut.length() <= 1024;
    }
    static final class Selection {
        final StatusBarNotification item;
        final NotificationReadiness.Report report;
        final String absentState;
        Selection(StatusBarNotification item, NotificationReadiness.Report report, String absentState) {
            this.item = item; this.report = report; this.absentState = absentState;
        }
    }
    static Selection active(StatusBarNotification[] items) {
        StatusBarNotification selected = null;
        NotificationReadiness.Report selectedReport = null, fallback = null;
        boolean summary = false; int inspected = 0;
        if (items != null) for (StatusBarNotification item : items) {
            if (item == null || !NotificationReadiness.PACKAGE.equals(item.getPackageName())) continue;
            if (++inspected > 20) {
                NotificationReadiness.Report capped = new NotificationReadiness.Report(); capped.state = "UNAVAILABLE";
                return new Selection(null, capped, "UNAVAILABLE");
            }
            NotificationReadiness.Report report = NotificationReadiness.inspect(item.getPackageName(), item::getNotification, true, true);
            if (report.state.equals("SUMMARY_SKIPPED")) { summary = true; continue; }
            if (fallback == null) fallback = report;
            if (hasSource(item) && report.state.equals("SHAPES_PRESENT")
                    && (selected == null || item.getPostTime() > selected.getPostTime())) {
                selected = item; selectedReport = report;
            }
        }
        if (selected != null) return new Selection(selected, selectedReport, null);
        if (fallback != null) return new Selection(null, fallback, fallback.shortcutIds == 0 && fallback.notifications > 0
            ? "SOURCE_REQUIRED" : fallback.state.equals("MALFORMED") ? "MALFORMED" : "NO_CONTENT");
        NotificationReadiness.Report empty = new NotificationReadiness.Report();
        if (summary) { empty.state = "SUMMARY_SKIPPED"; empty.summaries = 1; }
        return new Selection(null, empty, summary ? "SUMMARY_SKIPPED" : "NO_CONTENT");
    }
}

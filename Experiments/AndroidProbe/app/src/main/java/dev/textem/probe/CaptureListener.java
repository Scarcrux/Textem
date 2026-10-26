package dev.textem.probe;

import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

/** Passive metadata-only readiness gate. Never executes notification actions. */
public final class CaptureListener extends NotificationListenerService {
    private static volatile CaptureListener current;
    static boolean connected() { return current != null; }
    static void sampleCurrent() { CaptureListener value = current; if (value != null) value.sampleActive(); }
    @Override public void onListenerConnected() {
        current = this;
        if (CaptureState.enabled(this)) sampleActive();
    }
    @Override public void onListenerDisconnected() { disconnected(); }
    private void disconnected() {
        if (current != this) return;
        current = null; NotificationReadiness.Report report = new NotificationReadiness.Report();
        report.state = !CaptureState.enabled(this) ? "OFF" : CaptureState.access(this) ? "UNAVAILABLE" : "ACCESS_REQUIRED";
        CaptureState.record(this, report, "STATE");
    }
    @Override public void onDestroy() { disconnected(); super.onDestroy(); }
    @Override public void onNotificationPosted(StatusBarNotification item) {
        if (current != this || !CaptureState.enabled(this) || item == null || !NotificationReadiness.PACKAGE.equals(item.getPackageName())) return;
        NotificationReadiness.Report report = NotificationReadiness.inspect(item.getPackageName(), item::getNotification,
            true, CaptureState.access(this));
        CaptureState.record(this, report, "POSTED");
    }
    private void sampleActive() {
        boolean enabled = CaptureState.enabled(this), access = CaptureState.access(this);
        NotificationReadiness.Report empty = new NotificationReadiness.Report();
        if (!enabled || !access) {
            empty.state = enabled ? "ACCESS_REQUIRED" : "OFF"; CaptureState.record(this, empty, "STATE"); return;
        }
        try {
            StatusBarNotification[] items = getActiveNotifications();
            int inspected = 0;
            if (items != null) for (StatusBarNotification item : items) {
                if (item == null || !NotificationReadiness.PACKAGE.equals(item.getPackageName())) continue;
                if (++inspected > 20) {
                    // A capped search is not proof of an empty Google sample.
                    empty.state = "UNAVAILABLE"; CaptureState.record(this, empty, "STATE"); return;
                }
                NotificationReadiness.Report report = NotificationReadiness.inspect(item.getPackageName(), item::getNotification, true, true);
                if (!report.state.equals("SUMMARY_SKIPPED")) { CaptureState.record(this, report, "ACTIVE_SCAN"); return; }
            }
            if (inspected > 0) { empty.state = "SUMMARY_SKIPPED"; empty.summaries = 1; }
            CaptureState.record(this, empty, "ACTIVE_SCAN");
        } catch (RuntimeException failure) { empty.state = "UNAVAILABLE"; CaptureState.record(this, empty, "STATE"); }
    }
}

package dev.textem.probe;

import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

/** Passive metadata-only readiness gate. Never executes notification actions. */
public final class CaptureListener extends NotificationListenerService {
    private static volatile CaptureListener current;
    private final java.util.concurrent.atomic.AtomicLong contentGeneration = new java.util.concurrent.atomic.AtomicLong();
    private final java.util.concurrent.ThreadPoolExecutor contentWorker = new java.util.concurrent.ThreadPoolExecutor(1, 1, 0,
        java.util.concurrent.TimeUnit.SECONDS, new java.util.concurrent.ArrayBlockingQueue<>(1), new java.util.concurrent.ThreadPoolExecutor.DiscardOldestPolicy());
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
    @Override public void onDestroy() { contentGeneration.incrementAndGet(); contentWorker.shutdownNow(); disconnected(); super.onDestroy(); }
    @Override public void onNotificationPosted(StatusBarNotification item) {
        if (current != this || !CaptureState.enabled(this) || item == null || !NotificationReadiness.PACKAGE.equals(item.getPackageName())) return;
        NotificationReadiness.Report report = NotificationReadiness.inspect(item.getPackageName(), item::getNotification,
            true, CaptureState.access(this));
        CaptureState.record(this, report, "POSTED");
        // Group-summary updates must not cancel the individual preview queued just before them.
        if (!report.state.equals("SUMMARY_SKIPPED")) sampleContent(item, "POSTED");
    }
    private void sampleContent(StatusBarNotification item, String origin) {
        if (!NotificationContentStore.enabled(this) || !CaptureState.enabled(this) || !CaptureState.access(this)) return;
        long generation = contentGeneration.incrementAndGet(), revision = NotificationContentStore.revision(this);
        java.util.function.BooleanSupplier active = () -> current == this && contentGeneration.get() == generation
            && NotificationContentStore.revision(this) == revision && NotificationContentStore.enabled(this)
            && CaptureState.enabled(this) && CaptureState.access(this) && !Thread.currentThread().isInterrupted();
        try { contentWorker.execute(() -> {
            if (!active.getAsBoolean()) return;
            if (android.os.Build.VERSION.SDK_INT < 29) {
                NotificationContentStore.publish(this, new NotificationContent.Result("UNAVAILABLE", null), false, active); return;
            }
            try {
                NotificationContentStore.Identity identity = NotificationContentStore.identity(this);
                NotificationContent.Result result = NotificationContent.inspect(this, item.getPackageName(), item::getNotification,
                    true, true, identity.install, identity.secret, item.getUid(), origin, false);
                NotificationContentStore.publish(this, result, false, active);
            } catch (Exception failure) { NotificationContentStore.publish(this, new NotificationContent.Result("UNAVAILABLE", null), false, active); }
        }); } catch (java.util.concurrent.RejectedExecutionException stopped) { }
    }
    private void noContentCandidate(String state) {
        if (!NotificationContentStore.enabled(this)) return;
        contentGeneration.incrementAndGet();
        NotificationContentStore.publish(this, new NotificationContent.Result(state, null), false,
            () -> current == this && NotificationContentStore.enabled(this) && CaptureState.enabled(this) && CaptureState.access(this));
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
                    empty.state = "UNAVAILABLE"; CaptureState.record(this, empty, "STATE"); noContentCandidate("UNAVAILABLE"); return;
                }
                NotificationReadiness.Report report = NotificationReadiness.inspect(item.getPackageName(), item::getNotification, true, true);
                if (!report.state.equals("SUMMARY_SKIPPED")) {
                    CaptureState.record(this, report, "ACTIVE_SCAN"); sampleContent(item, "ACTIVE_SCAN"); return;
                }
            }
            if (inspected > 0) { empty.state = "SUMMARY_SKIPPED"; empty.summaries = 1; }
            CaptureState.record(this, empty, "ACTIVE_SCAN");
            noContentCandidate(inspected > 0 ? "SUMMARY_SKIPPED" : "NO_CONTENT");
        } catch (RuntimeException failure) { empty.state = "UNAVAILABLE"; CaptureState.record(this, empty, "STATE"); noContentCandidate("UNAVAILABLE"); }
    }
}

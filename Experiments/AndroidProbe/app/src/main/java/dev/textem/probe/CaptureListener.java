package dev.textem.probe;

import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

/** Passive metadata-only readiness gate. Never executes notification actions. */
public final class CaptureListener extends NotificationListenerService {
    private static volatile CaptureListener current;
    private final java.util.concurrent.atomic.AtomicLong contentGeneration = new java.util.concurrent.atomic.AtomicLong();
    private final java.util.concurrent.ThreadPoolExecutor contentWorker = new java.util.concurrent.ThreadPoolExecutor(1, 1, 0,
        java.util.concurrent.TimeUnit.SECONDS, new java.util.concurrent.ArrayBlockingQueue<>(32), new java.util.concurrent.ThreadPoolExecutor.AbortPolicy());
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
        if (!CaptureState.access(this)) {
            NotificationContentStore.clear(this); NotificationContentStore.status(this, "ACCESS_REQUIRED");
        }
        CaptureState.record(this, report, "STATE");
    }
    @Override public void onDestroy() { contentGeneration.incrementAndGet(); contentWorker.shutdownNow(); disconnected(); super.onDestroy(); }
    @Override public void onNotificationPosted(StatusBarNotification item) {
        if (current != this || !CaptureState.enabled(this) || item == null || !NotificationReadiness.PACKAGE.equals(item.getPackageName())) return;
        NotificationReadiness.Report report = NotificationReadiness.inspect(item.getPackageName(), item::getNotification,
            true, CaptureState.access(this));
        CaptureState.record(this, report, "POSTED");
        // Group-summary updates must not cancel the individual preview queued just before them.
        if (!report.state.equals("SUMMARY_SKIPPED")) {
            if (NotificationCandidates.hasSource(item)) sampleContent(item, "POSTED");
            else if (NotificationContentStore.enabled(this) && CaptureState.access(this)) {
                // Do not advance contentGeneration: a source-less event must not
                // discard a valid conversation already queued on the worker.
                NotificationContentStore.missingSource(this);
            }
        }
    }
    private void sampleContent(StatusBarNotification item, String origin) {
        if (!NotificationContentStore.enabled(this) || !CaptureState.enabled(this) || !CaptureState.access(this)) return;
        // Distinct sources must not cancel each other before reaching the journal.
        long generation = contentGeneration.get(), revision = NotificationContentStore.revision(this);
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
        }); } catch (java.util.concurrent.RejectedExecutionException stopped) { NotificationContentStore.status(this, "UNAVAILABLE"); }
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
            NotificationCandidates.Selection selection = NotificationCandidates.active(getActiveNotifications());
            CaptureState.record(this, selection.report, "ACTIVE_SCAN");
            if (selection.item != null) for (StatusBarNotification item : selection.content) sampleContent(item, "ACTIVE_SCAN");
            else noContentCandidate(selection.absentState);
        } catch (RuntimeException failure) { empty.state = "UNAVAILABLE"; CaptureState.record(this, empty, "STATE"); noContentCandidate("UNAVAILABLE"); }
    }
}

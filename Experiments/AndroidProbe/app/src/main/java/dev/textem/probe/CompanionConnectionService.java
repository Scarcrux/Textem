package dev.textem.probe;

import android.app.*;
import android.content.Intent;
import android.os.*;

/** Durable only after explicit Start. Stop/revocation/permission removal ends resume. */
public final class CompanionConnectionService extends Service {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final java.util.concurrent.ExecutorService worker = java.util.concurrent.Executors.newSingleThreadExecutor();
    private final java.util.concurrent.atomic.AtomicBoolean pending = new java.util.concurrent.atomic.AtomicBoolean();
    private static volatile String state = "Stopped. No local preview connection is running.";
    private volatile boolean stopped;
    private boolean started;
    private int pulse;
    private android.net.ConnectivityManager networks;
    static String state() { return state; }
    private boolean permissions() {
        return CaptureState.enabled(this) && CaptureState.access(this) && NotificationContentStore.enabled(this)
            && (Build.VERSION.SDK_INT < 33 || checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED);
    }
    private boolean mayResume() {
        return CompanionResume.allowed(this, CaptureState.enabled(this), CaptureState.access(this), NotificationContentStore.enabled(this),
            Build.VERSION.SDK_INT < 33 || checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED);
    }
    private final Runnable permissionCheck = new Runnable() { public void run() {
        if (!mayResume()) {
            CompanionResume.requested(CompanionConnectionService.this, false); stopSelf(); return;
        }
        if (++pulse % 5 == 0) reconcile();
        handler.postDelayed(this, 1000);
    }};
    private final android.net.ConnectivityManager.NetworkCallback networkCallback = new android.net.ConnectivityManager.NetworkCallback() {
        @Override public void onAvailable(android.net.Network network) { reconcile(); }
        @Override public void onLost(android.net.Network network) { reconcile(); }
        @Override public void onLinkPropertiesChanged(android.net.Network network, android.net.LinkProperties properties) { reconcile(); }
    };
    private void reconcile() {
        if (stopped || !pending.compareAndSet(false, true)) return;
        try { worker.execute(() -> {
            try {
                synchronized (CompanionConnectionService.this) {
                    if (stopped || !mayResume()) return;
                    try { CompanionServer.localAddress(this); }
                    catch (Exception unavailable) {
                        CompanionServer.stop(false, this);
                        state = "Waiting for private Wi-Fi. Credentials are retained; the connection will retry. VPN-only, cellular and public addresses are not used.";
                        return;
                    }
                    try {
                        CompanionServer.reconcile(this);
                        state = "Running on private Wi-Fi. The paired Mac can reconnect without a new connection file. Stop disables automatic resume.";
                    } catch (Exception unavailable) {
                        state = "Couldn’t restore the encrypted phone connection. Saved credentials are retained; retrying. Stop and retry Start if this persists.";
                    }
                }
            } finally { pending.set(false); }
        }); } catch (java.util.concurrent.RejectedExecutionException closing) { pending.set(false); }
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        String action = intent == null ? "RESUME" : intent.getAction();
        if ("STOP".equals(action)) { CompanionResume.requested(this, false); stopSelf(); return START_NOT_STICKY; }
        if (!("START".equals(action) || "RESUME".equals(action))) { stopSelf(); return START_NOT_STICKY; }
        if (("START".equals(action) && !permissions()) || (!"START".equals(action) && !mayResume())) {
            CompanionResume.requested(this, false);
            state = "Stopped. Enable checks, notification access, local content samples and running notifications first.";
            stopSelf(); return START_NOT_STICKY;
        }
        if (started) return START_STICKY;
        if (!CompanionResume.requested(this, true)) { state = "Couldn’t save connection start preference."; stopSelf(); return START_NOT_STICKY; }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("phone-connection", "Phone preview connection", NotificationManager.IMPORTANCE_LOW));
        PendingIntent stopAction = PendingIntent.getService(this, 0, new Intent(this, CompanionConnectionService.class).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, CaptureSetupActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(this, "phone-connection").setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Textem phone connection").setContentText("Paired Macs can read captured previews on private Wi-Fi. Tap Stop to disable resume.")
            .setContentIntent(open).setOngoing(true).setVisibility(Notification.VISIBILITY_SECRET)
            .addAction(new Notification.Action.Builder(null, "Stop", stopAction).build()).build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(213, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(213, notification);
        started = true; state = "Starting encrypted local connection…";
        networks = getSystemService(android.net.ConnectivityManager.class);
        try { networks.registerDefaultNetworkCallback(networkCallback); } catch (RuntimeException unavailable) { /* The bounded lifecycle pulse also reconciles. */ }
        reconcile(); handler.removeCallbacks(permissionCheck); handler.post(permissionCheck);
        return START_STICKY;
    }
    @Override public void onDestroy() {
        synchronized (this) { stopped = true; CompanionServer.stop(false, this); }
        handler.removeCallbacksAndMessages(null); worker.shutdownNow();
        if (networks != null) try { networks.unregisterNetworkCallback(networkCallback); } catch (RuntimeException ignored) { }
        state = CompanionResume.enabled(this) ? "Connection interrupted. Android may resume the owner-started service." : "Stopped. Automatic resume disabled; saved credentials are retained.";
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}

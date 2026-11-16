package dev.textem.probe;

import android.app.*;
import android.content.Intent;
import android.os.*;

/** Owner-started connected-device service. No boot receiver or automatic start. */
public final class CompanionConnectionService extends Service {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private static volatile String state = "Stopped. No local preview connection is running.";
    private volatile boolean stopped;
    private boolean started;
    static String state() { return state; }
    private final Runnable permissionCheck = new Runnable() { public void run() {
        if (!CaptureState.enabled(CompanionConnectionService.this) || !CaptureState.access(CompanionConnectionService.this)
                || !NotificationContentStore.enabled(CompanionConnectionService.this)) { stopSelf(); return; }
        handler.postDelayed(this, 1000);
    }};
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent == null || !"START".equals(intent.getAction())) { stopSelf(); return START_NOT_STICKY; }
        if (started) return START_NOT_STICKY;
        if (!CaptureState.enabled(this) || !CaptureState.access(this) || !NotificationContentStore.enabled(this)) {
            state = "Enable checks, Android notification access and local content samples first."; stopSelf(); return START_NOT_STICKY;
        }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("phone-connection", "Phone preview connection", NotificationManager.IMPORTANCE_LOW));
        Intent stop = new Intent(this, CompanionConnectionService.class).setAction("STOP");
        PendingIntent stopAction = PendingIntent.getService(this, 0, stop, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Intent setup = new Intent(this, CaptureSetupActivity.class);
        PendingIntent open = PendingIntent.getActivity(this, 0, setup, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(this, "phone-connection").setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Textem phone connection").setContentText("Paired Macs can read captured previews on your private network.")
            .setContentIntent(open).setOngoing(true).setVisibility(Notification.VISIBILITY_SECRET)
            .addAction(new Notification.Action.Builder(null, "Stop", stopAction).build()).build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(213, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(213, notification);
        started = true;
        state = "Starting encrypted local connection…";
        new Thread(() -> {
            try {
                synchronized (CompanionConnectionService.this) {
                    if (stopped) return;
                    CompanionServer.start(this);
                    state = "Running on your private network. Export the connection file for your Mac. Stop ends access; revoke invalidates previously exported files.";
                }
            } catch (Exception failure) {
                state = "Couldn’t start. Enable capture and content samples, connect to one private network, then retry.";
                handler.post(this::stopSelf);
            }
        }, "textem-connection-start").start();
        handler.removeCallbacks(permissionCheck); handler.post(permissionCheck);
        return START_NOT_STICKY;
    }
    @Override public void onDestroy() {
        synchronized (this) { stopped = true; CompanionServer.stop(false, this); }
        handler.removeCallbacksAndMessages(null);
        if (state.startsWith("Running") || state.startsWith("Starting")) state = "Stopped. Saved connection credentials are retained; start again to reconnect.";
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}

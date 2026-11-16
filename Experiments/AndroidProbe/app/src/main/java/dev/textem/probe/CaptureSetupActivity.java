package dev.textem.probe;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.provider.Settings;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** Opens Android's access screen; never approves access on the user's behalf. */
@SuppressLint("SetTextI18n")
public final class CaptureSetupActivity extends Activity {
    private final Handler handler = new Handler(android.os.Looper.getMainLooper());
    private TextView status;
    private TextView companionStatus;
    private TextView connectionStatus;
    private String connectionNotice = "";
    private long connectionNoticeUntil;
    private void connectionNotice(String value) {
        connectionNotice = value; connectionNoticeUntil = android.os.SystemClock.elapsedRealtime() + 15000; refresh();
    }
    CompanionLink companion;
    private final Runnable update = new Runnable() { public void run() { refresh(); handler.postDelayed(this, 1000); } };
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        ScrollView scroll = new ScrollView(this); LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL); root.setPadding(24, 90, 24, 90); scroll.addView(root); setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            int top, bottom;
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(android.view.WindowInsets.Type.systemBars());
                top = bars.top; bottom = bars.bottom;
            } else { top = insets.getSystemWindowInsetTop(); bottom = insets.getSystemWindowInsetBottom(); }
            root.setPadding(24, top + 24, 24, bottom + 24); return insets;
        });
        label(root, "Textem · Automatic recovery setup", 24);
        label(root, "This readiness check counts what Google Messages notifications expose: text, picture objects and attachment addresses. It does NOT save message text, graphics, addresses or titles. Full automatic sync is not enabled yet.", 17);
        label(root, "Android notification access is broad and can expose notifications from all apps. Textem ignores other packages before examining their payload. Only Google Messages shapes are inspected. The optional local connection sends captured previews only to a Mac holding its connection file, over encrypted private-network HTTPS. No message sending, notification dismissal, mark-read, Accessibility or default messaging changes.", 16);
        status = label(root, "", 16); status.setTag("capture-status");
        companion = new CompanionLink(this);
        label(root, "Verification-code access", 20);
        label(root, "Android can hide verification codes even when notification access is on. Open Bluetooth settings on your Mac to make it discoverable, then select that Mac in Android's device chooser. Choose only your actual Mac. Android controls approval; Textem cannot approve it for you. The association does not start message transfer or prove code recovery. Existing capture controls still apply.", 16);
        companionStatus = label(root, "", 16); companionStatus.setTag("companion-status");
        button(root, "Link Textem Mac (Android approval)", "companion-link", () -> companion.request(approval -> {
            try { startIntentSenderForResult(approval, 42, null, 0, 0, 0); }
            catch (android.content.IntentSender.SendIntentException failure) { throw new IllegalStateException(); }
        }, this::refresh));
        button(root, "Remove Textem Mac companion link", "companion-remove", () -> companion.remove(this::refresh));
        button(root, "Enable checks and open Android access settings", "capture-enable", () -> {
            CaptureState.enabled(this, true);
            NotificationReadiness.Report report = new NotificationReadiness.Report();
            report.state = !CaptureState.access(this) ? "ACCESS_REQUIRED" : CaptureListener.connected() ? "LISTENING" : "WAITING_FOR_LISTENER";
            CaptureState.record(this, report, "STATE");
            try {
                Intent settings = android.os.Build.VERSION.SDK_INT >= 30
                    ? new Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, CaptureState.component(this).flattenToString())
                    : new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
                startActivity(settings);
            } catch (RuntimeException unavailable) { status.setText("Open Settings → Notification access → Textem automatic recovery. Android approval must be yours."); }
        });
        button(root, "Refresh current Google Messages sample", "capture-refresh", () -> { CaptureListener.sampleCurrent(); refresh(); });
        button(root, "Disable checks", "capture-disable", () -> {
            CaptureState.enabled(this, false); NotificationReadiness.Report report = new NotificationReadiness.Report(); report.state = "OFF";
            CaptureState.record(this, report, "STATE"); refresh();
        });
        button(root, "Clear readiness diagnostics", "capture-clear", () -> { CaptureState.clear(this); refresh(); });
        label(root, "Optional local content previews: saves the latest Google notification sample and a bounded journal (up to four snapshots per source, 32 total, 8 MiB, seven days). Each sample has up to ten text previews and one available picture. Disable clears the journal; Delete also clears the latest sample. Granted private Google image URIs may be copied with byte, size and time limits; other references remain unavailable. Mac thread links require explicit confirmation. No full cards/history or uploads.", 16);
        button(root, "Enable local content samples", "content-enable", () -> {
            if (!CaptureState.enabled(this) || !CaptureState.access(this)) {
                status.setText("Enable readiness checks and approve Android notification access first."); return;
            }
            NotificationContentStore.enabled(this, true); CaptureListener.sampleCurrent(); refresh();
        });
        button(root, "Disable content samples (clear journal, keep latest)", "content-disable", () -> {
            NotificationContentStore.enabled(this, false); NotificationContentStore.status(this, "OFF"); refresh();
        });
        button(root, "Delete saved notification content", "content-clear", () -> { NotificationContentStore.clear(this); refresh(); });
        label(root, "Local Mac connection", 20);
        label(root, "Start this connection to read captured previews on your Mac without USB or Android debugging. Both devices must share private Wi-Fi. Start also enables resume after Android service interruption, phone restart and app updates, until you tap Stop or revoke access. The running notification has a Stop control. The Mac rediscovers the same pinned phone after network address changes. Android Force Stop still requires you to start again. This is partial notification content, not full conversation history.", 16);
        connectionStatus = label(root, "", 16); connectionStatus.setTag("connection-status");
        button(root, "Start local connection", "connection-start", () -> {
            if (!CaptureState.enabled(this) || !CaptureState.access(this) || !NotificationContentStore.enabled(this)) {
                connectionNotice("Enable checks, notification access and local content samples first."); return;
            }
            if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 44);
                connectionNotice("Allow the connection’s running/stop notification, then tap Start again. No connection has started."); return;
            }
            try { startForegroundService(new Intent(this, CompanionConnectionService.class).setAction("START")); }
            catch (RuntimeException unavailable) { connectionNotice("Android could not start the connection. Keep this screen open and try again."); }
        });
        button(root, "Export private connection file…", "connection-export", () -> {
            try {
                CompanionServer.pairing();
                Intent export = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, "Textem-phone.textempair");
                startActivityForResult(export, 43);
            } catch (Exception unavailable) { connectionNotice("Start the connection before exporting. Keep the file private: it grants preview access."); }
        });
        label(root, "The connection file is a secret. Transfer it privately to your Mac, import it under Phone connection in the preview pane, then delete the transferred copy. Anyone with this file and local-network access can read captured previews until you revoke it.", 16);
        button(root, "Stop local connection", "connection-stop", () -> {
            CompanionResume.requested(this, false);
            stopService(new Intent(this, CompanionConnectionService.class)); CompanionServer.stop(false, this); refresh();
        });
        button(root, "Revoke exported connection files", "connection-revoke", () -> {
            CompanionResume.requested(this, false);
            stopService(new Intent(this, CompanionConnectionService.class));
            connectionNotice(CompanionServer.stop(true, this) ? "Stopped and revoked. Previously exported files no longer authorize access." : "Stopped, but credential deletion could not be verified. Retry Revoke before restarting.");
        });
        button(root, "Back", "capture-back", this::finish);
        // Status must be meaningful before the first lifecycle/handler pulse.
        refresh();
    }
    private TextView label(LinearLayout root, String value, int size) {
        TextView text = new TextView(this); text.setText(value); text.setTextSize(size); text.setPadding(0, 8, 0, 20); root.addView(text); return text;
    }
    private void button(LinearLayout root, String title, String tag, Runnable action) {
        Button button = new Button(this); button.setText(title); button.setAllCaps(false); button.setTag(tag);
        button.setOnClickListener(v -> action.run()); root.addView(button);
    }
    void refresh() {
        String state = !CaptureState.enabled(this) ? "OFF" : !CaptureState.access(this) ? "ACCESS REQUIRED — approve on Android" : CaptureListener.connected() ? "CONNECTED" : "WAITING FOR ANDROID";
        String sample = "No current readiness sample.";
        try {
            org.json.JSONObject j = CaptureState.read(this);
            sample = "Last sample: " + j.getString("state") + " / " + j.getString("origin")
                + "\nText values: " + j.getInt("text_values") + "; bitmap pictures/icons: " + j.getInt("bitmap_pictures") + "/" + j.getInt("bitmap_picture_icons")
                + "; attachment URIs: " + j.getInt("uri_attachments")
                + "\nCounts only; full content recovery remains unproven.";
        } catch (Exception absent) { }
        String content = NotificationContentStore.enabled(this) ? "ON" : "OFF";
        try { content += " / last attempt: " + NotificationContentStore.read(this, NotificationContentStore.STATE, 4096).getString("state"); }
        catch (Exception absent) { }
        if (content.endsWith("REDACTED")) content += " — Android hid sensitive notification content; no code was recovered.";
        status.setText("Checks: " + state + "\n" + sample + "\nLocal content samples: " + content);
        if (connectionStatus != null) connectionStatus.setText(CompanionConnectionService.state()
            + (android.os.SystemClock.elapsedRealtime() < connectionNoticeUntil ? "\n" + connectionNotice : ""));
        if (companionStatus != null) {
            CompanionLink.State link = companion.state();
            companionStatus.setText(switch (link) {
                case LINKED -> "Android companion association: approved. Fresh verification-code recovery has not been verified. If Android still hides codes, reopen Textem notification access to refresh its listener.";
                case WAITING_FOR_APPROVAL -> "Android companion association: waiting for your approval. No approved link is claimed.";
                case NOT_LINKED -> "Android companion association: not linked. Codes may be hidden.";
                case UNSUPPORTED -> "Android companion association requires Android 13 or newer and companion-device setup support.";
                case UNAVAILABLE -> "Android companion association could not be verified. Retry the link; no code access is claimed.";
            });
        }
    }
    @Override protected void onResume() { super.onResume(); refresh(); handler.postDelayed(update, 1000); }
    @Override protected void onPause() { handler.removeCallbacksAndMessages(null); super.onPause(); }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != 43 || result != RESULT_OK || data == null || data.getData() == null) return;
        try (java.io.OutputStream out = getContentResolver().openOutputStream(data.getData(), "wt")) {
            if (out == null) throw new java.io.IOException();
            out.write(CompanionServer.pairing().toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)); out.flush();
            connectionNotice("Private connection file exported. Import it only on your Mac, then delete the transferred copy.");
        } catch (Exception failure) { connectionNotice("Connection export failed. No successful export is claimed."); }
    }
}

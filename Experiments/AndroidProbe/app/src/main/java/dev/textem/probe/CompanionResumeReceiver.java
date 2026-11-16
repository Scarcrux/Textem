package dev.textem.probe;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** System lifecycle only; never infer consent from a token or companion association. */
public final class CompanionResumeReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !(Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction()) || Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction()))) return;
        if (!CompanionResume.enabled(context)) return;
        boolean notifications = android.os.Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED;
        if (!CompanionResume.allowed(context, CaptureState.enabled(context), CaptureState.access(context), NotificationContentStore.enabled(context), notifications)) {
            CompanionResume.requested(context, false); return;
        }
        try { context.startForegroundService(new Intent(context, CompanionConnectionService.class).setAction("RESUME")); }
        catch (RuntimeException denied) { /* OS refusal never causes a permission/role workaround. */ }
    }
}

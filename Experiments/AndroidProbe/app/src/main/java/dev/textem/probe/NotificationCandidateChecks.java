package dev.textem.probe;

import android.app.Notification;
import android.content.Context;
import android.os.Process;
import android.service.notification.StatusBarNotification;

/** Real framework notifications through the production selector, synthetic only. */
final class NotificationCandidateChecks {
    static StatusBarNotification item(Context c, String shortcut, int uid, long time, String pkg, boolean summary) {
        Notification n = new Notification.Builder(c, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentText("Synthetic preview").setShortcutId(shortcut).build();
        if (summary) n.flags |= Notification.FLAG_GROUP_SUMMARY;
        return new StatusBarNotification(pkg, pkg, 1, "SYNTHETIC", uid, 0, 0, n, Process.myUserHandle(), time);
    }
    static void run(ProbeAutomation i) {
        i.phase("source-less first event does not hide the usable conversation in active scan");
        Context c = i.getTargetContext(); String pkg = NotificationReadiness.PACKAGE;
        StatusBarNotification missing = item(c, null, 0, 100, pkg, false);
        StatusBarNotification good = item(c, "SYNTHETIC_THREAD", 0, 10, pkg, false);
        StatusBarNotification newer = item(c, "SYNTHETIC_OTHER_THREAD", 0, 20, pkg, false);
        if (android.os.Build.VERSION.SDK_INT < 29) { i.check(!NotificationCandidates.hasSource(good)); return; }
        i.check(!NotificationCandidates.hasSource(missing) && NotificationCandidates.hasSource(good));
        i.check(NotificationCandidates.active(new StatusBarNotification[] {missing, good}).item == good);
        i.check(NotificationCandidates.active(new StatusBarNotification[] {good, missing}).item == good);
        i.check(NotificationCandidates.active(new StatusBarNotification[] {good, missing, newer}).item == newer);
        NotificationCandidates.Selection failed = NotificationCandidates.active(new StatusBarNotification[] {missing});
        i.check(failed.item == null && failed.absentState.equals("SOURCE_REQUIRED"));
        StatusBarNotification summary = item(c, "SYNTHETIC_THREAD", 0, 200, pkg, true);
        i.check(!NotificationCandidates.hasSource(summary));
        i.check(NotificationCandidates.active(new StatusBarNotification[] {summary, good}).item == good);
        i.check(NotificationCandidates.active(new StatusBarNotification[] {summary}).absentState.equals("SUMMARY_SKIPPED"));
        StatusBarNotification foreign = item(c, "SYNTHETIC_THREAD", 0, 300, "other.example", false);
        i.check(!NotificationCandidates.hasSource(foreign));
        i.check(NotificationCandidates.active(new StatusBarNotification[] {foreign, good}).item == good);
        i.check(!NotificationCandidates.hasSource(item(c, "SYNTHETIC_THREAD", -1, 300, pkg, false)));
        i.check(!NotificationCandidates.hasSource(item(c, new String(new char[1025]).replace('\0', 'x'), 0, 300, pkg, false)));
        i.check(NotificationCandidates.active(null).absentState.equals("NO_CONTENT"));
        StatusBarNotification[] capped = new StatusBarNotification[21]; java.util.Arrays.fill(capped, missing); capped[0] = good;
        NotificationCandidates.Selection limit = NotificationCandidates.active(capped);
        i.check(limit.item == null && limit.absentState.equals("UNAVAILABLE"));
        i.check(NotificationCandidates.active(java.util.Arrays.copyOf(capped, 20)).item == good);
    }
}

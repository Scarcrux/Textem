package dev.textem.probe;

import android.Manifest;
import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;
import android.widget.TextView;
import java.util.Arrays;

/** Dependency-free instrumented controls, run only in an explicitly selected emulator. */
public final class ProbeInstrumentation extends Instrumentation {
    private int checks;
    private String current = "startup";
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    private void check(boolean condition) {
        checks++;
        if (!condition) throw new AssertionError(current);
    }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            current = "positive text/link/real image via production scanner";
            FixtureSource good = new FixtureSource();
            ProbeEngine.Report report = ProbeEngine.scan(good, 41);
            check(report.sms == ProbeEngine.State.OK && report.mms == ProbeEngine.State.OK);
            check(report.smsRows == 1 && report.mmsRows == 1 && report.textMessages == 2);
            check(report.links == 1 && report.readableImages == 1);
            check(good.queries == 3 && good.imageReads == 1 && good.lastThread == 41);

            current = "successful empty control differs from denied, unavailable and error";
            FixtureSource zero = new FixtureSource(); zero.empty = true;
            ProbeEngine.Report empty = ProbeEngine.scan(zero, 7);
            check(empty.messages.isEmpty() && empty.sms == ProbeEngine.State.OK);
            FixtureSource denied = new FixtureSource(); denied.denied = true;
            ProbeEngine.Report blocked = ProbeEngine.scan(denied, 7);
            check(blocked.messages.isEmpty() && blocked.sms == ProbeEngine.State.BLOCKED
                && blocked.mms == ProbeEngine.State.BLOCKED);
            check(ProbeEngine.index(denied).state == ProbeEngine.State.BLOCKED);
            FixtureSource missing = new FixtureSource(); missing.unavailable = true;
            ProbeEngine.Report unavailable = ProbeEngine.scan(missing, 7);
            check(unavailable.sms == ProbeEngine.State.UNAVAILABLE && unavailable.mms == ProbeEngine.State.UNAVAILABLE);
            FixtureSource broken = new FixtureSource(); broken.queryError = true;
            check(ProbeEngine.scan(broken, 7).sms == ProbeEngine.State.ERROR);
            check(ProbeEngine.index(broken).state == ProbeEngine.State.ERROR);
            check(ProbeEngine.index(missing).state == ProbeEngine.State.UNAVAILABLE);
            check(ProbeEngine.index(zero).threads.isEmpty() && ProbeEngine.index(zero).state == ProbeEngine.State.OK);

            current = "unreadable, denied and oversized images never count as recovered";
            FixtureSource corrupt = new FixtureSource(); corrupt.brokenImage = true;
            ProbeEngine.Report corruptReport = ProbeEngine.scan(corrupt, 7);
            check(corruptReport.readableImages == 0 && corruptReport.unreadableImages == 1);
            FixtureSource locked = new FixtureSource(); locked.deniedImage = true;
            ProbeEngine.Report lockedReport = ProbeEngine.scan(locked, 7);
            check(lockedReport.readableImages == 0 && lockedReport.unreadableImages == 1);
            FixtureSource oversized = new FixtureSource(); oversized.oversizedImage = true;
            ProbeEngine.Report large = ProbeEngine.scan(oversized, 7);
            check(large.readableImages == 0 && large.oversizedImages == 1 && large.limited);
            FixtureSource partsDenied = new FixtureSource(); partsDenied.deniedTable = ProbeEngine.Table.PARTS;
            ProbeEngine.Report parts = ProbeEngine.scan(partsDenied, 7);
            check(parts.partFailures == 1 && parts.readableImages == 0);

            current = "bounded rows, text, index, parts and image reads";
            FixtureSource many = new FixtureSource(); many.smsCount = 25; many.imageCount = 40;
            many.threadCount = 60;
            char[] longText = new char[ProbeEngine.TEXT_LIMIT + 5]; Arrays.fill(longText, 'x');
            many.body = new String(longText);
            ProbeEngine.Report capped = ProbeEngine.scan(many, 7);
            check(capped.smsRows == 20 && capped.limited);
            check(capped.messages.get(0).text.length() <= ProbeEngine.TEXT_LIMIT);
            check(capped.imageParts == 31 && capped.skippedImages == 28 && many.imageReads == 3);
            ProbeEngine.Index index = ProbeEngine.index(many);
            check(index.threads.size() == 50 && index.limited);
            boolean rejected = false;
            try { ProbeEngine.scan(good, -1); } catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected);

            current = "production query specs bind only the selected numeric thread";
            for (ProbeEngine.Table table : new ProbeEngine.Table[] {ProbeEngine.Table.SMS, ProbeEngine.Table.MMS}) {
                ProviderSource.Query query = ProviderSource.spec(table, 41);
                check("thread_id = ?".equals(query.selection) && Arrays.equals(query.args, new String[] {"41"}));
                check("date DESC".equals(query.order));
            }
            check(ProviderSource.spec(ProbeEngine.Table.PARTS, 123).uri.toString().equals("content://mms/123/part"));

            current = "summary excludes payload, source identifiers and addresses";
            FixtureSource secret = new FixtureSource();
            secret.body = "PRIVATE_MESSAGE_SENTINEL https://example.invalid/PRIVATE_PATH";
            String summary = ProbeEngine.scan(secret, 999991).summary();
            check(!summary.contains("PRIVATE") && !summary.contains("example.invalid") && !summary.contains("999991"));
            check(summary.contains("web links: 1") && summary.contains("not a complete RCS history"));

            current = "APK manifest has only read permission and no services/providers";
            PackageManager pm = getTargetContext().getPackageManager();
            PackageInfo info = pm.getPackageInfo(getTargetContext().getPackageName(),
                PackageManager.GET_PERMISSIONS | PackageManager.GET_SERVICES | PackageManager.GET_PROVIDERS);
            check(Arrays.equals(info.requestedPermissions, new String[] {Manifest.permission.READ_SMS}));
            check(info.services == null && info.providers == null);
            check((info.applicationInfo.flags & android.content.pm.ApplicationInfo.FLAG_ALLOW_BACKUP) == 0);
            check((info.applicationInfo.flags & android.content.pm.ApplicationInfo.FLAG_USES_CLEARTEXT_TRAFFIC) == 0);

            current = "real provider denies before any query when SMS permission is absent";
            check(getTargetContext().checkSelfPermission(Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED);
            ProviderSource real = new ProviderSource(getTargetContext());
            check(ProbeEngine.index(real).state == ProbeEngine.State.BLOCKED);
            check(ProbeEngine.scan(real, 7).sms == ProbeEngine.State.BLOCKED);

            current = "actual Activity: blocked home and synthetic controls UI";
            Intent intent = new Intent(getTargetContext(), ProbeActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ProbeActivity activity = (ProbeActivity) startActivitySync(intent);
            runOnMainSync(() -> {
                check((activity.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_SECURE) != 0);
                View root = activity.findViewById(android.R.id.content);
                check(((TextView) root.findViewWithTag("status")).getText().toString().startsWith("BLOCKED:"));
                root.findViewWithTag("controls").performClick();
            });
            check(activity.awaitIdle());
            runOnMainSync(() -> {
                View root = activity.findViewById(android.R.id.content);
                String text = ((TextView) root.findViewWithTag("status")).getText().toString();
                check(text.startsWith("PASS:") && text.contains("decodable: 1"));
                root.findViewWithTag("home").performClick();
                check(((TextView) root.findViewWithTag("status")).getText().toString().startsWith("BLOCKED:"));
                activity.finish();
            });
            result.putString("stream", "PASS: " + checks + " assertions; production pipeline controls and actual UI; no phone reads.\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            // Fixed test-case label, never arbitrary exception/provider strings.
            result.putString("stream", "FAIL after " + checks + " assertions: " + current + "\n");
            finish(Activity.RESULT_CANCELED, result);
        }
    }
}

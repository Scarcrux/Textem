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
import android.widget.EditText;
import android.widget.LinearLayout;
import java.util.Arrays;

/** ADB-invoked fixture/UI tests: never query message providers if SMS is granted. */
@android.annotation.SuppressLint("SetTextI18n") // Deliberate synthetic filter inputs, not translatable UI.
public class ProbeAutomation extends Instrumentation {
    private int checks;
    private String current = "startup";
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    protected boolean requireDeniedPermission() { return false; }
    void check(boolean condition) {
        checks++;
        if (!condition) throw new AssertionError(current);
    }
    void phase(String name) {
        current = name;
        Bundle progress = new Bundle(); progress.putString("phase", name);
        sendStatus(1, progress);
    }
    private ProbeActivity launch(Intent intent) throws Exception {
        java.util.concurrent.ExecutorService launcher = java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            return launcher.submit(() -> (ProbeActivity) startActivitySync(intent))
                .get(15, java.util.concurrent.TimeUnit.SECONDS);
        } finally { launcher.shutdownNow(); }
    }
    @Override public void onStart() {
        Bundle result = new Bundle();
        int privateQueriesBefore = ProviderSource.queryAttempts();
        int privateMediaBefore = ProviderSource.mediaAttempts();
        try {
            phase("positive text/link/real image via production scanner");
            FixtureSource good = new FixtureSource();
            ProbeEngine.Report report = ProbeEngine.scan(good, 41);
            check(report.sms == ProbeEngine.State.OK && report.mms == ProbeEngine.State.OK);
            check(report.smsRows == 1 && report.mmsRows == 1 && report.textMessages == 2);
            check(report.links == 1 && report.readableImages == 1);
            check(good.queries == 3 && good.imageReads == 1 && good.lastThread == 41);

            phase("successful empty control differs from denied, unavailable and error");
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

            phase("unreadable, denied and oversized images never count as recovered");
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

            phase("bounded rows, text, index, parts and image reads");
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
            check(many.addressQueries == 50);
            boolean rejected = false;
            try { ProbeEngine.scan(good, -1); } catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected);

            phase("production query specs bind only the selected numeric thread");
            for (ProbeEngine.Table table : new ProbeEngine.Table[] {ProbeEngine.Table.SMS, ProbeEngine.Table.MMS}) {
                ProviderSource.Query query = ProviderSource.spec(table, 41);
                check("thread_id = ?".equals(query.selection) && Arrays.equals(query.args, new String[] {"41"}));
                check("date DESC".equals(query.order));
            }
            check(ProviderSource.spec(ProbeEngine.Table.PARTS, 123).uri.toString().equals("content://mms/123/part"));
            ProviderSource.Query threadQuery = ProviderSource.spec(ProbeEngine.Table.THREADS, 0);
            check(Arrays.asList(threadQuery.columns).containsAll(Arrays.asList("recipient_ids", "date")));
            ProviderSource.Query addressQuery = ProviderSource.spec(ProbeEngine.Table.ADDRESS, 11);
            check(addressQuery.uri.toString().equals("content://mms-sms/canonical-address/11")
                && Arrays.equals(addressQuery.columns, new String[] {"address"}));
            rejected = false;
            try { ProviderSource.spec(ProbeEngine.Table.ADDRESS, -1); }
            catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected);

            phase("participant labels, optional-metadata failures, caps and local filtering");
            FixtureSource labelled = new FixtureSource(); labelled.address = "Caf\u00e9 offers";
            ProbeEngine.ThreadEntry entry = ProbeEngine.index(labelled).threads.get(0);
            check(entry.participants.equals("Caf\u00e9 offers") && entry.time == 1_700_000_000_000L);
            check(entry.preview.equals("Synthetic example preview") && entry.matches("CAFE"));
            int indexedQueries = labelled.queries;
            check(entry.matches("EXAMPLE PREVIEW") && !entry.matches("no-such-synthetic-match"));
            check(labelled.queries == indexedQueries);
            for (int failure = 0; failure < 6; failure++) {
                FixtureSource fallback = new FixtureSource();
                if (failure == 0) fallback.missingAddress = true;
                if (failure == 1) fallback.emptyAddress = true;
                if (failure == 2) fallback.deniedTable = ProbeEngine.Table.ADDRESS;
                if (failure == 3) fallback.recipientIds = "-1 ../22 0 9999999999999999999";
                if (failure == 4) fallback.recipientIds = "";
                if (failure == 5) fallback.brokenAddress = true;
                ProbeEngine.Index fallbackIndex = ProbeEngine.index(fallback);
                check(fallbackIndex.state == ProbeEngine.State.OK && fallbackIndex.threads.size() == 1
                    && fallbackIndex.threads.get(0).participants.equals("Participants unavailable"));
                if (failure == 3 || failure == 4) check(fallback.addressQueries == 0);
            }
            FixtureSource group = new FixtureSource();
            group.recipientIds = "11 12 13 14 15 16 17 18 19 20";
            char[] longAddress = new char[ProbeEngine.ADDRESS_LIMIT + 100]; Arrays.fill(longAddress, 'x');
            group.address = new String(longAddress);
            ProbeEngine.ThreadEntry groupEntry = ProbeEngine.index(group).threads.get(0);
            check(group.addressQueries == ProbeEngine.PARTICIPANT_LIMIT);
            check(groupEntry.participants.startsWith(new String(longAddress, 0, ProbeEngine.ADDRESS_LIMIT)
                + " \u00b7 more/unavailable"));
            FixtureSource partial = new FixtureSource(); partial.recipientIds = "11 invalid";
            check(ProbeEngine.index(partial).threads.get(0).participants.contains("more/unavailable"));

            phase("summary excludes payload, source identifiers and addresses");
            FixtureSource secret = new FixtureSource();
            secret.body = "PRIVATE_MESSAGE_SENTINEL https://example.invalid/PRIVATE_PATH";
            String summary = ProbeEngine.scan(secret, 999991).summary();
            check(!summary.contains("PRIVATE") && !summary.contains("example.invalid") && !summary.contains("999991"));
            check(summary.contains("web links: 1") && summary.contains("not a complete RCS history"));

            phase("APK manifest keeps read permission and only a system-bound notification listener");
            PackageManager pm = getTargetContext().getPackageManager();
            PackageInfo info = pm.getPackageInfo(getTargetContext().getPackageName(),
                PackageManager.GET_PERMISSIONS | PackageManager.GET_SERVICES | PackageManager.GET_PROVIDERS);
            check(Arrays.equals(info.requestedPermissions, new String[] {Manifest.permission.READ_SMS}));
            check(info.services != null && info.services.length == 1 && info.providers == null);
            check(info.services[0].name.equals("dev.textem.probe.CaptureListener") && !info.services[0].exported
                && "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE".equals(info.services[0].permission));
            check((info.applicationInfo.flags & android.content.pm.ApplicationInfo.FLAG_ALLOW_BACKUP) == 0);
            check((info.applicationInfo.flags & android.content.pm.ApplicationInfo.FLAG_USES_CLEARTEXT_TRAFFIC) == 0);

            phase("permission-aware guard; no provider reads with existing grant");
            final boolean granted = getTargetContext().checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED;
            if (requireDeniedPermission()) check(!granted);
            if (!granted) {
                ProviderSource real = new ProviderSource(getTargetContext());
                check(ProbeEngine.index(real).state == ProbeEngine.State.BLOCKED);
                check(ProbeEngine.scan(real, 7).sms == ProbeEngine.State.BLOCKED);
            }

            phase("fixed-field metadata writer excludes content and enforces bounds");
            ProbeEngine.Report privateReport = ProbeEngine.scan(secret, 999991);
            check(ProbeDiagnostics.record(getTargetContext(), ProbeDiagnostics.Kind.SYNTHETIC, privateReport));
            org.json.JSONObject metadata = ProbeDiagnostics.read(getTargetContext());
            check(metadata.getString("kind").equals("SYNTHETIC") && metadata.getInt("links") == 1);
            check(!metadata.toString().contains("PRIVATE") && !metadata.toString().contains("999991"));
            check(metadata.length() == ProbeDiagnostics.KEY_COUNT);
            check((android.system.Os.stat(new java.io.File(getTargetContext().getFilesDir(),
                "probe-summary.json").getPath()).st_mode & 0777) == 0600);
            ProbeEngine.Report invalid = new ProbeEngine.Report(); invalid.smsRows = -1;
            check(!ProbeDiagnostics.record(getTargetContext(), ProbeDiagnostics.Kind.SELECTED_HISTORY, invalid));
            check(!ProbeDiagnostics.exists(getTargetContext()));
            ProbeDiagnostics.clear(getTargetContext());
            check(!ProbeDiagnostics.exists(getTargetContext()));

            phase("actual Activity: permission-aware home, controls, readback and clear");
            Intent intent = new Intent(getTargetContext(), ProbeActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ProbeActivity activity = launch(intent);
            runOnMainSync(() -> {
                check((activity.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_SECURE) != 0);
                View root = activity.findViewById(android.R.id.content);
                check(((TextView) root.findViewWithTag("status")).getText().toString()
                    .startsWith(granted ? "SMS permission granted" : "BLOCKED:"));
                root.findViewWithTag("controls").performClick();
            });
            check(activity.awaitIdle());
            check(ProbeDiagnostics.read(getTargetContext()).getString("kind").equals("SYNTHETIC"));
            runOnMainSync(() -> {
                View root = activity.findViewById(android.R.id.content);
                String text = ((TextView) root.findViewWithTag("status")).getText().toString();
                check(text.startsWith("PASS:") && text.contains("decodable: 1"));
                root.findViewWithTag("home").performClick();
                check(((TextView) root.findViewWithTag("status")).getText().toString()
                    .startsWith(granted ? "SMS permission granted" : "BLOCKED:"));
                check(!ProbeDiagnostics.exists(getTargetContext()));
                activity.finish();
            });

            phase("fixture-backed thread list, explicit selection, rendering and kind boundary");
            Intent fixtureIntent = new Intent(getTargetContext(), ProbeActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("fixture_history", true);
            ProbeActivity fixtureActivity = launch(fixtureIntent);
            runOnMainSync(() -> fixtureActivity.findViewById(android.R.id.content)
                .findViewWithTag("history").performClick());
            check(fixtureActivity.awaitIdle());
            runOnMainSync(() -> {
                View root = fixtureActivity.findViewById(android.R.id.content);
                check(((TextView) root.findViewWithTag("status")).getText().toString().contains("listed: 2"));
                String row = ((TextView) root.findViewWithTag("thread-0")).getText().toString();
                check(row.startsWith("Synthetic example business\nLast message:")
                    && row.contains("Synthetic example preview") && !row.contains("Thread 1"));
                EditText filter = root.findViewWithTag("filter");
                check(!filter.isSaveEnabled() && filter.getImportantForAutofill()
                    == View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
                filter.setText("S\u00ddNTH\u00c9TIC");
                check(((LinearLayout) root.findViewWithTag("threads")).getChildCount() == 2);
                filter.setText("NO-SUCH-FIXTURE-MATCH");
                check(root.findViewWithTag("thread-0") == null && root.findViewWithTag("thread-1") == null);
                check(((TextView) root.findViewWithTag("status")).getText().toString().contains("No matching loaded threads"));
                filter.setText("SECOND OFFER");
                check(root.findViewWithTag("thread-0") == null && root.findViewWithTag("thread-1") != null);
                root.findViewWithTag("thread-1").performClick();
            });
            check(fixtureActivity.awaitIdle());
            org.json.JSONObject fixtureMetadata = ProbeDiagnostics.read(getTargetContext());
            check(fixtureMetadata.getString("kind").equals("SYNTHETIC"));
            check(fixtureMetadata.getInt("readable_images") == 1 && fixtureMetadata.getInt("links") == 1);
            runOnMainSync(() -> {
                View root = fixtureActivity.findViewById(android.R.id.content);
                check(((TextView) root.findViewWithTag("status")).getText().toString().contains("Messages with text: 2"));
                check(((TextView) root.findViewWithTag("message-0")).getText().toString().contains("SECOND_THREAD_SENTINEL"));
                root.findViewWithTag("home").performClick();
                check(!ProbeDiagnostics.exists(getTargetContext()));
                fixtureActivity.finish();
            });
            ShareProbeChecks.run(this);
            NotificationReadinessChecks.run(this);
            phase("no private provider calls and no permission changes during automation");
            check(ProviderSource.queryAttempts() == privateQueriesBefore);
            check(ProviderSource.mediaAttempts() == privateMediaBefore);
            check((getTargetContext().checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) == granted);
            result.putString("stream", "PASS: " + checks + " assertions; production pipeline controls and actual UI; no phone reads.\n");
            result.putString("permission_branch", granted ? "GRANTED_NO_PROVIDER_READS" : "DENIED_GUARD_TESTED");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            // Fixed test-case label, never arbitrary exception/provider strings.
            result.putString("stream", "FAIL after " + checks + " assertions: " + current + "\n");
            finish(Activity.RESULT_CANCELED, result);
        }
    }
}

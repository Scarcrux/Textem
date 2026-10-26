package dev.textem.probe;

import android.content.ClipData;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.net.Uri;
import android.view.View;
import android.view.WindowManager;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/** Synthetic scanner + installed receiver checks; never open real shared data. */
final class ShareProbeChecks {
    static ShareProbeActivity launch(ProbeAutomation i, String mode) throws Exception {
        java.util.concurrent.ExecutorService launcher = Executors.newSingleThreadExecutor();
        try {
            Intent intent = new Intent(i.getTargetContext(), ShareProbeActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("share_fixture", mode);
            return launcher.submit(() -> (ShareProbeActivity) i.startActivitySync(intent)).get(15, TimeUnit.SECONDS);
        } finally { launcher.shutdownNow(); }
    }
    private static ShareProbeEngine.Report inspect(String mode, ShareFixtures fixture) {
        return ShareProbeEngine.inspect(ShareProbeEngine.parse(ShareFixtures.intent(mode)), fixture);
    }
    static void run(ProbeAutomation i) throws Exception {
        int actualOpens = SharedImageSource.opens();
        i.phase("share positive bytes versus text-only and fake image MIME controls");
        ShareFixtures png = new ShareFixtures("image");
        ShareProbeEngine.Report positive = inspect("image", png);
        i.check(positive.state == ShareProbeEngine.State.IMAGE_READABLE && positive.readableImages == 1);
        i.check(png.opens == 1 && png.closes == 1 && png.bytesRead > 0);
        ShareFixtures text = new ShareFixtures("text");
        ShareProbeEngine.Report negative = inspect("text", text);
        i.check(negative.state == ShareProbeEngine.State.TEXT_OR_LINK_ONLY && negative.links == 1 && text.opens == 0);
        Intent fakeMime = new Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_TEXT, "not an image");
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(fakeMime), text).state == ShareProbeEngine.State.TEXT_OR_LINK_ONLY);
        Intent html = new Intent(Intent.ACTION_SEND).setType("text/html")
            .putExtra(Intent.EXTRA_HTML_TEXT, "<a href=\"https://example.invalid/PRIVATE_PATH\">PRIVATE</a>");
        i.check(ShareProbeEngine.parse(html).textPresent && ShareProbeEngine.parse(html).links == 1);
        html.putExtra(Intent.EXTRA_TEXT, "https://example.invalid/PRIVATE_PATH");
        i.check(ShareProbeEngine.parse(html).links == 1);
        i.check(!positive.summary().contains("content://") && !negative.summary().contains("PRIVATE")
            && !negative.summary().contains("example.invalid"));

        i.phase("share denied, corrupt, empty, oversized and timeout outcomes discriminate");
        for (String mode : new String[] {"denied", "untrusted", "corrupt", "empty", "oversized", "timeout"}) {
            ShareFixtures source = new ShareFixtures(mode);
            ShareProbeEngine.Report report = inspect(mode, source);
            i.check(report.readableImages == 0 && ShareDiagnostics.valid(report));
            if (mode.equals("denied") || mode.equals("untrusted")) i.check(source.opens == 0 && report.state == ShareProbeEngine.State.BLOCKED);
            if (mode.equals("corrupt") || mode.equals("empty")) i.check(report.unreadableImages == 1 && source.closes == 1);
            if (mode.equals("oversized")) i.check(report.oversizedImages == 1 && report.limited
                && source.bytesRead == ShareProbeEngine.BYTE_LIMIT + 1 && source.closes == 1);
            if (mode.equals("timeout")) i.check(report.state == ShareProbeEngine.State.TIMEOUT);
        }

        i.phase("share URI policy cannot use READ_SMS or fetch network/file content");
        for (String value : new String[] {"content://sms/1", "content://mms/part/1", "file:///private",
                "https://example.invalid/image.png", "content://untrusted.invalid/1",
                "content://" + ShareProbeEngine.MEDIA_AUTHORITY + "@untrusted.invalid/1"}) {
            Intent bad = ShareFixtures.intent("image").putExtra(Intent.EXTRA_STREAM, Uri.parse(value));
            ShareFixtures source = new ShareFixtures("image");
            ShareProbeEngine.Report report = ShareProbeEngine.inspect(ShareProbeEngine.parse(bad), source);
            i.check(report.state == ShareProbeEngine.State.BLOCKED && source.opens == 0);
        }
        Intent noFlag = ShareFixtures.intent("image").setFlags(0);
        ShareFixtures noFlagSource = new ShareFixtures("image");
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(noFlag), noFlagSource).state == ShareProbeEngine.State.BLOCKED
            && noFlagSource.opens == 0);
        SharedImageSource real = new SharedImageSource(i.getTargetContext());
        i.check(!real.explicitGrant(ShareFixtures.uri(1)));
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(ShareFixtures.intent("image")), real).state == ShareProbeEngine.State.BLOCKED);
        boolean blocked = false;
        try { real.open(ShareFixtures.uri(1)); } catch (SecurityException expected) { blocked = true; }
        finally { real.cancel(); }
        i.check(blocked && SharedImageSource.opens() == actualOpens);

        i.phase("observed ProxyProvider exact authority keeps grant and provider guards");
        Uri proxyUri = Uri.parse("content://" + ShareProbeEngine.PROXY_AUTHORITY + "/synthetic-ungranted");
        Intent proxy = ShareFixtures.intent("image").putExtra(Intent.EXTRA_STREAM, proxyUri);
        ShareFixtures proxyGood = new ShareFixtures("image");
        ShareProbeEngine.Report proxyImage = ShareProbeEngine.inspect(ShareProbeEngine.parse(proxy), proxyGood);
        i.check(ShareProbeEngine.knownMediaUri(proxyUri) && proxyImage.state == ShareProbeEngine.State.IMAGE_READABLE
            && proxyImage.readableImages == 1 && proxyGood.opens == 1 && proxyGood.closes == 1);
        i.check(ShareDiagnostics.valid(proxyImage) && proxyImage.source.policy == ShareSourceDiagnostics.Policy.ALLOWED);
        for (String mode : new String[] {"denied", "untrusted"}) {
            ShareFixtures refused = new ShareFixtures(mode);
            ShareProbeEngine.Report refusal = ShareProbeEngine.inspect(ShareProbeEngine.parse(proxy), refused);
            i.check(refusal.state == ShareProbeEngine.State.BLOCKED && refused.opens == 0
                && refusal.blockReason == (mode.equals("denied") ? ShareProbeEngine.BlockReason.READ_GRANT_MISSING
                    : ShareProbeEngine.BlockReason.PROVIDER_POLICY));
        }
        ShareFixtures proxyNoFlag = new ShareFixtures("image");
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(new Intent(proxy).setFlags(0)), proxyNoFlag).blockReason
            == ShareProbeEngine.BlockReason.READ_GRANT_MISSING && proxyNoFlag.opens == 0);
        Intent proxyLookalike = new Intent(proxy).putExtra(Intent.EXTRA_STREAM,
            Uri.parse("content://" + ShareProbeEngine.PROXY_AUTHORITY + ".untrusted.invalid/synthetic"));
        ShareFixtures proxyOther = new ShareFixtures("image");
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(proxyLookalike), proxyOther).blockReason
            == ShareProbeEngine.BlockReason.URI_POLICY && proxyOther.opens == 0);
        SharedImageSource proxyLive = new SharedImageSource(i.getTargetContext());
        i.check(!proxyLive.explicitGrant(proxyUri));
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(proxy), proxyLive).blockReason
            == ShareProbeEngine.BlockReason.READ_GRANT_MISSING);
        boolean proxyDenied = false;
        try { proxyLive.open(proxyUri); } catch (SecurityException expected) { proxyDenied = true; }
        finally { proxyLive.cancel(); }
        i.check(proxyDenied && SharedImageSource.opens() == actualOpens);

        i.phase("share parser bounds, duplicates, malformed extras and unsupported actions");
        Intent duplicate = ShareFixtures.intent("image");
        duplicate.setClipData(ClipData.newRawUri("PRIVATE_FILENAME_SENTINEL", ShareFixtures.uri(1)));
        i.check(ShareProbeEngine.parse(duplicate).uris.size() == 1);
        Intent multiple = new Intent(Intent.ACTION_SEND_MULTIPLE).setType("image/png").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        ArrayList<Uri> uris = new ArrayList<>(); for (int n = 0; n < 12; n++) uris.add(ShareFixtures.uri(n));
        multiple.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        ShareFixtures many = new ShareFixtures("image");
        ShareProbeEngine.Input limited = ShareProbeEngine.parse(multiple);
        ShareProbeEngine.Report capped = ShareProbeEngine.inspect(limited, many);
        i.check(limited.uris.size() == 8 && capped.limited && capped.attemptedImages == 3 && capped.skippedUris == 5);
        i.check(many.opens == 3 && many.closes == 3 && capped.state == ShareProbeEngine.State.PARTIAL_IMAGE);
        i.check(ShareDiagnostics.valid(capped));
        Intent malformed = ShareFixtures.intent("image").putExtra(Intent.EXTRA_STREAM, new Intent("PRIVATE_SENTINEL"));
        ShareFixtures unused = new ShareFixtures("image");
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(malformed), unused).state == ShareProbeEngine.State.MALFORMED && unused.opens == 0);
        Intent unsupported = ShareFixtures.intent("image").setAction(Intent.ACTION_VIEW);
        i.check(ShareProbeEngine.inspect(ShareProbeEngine.parse(unsupported), unused).state == ShareProbeEngine.State.UNSUPPORTED && unused.opens == 0);
        char[] longText = new char[ShareProbeEngine.TEXT_LIMIT + 1]; java.util.Arrays.fill(longText, 'x');
        i.check(ShareProbeEngine.parse(new Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, new String(longText))).limited);

        i.phase("separate private share report rejects payload fields and invalid counts");
        ProbeEngine.Report history = new ProbeEngine.Report();
        i.check(ProbeDiagnostics.record(i.getTargetContext(), ProbeDiagnostics.Kind.SYNTHETIC, history));
        i.check(ShareDiagnostics.record(i.getTargetContext(), true, positive));
        org.json.JSONObject metadata = ShareDiagnostics.read(i.getTargetContext());
        i.check(metadata.length() == ShareDiagnostics.KEY_COUNT && metadata.getString("kind").equals("SYNTHETIC_SHARE"));
        i.check(!metadata.toString().contains("PRIVATE_PATH") && !metadata.toString().contains("content://"));
        i.check((android.system.Os.stat(new java.io.File(i.getTargetContext().getFilesDir(),
            "share-summary.json").getPath()).st_mode & 0777) == 0600);
        ShareProbeEngine.Report invalid = new ShareProbeEngine.Report(); invalid.readableImages = 1;
        i.check(!ShareDiagnostics.record(i.getTargetContext(), false, invalid) && !ShareDiagnostics.exists(i.getTargetContext()));
        i.check(ProbeDiagnostics.exists(i.getTargetContext()));

        i.phase("actual share Activity has consent gate, secure window, result and Clear");
        int fixtureOpens = ShareFixtures.allOpens.get();
        ShareProbeActivity activity = launch(i, "image");
        i.runOnMainSync(() -> {
            i.check((activity.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_SECURE) != 0);
            i.check(activity.getIntent().getExtras() == null && activity.getIntent().getData() == null);
            View root = activity.findViewById(android.R.id.content);
            i.check(((TextView) root.findViewWithTag("share-status")).getText().toString().startsWith("Waiting"));
            i.check(!ShareDiagnostics.exists(i.getTargetContext()) && SharedImageSource.opens() == actualOpens);
            i.check(ShareFixtures.allOpens.get() == fixtureOpens);
            root.findViewWithTag("inspect-share").performClick();
        });
        i.check(activity.awaitIdle());
        i.check(ShareFixtures.allOpens.get() == fixtureOpens + 1);
        i.check(ShareDiagnostics.read(i.getTargetContext()).getString("kind").equals("SYNTHETIC_SHARE"));
        i.runOnMainSync(() -> {
            View root = activity.findViewById(android.R.id.content);
            i.check(((TextView) root.findViewWithTag("share-status")).getText().toString().contains("IMAGE_READABLE"));
            root.findViewWithTag("clear-share").performClick();
            i.check(!ShareDiagnostics.exists(i.getTargetContext()) && ProbeDiagnostics.exists(i.getTargetContext()));
        });
        ShareProbeActivity textActivity = launch(i, "text");
        i.runOnMainSync(() -> textActivity.findViewById(android.R.id.content).findViewWithTag("inspect-share").performClick());
        i.check(textActivity.awaitIdle());
        i.runOnMainSync(() -> {
            View root = textActivity.findViewById(android.R.id.content);
            String summary = ((TextView) root.findViewWithTag("share-status")).getText().toString();
            i.check(summary.contains("TEXT_OR_LINK_ONLY") && !summary.contains("PRIVATE") && !summary.contains("example.invalid"));
            root.findViewWithTag("clear-share").performClick();
        });
        i.phase("actual share deadline cancels blocked synthetic read without late overwrite");
        ShareProbeActivity slow = launch(i, "wait");
        i.runOnMainSync(() -> slow.findViewById(android.R.id.content).findViewWithTag("inspect-share").performClick());
        i.check(ShareFixtures.waitStarted.await(3, TimeUnit.SECONDS));
        i.check(slow.awaitIdle());
        i.check(ShareFixtures.waitClosed.await(3, TimeUnit.SECONDS));
        i.check(ShareDiagnostics.read(i.getTargetContext()).getString("state").equals("TIMEOUT"));
        i.runOnMainSync(() -> slow.findViewById(android.R.id.content).findViewWithTag("clear-share").performClick());
        i.waitForIdleSync();
        i.check(!ShareDiagnostics.exists(i.getTargetContext()));
        i.phase("new incoming share cancels older read and prevents stale-result overwrite");
        ShareProbeActivity older = launch(i, "wait");
        i.runOnMainSync(() -> older.findViewById(android.R.id.content).findViewWithTag("inspect-share").performClick());
        i.check(ShareFixtures.waitStarted.await(3, TimeUnit.SECONDS));
        i.runOnMainSync(() -> older.onNewIntent(new Intent().putExtra("share_fixture", "text")));
        ShareProbeActivity newer = older;
        i.check(ShareFixtures.waitClosed.await(3, TimeUnit.SECONDS));
        i.check(ShareProbeActivity.awaitWorkerIdle());
        i.waitForIdleSync();
        i.check(!ShareDiagnostics.exists(i.getTargetContext()));
        i.runOnMainSync(() -> newer.findViewById(android.R.id.content).findViewWithTag("inspect-share").performClick());
        i.check(newer.awaitIdle());
        i.check(ShareDiagnostics.read(i.getTargetContext()).getString("state").equals("TEXT_OR_LINK_ONLY"));
        i.runOnMainSync(() -> newer.findViewById(android.R.id.content).findViewWithTag("clear-share").performClick());
        android.content.pm.PackageManager pm = i.getTargetContext().getPackageManager();
        ActivityInfo receiver = pm.getActivityInfo(new android.content.ComponentName(i.getTargetContext(), ShareProbeActivity.class), 0);
        i.check(receiver.exported && (receiver.flags & ActivityInfo.FLAG_EXCLUDE_FROM_RECENTS) != 0);
        Intent shareIntent = new Intent(Intent.ACTION_SEND).setType("image/png").setPackage(i.getTargetContext().getPackageName());
        i.check(pm.queryIntentActivities(shareIntent, 0).size() == 1);
        i.check(pm.queryIntentActivities(shareIntent.setType("text/plain"), 0).size() == 1);
        i.check(pm.queryIntentActivities(shareIntent.setType("video/mp4"), 0).isEmpty());
        ShareSourceChecks.run(i);
        ProbeDiagnostics.clear(i.getTargetContext()); ShareDiagnostics.clear(i.getTargetContext());
        i.check(SharedImageSource.opens() == actualOpens);
    }
}

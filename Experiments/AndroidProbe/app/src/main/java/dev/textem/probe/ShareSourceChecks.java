package dev.textem.probe;

import android.content.Intent;
import android.content.pm.ProviderInfo;
import android.net.Uri;
import android.view.View;
import android.widget.TextView;

/** Synthetic discriminating controls for source diagnostics; no Google provider reads. */
final class ShareSourceChecks {
    static void run(ProbeAutomation i) throws Exception {
        i.phase("source diagnostics discriminate URI rules without opening rejected sources");
        String base = "content://" + ShareProbeEngine.MEDIA_AUTHORITY;
        String[] values = {base + "/PRIVATE_PATH?PRIVATE_QUERY", "content://unknown.invalid/PRIVATE_PATH",
            "https://example.invalid/PRIVATE_PATH", "file:///PRIVATE_PATH", "content://sms/1",
            "content://mms/part/1", "content://0@" + ShareProbeEngine.MEDIA_AUTHORITY + "/PRIVATE_PATH",
            base + ":33/PRIVATE_PATH", base + "/PRIVATE_PATH#PRIVATE_FRAGMENT", "content:///PRIVATE_PATH"};
        ShareSourceDiagnostics.Policy[] rules = {ShareSourceDiagnostics.Policy.ALLOWED,
            ShareSourceDiagnostics.Policy.AUTHORITY_NOT_ALLOWED, ShareSourceDiagnostics.Policy.NON_CONTENT,
            ShareSourceDiagnostics.Policy.NON_CONTENT, ShareSourceDiagnostics.Policy.AUTHORITY_NOT_ALLOWED,
            ShareSourceDiagnostics.Policy.AUTHORITY_NOT_ALLOWED, ShareSourceDiagnostics.Policy.USER_INFO_PRESENT,
            ShareSourceDiagnostics.Policy.PORT_PRESENT, ShareSourceDiagnostics.Policy.FRAGMENT_PRESENT,
            ShareSourceDiagnostics.Policy.AUTHORITY_NOT_ALLOWED};
        for (int n = 0; n < values.length; n++) {
            Uri uri = Uri.parse(values[n]);
            ShareFixtures source = new ShareFixtures("image");
            Intent intent = ShareFixtures.intent("image").putExtra(Intent.EXTRA_STREAM, uri);
            ShareProbeEngine.Report report = ShareProbeEngine.inspect(ShareProbeEngine.parse(intent), source);
            i.check(report.source.policy == rules[n] && ShareDiagnostics.valid(report));
            i.check((rules[n] == ShareSourceDiagnostics.Policy.ALLOWED) == ShareProbeEngine.knownMediaUri(uri));
            i.check(source.opens == (n == 0 ? 1 : 0));
            i.check(source.descriptions == (ShareSourceDiagnostics.metadataEligible(uri) ? 1 : 0));
            String summary = report.summary();
            i.check(!summary.contains("PRIVATE_PATH") && !summary.contains("PRIVATE_QUERY")
                && !summary.contains("PRIVATE_FRAGMENT") && !summary.contains("unknown.invalid")
                && !summary.contains(ShareProbeEngine.MEDIA_AUTHORITY));
        }
        i.phase("unknown Messages-owned, other-app, unresolved and unavailable stay blocked");
        for (String mode : new String[] {"image", "untrusted", "unresolved", "metadata-error"}) {
            ShareFixtures source = new ShareFixtures(mode);
            ShareProbeEngine.Report report = ShareProbeEngine.inspect(ShareProbeEngine.parse(ShareFixtures.intent("unknown")), source);
            i.check(report.state == ShareProbeEngine.State.BLOCKED && source.opens == 0 && source.descriptions == 1);
            i.check(report.blockReason == ShareProbeEngine.BlockReason.URI_POLICY
                && report.source.policy == ShareSourceDiagnostics.Policy.AUTHORITY_NOT_ALLOWED);
            ShareSourceDiagnostics.Owner expected = mode.equals("image") ? ShareSourceDiagnostics.Owner.GOOGLE_MESSAGES
                : mode.equals("untrusted") ? ShareSourceDiagnostics.Owner.OTHER_APP
                : mode.equals("unresolved") ? ShareSourceDiagnostics.Owner.UNRESOLVED : ShareSourceDiagnostics.Owner.UNAVAILABLE;
            i.check(report.source.owner == expected && ShareDiagnostics.valid(report));
            i.check(ShareDiagnostics.record(i.getTargetContext(), true, report));
            String json = ShareDiagnostics.read(i.getTargetContext()).toString();
            i.check(!json.contains("PRIVATE_PATH") && !json.contains("PRIVATE_QUERY")
                && !json.contains("PRIVATE_ERROR_SENTINEL") && !json.contains("private.example")
                && !json.contains("unknown.invalid") && !json.contains("content://"));
        }
        ShareFixtures unavailable = new ShareFixtures("metadata-error");
        ShareProbeEngine.Report stillReadable = ShareProbeEngine.inspect(
            ShareProbeEngine.parse(ShareFixtures.intent("image")), unavailable);
        i.check(stillReadable.state == ShareProbeEngine.State.IMAGE_READABLE && unavailable.opens == 1
            && stillReadable.source.owner == ShareSourceDiagnostics.Owner.UNAVAILABLE);
        ProviderInfo info = new ProviderInfo(); info.packageName = "com.google.android.apps.messaging";
        info.grantUriPermissions = true;
        i.check(ShareSourceDiagnostics.classify(info, ShareSourceDiagnostics.Grant.GRANTED).access
            == ShareSourceDiagnostics.Access.PRIVATE_GRANT_CAPABLE);
        info.exported = true;
        i.check(ShareSourceDiagnostics.classify(info, ShareSourceDiagnostics.Grant.GRANTED).access
            == ShareSourceDiagnostics.Access.EXPORTED);
        info.exported = false; info.grantUriPermissions = false;
        i.check(ShareSourceDiagnostics.classify(info, ShareSourceDiagnostics.Grant.DENIED).access
            == ShareSourceDiagnostics.Access.PRIVATE_NO_GRANTS);
        i.check(ShareSourceDiagnostics.classify(null, ShareSourceDiagnostics.Grant.DENIED).owner
            == ShareSourceDiagnostics.Owner.UNRESOLVED);
        SharedImageSource live = new SharedImageSource(i.getTargetContext());
        int opens = SharedImageSource.opens();
        ShareSourceDiagnostics.Metadata absent = live.describe(Uri.parse("content://textem.absent.invalid/PRIVATE_PATH"));
        i.check(absent.owner == ShareSourceDiagnostics.Owner.UNRESOLVED && absent.grant == ShareSourceDiagnostics.Grant.DENIED);
        i.check(live.describe(Uri.parse("https://example.invalid/PRIVATE_PATH")).owner == ShareSourceDiagnostics.Owner.NOT_CHECKED);
        live.cancel(); i.check(SharedImageSource.opens() == opens);

        i.phase("mixed source categories and strict schema-2 writer validation");
        Intent mixed = ShareFixtures.intent("image");
        mixed.setClipData(android.content.ClipData.newRawUri("PRIVATE_FILENAME", Uri.parse("https://example.invalid/PRIVATE_PATH")));
        ShareFixtures source = new ShareFixtures("image");
        ShareProbeEngine.Report partial = ShareProbeEngine.inspect(ShareProbeEngine.parse(mixed), source);
        i.check(partial.state == ShareProbeEngine.State.PARTIAL_IMAGE && partial.source.policy == ShareSourceDiagnostics.Policy.MULTIPLE
            && partial.source.owner == ShareSourceDiagnostics.Owner.MULTIPLE && source.opens == 1);
        i.check(ShareDiagnostics.valid(partial));
        ShareProbeEngine.Report invalid = new ShareProbeEngine.Report();
        invalid.source.owner = ShareSourceDiagnostics.Owner.GOOGLE_MESSAGES;
        i.check(!ShareDiagnostics.record(i.getTargetContext(), true, invalid));
        ShareProbeEngine.Report unknown = ShareProbeEngine.inspect(ShareProbeEngine.parse(ShareFixtures.intent("unknown")), new ShareFixtures("image"));
        unknown.source.policy = ShareSourceDiagnostics.Policy.ALLOWED;
        i.check(!ShareDiagnostics.record(i.getTargetContext(), true, unknown));

        i.phase("installed blocked-share UI shows categories only after Inspect");
        int descriptions = ShareFixtures.allDescriptions.get();
        ShareProbeActivity activity = ShareProbeChecks.launch(i, "unknown");
        i.runOnMainSync(() -> {
            View root = activity.findViewById(android.R.id.content);
            i.check(ShareFixtures.allDescriptions.get() == descriptions && !ShareDiagnostics.exists(i.getTargetContext()));
            root.findViewWithTag("inspect-share").performClick();
        });
        i.check(activity.awaitIdle());
        i.check(ShareFixtures.allDescriptions.get() == descriptions + 1);
        org.json.JSONObject saved = ShareDiagnostics.read(i.getTargetContext());
        i.check(saved.getInt("schema") == 2 && saved.length() == ShareDiagnostics.KEY_COUNT
            && saved.getString("provider_owner").equals("GOOGLE_MESSAGES")
            && saved.getString("uri_policy_detail").equals("AUTHORITY_NOT_ALLOWED")
            && saved.getString("explicit_read_grant").equals("GRANTED") && saved.getBoolean("share_read_flag"));
        i.runOnMainSync(() -> {
            View root = activity.findViewById(android.R.id.content);
            String summary = ((TextView) root.findViewWithTag("share-status")).getText().toString();
            i.check(summary.contains("BLOCKED") && summary.contains("AUTHORITY_NOT_ALLOWED")
                && summary.contains("GOOGLE_MESSAGES") && summary.contains("PRIVATE_GRANT_CAPABLE")
                && summary.contains("explicit read grant: GRANTED") && summary.contains("package visibility"));
            i.check(!summary.contains("PRIVATE_PATH") && !summary.contains("PRIVATE_QUERY")
                && !summary.contains("unknown.invalid") && !summary.contains("content://"));
            root.findViewWithTag("clear-share").performClick();
            i.check(!ShareDiagnostics.exists(i.getTargetContext()));
        });
    }
}

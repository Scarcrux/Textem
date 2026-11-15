package dev.textem.probe;

import android.content.Intent;
import android.widget.TextView;

/** Fake gateway only: never requests/removes a real system association. */
final class CompanionLinkChecks {
    private static final class Fake implements CompanionLink.Gateway {
        boolean supported = true, queryFails, requestFails, removeFails;
        int[] ids = new int[0]; int requests, removals;
        CompanionLink.Callback callback;
        public boolean supported() { return supported; }
        public int[] ownedAssociations() { if (queryFails) throw new IllegalStateException(); return ids; }
        public void request(CompanionLink.Callback value) {
            requests++; if (requestFails) throw new IllegalStateException(); callback = value;
        }
        public void remove(int id) {
            if (removeFails) throw new IllegalStateException();
            if (ids.length != 1 || ids[0] != id) throw new AssertionError();
            removals++; ids = new int[0];
        }
    }
    static void run(ProbeAutomation i) throws Exception {
        i.phase("companion approval uses OS state, never a callback as proof");
        Fake f = new Fake(); CompanionLink link = new CompanionLink(f);
        int[] presented = {0}, changed = {0};
        i.check(link.state() == CompanionLink.State.NOT_LINKED);
        link.request(sender -> presented[0]++, () -> changed[0]++);
        i.check(f.requests == 1 && link.state() == CompanionLink.State.WAITING_FOR_APPROVAL);
        link.request(sender -> presented[0]++, () -> {}); i.check(f.requests == 1);
        f.callback.pending(null); i.check(presented[0] == 1);
        f.callback.created(); i.check(link.state() == CompanionLink.State.NOT_LINKED);
        link.request(sender -> {}, () -> {}); f.ids = new int[] {41}; f.callback.created();
        i.check(link.state() == CompanionLink.State.LINKED);
        link.request(sender -> {}, () -> {}); i.check(f.requests == 2);
        f.ids = new int[0]; i.check(link.state() == CompanionLink.State.NOT_LINKED);
        link.request(sender -> {}, () -> {}); f.callback.failed();
        i.check(link.state() == CompanionLink.State.UNAVAILABLE);
        link.request(sender -> { throw new IllegalStateException(); }, () -> {});
        f.callback.pending(null); i.check(link.state() == CompanionLink.State.UNAVAILABLE);
        f.requestFails = true; link.request(sender -> {}, () -> {});
        i.check(link.state() == CompanionLink.State.UNAVAILABLE);
        f.requestFails = false; f.queryFails = true;
        i.check(link.state() == CompanionLink.State.UNAVAILABLE);
        f.queryFails = false; f.ids = new int[] {41};
        CompanionLink removal = new CompanionLink(f); f.removeFails = true;
        removal.remove(() -> {}); i.check(removal.state() == CompanionLink.State.UNAVAILABLE && f.removals == 0);
        f.removeFails = false; removal.remove(() -> {});
        i.check(removal.state() == CompanionLink.State.NOT_LINKED && f.removals == 1);
        f.supported = false; CompanionLink unsupported = new CompanionLink(f); int before = f.requests;
        unsupported.request(sender -> {}, () -> {});
        i.check(unsupported.state() == CompanionLink.State.UNSUPPORTED && f.requests == before);

        i.phase("companion setup UI renders linked, unlinked and approval states with fake gateway");
        java.util.concurrent.ExecutorService launcher = java.util.concurrent.Executors.newSingleThreadExecutor();
        CaptureSetupActivity activity;
        try { activity = launcher.submit(() -> (CaptureSetupActivity) i.startActivitySync(new Intent(i.getTargetContext(), CaptureSetupActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))).get(15, java.util.concurrent.TimeUnit.SECONDS); }
        finally { launcher.shutdownNow(); }
        i.runOnMainSync(() -> {
            Fake fixture = new Fake(); activity.companion = new CompanionLink(fixture); activity.refresh();
            android.view.View root = activity.findViewById(android.R.id.content);
            TextView status = root.findViewWithTag("companion-status");
            i.check(status.getText().toString().contains("not linked"));
            i.check(root.findViewWithTag("companion-remove") != null);
            root.findViewWithTag("companion-link").performClick();
            i.check(fixture.requests == 1 && status.getText().toString().contains("waiting for your approval"));
            fixture.callback.failed(); i.check(status.getText().toString().contains("could not be verified"));
            fixture.ids = new int[] {41}; activity.companion = new CompanionLink(fixture); activity.refresh();
            i.check(status.getText().toString().contains("approved") && status.getText().toString().contains("has not been verified"));
            root.findViewWithTag("companion-remove").performClick();
            i.check(fixture.removals == 1 && status.getText().toString().contains("not linked"));
            activity.finish();
        });
    }
}

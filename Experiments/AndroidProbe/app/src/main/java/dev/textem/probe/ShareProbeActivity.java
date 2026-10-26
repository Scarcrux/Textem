package dev.textem.probe;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.WindowManager;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/** Explicit-consent share target: diagnostic Inspect and separate local PNG Save action. */
@SuppressLint("SetTextI18n")
public final class ShareProbeActivity extends Activity {
    private static final ExecutorService worker = Executors.newSingleThreadExecutor(r -> {
        Thread thread = new Thread(r, "share-inspection"); thread.setDaemon(true); return thread;
    });
    private static final AtomicBoolean busy = new AtomicBoolean();
    private static final AtomicInteger epoch = new AtomicInteger();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private LinearLayout content;
    private TextView status;
    private ShareProbeEngine.Input input;
    private boolean synthetic, complete;
    private String fixtureMode;
    private SharedImageSource live;
    private Future<?> job;
    private int token;
    private volatile CountDownLatch idle = new CountDownLatch(0);
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        ScrollView scroll = new ScrollView(this);
        content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(24, 36, 24, 36); scroll.addView(content);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            int top, bottom;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                top = bars.top; bottom = bars.bottom;
            } else { top = insets.getSystemWindowInsetTop(); bottom = insets.getSystemWindowInsetBottom(); }
            content.setPadding(24, 36 + top, 24, 36 + bottom); return insets;
        });
        setContentView(scroll);
        receive(getIntent());
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent); invalidate(); receive(intent);
    }
    private void receive(Intent received) {
        token = epoch.incrementAndGet(); complete = false; live = null; job = null;
        content.removeAllViews();
        ShareDiagnostics.clear(this); // Do not leave an old successful share as the new share's result.
        boolean incoming;
        try {
            synthetic = received.hasExtra("share_fixture");
            fixtureMode = synthetic ? received.getStringExtra("share_fixture") : null;
            incoming = synthetic || Intent.ACTION_SEND.equals(received.getAction()) || Intent.ACTION_SEND_MULTIPLE.equals(received.getAction());
            input = ShareProbeEngine.parse(synthetic ? ShareFixtures.intent(fixtureMode) : received);
        } catch (RuntimeException error) {
            input = new ShareProbeEngine.Input(); input.malformed = true; incoming = true;
        }
        setIntent(new Intent()); // Don't preserve the raw share payload as Activity state.
        label(synthetic ? "SYNTHETIC share · no phone reads" : "Textem Share Probe", 24);
        label("Inspect keeps only diagnostic counts. Save image for Mac prepares one private PNG (up to 2048px) for your paired Mac to import. No message text, links, source addresses or filenames are exported. No website is opened.", 16);
        status = label(incoming ? "Waiting for your Inspect tap. No shared image has been opened."
            : "In Google Messages, use Share on one approved graphic if that action is available, then choose Textem Share Probe. If Share supplies only text/a link, this probe will report that negative result.", 16);
        status.setTag("share-status");
        if (incoming) {
            label("Inspect attempts at most 3 explicitly granted private Google Messages image URIs, 6 MiB each. Other sources are blocked. The sender is not authenticated by the share dialog. A readable shared image does not establish that it matches the visible preview card.", 16);
            label("Inspect also checks provider metadata and URI-grant status for simple content addresses, even when the image allowlist blocks them. This does not open that provider or change permissions.", 16);
            button("Inspect shared item", "inspect-share", this::inspect);
            button("Save image for Mac", "save-mac-image", this::saveForMac);
        }
        button("Remove saved Mac image", "remove-mac-image", () -> {
            if (busy.get()) return;
            ShareImageExport.clear(this, synthetic); status.setText("Saved Mac image removed. Messages and diagnostic results are unchanged.");
        });
        button("Clear share result and close", "clear-share", () -> {
            invalidate(); ShareDiagnostics.clear(this); finish();
        });
    }
    private TextView label(String text, int size) {
        TextView view = new TextView(this); view.setText(text); view.setTextSize(size);
        view.setPadding(0, 8, 0, 16); content.addView(view); return view;
    }
    private void button(String text, String tag, Runnable action) {
        Button view = new Button(this); view.setText(text); view.setAllCaps(false); view.setTag(tag);
        view.setOnClickListener(v -> action.run()); content.addView(view);
    }
    private boolean current() { return epoch.get() == token && !isDestroyed() && !isFinishing() && !complete; }
    private void saveForMac() {
        if (!current() || input == null || !busy.compareAndSet(false, true)) return;
        content.findViewWithTag("inspect-share").setEnabled(false);
        content.findViewWithTag("save-mac-image").setEnabled(false);
        status.setText("Preparing one explicitly granted image for Mac import…");
        idle = new CountDownLatch(1); CountDownLatch selectedIdle = idle;
        int selectedToken = token; ShareProbeEngine.Input selected = input;
        SharedImageSource selectedLive = synthetic ? null : new SharedImageSource(this); live = selectedLive;
        ShareProbeEngine.Source source = synthetic ? new ShareFixtures(fixtureMode) : selectedLive;
        job = worker.submit(() -> {
            boolean saved;
            try { saved = ShareImageExport.save(this, selected, source, synthetic, () -> epoch.get() == selectedToken); }
            finally { if (selectedLive != null) selectedLive.cancel(); busy.set(false); }
            boolean success = saved;
            runOnUiThread(() -> {
                if (token == selectedToken && current()) {
                    complete = true; input = null;
                    status.setText(success ? (synthetic ? "SYNTHETIC PNG saved; the Mac rejects test exports."
                        : "Image saved for Mac. In Textem, open Shared Phone Images and click Import from phone. The private PNG stays until replaced or removed.")
                        : "No new image saved. One readable, granted Google Messages image is required. Any previous saved image is kept.");
                }
                selectedIdle.countDown();
            });
        });
        handler.postDelayed(() -> {
            if (token != selectedToken || !current()) return;
            epoch.compareAndSet(selectedToken, selectedToken + 1);
            if (selectedLive != null) selectedLive.cancel(); if (job != null) job.cancel(true);
            complete = true; input = null; status.setText("Image preparation timed out. No success is claimed; retry with a fresh Share.");
            selectedIdle.countDown();
        }, 10_000);
    }
    private void inspect() {
        if (!current()) return;
        if (!busy.compareAndSet(false, true)) {
            status.setText("A previous inspection is still stopping. No additional read started. Close and relaunch the probe if it does not stop.");
            return;
        }
        content.findViewWithTag("inspect-share").setEnabled(false);
        content.findViewWithTag("save-mac-image").setEnabled(false);
        status.setText("Inspecting only the supplied item locally…");
        idle = new CountDownLatch(1);
        CountDownLatch selectedIdle = idle;
        int selectedToken = token;
        ShareProbeEngine.Input selected = input;
        ShareProbeEngine.Source source;
        if (synthetic) source = new ShareFixtures(fixtureMode);
        else { live = new SharedImageSource(this); source = live; }
        job = worker.submit(() -> {
            ShareProbeEngine.Report r;
            try { r = ShareProbeEngine.inspect(selected, source); }
            catch (Throwable failed) { r = ShareProbeEngine.initial(selected); r.state = ShareProbeEngine.State.ERROR; }
            finally { if (source instanceof SharedImageSource) ((SharedImageSource) source).cancel(); busy.set(false); }
            ShareProbeEngine.Report result = r;
            runOnUiThread(() -> { if (token == selectedToken && current()) show(result); selectedIdle.countDown(); });
        });
        handler.postDelayed(() -> {
            if (token != selectedToken || !current()) return;
            if (live != null) live.cancel();
            if (job != null) job.cancel(true);
            ShareProbeEngine.Report r = ShareProbeEngine.initial(selected);
            r.state = ShareProbeEngine.State.TIMEOUT; r.limited = true;
            show(r); selectedIdle.countDown();
        }, 10_000);
    }
    private void show(ShareProbeEngine.Report r) {
        complete = true;
        boolean recorded = ShareDiagnostics.record(this, synthetic, r);
        status.setText(r.summary() + (r.state == ShareProbeEngine.State.TIMEOUT
            ? "\nInspection timed out; counters can omit an unfinished read. No success is claimed." : "")
            + (recorded ? "\nContent-free share diagnostics are ready for Mac readback."
                : "\nNo valid share diagnostic could be saved."));
        input = null;
    }
    private void invalidate() {
        epoch.compareAndSet(token, token + 1); complete = true; handler.removeCallbacksAndMessages(null);
        if (live != null) live.cancel(); if (job != null) job.cancel(true);
        input = null; setIntent(new Intent()); idle.countDown();
    }
    boolean awaitIdle() throws InterruptedException { return idle.await(15, TimeUnit.SECONDS); }
    static boolean awaitWorkerIdle() throws Exception { return worker.submit(() -> true).get(3, TimeUnit.SECONDS); }
    @Override protected void onDestroy() {
        invalidate(); content.removeAllViews(); super.onDestroy();
    }
}

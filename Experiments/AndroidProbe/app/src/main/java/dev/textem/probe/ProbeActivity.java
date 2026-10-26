package dev.textem.probe;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.PersistableBundle;
import android.os.Build;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.EditText;
import android.text.Editable;
import android.text.TextWatcher;
import android.text.InputType;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import java.text.DateFormat;
import java.util.Date;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

// Diagnostic v1 deliberately uses fixed English labels matching its content-free report.
@SuppressLint("SetTextI18n")
public final class ProbeActivity extends Activity {
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private LinearLayout content;
    private TextView status;
    private String safeSummary;
    private boolean fixtureHistory;
    private int generation;
    private volatile CountDownLatch workIdle = new CountDownLatch(0);

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        fixtureHistory = getIntent().getBooleanExtra("fixture_history", false);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        ScrollView scroll = new ScrollView(this);
        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(24, 36, 24, 36);
        scroll.setFillViewport(true);
        scroll.addView(content);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            int top, bottom;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                top = bars.top; bottom = bars.bottom;
            } else { top = insets.getSystemWindowInsetTop(); bottom = insets.getSystemWindowInsetBottom(); }
            content.setPadding(24, 36 + top, 24, 36 + bottom);
            return insets;
        });
        setContentView(scroll);
        home(false);
        if (getIntent().getBooleanExtra("open_capture_setup", false))
            startActivity(new android.content.Intent(this, CaptureSetupActivity.class));
    }

    private void base(String title) {
        content.removeAllViews();
        label(title, 24);
        status = label("", 16);
        status.setTag("status");
    }
    private TextView label(String value, int size) {
        TextView view = new TextView(this);
        view.setText(value); view.setTextSize(size); view.setPadding(0, 8, 0, 12);
        content.addView(view);
        return view;
    }
    private Button button(String title, String tag, Runnable action) {
        Button button = new Button(this);
        button.setText(title); button.setTag(tag); button.setAllCaps(false);
        button.setOnClickListener(view -> action.run());
        content.addView(button);
        return button;
    }

    private void home() { home(true); }
    private void home(boolean clearDiagnostics) {
        generation++;
        safeSummary = null;
        if (clearDiagnostics) ProbeDiagnostics.clear(this);
        base(fixtureHistory ? "SYNTHETIC history · no phone data" : "Textem · Read-only phone probe");
        label("No Internet access. No sending, mark-read, deletion, Google pairing, or default-SMS changes. Only content-free diagnostic counters are saved locally for this paired Mac; Clear removes them.", 16);
        label("SMS permission is broad: Android may expose SMS/MMS content across your phone. This probe shows at most 50 recent threads with participant addresses, dates and snippets for you to choose from, then samples only the thread you tap. No Contacts access or business-name lookup. Content stays on this screen/in memory; screenshots are blocked.", 16);
        status.setText(hasPermission() ? "SMS permission granted; no reads until you choose history."
            : "BLOCKED: SMS permission not granted. This does not mean your messages are absent.");
        button("Choose a history thread", "history", () -> {
            if (!fixtureHistory && !hasPermission()) requestPermissions(new String[] {Manifest.permission.READ_SMS}, 10);
            else loadIndex();
        });
        button("Run synthetic controls (no phone reads)", "controls", this::synthetic);
        button("How to test shared graphics", "share-help", () ->
            startActivity(new android.content.Intent(this, ShareProbeActivity.class)));
        button("Automatic recovery setup", "capture-setup", () -> startActivity(new android.content.Intent(this, CaptureSetupActivity.class)));
    }
    private boolean hasPermission() { return checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED; }
    private ProbeEngine.Source source() {
        if (!fixtureHistory) return new ProviderSource(this);
        FixtureSource fixture = new FixtureSource();
        fixture.threadCount = 2; fixture.distinctThreads = true;
        return fixture;
    }

    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code != 10) return;
        if (hasPermission()) loadIndex();
        else status.setText("BLOCKED: SMS access was denied or installer-restricted. No messages were queried. Do not switch your default SMS app. Synthetic controls still work.");
    }

    private void background(Runnable job) {
        status.setText("Working locally…");
        workIdle = new CountDownLatch(1);
        CountDownLatch done = workIdle;
        worker.execute(() -> {
            try { job.run(); }
            finally { runOnUiThread(done::countDown); }
        });
    }
    private void loadIndex() {
        int token = ++generation;
        background(() -> {
            ProbeEngine.Index index = ProbeEngine.index(source());
            runOnUiThread(() -> {
                if (isDestroyed() || generation != token) return;
                base("Choose one thread · phone only");
                label("Participants are provider addresses/short codes, not verified business or contact names. Filter checks only these loaded labels and previews; it does not search older messages.", 16);
                EditText filter = new EditText(this);
                filter.setTag("filter"); filter.setHint("Filter by address or preview text");
                filter.setSingleLine(true); filter.setSaveEnabled(false);
                filter.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
                filter.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING | EditorInfo.IME_FLAG_NO_EXTRACT_UI);
                filter.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
                content.addView(filter);
                LinearLayout rows = new LinearLayout(this);
                rows.setOrientation(LinearLayout.VERTICAL); rows.setTag("threads");
                content.addView(rows);
                filter.addTextChangedListener(new TextWatcher() {
                    public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
                    public void onTextChanged(CharSequence s, int start, int before, int count) {
                        showThreads(index, rows, s.toString());
                    }
                    public void afterTextChanged(Editable s) { }
                });
                showThreads(index, rows, "");
                button("Clear and return", "home", this::home);
            });
        });
    }
    private void showThreads(ProbeEngine.Index index, LinearLayout rows, String query) {
        rows.removeAllViews();
        for (int i = 0; i < index.threads.size(); i++) {
            ProbeEngine.ThreadEntry entry = index.threads.get(i);
            if (!entry.matches(query)) continue;
            String date = entry.time > 0 ? DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                .format(new Date(entry.time)) : "Date unavailable";
            Button row = new Button(this);
            row.setText(entry.participants + "\nLast message: " + date + "\n"
                + (entry.preview.isEmpty() ? "[No preview exposed]" : entry.preview));
            row.setAllCaps(false); row.setGravity(android.view.Gravity.START | android.view.Gravity.CENTER_VERTICAL);
            row.setTag("thread-" + i);
            // Keep the original entry, never select by the filtered display position.
            row.setOnClickListener(view -> scan(entry.id));
            rows.addView(row);
        }
        status.setText("Provider: " + index.state + "; listed: " + index.threads.size()
            + "; showing: " + rows.getChildCount()
            + (index.limited ? " (50-thread cap reached)" : "")
            + (rows.getChildCount() == 0 ? "\nNo matching loaded threads. Clear the filter to see all." : "")
            + "\nMissing threads here do not prove RCS absence.");
    }
    private void scan(long id) {
        int token = ++generation;
        background(() -> {
            ProbeEngine.Report report = ProbeEngine.scan(source(), id);
            runOnUiThread(() -> {
                if (isDestroyed() || generation != token) return;
                base(fixtureHistory ? "Selected SYNTHETIC sample · no phone data" : "Selected-thread sample · private");
                safeSummary = report.summary();
                boolean recorded = ProbeDiagnostics.record(this, fixtureHistory
                    ? ProbeDiagnostics.Kind.SYNTHETIC : ProbeDiagnostics.Kind.SELECTED_HISTORY, report);
                status.setText(safeSummary);
                label(recorded ? "Content-free counters are ready for automatic Mac readback. Message content stays on this phone."
                    : "Diagnostic readback could not be saved; no content was exported.", 16);
                label("Image counts are readable provider attachments, not proof of the phone's link-preview graphic. Links below are plain text and are never opened or fetched. Compare this sample with Google Messages yourself.", 16);
                for (int i = 0; i < report.messages.size(); i++) {
                    ProbeEngine.Message message = report.messages.get(i);
                    label(message.text.isEmpty() ? "[No text exposed in this row]" : message.text, 16)
                        .setTag("message-" + i);
                }
                button("Copy content-free summary", "copy", this::copySummary);
                button("Clear and return", "home", this::home);
            });
        });
    }
    private void synthetic() {
        int token = ++generation;
        background(() -> {
            FixtureSource good = new FixtureSource();
            ProbeEngine.Report positive = ProbeEngine.scan(good, 7);
            FixtureSource empty = new FixtureSource(); empty.empty = true;
            ProbeEngine.Report zero = ProbeEngine.scan(empty, 7);
            FixtureSource denied = new FixtureSource(); denied.denied = true;
            ProbeEngine.Report blocked = ProbeEngine.scan(denied, 7);
            boolean pass = positive.textMessages == 2 && positive.links == 1
                && positive.readableImages == 1 && zero.messages.isEmpty()
                && blocked.sms == ProbeEngine.State.BLOCKED && blocked.mms == ProbeEngine.State.BLOCKED;
            runOnUiThread(() -> {
                if (isDestroyed() || generation != token) return;
                base("Synthetic controls · NOT phone data");
                ProbeDiagnostics.record(this, ProbeDiagnostics.Kind.SYNTHETIC, positive);
                status.setText((pass ? "PASS" : "FAIL") + ": positive text/link/image, empty, and permission-denied controls.\n"
                    + "Synthetic source queries: " + good.queries + "; image reads: " + good.imageReads
                    + "\n" + positive.summary()
                    + "\nThis does not establish access to your phone's RCS business messages.");
                button("Clear and return", "home", this::home);
            });
        });
    }
    private void copySummary() {
        if (safeSummary == null) return;
        ClipData clip = ClipData.newPlainText("Textem capability summary", safeSummary);
        PersistableBundle extras = new PersistableBundle();
        extras.putBoolean("android.content.extra.IS_SENSITIVE", true);
        clip.getDescription().setExtras(extras);
        getSystemService(ClipboardManager.class).setPrimaryClip(clip);
    }
    boolean awaitIdle() throws InterruptedException { return workIdle.await(15, TimeUnit.SECONDS); }

    @Override protected void onDestroy() {
        generation++;
        safeSummary = null;
        worker.shutdownNow();
        content.removeAllViews();
        super.onDestroy();
    }
}

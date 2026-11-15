package dev.textem.probe;

import android.app.Instrumentation;
import android.app.Notification;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Bitmap;
import android.os.Bundle;
import java.io.File;
import org.json.JSONObject;

/** No activities, UI events, message-provider queries or production writes. */
public final class JournalInstrumentation extends Instrumentation {
    private int checks;
    private void check(boolean value) { checks++; if (!value) throw new AssertionError("journal fixture check " + checks); }
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    private JSONObject sample(Context c, String source, String text, Bitmap image) throws Exception {
        Notification n = new Notification.Builder(c, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Synthetic journal source").setContentText(text).setShortcutId(source).build();
        if (image != null) n.extras.putParcelable(Notification.EXTRA_PICTURE, image);
        NotificationContent.Result result = NotificationContent.inspect(c, NotificationReadiness.PACKAGE, () -> n, true, true,
            "57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32], 0, "POSTED", true);
        check(result.state.equals("SAVED") && result.document != null); return result.document;
    }
    @Override public void onStart() {
        Bundle result = new Bundle(); Context owner = getTargetContext();
        File directory = new File(owner.getCacheDir(), "notification-content-controls");
        Context fixture = new ContextWrapper(owner) {
            @Override public File getFilesDir() { return directory; }
            @Override public android.content.SharedPreferences getSharedPreferences(String name, int mode) {
                return super.getSharedPreferences("journal-fixture-" + name, mode);
            }
        };
        try {
            if (!directory.exists() && !directory.mkdirs()) throw new IllegalStateException();
            android.service.notification.StatusBarNotification old = NotificationCandidateChecks.item(fixture, "source-a", 0, 10, NotificationReadiness.PACKAGE, false);
            android.service.notification.StatusBarNotification recent = NotificationCandidateChecks.item(fixture, "source-b", 0, 20, NotificationReadiness.PACKAGE, false);
            NotificationCandidates.Selection selected = NotificationCandidates.active(new android.service.notification.StatusBarNotification[] {recent, old});
            check(selected.item == recent && selected.content.size() == 2 && selected.content.get(0) == old && selected.content.get(1) == recent);
            android.service.notification.StatusBarNotification[] over = new android.service.notification.StatusBarNotification[21]; java.util.Arrays.fill(over, old);
            check(NotificationCandidates.active(over).content.isEmpty());
            NotificationJournal.clear(fixture);
            JSONObject a = sample(fixture, "source-a", "Synthetic A", null);
            JSONObject b = sample(fixture, "source-b", "Synthetic B", null);
            NotificationJournal.append(fixture, a, true); NotificationJournal.append(fixture, b, true);
            JSONObject both = NotificationJournal.read(fixture);
            check(both.getJSONArray("samples").length() == 2 && both.getLong("revision") == 2);
            JSONObject duplicate = new JSONObject(a.toString()); duplicate.put("captured_at_ms", System.currentTimeMillis()); duplicate.put("origin", "ACTIVE_SCAN");
            NotificationJournal.append(fixture, duplicate, true);
            check(NotificationJournal.read(fixture).getLong("revision") == 2);
            boolean refused = false;
            try { NotificationJournal.append(owner, a, true); } catch (IllegalArgumentException expected) { refused = true; }
            check(refused);
            for (int i = 0; i < 8; i++) NotificationJournal.append(fixture, sample(fixture, "source-a", "Synthetic A " + i, null), true);
            check(NotificationJournal.read(fixture).getJSONArray("samples").length() == 5);
            check(NotificationJournal.read(fixture).getLong("dropped") == 5);
            NotificationJournal.clear(fixture);
            for (int i = 0; i < 36; i++) NotificationJournal.append(fixture, sample(fixture, "source-" + i, "Synthetic " + i, null), true);
            check(NotificationJournal.read(fixture).getJSONArray("samples").length() == 32);
            check(NotificationJournal.read(fixture).getLong("dropped") == 4);
            NotificationJournal.clear(fixture);
            Bitmap image = Bitmap.createBitmap(400, 400, Bitmap.Config.ARGB_8888);
            java.util.Random random = new java.util.Random(17);
            int[] pixels = new int[400 * 400]; for (int i = 0; i < pixels.length; i++) pixels[i] = 0xff000000 | random.nextInt(0x1000000);
            image.setPixels(pixels, 0, 400, 0, 0, 400, 400);
            for (int i = 0; i < 16; i++) {
                JSONObject picture = sample(fixture, "picture-" + i, "Synthetic picture " + i, image);
                check(picture.getString("image_state").equals("BITMAP_PREVIEW"));
                NotificationJournal.append(fixture, picture, true);
            }
            image.recycle(); check(new File(directory, NotificationJournal.FILE).length() <= NotificationJournal.MAX_BYTES);
            check(NotificationJournal.read(fixture).getLong("dropped") > 0);
            NotificationContentStore.enabled(fixture, false); check(!new File(directory, NotificationJournal.FILE).exists());
            NotificationJournal.append(fixture, a, true); NotificationContentStore.clear(fixture); check(!new File(directory, NotificationJournal.FILE).exists());
            NotificationJournal.append(fixture, a, true); CaptureState.enabled(fixture, false); check(!new File(directory, NotificationJournal.FILE).exists());
            check(ProviderSource.queryAttempts() == 0 && ProviderSource.mediaAttempts() == 0);
            result.putInt("checks", checks); result.putString("result", "PASS_NO_UI_NO_PROVIDER_READS"); finish(0, result);
        } catch (Exception | AssertionError failure) {
            result.putInt("checks", checks); result.putString("result", "FAIL"); finish(1, result);
        } finally {
            NotificationJournal.clear(fixture); NotificationContentStore.clear(fixture);
            fixture.getSharedPreferences("notification-capture", 0).edit().clear().apply();
            fixture.getSharedPreferences("notification-content", 0).edit().clear().apply();
        }
    }
}

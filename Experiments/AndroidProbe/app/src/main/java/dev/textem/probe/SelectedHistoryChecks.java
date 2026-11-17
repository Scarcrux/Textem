package dev.textem.probe;

import android.database.Cursor;
import android.database.MatrixCursor;
import org.json.*;

/** Synthetic controls through the production selected-thread reader. No ContentResolver. */
final class SelectedHistoryChecks {
    static class Source implements SelectedHistory.Source {
        boolean denied, missing, brokenParts, many; String body = "Synthetic older selected text"; int reads; long lastThread;
        public Cursor rows(boolean mms, long thread) {
            reads++; lastThread = thread;
            if (denied) throw new SecurityException();
            if (missing) return null;
            MatrixCursor cursor = new MatrixCursor(mms ? new String[]{"_id", "date", "msg_box"} : new String[]{"_id", "date", "body", "type"});
            if (mms) cursor.addRow(new Object[]{900, 2, 2});
            else for (int i = 0; i < (many ? 505 : 2); i++) cursor.addRow(new Object[]{100 + i, 1000 + i,
                thread == 7 ? body : "OTHER_THREAD_SENTINEL", 1});
            return cursor;
        }
        public Cursor parts(long message) {
            if (brokenParts) throw new SecurityException();
            MatrixCursor parts = new MatrixCursor(new String[]{"ct", "text"});
            parts.addRow(new Object[]{"text/plain", "Synthetic MMS text"});
            parts.addRow(new Object[]{"image/png", null});
            return parts;
        }
    }
    static JSONObject sample() throws Exception {
        return SelectedHistory.capture(new Source(), 7, "Synthetic participant",
            new NotificationContentStore.Identity("57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32]), true);
    }
    static void run(ProbeAutomation i) throws Exception {
        i.phase("selected provider history positive, denied, bounded and isolated controls");
        for (boolean mms : new boolean[]{false, true}) {
            ProviderSource.Query query = SelectedHistory.spec(mms, 7);
            i.check(query.selection.equals("thread_id = ?") && java.util.Arrays.equals(query.args, new String[]{"7"}));
            i.check(query.uri.toString().equals(mms ? "content://mms" : "content://sms"));
            i.check(query.order.equals("date DESC, _id DESC"));
        }
        if (!SelectedHistory.permission(i.getTargetContext())) {
            boolean blocked = false;
            try { SelectedHistory.provider(i.getTargetContext()).rows(false, 7); } catch (SecurityException expected) { blocked = true; }
            i.check(blocked);
        }
        Source source = new Source();
        JSONObject sample = SelectedHistory.capture(source, 7, "Synthetic participant",
            new NotificationContentStore.Identity("57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32]), true);
        i.check(source.reads == 2 && source.lastThread == 7);
        i.check(sample.getJSONArray("messages").length() == 3 && !sample.getBoolean("complete"));
        i.check(!sample.toString().contains("OTHER_THREAD_SENTINEL") && !sample.toString().contains("Synthetic participant"));
        i.check(sample.getString("source_key").matches("[0-9a-f]{64}"));
        JSONArray rows = sample.getJSONArray("messages");
        i.check(rows.getJSONObject(0).getLong("timestamp_ms") == 1000);
        i.check(rows.getJSONObject(2).getString("direction").equals("SENT"));
        i.check(rows.getJSONObject(2).getInt("attachments_omitted") == 1);
        java.util.HashSet<String> ids = new java.util.HashSet<>();
        for (int n = 0; n < rows.length(); n++) ids.add(rows.getJSONObject(n).getString("id"));
        i.check(ids.size() == 3);
        source.denied = true;
        JSONObject denied = SelectedHistory.capture(source, 7, "Synthetic participant",
            new NotificationContentStore.Identity("57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32]), true);
        i.check(denied.getString("sms").equals("BLOCKED") && denied.getJSONArray("messages").length() == 0);
        source.denied = false; source.missing = true;
        JSONObject absent = SelectedHistory.capture(source, 7, "Synthetic participant",
            new NotificationContentStore.Identity("57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32]), true);
        i.check(absent.getString("sms").equals("UNAVAILABLE") && absent.getJSONArray("messages").length() == 0);
        source.missing = false; source.many = true; source.brokenParts = true;
        JSONObject capped = SelectedHistory.capture(source, 7, "Synthetic participant",
            new NotificationContentStore.Identity("57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32]), true);
        i.check(capped.getBoolean("limited") && capped.getJSONArray("messages").length() == 501);
        i.check(!capped.getJSONArray("messages").getJSONObject(500).getBoolean("parts_complete"));
        source.brokenParts = false;
        char[] longBody = new char[SelectedHistory.MAX_BYTES]; java.util.Arrays.fill(longBody, 'x');
        source.body = new String(longBody);
        JSONObject byteCapped = SelectedHistory.capture(source, 7, "Synthetic participant",
            new NotificationContentStore.Identity("57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32]), true);
        i.check(byteCapped.getBoolean("limited") && byteCapped.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length <= SelectedHistory.MAX_BYTES);
        i.check(byteCapped.getJSONArray("messages").length() < 501);
        i.check(byteCapped.getJSONArray("messages").getJSONObject(0).getBoolean("truncated"));
        i.check(byteCapped.getJSONArray("messages").getJSONObject(byteCapped.getJSONArray("messages").length() - 1).getString("direction").equals("SENT"));
        boolean refused = false;
        try { SelectedHistory.publish(i.getTargetContext(), sample, true); } catch (SecurityException expected) { refused = true; }
        i.check(refused);
    }
}

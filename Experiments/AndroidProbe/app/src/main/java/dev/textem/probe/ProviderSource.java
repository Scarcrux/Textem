package dev.textem.probe;

import android.Manifest;
import android.content.ContentResolver;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.atomic.AtomicInteger;

/** Public providers only. There are deliberately no mutation, file-database or network APIs. */
final class ProviderSource implements ProbeEngine.Source {
    private static final AtomicInteger queryAttempts = new AtomicInteger();
    private static final AtomicInteger mediaAttempts = new AtomicInteger();
    static int queryAttempts() { return queryAttempts.get(); }
    static int mediaAttempts() { return mediaAttempts.get(); }
    private final Context context;
    ProviderSource(Context context) { this.context = context.getApplicationContext(); }

    @Override public Cursor query(ProbeEngine.Table table, long id) {
        if (context.checkSelfPermission(Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED)
            throw new SecurityException();
        Query query = spec(table, id);
        queryAttempts.incrementAndGet();
        return context.getContentResolver().query(query.uri, query.columns, query.selection, query.args, query.order);
    }

    static final class Query {
        final Uri uri;
        final String[] columns, args;
        final String selection, order;
        Query(String uri, String[] columns, String selection, String[] args, String order) {
            this.uri = Uri.parse(uri); this.columns = columns; this.selection = selection;
            this.args = args; this.order = order;
        }
    }
    static Query spec(ProbeEngine.Table table, long id) {
        if (table != ProbeEngine.Table.THREADS && id <= 0) throw new IllegalArgumentException();
        switch (table) {
            case THREADS:
                return new Query("content://mms-sms/conversations?simple=true",
                    new String[] {"_id", "snippet"}, null, null, "date DESC");
            case SMS:
                return new Query("content://sms", new String[] {"_id", "body", "date"},
                    "thread_id = ?", new String[] {Long.toString(id)}, "date DESC");
            case MMS:
                return new Query("content://mms", new String[] {"_id", "date"},
                    "thread_id = ?", new String[] {Long.toString(id)}, "date DESC");
            case PARTS:
                return new Query("content://mms/" + id + "/part",
                    new String[] {"_id", "ct", "text"}, null, null, null);
            default: throw new IllegalArgumentException();
        }
    }

    @Override public byte[] image(long partId) throws IOException {
        mediaAttempts.incrementAndGet();
        try (InputStream stream = context.getContentResolver().openInputStream(
                Uri.parse("content://mms/part/" + partId))) {
            if (stream == null) return null;
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int n;
            while ((n = stream.read(buffer, 0,
                    Math.min(buffer.length, ProbeEngine.BYTE_LIMIT + 1 - bytes.size()))) != -1) {
                bytes.write(buffer, 0, n);
                if (bytes.size() > ProbeEngine.BYTE_LIMIT) break;
            }
            return bytes.toByteArray();
        }
    }
}

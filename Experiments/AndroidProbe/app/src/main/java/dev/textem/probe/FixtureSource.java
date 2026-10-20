package dev.textem.probe;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import java.io.ByteArrayOutputStream;

/** Public, clearly synthetic controls; never access a ContentResolver. */
class FixtureSource implements ProbeEngine.Source {
    int queries, imageReads;
    long lastThread;
    boolean empty, denied, unavailable, brokenImage, oversizedImage, deniedImage, queryError;
    int smsCount = 1, imageCount = 1, threadCount = 1;
    ProbeEngine.Table deniedTable;
    String body = "Synthetic hello https://example.invalid/offer";

    @Override public Cursor query(ProbeEngine.Table table, long id) {
        queries++;
        if (denied || table == deniedTable) throw new SecurityException();
        if (queryError) throw new IllegalStateException();
        if (unavailable) return null;
        switch (table) {
            case THREADS: {
                MatrixCursor c = new MatrixCursor(new String[] {"_id", "snippet"});
                if (!empty) for (int i = 0; i < threadCount; i++)
                    c.addRow(new Object[] {7 + i, "Synthetic example business"});
                return c;
            }
            case SMS: {
                lastThread = id;
                MatrixCursor c = new MatrixCursor(new String[] {"_id", "body", "date"});
                if (!empty) for (int i = 0; i < smsCount; i++) c.addRow(new Object[] {100 + i, body, 1000 + i});
                return c;
            }
            case MMS: {
                lastThread = id;
                MatrixCursor c = new MatrixCursor(new String[] {"_id", "date"});
                if (!empty) c.addRow(new Object[] {101, 2});
                return c;
            }
            case PARTS: {
                MatrixCursor c = new MatrixCursor(new String[] {"_id", "ct", "text"});
                if (!empty) {
                    c.addRow(new Object[] {201, "text/plain", "Synthetic image caption"});
                    for (int i = 0; i < imageCount; i++) c.addRow(new Object[] {202 + i, "image/png", null});
                }
                return c;
            }
            default: throw new IllegalArgumentException();
        }
    }

    @Override public byte[] image(long partId) throws java.io.IOException {
        imageReads++;
        if (deniedImage) throw new SecurityException();
        if (oversizedImage) return new byte[ProbeEngine.BYTE_LIMIT + 1];
        if (brokenImage) return new byte[] {0, 1, 2};
        // Generate a known-valid PNG rather than trusting a copied base64 blob.
        // The initial literal failed real Android decoding, correctly turning
        // the positive-control gate red; malformed bytes stay a separate control.
        Bitmap bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888);
        bitmap.eraseColor(0xff00aa44);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try { bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes); }
        finally { bitmap.recycle(); }
        return bytes.toByteArray();
    }
}

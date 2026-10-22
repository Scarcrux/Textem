package dev.textem.probe;

import android.database.Cursor;
import android.graphics.BitmapFactory;
import android.graphics.Bitmap;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.text.Normalizer;
import java.util.regex.Pattern;

/** The same bounded, read-only pipeline serves real providers and synthetic controls. */
final class ProbeEngine {
    static final int ROW_LIMIT = 20, THREAD_LIMIT = 50, PART_LIMIT = 32;
    static final int IMAGE_LIMIT = 3, BYTE_LIMIT = 6 * 1024 * 1024, TEXT_LIMIT = 20_000;
    static final int PARTICIPANT_LIMIT = 8, ADDRESS_LIMIT = 128, PREVIEW_LIMIT = 200;
    enum Table { THREADS, ADDRESS, SMS, MMS, PARTS }
    enum State { OK, BLOCKED, UNAVAILABLE, ERROR }
    interface Source {
        Cursor query(Table table, long id);
        byte[] image(long partId) throws java.io.IOException;
    }
    static final class ThreadEntry {
        final long id;
        final String preview, participants;
        final long time;
        ThreadEntry(long id, String preview, String participants, long time) {
            this.id = id; this.preview = preview; this.participants = participants; this.time = time;
        }
        boolean matches(String query) {
            return searchKey(participants + " " + preview).contains(searchKey(query));
        }
    }
    static final class Index {
        State state = State.OK;
        boolean limited;
        final List<ThreadEntry> threads = new ArrayList<>();
    }
    static final class Message {
        String text = "";
        long time;
        int links;
        Message(long time) { this.time = time; }
    }
    static final class Report {
        State sms = State.OK, mms = State.OK;
        int smsRows, mmsRows, textMessages, links, imageParts, readableImages;
        int unreadableImages, oversizedImages, skippedImages, partFailures;
        boolean limited;
        final List<Message> messages = new ArrayList<>();
        String summary() {
            // Fixed fields only: never append exceptions, source strings, IDs or content.
            return "Textem Android probe v1\nSMS: " + sms + "; MMS: " + mms
                + "\nSMS rows: " + smsRows + "; MMS rows: " + mmsRows
                + "\nMessages with text: " + textMessages + "; web links: " + links
                + "\nImage parts: " + imageParts + "; decodable: " + readableImages
                + "\nUnreadable: " + unreadableImages + "; oversized: " + oversizedImages
                + "; skipped by cap: " + skippedImages + "; part failures: " + partFailures
                + "\nBounds reached: " + limited
                + "\nProvider sample only; not a complete RCS history or rich-card verdict.";
        }
    }

    private static final Pattern LINK = Pattern.compile("https?://[^\\s<>\"']+", Pattern.CASE_INSENSITIVE);
    static String bounded(String value) {
        if (value == null) return "";
        return value.substring(0, Math.min(value.length(), TEXT_LIMIT));
    }
    static String text(Cursor c, String column) {
        int i = c.getColumnIndexOrThrow(column);
        return bounded(c.isNull(i) ? "" : c.getString(i));
    }
    static long number(Cursor c, String column) { return c.getLong(c.getColumnIndexOrThrow(column)); }
    private static String optionalText(Cursor c, String column) {
        return c.getColumnIndex(column) < 0 ? "" : text(c, column);
    }
    private static String displayText(String value, int limit) {
        // Provider values are plain display text, not controls or multi-line headings.
        String clean = bounded(value).replaceAll("[\\p{Cc}\\p{Cf}]", " ").trim();
        return clean.substring(0, Math.min(limit, clean.length()));
    }
    private static String searchKey(String value) {
        return Normalizer.normalize(bounded(value), Normalizer.Form.NFD)
            .replaceAll("\\p{M}+", "").toLowerCase(Locale.ROOT).trim();
    }
    private static String participants(Source source, String ids) {
        String raw = ids.trim();
        if (raw.isEmpty()) return "Participants unavailable";
        String[] tokens = raw.split("\\s+", PARTICIPANT_LIMIT + 1);
        List<String> addresses = new ArrayList<>();
        boolean incomplete = tokens.length > PARTICIPANT_LIMIT;
        for (int i = 0; i < Math.min(tokens.length, PARTICIPANT_LIMIT); i++) {
            String address = "";
            try {
                // Reject signs, paths, overflow and zero before querying the provider.
                if (!tokens[i].matches("[0-9]{1,19}")) throw new IllegalArgumentException();
                long id = Long.parseLong(tokens[i]);
                if (id <= 0) throw new IllegalArgumentException();
                try (Cursor c = source.query(Table.ADDRESS, id)) {
                    if (c != null && c.moveToFirst()) address = displayText(text(c, "address"), ADDRESS_LIMIT);
                }
            } catch (RuntimeException ignored) { /* Optional labels must not hide a valid thread. */ }
            if (address.isEmpty()) incomplete = true;
            else if (!addresses.contains(address)) addresses.add(address);
        }
        if (addresses.isEmpty()) return "Participants unavailable";
        return String.join(", ", addresses) + (incomplete ? " · more/unavailable participants" : "");
    }

    static Index index(Source source) {
        Index result = new Index();
        try (Cursor c = source.query(Table.THREADS, 0)) {
            if (c == null) { result.state = State.UNAVAILABLE; return result; }
            while (c.moveToNext()) {
                if (result.threads.size() == THREAD_LIMIT) { result.limited = true; break; }
                long id = number(c, "_id");
                if (id <= 0) throw new IllegalStateException();
                String preview = displayText(text(c, "snippet"), PREVIEW_LIMIT);
                String people = participants(source, optionalText(c, "recipient_ids"));
                long time = c.getColumnIndex("date") < 0 ? 0 : number(c, "date");
                result.threads.add(new ThreadEntry(id, preview, people, time));
            }
        } catch (SecurityException e) { result.state = State.BLOCKED;
        } catch (RuntimeException e) { result.state = State.ERROR; }
        if (result.state != State.OK) result.threads.clear();
        return result;
    }

    static Report scan(Source source, long threadId) {
        if (threadId <= 0) throw new IllegalArgumentException("Select a positive thread ID");
        Report r = new Report();
        for (Table table : new Table[] {Table.SMS, Table.MMS}) {
            State state = State.OK;
            try (Cursor c = source.query(table, threadId)) {
                if (c == null) { state = State.UNAVAILABLE; }
                else {
                    int count = 0;
                    while (c.moveToNext()) {
                        if (count++ == ROW_LIMIT) { r.limited = true; break; }
                        long time = number(c, "date");
                        Message message = new Message(table == Table.MMS ? time * 1000 : time);
                        if (table == Table.SMS) {
                            r.smsRows++;
                            String raw = c.getString(c.getColumnIndexOrThrow("body"));
                            if (raw != null && raw.length() > TEXT_LIMIT) r.limited = true;
                            message.text = bounded(raw);
                        } else {
                            r.mmsRows++;
                            readParts(source, number(c, "_id"), message, r);
                        }
                        message.links = countLinks(message.text);
                        if (!message.text.trim().isEmpty()) r.textMessages++;
                        r.links += message.links;
                        r.messages.add(message);
                    }
                }
            } catch (SecurityException e) { state = State.BLOCKED;
            } catch (RuntimeException e) { state = State.ERROR; }
            if (table == Table.SMS) r.sms = state; else r.mms = state;
        }
        r.messages.sort(Comparator.comparingLong((Message m) -> m.time));
        return r;
    }

    private static void readParts(Source source, long messageId, Message message, Report r) {
        try (Cursor parts = source.query(Table.PARTS, messageId)) {
            if (parts == null) { r.partFailures++; return; }
            int count = 0;
            while (parts.moveToNext()) {
                if (count++ == PART_LIMIT) { r.limited = true; break; }
                String type = text(parts, "ct");
                if ("text/plain".equalsIgnoreCase(type)) {
                    String raw = parts.getString(parts.getColumnIndexOrThrow("text"));
                    if (raw != null && raw.length() + message.text.length() + 1 > TEXT_LIMIT) r.limited = true;
                    message.text = bounded(message.text + (message.text.isEmpty() ? "" : "\n") + bounded(raw));
                } else if (type.startsWith("image/")) {
                    r.imageParts++;
                    if (r.imageParts > IMAGE_LIMIT) { r.skippedImages++; r.limited = true; continue; }
                    try {
                        byte[] data = source.image(number(parts, "_id"));
                        if (data == null) { r.unreadableImages++; continue; }
                        if (data.length > BYTE_LIMIT) { r.oversizedImages++; r.limited = true; continue; }
                        BitmapFactory.Options options = new BitmapFactory.Options();
                        options.inJustDecodeBounds = true;
                        BitmapFactory.decodeByteArray(data, 0, data.length, options);
                        if (options.outWidth <= 0 || options.outHeight <= 0) { r.unreadableImages++; continue; }
                        int sample = 1;
                        while (options.outWidth / sample > 256 || options.outHeight / sample > 256) sample *= 2;
                        options.inJustDecodeBounds = false;
                        options.inSampleSize = sample;
                        Bitmap decoded = BitmapFactory.decodeByteArray(data, 0, data.length, options);
                        if (decoded != null) { r.readableImages++; decoded.recycle(); }
                        else r.unreadableImages++;
                    } catch (SecurityException | java.io.IOException e) { r.unreadableImages++; }
                }
            }
        } catch (RuntimeException e) { r.partFailures++; }
    }

    private static int countLinks(String text) {
        int n = 0;
        java.util.regex.Matcher matcher = LINK.matcher(text);
        while (matcher.find()) n++;
        return n;
    }
}

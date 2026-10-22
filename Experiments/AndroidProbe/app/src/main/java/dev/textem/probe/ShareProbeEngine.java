package dev.textem.probe;

import android.content.ClipData;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.Arrays;
import java.util.HashSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Untrusted share input -> fixed counters. Never retain text or render/fetch a URL. */
final class ShareProbeEngine {
    static final int URI_LIMIT = 8, OPEN_LIMIT = 3, BYTE_LIMIT = 6 * 1024 * 1024;
    static final int TEXT_LIMIT = 20_000, LINK_LIMIT = 10_000;
    static final String MEDIA_AUTHORITY =
        "com.google.android.apps.messaging.shared.datamodel.richcard.RichCardMediaFileProvider";
    private static final Set<String> AUTHORITIES = new HashSet<>(Arrays.asList(MEDIA_AUTHORITY,
        "com.google.android.apps.messaging.shared.datamodel.provider.MmsFileProvider",
        "com.google.android.apps.messaging.shared.datamodel.BugleContentProviderInternal",
        "com.google.android.apps.messaging.shared.datamodel.provider.InternalMediaScratchFileProvider",
        "com.google.android.apps.messaging.sharing.fileprovider",
        "com.google.android.apps.messaging.fileprovider",
        "com.google.android.rcs.service.fileprovider"));
    private static final Pattern LINK = Pattern.compile("https?://[^\\s<>\"']+", Pattern.CASE_INSENSITIVE);
    enum State { IMAGE_READABLE, PARTIAL_IMAGE, TEXT_OR_LINK_ONLY, EMPTY, BLOCKED,
        UNREADABLE, UNSUPPORTED, MALFORMED, TIMEOUT, ERROR }
    enum BlockReason { NONE, URI_POLICY, READ_GRANT_MISSING, PROVIDER_POLICY, READ_DENIED, MULTIPLE }
    interface Source {
        boolean explicitGrant(Uri uri);
        boolean privateMessagesProvider(Uri uri);
        InputStream open(Uri uri) throws IOException;
    }
    static final class Input {
        final List<Uri> uris = new ArrayList<>();
        boolean readFlag, textPresent, limited, malformed, supported;
        int links;
    }
    static final class Report {
        State state = State.EMPTY;
        BlockReason blockReason = BlockReason.NONE;
        int uris, attemptedImages, readableImages, blockedUris, unreadableImages, oversizedImages, skippedUris, links;
        boolean textPresent, limited;
        String summary() {
            return "Share result: " + state + "\nURI candidates: " + uris
                + "; opened: " + attemptedImages + "; decodable images: " + readableImages
                + "\nBlocked: " + blockedUris + " (" + blockReason + "); unreadable: " + unreadableImages
                + "; oversized: " + oversizedImages + "; skipped: " + skippedUris
                + "\nText supplied: " + textPresent + "; web links: " + links
                + "; bounds reached: " + limited
                + "\nA decodable shared image is not proof of the exact visible card or a full history.";
        }
    }
    static boolean knownMediaUri(Uri uri) {
        return uri != null && uri.toString().length() <= 4096 && "content".equals(uri.getScheme())
            && AUTHORITIES.contains(uri.getAuthority())
            && uri.getPort() == -1 && uri.getFragment() == null;
    }
    @SuppressWarnings("deprecation") // Uri-only validation also supports API26-32.
    static Input parse(Intent intent) {
        Input input = new Input();
        if (intent == null) return input;
        Set<String> links = new LinkedHashSet<>();
        try {
            String action = intent.getAction(), type = intent.getType();
            input.supported = (Intent.ACTION_SEND.equals(action) || Intent.ACTION_SEND_MULTIPLE.equals(action))
                && type != null && (type.startsWith("image/") || type.equals("text/plain") || type.equals("text/html"));
            if (!input.supported) return input;
            input.readFlag = (intent.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0;
            addText(input, links, intent.getCharSequenceExtra(Intent.EXTRA_TEXT));
            addText(input, links, intent.getStringExtra(Intent.EXTRA_HTML_TEXT));
            if (Intent.ACTION_SEND_MULTIPLE.equals(action)) {
                ArrayList<?> streams = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
                if (streams != null) {
                    if (streams.size() > URI_LIMIT) input.limited = true;
                    for (int i = 0; i < Math.min(URI_LIMIT, streams.size()); i++) addUri(input, streams.get(i));
                }
            } else if (intent.hasExtra(Intent.EXTRA_STREAM)) addUri(input, intent.getParcelableExtra(Intent.EXTRA_STREAM));
            addUri(input, intent.getData());
            ClipData clip = intent.getClipData();
            if (clip != null) {
                if (clip.getItemCount() > URI_LIMIT) input.limited = true;
                for (int i = 0; i < Math.min(URI_LIMIT, clip.getItemCount()); i++) {
                    ClipData.Item item = clip.getItemAt(i);
                    addUri(input, item.getUri());
                    addText(input, links, item.getText()); // Never coerceToText: that can query a provider.
                    addText(input, links, item.getHtmlText());
                }
            }
        } catch (RuntimeException malformed) { input.malformed = true; }
        return input;
    }
    private static void addUri(Input input, Object value) {
        if (value == null) return;
        if (!(value instanceof Uri) || value.toString().length() > 4096) { input.malformed = true; return; }
        Uri uri = (Uri) value;
        if (input.uris.contains(uri)) return;
        if (input.uris.size() == URI_LIMIT) { input.limited = true; return; }
        input.uris.add(uri);
    }
    private static void addText(Input input, Set<String> links, CharSequence value) {
        if (value == null || value.length() == 0) return;
        input.textPresent = true;
        if (value.length() > TEXT_LIMIT) input.limited = true;
        String text = value.subSequence(0, Math.min(TEXT_LIMIT, value.length())).toString();
        Matcher matches = LINK.matcher(text);
        while (matches.find()) {
            if (links.size() == LINK_LIMIT) { input.limited = true; break; }
            links.add(matches.group());
        }
        input.links = links.size();
    }
    static Report initial(Input input) {
        Report r = new Report();
        r.uris = input.uris.size(); r.links = input.links;
        r.textPresent = input.textPresent; r.limited = input.limited;
        return r;
    }
    static Report inspect(Input input, Source source) {
        Report r = initial(input);
        if (input.malformed) { r.state = State.MALFORMED; return r; }
        if (!input.supported) { r.state = State.UNSUPPORTED; return r; }
        for (Uri uri : input.uris) {
            boolean attempted = false;
            try {
                if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                if (!knownMediaUri(uri)) { blocked(r, BlockReason.URI_POLICY); continue; }
                if (!input.readFlag || !source.explicitGrant(uri)) { blocked(r, BlockReason.READ_GRANT_MISSING); continue; }
                if (!source.privateMessagesProvider(uri)) { blocked(r, BlockReason.PROVIDER_POLICY); continue; }
                if (r.attemptedImages == OPEN_LIMIT) { r.skippedUris++; r.limited = true; continue; }
                r.attemptedImages++;
                attempted = true;
                int outcome;
                try (InputStream stream = source.open(uri)) {
                    if (stream == null) { r.unreadableImages++; continue; }
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    byte[] buffer = new byte[8192];
                    while (bytes.size() <= BYTE_LIMIT) {
                        if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                        int n = stream.read(buffer, 0, Math.min(buffer.length, BYTE_LIMIT + 1 - bytes.size()));
                        if (n < 0) break;
                        if (n == 0) throw new IOException();
                        bytes.write(buffer, 0, n);
                    }
                    outcome = bytes.size() > BYTE_LIMIT ? 2 : decodable(bytes.toByteArray()) ? 1 : 0;
                }
                if (outcome == 2) { r.oversizedImages++; r.limited = true; }
                else if (outcome == 1) r.readableImages++; else r.unreadableImages++;
            } catch (InterruptedIOException timeout) { r.state = State.TIMEOUT; return r;
            } catch (SecurityException denied) { blocked(r, BlockReason.READ_DENIED);
            } catch (IOException | RuntimeException failed) {
                if (attempted) r.unreadableImages++; else blocked(r, BlockReason.PROVIDER_POLICY);
            }
        }
        if (r.readableImages > 0) r.state = r.blockedUris + r.unreadableImages + r.oversizedImages + r.skippedUris > 0
            ? State.PARTIAL_IMAGE : State.IMAGE_READABLE;
        else if (r.blockedUris > 0) r.state = State.BLOCKED;
        else if (r.unreadableImages + r.oversizedImages > 0) r.state = State.UNREADABLE;
        else r.state = r.textPresent ? State.TEXT_OR_LINK_ONLY : State.EMPTY;
        return r;
    }
    private static void blocked(Report r, BlockReason reason) {
        r.blockedUris++;
        r.blockReason = r.blockReason == BlockReason.NONE || r.blockReason == reason ? reason : BlockReason.MULTIPLE;
    }
    private static boolean decodable(byte[] bytes) {
        BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        if (options.outWidth <= 0 || options.outHeight <= 0 || options.outWidth > 16_384 || options.outHeight > 16_384
                || (long) options.outWidth * options.outHeight > 64_000_000) return false;
        options.inSampleSize = 1;
        while (options.outWidth / options.inSampleSize > 256 || options.outHeight / options.inSampleSize > 256)
            options.inSampleSize *= 2;
        options.inJustDecodeBounds = false;
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
        if (bitmap == null) return false;
        bitmap.recycle(); return true;
    }
}

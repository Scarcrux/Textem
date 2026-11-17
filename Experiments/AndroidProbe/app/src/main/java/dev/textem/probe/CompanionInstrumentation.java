package dev.textem.probe;

import android.app.Instrumentation;
import android.app.Notification;
import android.content.*;
import android.os.Bundle;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.net.ssl.*;
import org.json.JSONObject;

/** Synthetic loopback TLS only. No UI, owner journals, grants or Google calls. */
// Fixture trust is exact-leaf SHA-256 plus validity; synchronous cleanup must
// finish before the instrumentation process exits. Neither touches owner state.
@android.annotation.SuppressLint({"CustomX509TrustManager", "ApplySharedPref"})
public final class CompanionInstrumentation extends Instrumentation {
    private int checks;
    private String trustPhase = "not_called";
    private String protocol = "TLSv1.2";
    private String path = "/v1/journal";
    private void check(boolean value) { checks++; if (!value) throw new AssertionError(); }
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    private String request(JSONObject pair, String token, String extra, String pin) throws Exception {
        X509TrustManager trust = new X509TrustManager() {
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            public void checkClientTrusted(X509Certificate[] chain, String auth) throws java.security.cert.CertificateException { throw new java.security.cert.CertificateException(); }
            public void checkServerTrusted(X509Certificate[] chain, String auth) throws java.security.cert.CertificateException {
                trustPhase = "called";
                try {
                    StringBuilder actual = new StringBuilder();
                    for (byte b : MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded())) actual.append(String.format(Locale.ROOT, "%02x", b & 255));
                    if (chain.length != 1 || !actual.toString().equals(pin)) throw new GeneralSecurityException();
                    chain[0].checkValidity();
                    trustPhase = "accepted";
                } catch (Exception failure) { throw new java.security.cert.CertificateException(); }
            }
        };
        SSLContext tls = SSLContext.getInstance("TLS"); tls.init(null, new TrustManager[]{trust}, new SecureRandom());
        try (SSLSocket socket = (SSLSocket) tls.getSocketFactory().createSocket(pair.getString("host"), pair.getInt("port"))) {
            socket.setEnabledProtocols(new String[]{protocol});
            socket.setSoTimeout(5000); socket.startHandshake();
            socket.getOutputStream().write(("GET " + path + " HTTP/1.1\r\nHost: fixture\r\nAuthorization: Bearer " + token
                + "\r\nX-Textem-Request-ID: 57b2dd91-cfa8-4193-9a38-e2d6d6470625\r\n" + extra + "\r\n").getBytes(StandardCharsets.US_ASCII));
            ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] buffer = new byte[4096]; int count;
            try { while ((count = socket.getInputStream().read(buffer)) != -1) { out.write(buffer, 0, count); if (out.size() > 65536) throw new IOException(); } }
            catch (SSLException closed) { if (out.size() == 0) return ""; }
            return out.toString("UTF-8");
        }
    }
    @Override public void onStart() {
        Bundle result = new Bundle(); Context owner = getTargetContext();
        File directory = new File(owner.getCacheDir(), "notification-content-controls");
        Context fixture = new ContextWrapper(owner) {
            @Override public File getFilesDir() { return directory; }
            @Override public android.content.SharedPreferences getSharedPreferences(String name, int mode) {
                return super.getSharedPreferences("companion-fixture-" + name, mode);
            }
        };
        CompanionServer server = null;
        int completion = 1;
        try {
            if (!directory.exists() && !directory.mkdirs()) throw new IOException();
            // A previous interrupted instrument may have left a fixture key.
            // Never reuse that key to judge a changed key-generation contract.
            KeyStore before = KeyStore.getInstance("AndroidKeyStore"); before.load(null);
            before.deleteEntry("textem-companion-tls-v1-fixture"); before.deleteEntry("textem-companion-token-v1-fixture");
            fixture.getSharedPreferences("companion-channel", 0).edit().clear().commit();
            boolean refused = false;
            try { CompanionServer.fixture(owner, () -> true); } catch (SecurityException expected) { refused = true; }
            check(refused);
            CaptureState.enabled(fixture, true); NotificationContentStore.enabled(fixture, true);
            Notification n = new Notification.Builder(fixture, "synthetic-content").setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Synthetic transport source").setContentText("Synthetic preview").setShortcutId("fixture-source").build();
            NotificationContent.Result sample = NotificationContent.inspect(fixture, NotificationReadiness.PACKAGE, () -> n, true, true,
                "57b2dd91-cfa8-4193-9a38-e2d6d6470625", new byte[32], 0, "POSTED", true);
            check(sample.document != null); NotificationJournal.clear(fixture); NotificationJournal.append(fixture, sample.document, true);
            AtomicBoolean authorized = new AtomicBoolean(true);
            server = CompanionServer.fixture(fixture, authorized::get);
            JSONObject pair = server.fixturePairing(); String token = pair.getString("token"), pin = pair.getString("certificate_sha256");
            check(token.matches("[0-9a-f]{64}") && pin.matches("[0-9a-f]{64}"));
            String response = request(pair, token, "", pin);
            check(response.startsWith("HTTP/1.1 200")); check(response.contains("Synthetic preview"));
            check(response.contains("X-Textem-Request-ID: 57b2dd91-cfa8-4193-9a38-e2d6d6470625"));
            if (Arrays.asList(SSLContext.getDefault().getSupportedSSLParameters().getProtocols()).contains("TLSv1.3")) {
                protocol = "TLSv1.3"; check(request(pair, token, "", pin).startsWith("HTTP/1.1 200"));
            }
            path = "/v1/selected-history";
            response = request(pair, token, "", pin); check(response.startsWith("HTTP/1.1 404"));
            SelectedHistory.publish(fixture, SelectedHistoryChecks.sample(), true);
            response = request(pair, token, "", pin); check(response.startsWith("HTTP/1.1 200"));
            check(response.contains("Synthetic older selected text") && response.contains("SYNTHETIC_HISTORY_LIBRARY"));
            check(!response.contains("OTHER_THREAD_SENTINEL"));
            response = request(pair, "bad", "", pin); check(response.startsWith("HTTP/1.1 403") && !response.contains("Synthetic older selected text"));
            path = "/v1/journal";
            response = request(pair, "bad", "", pin); check(response.startsWith("HTTP/1.1 403")); check(!response.contains("Synthetic preview"));
            response = request(pair, token, "Authorization: Bearer " + token + "\r\n", pin); check(response.startsWith("HTTP/1.1 403"));
            refused = false;
            try { request(pair, token, "", String.join("", Collections.nCopies(64, "0"))); } catch (SSLException expected) { refused = true; } check(refused);
            authorized.set(false); response = request(pair, token, "", pin); check(response.isEmpty() || response.startsWith("HTTP/1.1 403"));
            authorized.set(true); NotificationContentStore.enabled(fixture, false);
            response = request(pair, token, "", pin); check(response.isEmpty() || response.startsWith("HTTP/1.1 403"));
            check(!new File(directory, SelectedHistory.FILE).exists());
            NotificationContentStore.enabled(fixture, true); NotificationJournal.append(fixture, sample.document, true);
            server.closeFixture(); server = CompanionServer.fixture(fixture, authorized::get);
            JSONObject again = server.fixturePairing(); check(again.getString("token").equals(token));
            check(again.getString("certificate_sha256").equals(pin)); check(again.getInt("port") == pair.getInt("port"));
            check(request(again, token, "", pin).startsWith("HTTP/1.1 200"));
            check(server.revokeFixture()); server = CompanionServer.fixture(fixture, authorized::get);
            JSONObject rotated = server.fixturePairing(); check(!rotated.getString("token").equals(token));
            check(request(rotated, token, "", pin).startsWith("HTTP/1.1 403"));
            check(request(rotated, rotated.getString("token"), "", pin).startsWith("HTTP/1.1 200"));
            check(ProviderSource.queryAttempts() == 0 && ProviderSource.mediaAttempts() == 0);
            result.putInt("checks", checks); result.putString("result", "PASS_SYNTHETIC_LOOPBACK_TLS_NO_UI_NO_OWNER_CONTENT"); completion = 0;
        } catch (Exception | AssertionError failure) {
            result.putInt("checks", checks); result.putString("result", "FAIL");
            result.putString("failure_kind", failure instanceof SSLException ? "TLS" : failure instanceof AssertionError ? "ASSERTION" : "IO_OR_FORMAT");
            result.putString("fixture_reason", CompanionServer.fixtureReason(failure));
            result.putString("trust_phase", trustPhase);
            result.putString("server_progress", server == null ? "not_started" : server.fixtureProgress());
            result.putString("server_failure", server == null ? "not_started" : server.fixtureFailure());
        } finally {
            if (server != null) server.closeFixture();
            NotificationJournal.clear(fixture); NotificationContentStore.clear(fixture);
            for (String name : new String[]{"notification-capture", "notification-content", "companion-channel"}) fixture.getSharedPreferences(name, 0).edit().clear().commit();
            try { KeyStore keys = KeyStore.getInstance("AndroidKeyStore"); keys.load(null); keys.deleteEntry("textem-companion-tls-v1-fixture"); keys.deleteEntry("textem-companion-token-v1-fixture"); } catch (Exception ignored) { }
        }
        // finish can terminate the process; cleanup must precede it.
        finish(completion, result);
    }
}

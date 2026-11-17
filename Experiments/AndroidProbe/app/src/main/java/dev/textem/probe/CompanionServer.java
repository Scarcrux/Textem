package dev.textem.probe;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import javax.net.ssl.*;
import javax.security.auth.x500.X500Principal;
import org.json.JSONObject;

/** Explicitly started LAN channel. No Google session, ADB, send API or history scan. */
final class CompanionServer {
    static final String SERVICE_TYPE = "_textem-phone._tcp.";
    private static final String TLS_KEY = "textem-companion-tls-v1", TOKEN_KEY = "textem-companion-token-v1";
    // start() stores only getApplicationContext(); fixture instances never enter
    // this field and are closed by their instrument, so no Activity is retained.
    @android.annotation.SuppressLint("StaticFieldLeak")
    private static CompanionServer active;
    private final Context context;
    private final boolean syntheticFixture;
    private final java.util.function.BooleanSupplier fixtureAccess;
    private final SSLServerSocket listener;
    private final String token;
    private final JSONObject descriptor;
    private final java.util.concurrent.ScheduledExecutorService deadlines = java.util.concurrent.Executors.newSingleThreadScheduledExecutor(task -> {
        Thread thread = new Thread(task, "textem-connection-deadline"); thread.setDaemon(true); return thread;
    });
    private volatile boolean running = true;
    private volatile SSLSocket current;
    private android.net.nsd.NsdManager discovery;
    private android.net.nsd.NsdManager.RegistrationListener registration;
    private volatile String fixtureFailure = "none";
    private final StringBuffer fixtureProgress = new StringBuffer();
    String fixtureProgress() { if (!syntheticFixture) throw new SecurityException(); return fixtureProgress.toString(); }
    String fixtureFailure() { if (!syntheticFixture) throw new SecurityException(); return fixtureFailure; }
    static String fixtureReason(Throwable failure) {
        StringBuilder out = new StringBuilder(failure.getClass().getSimpleName());
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
            java.util.regex.Matcher reasons = java.util.regex.Pattern.compile("\\b[A-Z][A-Z_]{3,}\\b").matcher(String.valueOf(cause.getMessage()));
            while (reasons.find() && out.length() < 512) out.append('/').append(reasons.group());
            // This helper is used only by a synthetic loopback instrument. Keep
            // diagnostic causes, but redact any hex credential/address shape.
            String message = String.valueOf(cause.getMessage()).replaceAll("[0-9a-fA-F]{16,}", "<redacted>")
                .replaceAll("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b", "<address>");
            out.append(':').append(message.substring(0, Math.min(300, message.length())));
        }
        return out.toString();
    }

    static synchronized JSONObject start(Context context) throws Exception {
        if (active != null && active.running) return new JSONObject(active.descriptor.toString());
        if (!CaptureState.enabled(context) || !CaptureState.access(context) || !NotificationContentStore.enabled(context)) throw new SecurityException();
        active = new CompanionServer(context.getApplicationContext(), false, null);
        Thread thread = new Thread(active::serve, "textem-companion-https"); thread.setDaemon(true); thread.start();
        return new JSONObject(active.descriptor.toString());
    }
    static synchronized JSONObject pairing() throws Exception {
        if (active == null || !active.allowed()) throw new IllegalStateException();
        return new JSONObject(active.descriptor.toString());
    }
    static java.net.InetAddress localAddress(Context c) throws Exception {
        android.net.ConnectivityManager manager = c.getSystemService(android.net.ConnectivityManager.class);
        android.net.Network network = manager.getActiveNetwork();
        android.net.NetworkCapabilities caps = manager.getNetworkCapabilities(network);
        android.net.LinkProperties link = manager.getLinkProperties(network);
        if (caps == null || link == null || !caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)
                || caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) throw new IOException();
        java.util.ArrayList<InetAddress> found = new java.util.ArrayList<>();
        for (android.net.LinkAddress item : link.getLinkAddresses()) {
            InetAddress address = item.getAddress();
            if (address instanceof Inet4Address && address.isSiteLocalAddress()) found.add(address);
        }
        if (found.size() != 1) throw new IOException(); return found.get(0);
    }
    static synchronized void reconcile(Context c) throws Exception {
        InetAddress address;
        try { address = localAddress(c); }
        catch (Exception unavailable) { stop(false, c); throw unavailable; }
        if (active != null && active.allowed() && address.equals(active.listener.getInetAddress())) return;
        stop(false, c); start(c);
    }
    // Only a private, fixed cache directory may host a synthetic loopback
    // instrument. It has separate keys/preferences and never enters `active`.
    static CompanionServer fixture(Context c, java.util.function.BooleanSupplier access) throws Exception {
        if (!c.getFilesDir().equals(new File(c.getCacheDir(), "notification-content-controls"))) throw new SecurityException();
        CompanionServer server = new CompanionServer(c, true, access);
        Thread thread = new Thread(server::serve, "textem-fixture-https"); thread.setDaemon(true); thread.start(); return server;
    }
    JSONObject fixturePairing() throws Exception { if (!syntheticFixture) throw new SecurityException(); return new JSONObject(descriptor.toString()); }
    void closeFixture() { if (!syntheticFixture) throw new SecurityException(); close(); }
    boolean revokeFixture() { closeFixture(); return revokeToken(context, true); }
    private void close() {
        running = false; try { listener.close(); } catch (IOException ignored) { }
        try { if (current != null) current.close(); } catch (IOException ignored) { }
        deadlines.shutdownNow();
        if (discovery != null && registration != null) {
            try { discovery.unregisterService(registration); } catch (RuntimeException ignored) { }
        }
    }
    static synchronized boolean stop(boolean revoke, Context context) {
        if (active != null) { active.close(); active = null; }
        if (revoke) CompanionResume.requested(context, false);
        return !revoke || revokeToken(context, false);
    }
    private static boolean revokeToken(Context context, boolean fixture) {
        boolean removed = context.getSharedPreferences("companion-channel", 0).edit().remove("wrapped-token").commit();
        try {
            KeyStore keys = KeyStore.getInstance("AndroidKeyStore"); keys.load(null);
            keys.deleteEntry(TOKEN_KEY + (fixture ? "-fixture" : ""));
            return removed;
        } catch (Exception failure) { return false; }
    }
    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(); for (byte b : bytes) out.append(String.format(Locale.ROOT, "%02x", b & 255)); return out.toString();
    }
    private static String token(Context c, KeyStore keys, String alias) throws Exception {
        if (!keys.containsAlias(alias)) {
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        javax.crypto.SecretKey key = (javax.crypto.SecretKey) keys.getKey(alias, null);
        android.content.SharedPreferences prefs = c.getSharedPreferences("companion-channel", 0);
        String stored = prefs.getString("wrapped-token", null);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        if (stored != null) {
            byte[] value = Base64.decode(stored, Base64.NO_WRAP);
            if (value.length != 12 + 32 + 16) throw new GeneralSecurityException();
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, Arrays.copyOf(value, 12)));
            return hex(cipher.doFinal(Arrays.copyOfRange(value, 12, value.length)));
        }
        byte[] value = new byte[32]; new SecureRandom().nextBytes(value);
        cipher.init(Cipher.ENCRYPT_MODE, key); byte[] encrypted = cipher.doFinal(value), iv = cipher.getIV();
        ByteArrayOutputStream wrapped = new ByteArrayOutputStream(); wrapped.write(iv); wrapped.write(encrypted);
        if (!prefs.edit().putString("wrapped-token", Base64.encodeToString(wrapped.toByteArray(), Base64.NO_WRAP)).commit()) throw new IOException();
        return hex(value);
    }
    private CompanionServer(Context c, boolean synthetic, java.util.function.BooleanSupplier access) throws Exception {
        context = c; syntheticFixture = synthetic; fixtureAccess = access;
        List<InetAddress> addresses = Collections.singletonList(synthetic ? InetAddress.getByName("127.0.0.1") : localAddress(c));
        final String tlsAlias = TLS_KEY + (synthetic ? "-fixture" : "");
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore"); keys.load(null);
        if (!keys.containsAlias(tlsAlias)) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
            generator.initialize(new KeyGenParameterSpec.Builder(tlsAlias, KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                // Conscrypt hashes the TLS transcript before its private-key
                // upcall and signs it with NONEwithECDSA. Authorize that raw
                // digest operation as well as certificate self-signing SHA256.
                .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                .setCertificateSubject(new X500Principal("CN=Textem Companion"))
                .setCertificateSerialNumber(java.math.BigInteger.ONE)
                .setCertificateNotBefore(new Date(System.currentTimeMillis() - 300000))
                .setCertificateNotAfter(new Date(System.currentTimeMillis() + 3650L * 86400000)).build());
            generator.generateKeyPair();
        }
        final PrivateKey privateKey = (PrivateKey) keys.getKey(tlsAlias, null);
        final X509Certificate certificate = (X509Certificate) keys.getCertificate(tlsAlias);
        X509KeyManager manager = new X509KeyManager() {
            public String[] getClientAliases(String type, java.security.Principal[] issuers) { return null; }
            public String chooseClientAlias(String[] types, java.security.Principal[] issuers, Socket socket) { return null; }
            public String[] getServerAliases(String type, java.security.Principal[] issuers) { return "EC".equals(type) ? new String[]{tlsAlias} : null; }
            public String chooseServerAlias(String type, java.security.Principal[] issuers, Socket socket) {
                if (syntheticFixture) fixtureProgress.append("alias:").append(type).append(';');
                return "EC".equals(type) ? tlsAlias : null;
            }
            public X509Certificate[] getCertificateChain(String alias) { return tlsAlias.equals(alias) ? new X509Certificate[]{certificate} : null; }
            public PrivateKey getPrivateKey(String alias) { return tlsAlias.equals(alias) ? privateKey : null; }
        };
        SSLContext tls = SSLContext.getInstance("TLS"); tls.init(new KeyManager[]{manager}, null, new SecureRandom());
        token = token(c, keys, TOKEN_KEY + (synthetic ? "-fixture" : ""));
        listener = (SSLServerSocket) tls.getServerSocketFactory().createServerSocket();
        listener.setReuseAddress(true);
        List<String> protocols = new ArrayList<>(); for (String protocol : listener.getSupportedProtocols())
            if (protocol.equals("TLSv1.2") || protocol.equals("TLSv1.3")) protocols.add(protocol);
        listener.setEnabledProtocols(protocols.toArray(new String[0]));
        try {
            int port = c.getSharedPreferences("companion-channel", 0).getInt("port", 0);
            if (port != 0 && (port < 1024 || port > 65535)) throw new IOException();
            listener.bind(new InetSocketAddress(addresses.get(0), port), 4);
            if (!c.getSharedPreferences("companion-channel", 0).edit().putInt("port", listener.getLocalPort()).commit()) throw new IOException();
            descriptor = new JSONObject(); descriptor.put("schema", 1); descriptor.put("kind", "TEXTEM_COMPANION_PAIRING");
            descriptor.put("host", addresses.get(0).getHostAddress()); descriptor.put("port", listener.getLocalPort());
            descriptor.put("certificate_sha256", hex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded())));
            descriptor.put("token", token); descriptor.put("install_id", NotificationContentStore.identity(c).install);
            if (!synthetic) advertise(descriptor.getString("certificate_sha256"));
        } catch (Exception failure) { listener.close(); throw failure; }
    }
    private void advertise(String pin) {
        discovery = context.getSystemService(android.net.nsd.NsdManager.class);
        registration = new android.net.nsd.NsdManager.RegistrationListener() {
            public void onRegistrationFailed(android.net.nsd.NsdServiceInfo service, int error) { }
            public void onUnregistrationFailed(android.net.nsd.NsdServiceInfo service, int error) { }
            public void onServiceUnregistered(android.net.nsd.NsdServiceInfo service) { }
            public void onServiceRegistered(android.net.nsd.NsdServiceInfo service) {
                if (!running) try { discovery.unregisterService(this); } catch (RuntimeException ignored) { }
            }
        };
        android.net.nsd.NsdServiceInfo service = new android.net.nsd.NsdServiceInfo();
        service.setServiceName("Textem-" + pin.substring(0, 12)); service.setServiceType(SERVICE_TYPE); service.setPort(listener.getLocalPort());
        try { discovery.registerService(service, android.net.nsd.NsdManager.PROTOCOL_DNS_SD, registration); }
        catch (RuntimeException unavailable) { /* Pinned saved-address access remains available. */ }
    }
    private boolean allowed() {
        return running && CaptureState.enabled(context) && (syntheticFixture ? fixtureAccess.getAsBoolean() : CaptureState.access(context)) && NotificationContentStore.enabled(context);
    }
    private void serve() {
        while (running) {
            java.util.concurrent.ScheduledFuture<?> expiry = null;
            try (SSLSocket socket = (SSLSocket) listener.accept()) {
                expiry = deadlines.schedule(() -> { try { socket.close(); } catch (IOException ignored) { } }, 15, java.util.concurrent.TimeUnit.SECONDS);
                current = socket; socket.setSoTimeout(5000);
                if (syntheticFixture) fixtureProgress.append("handshake;");
                socket.startHandshake();
                if (syntheticFixture) fixtureProgress.append("established;");
                long deadline = android.os.SystemClock.elapsedRealtime() + 5000;
                ByteArrayOutputStream bytes = new ByteArrayOutputStream(); InputStream input = socket.getInputStream();
                int value; String request = "";
                while (bytes.size() < 4096) {
                    long remaining = deadline - android.os.SystemClock.elapsedRealtime();
                    if (remaining <= 0) break;
                    socket.setSoTimeout((int) remaining);
                    value = input.read(); if (value < 0) break;
                    bytes.write(value); request = bytes.toString("US-ASCII"); if (request.endsWith("\r\n\r\n")) break;
                }
                if (!request.endsWith("\r\n\r\n")) continue;
                String[] lines = request.split("\r\n"); Map<String, String> headers = new HashMap<>(); boolean duplicate = false;
                for (int i = 1; i < lines.length; i++) { int separator = lines[i].indexOf(':'); if (separator <= 0) { duplicate = true; break; }
                    String name = lines[i].substring(0, separator).trim().toLowerCase(Locale.ROOT);
                    if (headers.put(name, lines[i].substring(separator + 1).trim()) != null) duplicate = true; }
                String id = headers.getOrDefault("x-textem-request-id", "");
                boolean history = lines[0].equals("GET /v1/selected-history HTTP/1.1");
                boolean authorized = !duplicate && (history || lines[0].equals("GET /v1/journal HTTP/1.1"))
                    && id.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
                    && MessageDigest.isEqual(("Bearer " + token).getBytes(StandardCharsets.US_ASCII),
                        headers.getOrDefault("authorization", "").getBytes(StandardCharsets.US_ASCII));
                byte[] body = new byte[0]; String status = "403 Forbidden";
                long revision = NotificationContentStore.revision(context);
                if (authorized && allowed()) {
                    try {
                        if (history && !syntheticFixture && !SelectedHistory.permission(context)) throw new SecurityException();
                        JSONObject journal = history ? SelectedHistory.read(context) : NotificationJournal.read(context);
                        String expected = history ? (syntheticFixture ? "SYNTHETIC_HISTORY_LIBRARY" : "PHONE_HISTORY_LIBRARY")
                            : (syntheticFixture ? "SYNTHETIC_NOTIFICATION_JOURNAL" : "NOTIFICATION_JOURNAL");
                        if (!journal.getString("kind").equals(expected)) throw new SecurityException();
                        body = journal.toString().getBytes(StandardCharsets.UTF_8);
                        status = body.length <= NotificationJournal.MAX_BYTES && allowed()
                            && NotificationContentStore.revision(context) == revision ? "200 OK" : "403 Forbidden";
                    } catch (Exception absent) { status = "404 Not Found"; }
                }
                if (!status.equals("200 OK")) body = new byte[0];
                if (!allowed() || (history && !syntheticFixture && !SelectedHistory.permission(context)) || NotificationContentStore.revision(context) != revision) continue;
                OutputStream out = socket.getOutputStream();
                out.write(("HTTP/1.1 " + status + "\r\nContent-Type: application/json\r\nX-Textem-Request-ID: " +
                    (authorized ? id : "") + "\r\nContent-Length: " + body.length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                for (int offset = 0; offset < body.length; offset += 16384) {
                    if (!allowed() || (history && !syntheticFixture && !SelectedHistory.permission(context)) || NotificationContentStore.revision(context) != revision) throw new SecurityException();
                    out.write(body, offset, Math.min(16384, body.length - offset));
                }
                out.flush();
            } catch (Exception failure) {
                if (syntheticFixture) fixtureFailure = fixtureReason(failure);
                // Never log payload, token, address or exception text.
            }
            finally { if (expiry != null) expiry.cancel(false); current = null; }
        }
    }
}

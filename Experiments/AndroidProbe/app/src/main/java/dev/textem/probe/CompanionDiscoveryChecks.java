package dev.textem.probe;

import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Emulator-only registration sample; no listener, token, phone identity or content. */
final class CompanionDiscoveryChecks {
    static void run(ProbeAutomation test) throws Exception {
        test.phase("DNS-SD platform accepts and removes the synthetic service type");
        NsdManager manager = test.getTargetContext().getSystemService(NsdManager.class);
        CountDownLatch complete = new CountDownLatch(1), removed = new CountDownLatch(1);
        AtomicBoolean registered = new AtomicBoolean(), done = new AtomicBoolean();
        NsdManager.RegistrationListener listener = new NsdManager.RegistrationListener() {
            public void onServiceRegistered(NsdServiceInfo service) {
                registered.set(true); complete.countDown();
                if (done.get()) try { manager.unregisterService(this); } catch (RuntimeException ignored) { }
            }
            public void onRegistrationFailed(NsdServiceInfo service, int code) { complete.countDown(); }
            public void onUnregistrationFailed(NsdServiceInfo service, int code) { removed.countDown(); }
            public void onServiceUnregistered(NsdServiceInfo service) { removed.countDown(); }
        };
        NsdServiceInfo service = new NsdServiceInfo(); service.setServiceName("Textem-synthetic-" + java.util.UUID.randomUUID().toString().substring(0, 8));
        service.setServiceType(CompanionServer.SERVICE_TYPE); service.setPort(9199);
        try {
            manager.registerService(service, NsdManager.PROTOCOL_DNS_SD, listener);
            test.check(complete.await(8, TimeUnit.SECONDS) && registered.get());
        } finally {
            done.set(true);
            try { manager.unregisterService(listener); removed.await(3, TimeUnit.SECONDS); } catch (RuntimeException ignored) { }
        }
    }
}

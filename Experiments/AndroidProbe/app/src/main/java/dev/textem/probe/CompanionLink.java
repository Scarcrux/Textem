package dev.textem.probe;

import android.app.Activity;
import android.companion.AssociationInfo;
import android.companion.AssociationRequest;
import android.companion.CompanionDeviceManager;
import android.companion.BluetoothDeviceFilter;
import android.content.IntentSender;
import android.os.Build;
import java.util.function.Consumer;

/** Public OS association flow. No role/profile grants or automatic approval. */
final class CompanionLink {
    static final String DISPLAY_NAME = "Textem Mac";
    enum State { UNSUPPORTED, NOT_LINKED, WAITING_FOR_APPROVAL, LINKED, UNAVAILABLE }
    interface Callback {
        void pending(IntentSender approval);
        void created();
        void failed();
    }
    interface Gateway {
        boolean supported();
        int[] ownedAssociations();
        void request(Callback callback);
        void remove(int id);
    }
    private final Gateway gateway;
    private boolean pending, failed;
    CompanionLink(Gateway gateway) { this.gateway = gateway; }
    CompanionLink(Activity activity) { this(new AndroidGateway(activity)); }
    State state() {
        try {
            if (!gateway.supported()) return State.UNSUPPORTED;
            if (failed) return State.UNAVAILABLE;
            // A callback is not proof that the OS persisted the association.
            if (gateway.ownedAssociations().length > 0) return State.LINKED;
            return pending ? State.WAITING_FOR_APPROVAL : State.NOT_LINKED;
        } catch (RuntimeException unavailable) { return State.UNAVAILABLE; }
    }
    void request(Consumer<IntentSender> presentApproval, Runnable changed) {
        State current = state();
        if (pending || current == State.LINKED || current == State.UNSUPPORTED) return;
        failed = false; pending = true; changed.run();
        try {
            gateway.request(new Callback() {
                public void pending(IntentSender approval) {
                    try { presentApproval.accept(approval); }
                    catch (RuntimeException unavailable) { failed(); }
                }
                public void created() { pending = false; failed = false; changed.run(); }
                public void failed() { pending = false; failed = true; changed.run(); }
            });
        } catch (RuntimeException unavailable) { pending = false; failed = true; changed.run(); }
    }
    void remove(Runnable changed) {
        try {
            for (int id : gateway.ownedAssociations()) gateway.remove(id);
            failed = false;
        } catch (RuntimeException unavailable) { failed = true; }
        changed.run();
    }
    private static final class AndroidGateway implements Gateway {
        private final Activity activity;
        AndroidGateway(Activity activity) { this.activity = activity; }
        private CompanionDeviceManager manager() { return activity.getSystemService(CompanionDeviceManager.class); }
        public boolean supported() {
            return Build.VERSION.SDK_INT >= 33 && activity.getPackageManager()
                .hasSystemFeature(android.content.pm.PackageManager.FEATURE_COMPANION_DEVICE_SETUP) && manager() != null;
        }
        public int[] ownedAssociations() {
            if (Build.VERSION.SDK_INT < 33) return new int[0];
            // getMyAssociations is scoped by Android to this package/user. Do not
            // claim or remove another app's or another kind of device association.
            java.util.Set<String> ids = activity.getSharedPreferences("mac-companion", 0)
                .getStringSet("associations", java.util.Collections.emptySet());
            return manager().getMyAssociations().stream()
                .filter(info -> ids.contains(Integer.toString(info.getId())))
                .mapToInt(AssociationInfo::getId).toArray();
        }
        public void request(Callback callback) {
            if (Build.VERSION.SDK_INT < 33) throw new IllegalStateException();
            AssociationRequest request = new AssociationRequest.Builder()
                .addDeviceFilter(new BluetoothDeviceFilter.Builder().build()).setSingleDevice(false).build();
            manager().associate(request, activity.getMainExecutor(), new CompanionDeviceManager.Callback() {
                @Override public void onAssociationPending(IntentSender approval) { callback.pending(approval); }
                @Override public void onAssociationCreated(AssociationInfo association) {
                    // Only remember the OS-created association for this flow;
                    // framework enumeration must still confirm it before LINKED.
                    android.content.SharedPreferences prefs = activity.getSharedPreferences("mac-companion", 0);
                    java.util.Set<String> ids = new java.util.HashSet<>(prefs.getStringSet("associations", java.util.Collections.emptySet()));
                    ids.add(Integer.toString(association.getId()));
                    if (prefs.edit().putStringSet("associations", ids).commit()) callback.created(); else callback.failed();
                }
                @Override public void onFailure(CharSequence ignored) { callback.failed(); }
            });
        }
        public void remove(int id) {
            if (Build.VERSION.SDK_INT < 33) throw new IllegalStateException();
            manager().disassociate(id);
            android.content.SharedPreferences prefs = activity.getSharedPreferences("mac-companion", 0);
            java.util.Set<String> ids = new java.util.HashSet<>(prefs.getStringSet("associations", java.util.Collections.emptySet()));
            ids.remove(Integer.toString(id)); prefs.edit().putStringSet("associations", ids).apply();
        }
    }
}

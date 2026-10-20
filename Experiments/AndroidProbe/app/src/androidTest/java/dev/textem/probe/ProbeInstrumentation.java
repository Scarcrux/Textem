package dev.textem.probe;

/** The emulator gate still refuses a pregranted installation. */
public final class ProbeInstrumentation extends ProbeAutomation {
    @Override protected boolean requireDeniedPermission() { return true; }
}

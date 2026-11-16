package dev.textem.probe;

import android.content.Context;

/** A saved token is not consent to resume. Only the explicit Start writes this flag. */
final class CompanionResume {
    static boolean enabled(Context c) { return c.getSharedPreferences("companion-channel", 0).getBoolean("resume-enabled", false); }
    static boolean requested(Context c, boolean enabled) {
        return c.getSharedPreferences("companion-channel", 0).edit().putBoolean("resume-enabled", enabled).commit();
    }
    static boolean allowed(Context c, boolean capture, boolean access, boolean content, boolean notifications) {
        return enabled(c) && capture && access && content && notifications;
    }
}

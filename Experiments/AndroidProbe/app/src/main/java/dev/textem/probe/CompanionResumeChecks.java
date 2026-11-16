package dev.textem.probe;

import android.content.Context;
import android.content.ContextWrapper;

final class CompanionResumeChecks {
    static void run(ProbeAutomation test) throws Exception {
        test.phase("only an explicit durable Start authorizes lifecycle resume");
        Context fixture = new ContextWrapper(test.getTargetContext()) {
            @Override public android.content.SharedPreferences getSharedPreferences(String name, int mode) {
                return super.getSharedPreferences("resume-fixture-" + name, mode);
            }
        };
        try {
            fixture.getSharedPreferences("companion-channel", 0).edit().clear().commit();
            fixture.getSharedPreferences("companion-channel", 0).edit().putString("wrapped-token", "synthetic-existing-token").commit();
            test.check(!CompanionResume.enabled(fixture));
            test.check(!CompanionResume.allowed(fixture, true, true, true, true));
            test.check(CompanionResume.requested(fixture, true));
            test.check(CompanionResume.allowed(fixture, true, true, true, true));
            test.check(!CompanionResume.allowed(fixture, false, true, true, true));
            test.check(!CompanionResume.allowed(fixture, true, false, true, true));
            test.check(!CompanionResume.allowed(fixture, true, true, false, true));
            test.check(!CompanionResume.allowed(fixture, true, true, true, false));
            test.check(CompanionResume.requested(fixture, false));
            test.check(!CompanionResume.allowed(fixture, true, true, true, true));
        } finally { fixture.getSharedPreferences("companion-channel", 0).edit().clear().commit(); }
    }
}

package dev.textem.probe;

import android.content.pm.ProviderInfo;
import android.net.Uri;

/** Finite categories only. Never retain an authority, package name or any URI part. */
final class ShareSourceDiagnostics {
    enum Policy { NOT_CHECKED, ALLOWED, NON_CONTENT, AUTHORITY_NOT_ALLOWED,
        USER_INFO_PRESENT, PORT_PRESENT, FRAGMENT_PRESENT, LENGTH_LIMIT, MULTIPLE }
    enum Owner { NOT_CHECKED, GOOGLE_MESSAGES, OTHER_APP, UNRESOLVED, UNAVAILABLE, MULTIPLE }
    enum Access { NOT_CHECKED, PRIVATE_GRANT_CAPABLE, EXPORTED, PRIVATE_NO_GRANTS,
        UNRESOLVED, UNAVAILABLE, MULTIPLE }
    enum Grant { NOT_CHECKED, GRANTED, DENIED, UNAVAILABLE, MULTIPLE }
    static final class Metadata {
        final Owner owner;
        final Access access;
        final Grant grant;
        Metadata(Owner owner, Access access, Grant grant) {
            this.owner = owner; this.access = access; this.grant = grant;
        }
        static Metadata unavailable() { return new Metadata(Owner.UNAVAILABLE, Access.UNAVAILABLE, Grant.UNAVAILABLE); }
    }
    Policy policy = Policy.NOT_CHECKED;
    Owner owner = Owner.NOT_CHECKED;
    Access access = Access.NOT_CHECKED;
    Grant grant = Grant.NOT_CHECKED;
    private int samples;

    static Policy policy(Uri uri) {
        if (uri == null || uri.toString().length() > 4096) return Policy.LENGTH_LIMIT;
        if (!"content".equals(uri.getScheme())) return Policy.NON_CONTENT;
        if (uri.getUserInfo() != null) return Policy.USER_INFO_PRESENT;
        if (uri.getPort() != -1) return Policy.PORT_PRESENT;
        if (uri.getFragment() != null) return Policy.FRAGMENT_PRESENT;
        return ShareProbeEngine.knownMediaUri(uri) ? Policy.ALLOWED : Policy.AUTHORITY_NOT_ALLOWED;
    }
    static boolean metadataEligible(Uri uri) {
        if (uri == null || uri.toString().length() > 4096 || !"content".equals(uri.getScheme())
                || uri.getUserInfo() != null || uri.getPort() != -1 || uri.getFragment() != null) return false;
        String authority = uri.getAuthority();
        // No user/profile prefixes, percent escapes or arbitrary source text sent to PackageManager.
        return authority != null && authority.length() <= 255 && authority.matches("[A-Za-z0-9_.-]+");
    }
    static Metadata classify(ProviderInfo info, Grant grant) {
        if (info == null) return new Metadata(Owner.UNRESOLVED, Access.UNRESOLVED, grant);
        return new Metadata("com.google.android.apps.messaging".equals(info.packageName)
            ? Owner.GOOGLE_MESSAGES : Owner.OTHER_APP,
            info.exported ? Access.EXPORTED : info.grantUriPermissions
                ? Access.PRIVATE_GRANT_CAPABLE : Access.PRIVATE_NO_GRANTS, grant);
    }
    void inspect(Uri uri, ShareProbeEngine.Source source) {
        Policy nextPolicy = policy(uri);
        Metadata metadata = new Metadata(Owner.NOT_CHECKED, Access.NOT_CHECKED, Grant.NOT_CHECKED);
        if (metadataEligible(uri)) {
            try {
                metadata = source.describe(uri);
                if (metadata == null || metadata.owner == null || metadata.access == null || metadata.grant == null)
                    metadata = Metadata.unavailable();
            } catch (RuntimeException unavailable) { metadata = Metadata.unavailable(); }
        }
        policy = samples == 0 || policy == nextPolicy ? nextPolicy : Policy.MULTIPLE;
        owner = samples == 0 || owner == metadata.owner ? metadata.owner : Owner.MULTIPLE;
        access = samples == 0 || access == metadata.access ? metadata.access : Access.MULTIPLE;
        grant = samples == 0 || grant == metadata.grant ? metadata.grant : Grant.MULTIPLE;
        samples++;
    }
    boolean valid(int uris) {
        if (policy == null || owner == null || access == null || grant == null) return false;
        if (uris == 0 && (policy != Policy.NOT_CHECKED || owner != Owner.NOT_CHECKED
                || access != Access.NOT_CHECKED || grant != Grant.NOT_CHECKED)) return false;
        if (uris < 2 && (policy == Policy.MULTIPLE || owner == Owner.MULTIPLE
                || access == Access.MULTIPLE || grant == Grant.MULTIPLE)) return false;
        if (policy == Policy.NOT_CHECKED && (owner != Owner.NOT_CHECKED
                || access != Access.NOT_CHECKED || grant != Grant.NOT_CHECKED)) return false;
        if ((owner == Owner.UNRESOLVED) != (access == Access.UNRESOLVED)) return false;
        if ((owner == Owner.UNAVAILABLE) != (access == Access.UNAVAILABLE)) return false;
        if ((owner == Owner.NOT_CHECKED) != (access == Access.NOT_CHECKED)) return false;
        if (owner == Owner.NOT_CHECKED && grant != Grant.NOT_CHECKED) return false;
        if (owner != Owner.NOT_CHECKED && grant == Grant.NOT_CHECKED) return false;
        if (policy == Policy.ALLOWED && owner == Owner.NOT_CHECKED) return false;
        if (policy != Policy.NOT_CHECKED && policy != Policy.ALLOWED
                && policy != Policy.AUTHORITY_NOT_ALLOWED && policy != Policy.MULTIPLE
                && owner != Owner.NOT_CHECKED) return false;
        return true;
    }
    String summary(boolean readFlag) {
        return "\nURI rule: " + policy + "; provider owner: " + owner
            + "\nProvider access: " + access + "; explicit read grant: " + grant
            + "; share read flag: " + readFlag
            + "\nCategories only; no source names or addresses retained. UNRESOLVED can mean hidden by Android package visibility."
            + "\nDiagnostics do not relax the allowlist or authorize a content read.";
    }
}

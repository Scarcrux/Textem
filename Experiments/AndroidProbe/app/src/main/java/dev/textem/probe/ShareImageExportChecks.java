package dev.textem.probe;

import android.content.Context;
import android.content.Intent;
import android.view.View;
import android.widget.TextView;
import java.io.File;
import java.nio.file.Files;
import java.security.MessageDigest;
import org.json.JSONObject;

/** Export controls are isolated in cache; never overwrite a pending owner image. */
final class ShareImageExportChecks {
    static void run(ProbeAutomation i) throws Exception {
        i.phase("canonical image export, digest, private files and synthetic isolation");
        Context c = i.getTargetContext(); ShareImageExport.clear(c, true);
        int realOpens = SharedImageSource.opens();
        ShareProbeEngine.Input input = ShareProbeEngine.parse(ShareFixtures.intent("image"));
        ShareFixtures positive = new ShareFixtures("image");
        i.check(ShareImageExport.save(c, input, positive, true));
        JSONObject first = ShareImageExport.manifest(c, true);
        i.check(first.length() == 10 && first.getString("kind").equals("SYNTHETIC_IMAGE")
            && first.getString("mime").equals("image/png") && first.getInt("schema") == 1);
        File root = new File(c.getCacheDir(), "share-export-controls");
        byte[] png = Files.readAllBytes(new File(root, first.getString("filename")).toPath());
        i.check(png.length == first.getInt("bytes") && png.length <= ShareProbeEngine.BYTE_LIMIT
            && first.getInt("width") > 0 && first.getInt("width") <= 2048 && first.getInt("height") <= 2048);
        StringBuilder hash = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(png)) hash.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
        i.check(hash.toString().equals(first.getString("sha256")));
        i.check((android.system.Os.stat(new File(root, ShareImageExport.MANIFEST).getPath()).st_mode & 0777) == 0600);
        i.check((android.system.Os.stat(new File(root, first.getString("filename")).getPath()).st_mode & 0777) == 0600);
        i.check(positive.opens == 1 && positive.closes == 1);
        i.check(!first.toString().contains("content://") && !first.toString().contains("PRIVATE_PATH"));
        ShareFixtures expands = new ShareFixtures("png-too-large");
        i.check(ShareProbeEngine.inspect(input, expands).state == ShareProbeEngine.State.IMAGE_READABLE);
        i.check(expands.bytesRead > 0 && expands.bytesRead < ShareProbeEngine.BYTE_LIMIT);
        for (String mode : new String[] {"denied", "untrusted", "corrupt", "oversized", "text", "png-too-large"}) {
            i.check(!ShareImageExport.save(c, ShareProbeEngine.parse(ShareFixtures.intent(mode)), new ShareFixtures(mode), true));
            i.check(ShareImageExport.manifest(c, true).getString("id").equals(first.getString("id")));
        }
        i.check(!ShareImageExport.save(c, input, new ShareFixtures("image"), true, () -> false));
        i.check(ShareImageExport.manifest(c, true).getString("id").equals(first.getString("id")));
        Intent multiple = ShareFixtures.intent("image");
        multiple.setClipData(android.content.ClipData.newRawUri("synthetic", ShareFixtures.uri(2)));
        ShareFixtures rejected = new ShareFixtures("image");
        i.check(!ShareImageExport.save(c, ShareProbeEngine.parse(multiple), rejected, true) && rejected.opens == 0);
        i.check(ShareImageExport.save(c, input, new ShareFixtures("image"), true));
        i.check(!ShareImageExport.manifest(c, true).getString("filename").equals(first.getString("filename")));
        i.check(ShareImageExport.save(c, input, new ShareFixtures("wide-export"), true));
        i.check(ShareImageExport.manifest(c, true).getInt("width") <= 2048);
        ShareImageExport.clear(c, true);
        i.check(!new File(root, ShareImageExport.MANIFEST).exists());

        i.phase("actual explicit Save image for Mac UI and separate remove action");
        ShareProbeActivity activity = ShareProbeChecks.launch(i, "image");
        i.runOnMainSync(() -> activity.findViewById(android.R.id.content).findViewWithTag("save-mac-image").performClick());
        i.check(activity.awaitIdle());
        i.check(ShareImageExport.manifest(c, true).getString("kind").equals("SYNTHETIC_IMAGE"));
        i.runOnMainSync(() -> {
            View rootView = activity.findViewById(android.R.id.content);
            i.check(((TextView) rootView.findViewWithTag("share-status")).getText().toString().startsWith("SYNTHETIC PNG saved"));
            rootView.findViewWithTag("remove-mac-image").performClick();
            i.check(!new File(root, ShareImageExport.MANIFEST).exists());
            rootView.findViewWithTag("clear-share").performClick();
        });
        i.check(SharedImageSource.opens() == realOpens);
    }
}

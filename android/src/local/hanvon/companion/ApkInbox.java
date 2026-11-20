package local.hanvon.companion;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import java.io.File;
import java.io.FileOutputStream;
import java.util.Locale;
import java.util.UUID;

final class ApkInbox {
    private static final long MAX_APK = 1024L * 1024 * 1024;

    static final class Pending {
        final String token;
        final String name;
        final String packageName;

        Pending(String token, String name, String packageName) {
            this.token = token;
            this.name = name;
            this.packageName = packageName;
        }
    }

    static void stage(Context context, String name, LanServer.Request request) throws Exception {
        SharedTree.validateName(name);
        if (!name.toLowerCase(Locale.ROOT).endsWith(".apk") || request.length == 0 || request.length > MAX_APK) {
            throw new LanServer.Problem(400, "请选择 1 GiB 以内的单个 APK");
        }
        if (pending(context) != null) throw new LanServer.Problem(409, "电纸书上还有一个待处理的安装请求");
        String token = UUID.randomUUID().toString();
        File file = file(context, token);
        File directory = file.getParentFile();
        if (!directory.isDirectory() && !directory.mkdirs()) throw new java.io.IOException("Cannot create APK inbox");
        boolean valid = false;
        try {
            try (FileOutputStream output = new FileOutputStream(file)) { request.copyBody(output); }
            PackageInfo info = context.getPackageManager().getPackageArchiveInfo(file.getAbsolutePath(), 0);
            if (info == null) throw new LanServer.Problem(400, "Android 无法解析这个 APK");
            if (!prefs(context).edit().putString("token", token).putString("name", name)
                .putString("package", info.packageName).commit()) throw new java.io.IOException("Cannot save APK request");
            valid = true;
        } finally {
            if (!valid) file.delete();
        }
    }

    static synchronized Pending pending(Context context) {
        SharedPreferences prefs = prefs(context);
        String token = prefs.getString("token", null);
        if (token == null || !file(context, token).isFile()) return null;
        return new Pending(token, prefs.getString("name", "APK"), prefs.getString("package", ""));
    }

    static synchronized void clear(Context context) {
        Pending pending = pending(context);
        if (pending != null) file(context, pending.token).delete();
        prefs(context).edit().clear().apply();
    }

    static File file(Context context, String token) {
        return new File(new File(context.getFilesDir(), "apk-inbox"), token + ".apk");
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences("apk-inbox", Context.MODE_PRIVATE);
    }
}

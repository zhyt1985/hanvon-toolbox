package local.hanvon.companion;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

public final class MainActivity extends Activity {
    private static final int CHOOSE_FOLDER = 10;
    private static final int INSTALLER = 11;
    private static final int INSTALL_PERMISSION = 12;
    private static final int CHOOSE_NOTES = 20;
    private static final int CHOOSE_FILES = 21;
    private static final int TREE_GRANTS = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;

    private final Runnable wirelessObserver = this::render;
    private boolean showingInstaller;
    private TextView rootStatus;
    private TextView connectionStatus;
    private TextView pendingStatus;
    private Button toggle;
    private Button install;
    private Button discard;
    private Button unpair;
    private PairedMacs pairedMacs;
    private ContentSources contentSources;
    private LinearLayout contentPanel;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        pairedMacs = new PairedMacs(this);
        contentSources = new ContentSources(this);
        showingInstaller = state != null && state.getBoolean("showingInstaller");
        ScrollView scroll = new ScrollView(this);
        LinearLayout contents = new LinearLayout(this);
        contents.setOrientation(LinearLayout.VERTICAL);
        int margin = Math.round(22 * getResources().getDisplayMetrics().density);
        contents.setPadding(margin, margin, margin, margin);
        scroll.setBackgroundColor(Color.WHITE);
        scroll.addView(contents);
        TextView title = addText(contents, "汉王工具箱伴侣", 28);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);

        rootStatus = addText(contents, "", 18);
        addButton(contents, "选择共享目录", this::selectDirectory);
        toggle = addButton(contents, "开启无线管理", this::toggleServer);
        connectionStatus = addText(contents, "", 19);
        connectionStatus.setTextIsSelectable(true);
        unpair = addButton(contents, "清除已配对的 Mac", () ->
            new android.app.AlertDialog.Builder(this).setMessage("清除后，已记住的 Mac 需要重新配对。")
                .setNegativeButton("取消", null)
                .setPositiveButton("清除配对", (dialog, which) -> contentAction(() -> {
                    contentSources.clearMacs(); pairedMacs.clear();
                })).show());

        addText(contents, "内容导出 · 只读来源", 22).setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        addText(contents, "与上方文件管理目录分开。添加来源后，在 Mac 点「无线来源」，核对请求编号后允许该 Mac 读取。", 16);
        addButton(contents, "添加笔记来源（只读）", () -> selectContent(CHOOSE_NOTES));
        addButton(contents, "添加文件收集来源（只读）", () -> selectContent(CHOOSE_FILES));
        contentPanel = new LinearLayout(this);
        contentPanel.setOrientation(LinearLayout.VERTICAL);
        contents.addView(contentPanel);

        TextView installerTitle = addText(contents, "APK 安装请求", 22);
        installerTitle.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        pendingStatus = addText(contents, "", 17);
        install = addButton(contents, "打开系统安装器", this::openInstaller);
        discard = addButton(contents, "清除待安装 APK", () -> {
            ApkInbox.clear(this);
            updateInstaller();
        });

        setContentView(scroll);
        render();
    }

    @Override protected void onResume() {
        super.onResume();
        render();
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        state.putBoolean("showingInstaller", showingInstaller);
        super.onSaveInstanceState(state);
    }

    @Override protected void onStart() {
        super.onStart();
        WirelessService.observe(wirelessObserver, this::onAPK);
        render();
    }

    @Override protected void onStop() {
        WirelessService.detach(wirelessObserver);
        super.onStop();
    }

    private void render() {
        Uri tree = grantedTree();
        String folderName = prefs().getString("folderName", "");
        WirelessService.State state = WirelessService.state();
        rootStatus.setText(tree == null
            ? "请选择一个共享子目录。可以在系统文件选择器中新建「汉王工具箱」文件夹。"
            : "已授权目录：" + folderName);
        unpair.setEnabled(pairedMacs.count() > 0);
        toggle.setEnabled(state.running || tree != null);
        toggle.setText(state.running ? "停止无线管理" : "开启无线管理");
        if (state.address != null) {
            connectionStatus.setText("Mac 工具箱 → 无线管理\n\n地址  " + state.address
                + "\n设备指纹  " + state.pin + "\n配对码  " + state.code
                + "\n已记住 " + pairedMacs.count() + " 台 Mac"
                + "\n无线管理可在后台运行，可从通知栏停止。"
                + (state.discoveryFailed ? "\n自动发现暂不可用，可在 Mac 上手动输入地址。" : ""));
        } else {
            connectionStatus.setText(state.message);
        }
        updateInstaller();
        renderContent();
    }

    private interface ContentAction { void run() throws Exception; }
    private void contentAction(ContentAction action) {
        try { action.run(); render(); }
        catch (Exception failure) { connectionStatus.setText("内容来源操作未完成：" + failure.getMessage()); }
    }

    private void selectContent(int request) {
        Intent select = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        try { startActivityForResult(select, request); }
        catch (RuntimeException failure) { connectionStatus.setText("系统未能打开内容来源选择器"); }
    }

    private void renderContent() {
        if (contentPanel == null) return;
        contentPanel.removeAllViews();
        try {
            JSONArray sources = contentSources.localSources();
            if (sources.length() == 0) addText(contentPanel, "尚未设置内容来源。只访问你选择的目录，不读取其他应用私有数据。", 16);
            for (int i=0;i<sources.length();i++) {
                JSONObject source = sources.getJSONObject(i);
                String id = source.getString("id");
                addText(contentPanel, source.getString("name") + " · "
                    + ("notes".equals(source.getString("kind")) ? "笔记来源" : "文件收集")
                    + " · 已授权 " + source.getJSONArray("grants").length() + " 台 Mac", 17);
                addButton(contentPanel, "撤销此来源的 Mac 访问", () ->
                    new android.app.AlertDialog.Builder(this).setMessage("所有 Mac 将停止通过内容导出读取此来源。设备原文件和原文件管理授权保留。")
                        .setNegativeButton("取消", null).setPositiveButton("撤销访问", (d,w) -> contentAction(() -> contentSources.revoke(id))).show());
                addButton(contentPanel, "移除此内容来源", () ->
                    new android.app.AlertDialog.Builder(this).setMessage("移除来源和相关读取授权，不删除目录或内容，也不改变文件管理目录。")
                        .setNegativeButton("取消", null).setPositiveButton("移除来源", (d,w) -> contentAction(() -> contentSources.remove(id))).show());
            }
            JSONArray pending = contentSources.pending();
            for (int i=0;i<pending.length();i++) {
                JSONObject request = pending.getJSONObject(i);
                String id = request.getString("id"), code = request.getString("code");
                String label = request.getString("sourceName");
                addText(contentPanel, "Mac 只读请求 · 编号 " + code + "\n来源：" + label, 20);
                addButton(contentPanel, "核对并允许请求 " + code, () ->
                    new android.app.AlertDialog.Builder(this).setTitle("允许这台 Mac 只读访问？")
                        .setMessage("请确认 Mac 显示相同编号 " + code + "。\n来源：" + label + "\n确认后可读取索引、正文及附件，直到撤销访问。")
                        .setNegativeButton("取消", null).setPositiveButton("允许只读访问", (d,w) -> contentAction(() -> contentSources.decide(id,true))).show());
                addButton(contentPanel, "拒绝请求 " + code, () -> contentAction(() -> contentSources.decide(id,false)));
            }
        } catch (Exception failure) { addText(contentPanel, "内容来源设置暂不可用，请重开伴侣应用后重试。", 16); }
    }

    private void selectDirectory() {
        Intent select = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .addFlags(TREE_GRANTS | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        try {
            startActivityForResult(select, CHOOSE_FOLDER);
        } catch (RuntimeException error) {
            connectionStatus.setText("系统没有打开共享目录选择器。");
        }
    }

    private void toggleServer() {
        if (WirelessService.state().running) {
            WirelessService.stop(this);
        } else if (grantedTree() != null) {
            try {
                WirelessService.start(this);
            } catch (RuntimeException failure) {
                connectionStatus.setText("系统未能开启无线管理服务，请重试。");
            }
        }
    }

    private void onAPK() {
        updateInstaller();
        if (hasWindowFocus() && getPackageManager().canRequestPackageInstalls()) openInstaller();
    }

    private void updateInstaller() {
        ApkInbox.Pending pending = ApkInbox.pending(this);
        pendingStatus.setText(pending == null
            ? "没有待处理的 APK。"
            : pending.name + "\n" + pending.packageName + "\n请在系统安装界面确认。");
        install.setVisibility(pending == null ? View.GONE : View.VISIBLE);
        discard.setVisibility(pending == null ? View.GONE : View.VISIBLE);
        install.setEnabled(!showingInstaller);
        discard.setEnabled(!showingInstaller);
        install.setText(getPackageManager().canRequestPackageInstalls() ? "打开系统安装器" : "允许来自此来源的安装");
    }

    private void openInstaller() {
        ApkInbox.Pending pending = ApkInbox.pending(this);
        if (pending == null || showingInstaller) return;
        if (!getPackageManager().canRequestPackageInstalls()) {
            try {
                startActivityForResult(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + getPackageName())), INSTALL_PERMISSION);
            } catch (RuntimeException error) {
                pendingStatus.setText("系统未提供此来源的安装权限入口。");
            }
            return;
        }
        Uri uri = new Uri.Builder().scheme("content").authority(ApkProvider.AUTHORITY)
            .appendPath("apk").appendPath(pending.token).build();
        Intent intent = new Intent(Intent.ACTION_VIEW).setDataAndType(uri, ApkProvider.MIME)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        intent.putExtra(Intent.EXTRA_RETURN_RESULT, true);
        intent.setClipData(ClipData.newRawUri("APK", uri));
        try {
            showingInstaller = true;
            updateInstaller();
            startActivityForResult(intent, INSTALLER);
        } catch (RuntimeException error) {
            showingInstaller = false;
            updateInstaller();
            pendingStatus.setText("系统未能打开 APK 安装界面。");
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if ((request == CHOOSE_NOTES || request == CHOOSE_FILES) && result == RESULT_OK && data != null && data.getData() != null) {
            contentAction(() -> {
                if ((data.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) == 0) throw new SecurityException("请选择可读目录");
                Uri uri = data.getData();
                getContentResolver().takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
                contentSources.add(uri, request == CHOOSE_NOTES ? "notes" : "files");
            });
            return;
        }
        if (request == INSTALL_PERMISSION) {
            updateInstaller();
            if (getPackageManager().canRequestPackageInstalls()) openInstaller();
        } else if (request == INSTALLER) {
            showingInstaller = false;
            if (result == RESULT_OK) ApkInbox.clear(this);
            updateInstaller();
        } else if (request == CHOOSE_FOLDER && result == RESULT_OK && data != null && data.getData() != null) {
            authorize(data);
        }
    }

    private void authorize(Intent data) {
        Uri selected = data.getData();
        Uri previous = grantedTree();
        if ((data.getFlags() & TREE_GRANTS) != TREE_GRANTS) {
            connectionStatus.setText("请选择可读写的共享目录。");
            return;
        }
        try {
            getContentResolver().takePersistableUriPermission(selected, TREE_GRANTS);
            String name = new SharedTree(this, selected).name();
            if (previous == null || !previous.equals(selected)) WirelessService.stop(this);
            prefs().edit().putString("tree", selected.toString()).putString("folderName", name).apply();
            if (previous != null && !previous.equals(selected)) {
                try { getContentResolver().releasePersistableUriPermission(previous,
                    contentSources.uses(previous) ? Intent.FLAG_GRANT_WRITE_URI_PERMISSION : TREE_GRANTS); }
                catch (SecurityException ignored) {}
            }
            render();
        } catch (Exception failure) {
            connectionStatus.setText("无法读取授权目录。请在内置存储中选择一个可读写的子目录。");
        }
    }

    private SharedPreferences prefs() { return WirelessService.preferences(this); }

    private Uri grantedTree() {
        String saved = prefs().getString("tree", null);
        return saved == null ? null : Uri.parse(saved);
    }

    private TextView addText(LinearLayout contents, String label, int size) {
        TextView text = new TextView(this);
        text.setText(label);
        text.setTextColor(Color.BLACK);
        text.setTextSize(size);
        text.setPadding(0, 14, 0, 12);
        contents.addView(text);
        return text;
    }

    private Button addButton(LinearLayout contents, String label, Runnable click) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextSize(18);
        button.setAllCaps(false);
        button.setOnClickListener(view -> click.run());
        contents.addView(button);
        return button;
    }
}

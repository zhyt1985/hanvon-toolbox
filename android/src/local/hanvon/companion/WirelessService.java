package local.hanvon.companion;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;
import java.io.FileNotFoundException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.util.Objects;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class WirelessService extends Service {
    private static final String CHANNEL = "hanvon-wireless";
    private static final String STOP = "local.hanvon.companion.STOP_WIRELESS";
    private static final int NOTIFICATION = 1;

    static final class State {
        final boolean running;
        final String message;
        final String address;
        final String pin;
        final String code;
        final boolean discoveryFailed;

        State(boolean running, String message, LanServer server, boolean discoveryFailed) {
            this.running = running;
            this.message = message;
            address = server == null ? null : server.address;
            pin = server == null ? null : server.pin;
            code = server == null ? null : server.code;
            this.discoveryFailed = discoveryFailed;
        }
    }

    // The service and activity access these callbacks and snapshots on the main thread.
    private static State snapshot = new State(false, "无线管理未开启", null, false);
    private static Runnable stateObserver;
    private static Runnable apkObserver;

    static State state() { return snapshot; }

    static void observe(Runnable state, Runnable apk) {
        stateObserver = state;
        apkObserver = apk;
    }

    static void detach(Runnable state) {
        if (stateObserver == state) observe(null, null);
    }

    static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences("companion", Context.MODE_PRIVATE);
    }

    static void start(Context context) {
        context.startForegroundService(new Intent(context, WirelessService.class));
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, WirelessService.class));
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Runnable reconcileNetwork = this::reconcileNetwork;
    private final ConnectivityManager.NetworkCallback networkEvents = new ConnectivityManager.NetworkCallback() {
        @Override public void onAvailable(Network network) { scheduleNetworkCheck(); }
        @Override public void onLost(Network network) { scheduleNetworkCheck(); }
        @Override public void onLinkPropertiesChanged(Network network, LinkProperties properties) {
            scheduleNetworkCheck();
        }
    };

    private ConnectivityManager connectivity;
    private PairedMacs pairedMacs;
    private Uri tree;
    private InetAddress address;
    private LanServer server;
    private volatile long generation;
    private boolean running;
    private boolean starting;
    private boolean discoveryFailed;
    private String stopMessage = "无线管理未开启";
    private SharedTree shared; // Accessed only by the worker.

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (running) return START_STICKY;
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel(CHANNEL, "无线管理",
            NotificationManager.IMPORTANCE_LOW));
        startForeground(NOTIFICATION, notification("正在启动无线管理…"));

        String saved = preferences(this).getString("tree", null);
        if (saved == null) {
            stopMessage = "请选择共享目录后再开启无线管理。";
            stopSelf();
            return START_NOT_STICKY;
        }
        tree = Uri.parse(saved);
        pairedMacs = new PairedMacs(this);
        connectivity = getSystemService(ConnectivityManager.class);
        try {
            connectivity.registerNetworkCallback(new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), networkEvents);
        } catch (RuntimeException failure) {
            Log.w("HanvonCompanion", "Cannot watch Wi-Fi", failure);
            stopMessage = "无法监控 Wi-Fi，请重新开启无线管理。";
            stopSelf();
            return START_NOT_STICKY;
        }
        running = true;
        reconcileNetwork();
        return START_STICKY;
    }

    private void scheduleNetworkCheck() {
        main.removeCallbacks(reconcileNetwork);
        main.postDelayed(reconcileNetwork, 350);
    }

    private InetAddress wifiAddress() {
        InetAddress candidate = null;
        for (Network network : connectivity.getAllNetworks()) {
            NetworkCapabilities caps = connectivity.getNetworkCapabilities(network);
            if (caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue;
            LinkProperties properties = connectivity.getLinkProperties(network);
            if (properties == null) continue;
            for (LinkAddress link : properties.getLinkAddresses()) {
                InetAddress ip = link.getAddress();
                if (!(ip instanceof Inet4Address) || ip.isLoopbackAddress()) continue;
                if (ip.equals(address)) return ip;
                if (candidate == null) candidate = ip;
            }
        }
        return candidate;
    }

    private void reconcileNetwork() {
        if (!running) return;
        InetAddress next = wifiAddress();
        if (Objects.equals(next, address) && (starting || server != null)) return;
        if (server != null) server.close();
        server = null;
        address = next;
        starting = next != null;
        discoveryFailed = false;
        long attempt = ++generation;
        if (next == null) {
            publish("等待 Wi-Fi 恢复，恢复后自动连接");
            return;
        }
        publish("正在启动无线管理…");
        worker.execute(() -> startServer(next, attempt));
    }

    private void startServer(InetAddress ip, long attempt) {
        try {
            if (attempt != generation) return;
            if (shared == null) {
                SharedTree pending = new SharedTree(this, tree);
                pending.cleanInterruptedUploads();
                shared = pending;
            }
            if (attempt != generation) return;
            LanServer started = new LanServer(this, ip, shared, pairedMacs,
                () -> main.post(() -> {
                    if (running && attempt == generation) {
                        publish("收到 APK 安装请求");
                        if (apkObserver != null) apkObserver.run();
                    }
                }),
                () -> main.post(() -> {
                    if (running && attempt == generation) publish("无线管理运行中");
                }),
                () -> main.post(() -> {
                    if (running && attempt == generation) {
                        discoveryFailed = true;
                        if (server != null) publish("无线管理运行中");
                    }
                }));
            main.post(() -> {
                if (!running || attempt != generation) { started.close(); return; }
                server = started;
                server.start();
                starting = false;
                publish("无线管理运行中");
            });
        } catch (Exception failure) {
            Log.w("HanvonCompanion", "Start failed", failure);
            main.post(() -> {
                if (!running || attempt != generation) return;
                starting = false;
                if (failure instanceof SecurityException || failure instanceof FileNotFoundException) {
                    stopMessage = "无法访问共享目录，请重新授权。";
                    stopSelf();
                } else {
                    publish("服务暂不可用，正在等待重试");
                    main.removeCallbacks(reconcileNetwork);
                    main.postDelayed(reconcileNetwork, 5000);
                }
            });
        }
    }

    private Notification notification(String message) {
        int flags = PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP), flags);
        PendingIntent stop = PendingIntent.getService(this, 1,
            new Intent(this, WirelessService.class).setAction(STOP), flags);
        return new Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("汉王工具箱伴侣")
            .setContentText(message)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(new Notification.Action.Builder(null, "停止无线管理", stop).build())
            .build();
    }

    private void publish(String message) {
        snapshot = new State(running, message, server, discoveryFailed);
        getSystemService(NotificationManager.class).notify(NOTIFICATION, notification(message));
        if (stateObserver != null) stateObserver.run();
    }

    @Override public void onDestroy() {
        if (running) connectivity.unregisterNetworkCallback(networkEvents);
        running = false;
        ++generation;
        main.removeCallbacks(reconcileNetwork);
        if (server != null) server.close();
        worker.shutdownNow();
        stopForeground(STOP_FOREGROUND_REMOVE);
        snapshot = new State(false, stopMessage, null, false);
        if (stateObserver != null) stateObserver.run();
        super.onDestroy();
    }
}

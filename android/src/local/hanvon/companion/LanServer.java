package local.hanvon.companion;

import android.content.Context;
import android.os.Build;
import android.util.Log;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import org.json.JSONObject;

final class LanServer implements AutoCloseable {
    static final long MAX_BODY = 4L * 1024 * 1024 * 1024;
    private final SSLServerSocket listener;
    private final SharedTree tree;
    private final ResumeStore resumable;
    private final ContentRoutes contentRoutes;
    private final Context context;
    private final Runnable onAPK;
    private final Runnable onPairing;
    private final PairedMacs pairedMacs;
    private final DeviceAdvertisement advertisement;
    private final DiscoverySocket discoverySocket;
    private final String deviceId;
    private final String rootName;
    private final String rootID;
    private volatile Socket active;
    private int failedAuthentications;
    final String pin;
    final String code;
    final String address;

    LanServer(Context context, InetAddress ip, SharedTree tree, PairedMacs pairedMacs,
              Runnable onAPK, Runnable onPairing, Runnable onDiscoveryFailure) throws Exception {
        this.context = context.getApplicationContext();
        this.tree = tree;
        resumable = new ResumeStore(context, tree);
        this.onAPK = onAPK;
        this.onPairing = onPairing;
        this.pairedMacs = pairedMacs;
        rootName = tree.name();
        rootID = tree.identity();
        TlsIdentity tls = new TlsIdentity(context, ip);
        deviceId = tls.deviceId;
        pin = tls.fingerprint;
        code = String.format(Locale.ROOT, "%08d", new SecureRandom().nextInt(100000000));
        listener = (SSLServerSocket) tls.context.getServerSocketFactory().createServerSocket();
        try {
            listener.setUseClientMode(false);
            listener.setEnabledProtocols(new String[] {"TLSv1.2"});
            listener.bind(new InetSocketAddress(ip, 0), 4);
            address = "https://" + ip.getHostAddress() + ":" + listener.getLocalPort();
            DeviceAdvertisement registered = null;
            DiscoverySocket datagrams = null;
            try {
                datagrams = new DiscoverySocket(context, deviceId, listener.getLocalPort());
            } catch (Exception failure) {
                Log.w("HanvonCompanion", "Unable to start datagram discovery", failure);
            }
            boolean hasDatagrams = datagrams != null;
            try {
                registered = new DeviceAdvertisement(context, deviceId, listener.getLocalPort(), () -> {
                    if (!hasDatagrams) onDiscoveryFailure.run();
                });
            } catch (RuntimeException failure) {
                Log.w("HanvonCompanion", "Unable to publish DNS-SD service", failure);
                if (!hasDatagrams) onDiscoveryFailure.run();
            }
            advertisement = registered;
            discoverySocket = datagrams;
            contentRoutes = new ContentRoutes(context, onPairing);
        } catch (Exception failure) {
            listener.close();
            throw failure;
        }
    }

    void start() { new Thread(this::serve, "hanvon-lan").start(); }

    @Override public void close() {
        contentRoutes.close();
        if (advertisement != null) advertisement.close();
        if (discoverySocket != null) discoverySocket.close();
        try { listener.close(); } catch (IOException ignored) {}
        Socket socket = active;
        if (socket != null) try { socket.close(); } catch (IOException ignored) {}
    }

    private void serve() {
        while (!listener.isClosed()) {
            try (SSLSocket socket = (SSLSocket) listener.accept()) {
                active = socket;
                if (listener.isClosed()) return;
                socket.setSoTimeout(20000);
                socket.startHandshake();
                handle(socket);
            } catch (IOException failure) {
                if (!listener.isClosed()) Log.d("HanvonCompanion", "Connection ended: " + failure.getClass().getSimpleName());
            } finally {
                active = null;
            }
        }
    }

    private void handle(Socket socket) throws IOException {
        BufferedInputStream input = new BufferedInputStream(socket.getInputStream());
        BufferedOutputStream output = new BufferedOutputStream(socket.getOutputStream());
        try {
            Request request = Request.read(input);
            if (request == null) return;
            authenticate(request);
            if (request.length > MAX_BODY) throw new Problem(413, "文件大小超过 4 GiB");
            if ("100-continue".equalsIgnoreCase(request.headers.get("expect"))) {
                output.write("HTTP/1.1 100 Continue\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                output.flush();
            }
            dispatch(request, output);
        } catch (Problem failure) {
            error(output, failure.status, failure.getMessage());
        } catch (FileNotFoundException failure) {
            error(output, 404, "未找到所选文件或目录");
        } catch (SecurityException failure) {
            error(output, 403, "请在电纸书上重新授权共享目录");
        } catch (Exception failure) {
            Log.w("HanvonCompanion", "Request failed: " + failure.getClass().getSimpleName());
            error(output, 500, "设备未完成此操作");
        }
    }

    private void authenticate(Request request) throws Problem {
        if (!"POST".equals(request.method) || !"/v1/pair".equals(request.route)) {
            if (!pairedMacs.contains(request.headers.get("x-hanvon-token"))) {
                throw new Problem(401, "配对已失效，请重新配对");
            }
            return;
        }
        if (failedAuthentications >= 8) throw new Problem(429, "请在电纸书上停止并重新开启服务");
        String supplied = request.headers.get("x-hanvon-code");
        if (supplied == null || !MessageDigest.isEqual(
            supplied.getBytes(StandardCharsets.UTF_8), code.getBytes(StandardCharsets.UTF_8))) {
            failedAuthentications++;
            throw new Problem(401, "无线配对码不匹配");
        }
    }

    private void dispatch(Request request, OutputStream output) throws Exception {
        if (request.route.startsWith("/v1/content/")) { contentRoutes.handle(request, output); return; }
        String route = request.method + " " + request.route;
        switch (route) {
            case "POST /v1/pair":
                json(output, 200, new JSONObject().put("id", deviceId).put("token", pairedMacs.add()));
                onPairing.run();
                break;
            case "GET /v1/info":
                json(output, 200, new JSONObject()
                    .put("protocol", 2)
                    .put("id", deviceId)
                    .put("root", rootName)
                    .put("rootID", rootID)
                    .put("recoveryCleanup", true)
                    .put("fileOperations", true)
                    .put("resumableTransfers", true)
                    .put("contentExport", new JSONObject().put("protocol", 1).put("sourceReads", true).put("snapshotDownloads", true).put("maxChunkBytes", ResumeFile.CHUNK))
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("android", Build.VERSION.RELEASE)
                    .put("display", Build.DISPLAY)
                    .put("buildID", Build.ID)
                    .put("incremental", Build.VERSION.INCREMENTAL));
                break;
            case "GET /v1/list":
                json(output, 200, tree.list(request.param("path")));
                break;
            case "GET /v1/file":
                SharedTree.Entry file = tree.file(request.param("path"));
                try (InputStream content = context.getContentResolver().openInputStream(file.uri)) {
                    if (content == null) throw new FileNotFoundException();
                    header(output, 200, "application/octet-stream", file.size);
                    byte[] bytes = new byte[65536];
                    int count;
                    while ((count = content.read(bytes)) != -1) output.write(bytes, 0, count);
                    output.flush();
                }
                break;
            case "POST /v1/folder":
                tree.createFolder(request.param("path"), request.param("name"));
                done(output);
                break;
            case "POST /v1/upload":
                request.requireBodyLength();
                tree.upload(request.param("path"), request.param("name"), request);
                done(output);
                break;
            case "GET /v1/resume/upload/status":
                json(output, 200, resumable.uploadStatus(request));
                break;
            case "POST /v1/resume/upload/chunk":
                json(output, 200, resumable.uploadChunk(request));
                break;
            case "POST /v1/resume/upload/commit":
                json(output, 200, resumable.commit(request));
                break;
            case "GET /v1/resume/download/info":
                json(output, 200, resumable.downloadInfo(request));
                break;
            case "GET /v1/resume/download/chunk":
                byte[] piece = resumable.downloadChunk(request);
                header(output, 200, "application/octet-stream", (long)piece.length);
                output.write(piece); output.flush();
                break;
            case "POST /v1/resume/abort":
                resumable.abort(request); done(output);
                break;
            case "POST /v1/rename":
                tree.rename(request.param("path"), request.param("name"));
                done(output);
                break;
            case "POST /v1/move":
                tree.move(request.param("path"), request.param("target"));
                done(output);
                break;
            case "POST /v1/copy":
                tree.copy(request.param("path"), request.param("target"));
                done(output);
                break;
            case "POST /v1/delete":
                tree.delete(request.param("path"));
                done(output);
                break;
            case "POST /v1/recovery/cleanup":
                boolean removed = tree.cleanupRecovery(request.param("path"), request.param("id"),
                    request.param("original"), request.param("size"), request.param("sha256"));
                json(output, 200, new JSONObject().put("removed", removed));
                break;
            case "POST /v1/apk":
                request.requireBodyLength();
                ApkInbox.stage(context, request.param("name"), request);
                try { done(output); } finally { onAPK.run(); }
                break;
            default:
                throw new Problem(404, "此操作不可用");
        }
    }

    private static void done(OutputStream output) throws Exception {
        json(output, 200, new JSONObject().put("ok", true));
    }

    private static void error(OutputStream output, int status, String message) throws IOException {
        try { json(output, status, new JSONObject().put("error", message)); }
        catch (org.json.JSONException failure) { throw new IOException(failure); }
    }

    static void json(OutputStream output, int status, Object value) throws IOException {
        byte[] data = value.toString().getBytes(StandardCharsets.UTF_8);
        header(output, status, "application/json; charset=utf-8", (long) data.length);
        output.write(data);
        output.flush();
    }

    static void header(OutputStream output, int status, String type, Long length) throws IOException {
        String headers = "HTTP/1.1 " + status + (status < 400 ? " OK" : " Error") + "\r\n"
            + "Content-Type: " + type + "\r\nCache-Control: no-store\r\nConnection: close\r\n"
            + (length == null ? "" : "Content-Length: " + length + "\r\n") + "\r\n";
        output.write(headers.getBytes(StandardCharsets.US_ASCII));
    }

    static final class Problem extends Exception {
        final int status;
        Problem(int status, String message) { super(message); this.status = status; }
    }

    static final class Request {
        final String method;
        final String route;
        final Map<String, String> headers;
        final long length;
        private final Map<String, String> params;
        final InputStream input;

        Request(String method, String route, Map<String, String> headers, long length,
                        Map<String, String> params, InputStream input) {
            this.method = method;
            this.route = route;
            this.headers = headers;
            this.length = length;
            this.params = params;
            this.input = input;
        }

        static Request read(InputStream input) throws IOException, Problem {
            String first = line(input);
            if (first == null) return null;
            String[] parts = first.split(" ", -1);
            if (parts.length != 3 || !parts[1].startsWith("/") || !parts[2].equals("HTTP/1.1")) {
                throw new Problem(400, "请求格式无效");
            }
            Map<String, String> headers = new HashMap<>();
            boolean complete = false;
            for (int i = 0; i < 48; i++) {
                String next = line(input);
                if (next == null) throw new EOFException();
                if (next.isEmpty()) { complete = true; break; }
                int colon = next.indexOf(':');
                if (colon <= 0) throw new Problem(400, "请求头无效");
                String key = next.substring(0, colon).toLowerCase(Locale.ROOT);
                if (headers.put(key, next.substring(colon + 1).trim()) != null) {
                    throw new Problem(400, "重复请求头");
                }
            }
            if (!complete || headers.containsKey("transfer-encoding")) throw new Problem(400, "请求头无效");
            long length;
            try {
                length = headers.containsKey("content-length") ? Long.parseLong(headers.get("content-length")) : -1;
                if (headers.containsKey("content-length") && length < 0) throw new NumberFormatException();
            } catch (NumberFormatException failure) { throw new Problem(400, "请求长度无效"); }

            String[] target = parts[1].split("\\?", 2);
            Map<String, String> params = new HashMap<>();
            if (target.length == 2 && !target[1].isEmpty()) {
                for (String pair : target[1].split("&", -1)) {
                    String[] tokens = pair.split("=", 2);
                    if (tokens.length != 2) throw new Problem(400, "请求参数无效");
                    try {
                        String previous = params.put(URLDecoder.decode(tokens[0], "UTF-8"), URLDecoder.decode(tokens[1], "UTF-8"));
                        if (previous != null) throw new Problem(400, "重复请求参数");
                    } catch (IllegalArgumentException failure) { throw new Problem(400, "请求参数编码无效"); }
                }
            }
            return new Request(parts[0], target[0], headers, length, params, input);
        }

        String param(String name) throws Problem {
            String value = params.get(name);
            if (value == null) throw new Problem(400, "缺少请求参数");
            return value;
        }

        void requireBodyLength() throws Problem {
            if (length < 0) throw new Problem(411, "上传缺少长度");
        }

        void copyBody(OutputStream output) throws IOException {
            byte[] buffer = new byte[65536];
            long remaining = length;
            while (remaining > 0) {
                int count = input.read(buffer, 0, (int) Math.min(remaining, buffer.length));
                if (count == -1) throw new EOFException();
                output.write(buffer, 0, count);
                remaining -= count;
            }
        }

        private static String line(InputStream input) throws IOException, Problem {
            ByteArrayOutputStream result = new ByteArrayOutputStream();
            for (int count = 0; count <= 16384; count++) {
                int value = input.read();
                if (value < 0) {
                    if (count == 0) return null;
                    throw new EOFException();
                }
                if (value == '\r') {
                    if (input.read() != '\n') throw new Problem(400, "请求行无效");
                    return result.toString("US-ASCII");
                }
                if (value < 32 || value >= 127) throw new Problem(400, "请求行无效");
                result.write(value);
            }
            throw new Problem(414, "请求行过长");
        }
    }
}

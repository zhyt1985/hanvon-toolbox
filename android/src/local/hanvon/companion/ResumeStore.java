package local.hanvon.companion;

import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import org.json.JSONObject;

final class ResumeStore {
    private final Context context;
    private final SharedTree tree;
    private final File directory;
    private final String scope;
    ResumeStore(Context context, SharedTree tree) throws Exception {
        this(context, tree, "", new File(context.getFilesDir(), "resumable-transfers"));
    }
    ResumeStore(Context context, SharedTree tree, String scope, File directory) throws Exception {
        this.context = context; this.tree = tree;
        this.scope = scope; this.directory = directory;
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建续传缓存");
        // Receipts and abandoned data expire after seven idle days, including old authorizations.
        File[] files = directory.listFiles();
        if (files != null) for (File file : files) if (System.currentTimeMillis() - file.lastModified() > 7L * 86400000) file.delete();
    }
    private String key(LanServer.Request request) throws Exception {
        String material = request.headers.get("x-hanvon-token") + "/" + scope + tree.identity() + "/" + ResumeFile.id(request.param("id"));
        return ResumeFile.digest(new ByteArrayInputStream(material.getBytes(StandardCharsets.UTF_8)));
    }
    private File data(String key) { return new File(directory, key + ".data"); }
    private File journal(String key) { return new File(directory, key + ".json"); }
    private JSONObject load(String key) throws Exception {
        if (!journal(key).isFile()) throw new LanServer.Problem(409, "续传记录已失效，请重新开始任务");
        journal(key).setLastModified(System.currentTimeMillis());
        if (data(key).exists()) data(key).setLastModified(System.currentTimeMillis());
        return new JSONObject(new String(Files.readAllBytes(journal(key).toPath()), StandardCharsets.UTF_8));
    }
    private void save(String key, JSONObject json) throws Exception {
        File temporary = new File(directory, key + ".tmp");
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            output.write(json.toString().getBytes(StandardCharsets.UTF_8)); output.getFD().sync();
        }
        java.nio.file.Files.move(temporary.toPath(), journal(key).toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                                  java.nio.file.StandardCopyOption.ATOMIC_MOVE);
    }
    JSONObject uploadStatus(LanServer.Request request) throws Exception {
        String key = key(request), path = request.param("path"), name = request.param("name");
        SharedTree.validateName(name);
        long total = ResumeFile.count(request.param("size"));
        String hash = ResumeFile.hash(request.param("sha256"));
        JSONObject record;
        if (journal(key).exists()) {
            record = load(key);
            if (!"upload".equals(record.getString("kind")) || !path.equals(record.getString("path"))
                || !name.equals(record.getString("name")) || total != record.getLong("size") || !hash.equals(record.getString("sha256"))) {
                throw new LanServer.Problem(409, "源文件或目标目录已改变，请重新加入任务");
            }
        } else {
            tree.checkAvailable(path, name);
            if (total > directory.getUsableSpace() - 32L * 1024 * 1024) throw new LanServer.Problem(507, "续传缓存空间不足");
            record = new JSONObject().put("kind", "upload").put("path", path).put("name", name)
                .put("size", total).put("sha256", hash).put("publishing", false).put("completed", false);
            save(key, record);
        }
        if (record.optBoolean("publishing") && tree.hasFile(path, name)) {
            if (!tree.matchesFile(path, name, total, hash)) throw new LanServer.Problem(409, "已提交的文件已改变");
            record.put("completed", true); save(key, record); data(key).delete();
        }
        boolean completed = record.optBoolean("completed");
        if (completed && !tree.hasFile(path, name)) throw new LanServer.Problem(409, "已提交的文件已移走，请重新加入任务");
        long offset = completed ? total : data(key).length();
        if (offset > total) throw new LanServer.Problem(409, "续传缓存大小异常");
        return new JSONObject().put("offset", offset).put("completed", completed);
    }
    JSONObject uploadChunk(LanServer.Request request) throws Exception {
        String key = key(request); JSONObject record = load(key);
        if (!"upload".equals(record.getString("kind")) || record.optBoolean("completed")) throw new LanServer.Problem(409, "任务已提交");
        long offset = ResumeFile.count(request.param("offset"));
        request.requireBodyLength();
        ResumeFile.append(data(key), offset, record.getLong("size"), request.length, request.input);
        return new JSONObject().put("offset", data(key).length()).put("completed", false);
    }
    JSONObject commit(LanServer.Request request) throws Exception {
        String key = key(request); JSONObject record = load(key);
        if (!"upload".equals(record.getString("kind"))) throw new LanServer.Problem(409, "任务类型错误");
        long size = record.getLong("size"); String hash = record.getString("sha256");
        String path = record.getString("path"), name = record.getString("name");
        if (record.optBoolean("publishing") && tree.hasFile(path, name)) {
            if (!tree.matchesFile(path, name, size, hash)) throw new LanServer.Problem(409, "目标文件已改变");
        } else {
            if (data(key).length() != size) throw new LanServer.Problem(409, "文件尚未完整接收");
            if (!data(key).exists()) new FileOutputStream(data(key)).close();
            try (InputStream input = new FileInputStream(data(key))) {
                if (!hash.equals(ResumeFile.digest(input))) throw new LanServer.Problem(409, "续传文件 SHA-256 不匹配，请重新加入任务");
            }
            tree.checkAvailable(path, name);
            record.put("publishing", true); save(key, record);
            try (InputStream input = new FileInputStream(data(key))) {
                tree.upload(path, name, new LanServer.Request("POST", "", Collections.emptyMap(), size, Collections.emptyMap(), input));
            }
        }
        record.put("completed", true); save(key, record); data(key).delete();
        return new JSONObject().put("offset", size).put("completed", true);
    }
    JSONObject downloadInfo(LanServer.Request request) throws Exception {
        String key = key(request), path = request.param("path");
        SharedTree.Entry file = tree.file(path);
        if (file.size == null) throw new LanServer.Problem(409, "无法确认源文件大小");
        String hash;
        try (InputStream input = context.getContentResolver().openInputStream(file.uri)) { hash = ResumeFile.digest(input); }
        SharedTree.Entry fresh = tree.file(path);
        if (!Objects.equals(file.size, fresh.size) || !Objects.equals(file.modified, fresh.modified)) throw new LanServer.Problem(409, "源文件已改变");
        JSONObject record = new JSONObject().put("kind", "download").put("path", path).put("size", file.size)
            .put("sha256", hash).put("modified", file.modified == null ? -1 : file.modified);
        if (journal(key).exists()) {
            JSONObject old = load(key);
            if (!"download".equals(old.getString("kind")) || !path.equals(old.getString("path"))
                || !hash.equals(old.getString("sha256")) || file.size != old.getLong("size")) {
                throw new LanServer.Problem(409, "设备源文件已改变，请重新加入任务");
            }
        }
        save(key, record);
        return record;
    }
    byte[] downloadChunk(LanServer.Request request) throws Exception {
        JSONObject record = load(key(request));
        if (!"download".equals(record.getString("kind"))) throw new LanServer.Problem(409, "任务类型错误");
        long offset = ResumeFile.count(request.param("offset")), count = ResumeFile.count(request.param("count"));
        if (count > ResumeFile.CHUNK || offset + count > record.getLong("size")) throw new LanServer.Problem(400, "分块范围无效");
        SharedTree.Entry file = tree.file(record.getString("path"));
        if (file.size == null || file.size != record.getLong("size")
            || (file.modified == null ? -1 : file.modified) != record.getLong("modified")) throw new LanServer.Problem(409, "设备源文件已改变");
        byte[] bytes = new byte[(int)count];
        try (InputStream input = context.getContentResolver().openInputStream(file.uri)) {
            if (input == null) throw new FileNotFoundException();
            long remaining = offset;
            while (remaining > 0) {
                long skipped = input.skip(remaining);
                if (skipped == 0) { if (input.read() < 0) throw new EOFException(); skipped = 1; }
                remaining -= skipped;
            }
            int read = 0;
            while (read < bytes.length) { int n = input.read(bytes, read, bytes.length - read); if (n < 0) throw new EOFException(); read += n; }
        }
        return bytes;
    }
    void abort(LanServer.Request request) throws Exception {
        String key = key(request); data(key).delete(); journal(key).delete();
    }
}

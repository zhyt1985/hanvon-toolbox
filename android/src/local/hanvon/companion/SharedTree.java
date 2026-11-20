package local.hanvon.companion;

import android.content.ContentResolver;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.util.Base64;
import android.webkit.MimeTypeMap;
import java.io.FileNotFoundException;
import java.io.OutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

final class SharedTree {
    private static final String STAGING_PREFIX = "HanvonToolbox-upload-";
    private static final String[] COLUMNS = {
        Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE,
        Document.COLUMN_LAST_MODIFIED
    };

    static final class Entry {
        final Uri uri;
        final String name;
        final boolean directory;
        final Long size;
        final Long modified;

        Entry(Uri uri, String name, boolean directory, Long size, Long modified) {
            this.uri = uri;
            this.name = name;
            this.directory = directory;
            this.size = size;
            this.modified = modified;
        }
    }

    private final ContentResolver resolver;
    private final Uri tree;
    private final Uri root;
    private final SharedPreferences uploads;

    SharedTree(Context context, Uri tree) {
        resolver = context.getContentResolver();
        uploads = context.getSharedPreferences("staged-uploads", Context.MODE_PRIVATE);
        this.tree = tree;
        root = document(DocumentsContract.getTreeDocumentId(tree));
    }

    String name() throws Exception {
        try (Cursor cursor = resolver.query(root, COLUMNS, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) throw new FileNotFoundException("无法读取授权目录");
            return cursor.getString(1);
        }
    }

    String identity() throws NoSuchAlgorithmException {
        byte[] digest = MessageDigest.getInstance("SHA-256")
            .digest(tree.toString().getBytes(StandardCharsets.UTF_8));
        return Base64.encodeToString(digest, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    JSONArray list(String path) throws Exception {
        Uri parent = resolve(path, true);
        JSONArray json = new JSONArray();
        for (Entry entry : children(parent)) {
            if (!isName(entry.name) || stagingName(entry.name)) continue;
            JSONObject row = new JSONObject()
                .put("name", entry.name)
                .put("directory", entry.directory);
            if (!entry.directory && entry.size != null) row.put("size", entry.size.longValue());
            if (entry.modified != null && entry.modified > 0) row.put("modified", entry.modified.longValue());
            json.put(row);
        }
        return json;
    }

    List<Entry> snapshotEntries(String path) throws Exception {
        List<Entry> result=children(resolve(path,true));
        for(Entry e:result) {
            if(!isName(e.name)||stagingName(e.name)) throw new LanServer.Problem(409,"来源存在无效名称或未完成的文件操作");
            SnapshotCapture.path(path.isEmpty()?e.name:path+"/"+e.name,false);
        }
        return result;
    }

    Entry file(String path) throws Exception {
        String[] parts = splitItem(path);
        Entry entry = find(resolve(parts[0], true), parts[1]);
        if (entry == null || entry.directory) throw new FileNotFoundException("文件不存在");
        return entry;
    }

    void createFolder(String path, String name) throws Exception {
        create(resolve(path, true), name, Document.MIME_TYPE_DIR);
    }

    void checkAvailable(String path, String name) throws Exception {
        validateName(name); ensureAvailable(resolve(path, true), name, null);
    }
    boolean hasFile(String path, String name) throws Exception { return find(resolve(path, true), name) != null; }
    boolean matchesFile(String path, String name, long size, String hash) throws Exception {
        Entry entry = find(resolve(path, true), name);
        if (entry == null || entry.directory || entry.size == null || entry.size != size) return false;
        try (InputStream input = resolver.openInputStream(entry.uri)) { return hash.equals(ResumeFile.digest(input)); }
    }

    void upload(String path, String name, LanServer.Request request) throws Exception {
        validateName(name);
        Uri parent = resolve(path, true);
        ensureAvailable(parent, name, null);
        String temporaryName = STAGING_PREFIX + UUID.randomUUID() + ".part";
        JSONObject journal = new JSONObject().put("tree", tree.toString())
            .put("parent", DocumentsContract.getDocumentId(parent));
        if (!uploads.edit().putString(temporaryName, journal.toString()).commit()) {
            throw new java.io.IOException("Cannot save upload journal");
        }

        Uri owned = null;
        boolean published = false;
        try {
            owned = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", temporaryName);
            if (owned == null) throw new FileNotFoundException("无法创建临时文件");
            try (OutputStream output = resolver.openOutputStream(owned, "w")) {
                if (output == null) throw new FileNotFoundException("无法写入临时文件");
                request.copyBody(output);
            }
            ensureAvailable(parent, name, null);
            Uri renamed = DocumentsContract.renameDocument(resolver, owned, name);
            if (renamed == null) throw new java.io.IOException("Cannot commit uploaded file");
            owned = renamed;
            if (!name.equals(displayName(renamed))) {
                throw new LanServer.Problem(409, "目标中已有同名项目");
            }
            published = true;
        } finally {
            if (published || removeStage(parent, temporaryName, owned)) {
                uploads.edit().remove(temporaryName).apply();
            }
        }
    }

    void cleanInterruptedUploads() {
        for (Map.Entry<String, ?> record : uploads.getAll().entrySet()) {
            String name = record.getKey();
            if (!stagingName(name) || !(record.getValue() instanceof String)) continue;
            try {
                JSONObject entry = new JSONObject((String) record.getValue());
                if (!tree.toString().equals(entry.getString("tree"))) continue;
                if (removeStage(document(entry.getString("parent")), name, null)) {
                    uploads.edit().remove(name).apply();
                }
            } catch (Exception failure) {
                android.util.Log.w("HanvonCompanion", "Cannot clean a staged upload", failure);
            }
        }
    }

    private boolean removeStage(Uri parent, String name, Uri known) {
        try {
            if (known != null) {
                return DocumentsContract.deleteDocument(resolver, known);
            }
            Entry entry = find(parent, name);
            return entry == null || DocumentsContract.deleteDocument(resolver, entry.uri);
        } catch (Exception failure) {
            android.util.Log.w("HanvonCompanion", "Staged upload cleanup deferred", failure);
            return false;
        }
    }

    private String displayName(Uri document) throws Exception {
        try (Cursor cursor = resolver.query(document, COLUMNS, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) throw new FileNotFoundException("无法读取提交后的文件");
            return cursor.getString(1);
        }
    }

    private static boolean stagingName(String name) {
        return name.toLowerCase(Locale.ROOT).matches("hanvontoolbox-(upload|copy)-[0-9a-f-]{36}\\.part");
    }

    void rename(String path, String name) throws Exception {
        String[] parts = splitItem(path);
        Uri parent = resolve(parts[0], true);
        Entry item = requireChild(parent, parts[1]);
        validateName(name);
        if (item.name.equals(name)) return;
        ensureAvailable(parent, name, item.uri);
        if (DocumentsContract.renameDocument(resolver, item.uri, name) == null) {
            throw new FileNotFoundException("目录提供器未完成重命名");
        }
    }

    void move(String path, String target) throws Exception {
        String[] parts = splitItem(path);
        Uri source = resolve(parts[0], true);
        Entry item = requireChild(source, parts[1]);
        if (target.equals(parts[0])) return;
        if (item.directory && (target.equals(path) || target.startsWith(path + "/"))) {
            throw new LanServer.Problem(400, "不能移动到目录自身或其子目录");
        }
        Uri destination = resolve(target, true);
        ensureAvailable(destination, parts[1], null);
        if (DocumentsContract.moveDocument(resolver, item.uri, source, destination) == null) {
            throw new LanServer.Problem(409, "此目录提供器无法移动所选项目");
        }
    }

    void delete(String path) throws Exception {
        String[] parts = splitItem(path);
        Uri parent = resolve(parts[0], true);
        Entry item = requireChild(parent, parts[1]);
        if (!DocumentsContract.deleteDocument(resolver, item.uri)) {
            throw new LanServer.Problem(409, "目录提供器未完成删除");
        }
    }

    void copy(String path, String target) throws Exception {
        String[] parts = splitItem(path);
        Entry source = requireChild(resolve(parts[0], true), parts[1]);
        if (source.directory && (target.equals(path) || target.startsWith(path + "/"))) {
            throw new LanServer.Problem(400, "不能复制到目录自身或其子目录");
        }
        Uri destination = resolve(target, true);
        ensureAvailable(destination, source.name, null);
        String temporaryName = "HanvonToolbox-copy-" + UUID.randomUUID() + ".part";
        JSONObject journal = new JSONObject().put("tree", tree.toString())
            .put("parent", DocumentsContract.getDocumentId(destination));
        if (!uploads.edit().putString(temporaryName, journal.toString()).commit()) {
            throw new java.io.IOException("无法保存复制记录");
        }
        Uri stage = null;
        try {
            stage = DocumentsContract.createDocument(resolver, destination, Document.MIME_TYPE_DIR, temporaryName);
            if (stage == null) throw new FileNotFoundException("无法创建复制临时目录");
            Uri copied = copyInto(source, stage, new java.util.HashSet<String>(), new int[] {0}, 0);
            ensureAvailable(destination, source.name, null);
            Uri published = DocumentsContract.moveDocument(resolver, copied, stage, destination);
            if (published == null || !source.name.equals(displayName(published))) {
                throw new LanServer.Problem(409, "未能提交复制结果");
            }
        } finally {
            if (removeStage(destination, temporaryName, stage)) uploads.edit().remove(temporaryName).apply();
        }
    }

    private Uri copyInto(Entry source, Uri parent, java.util.Set<String> visited, int[] count, int depth) throws Exception {
        if (++count[0] > 20000 || depth > 64 || !visited.add(source.uri.toString())) {
            throw new LanServer.Problem(409, "复制目录过大、层级过深或包含循环");
        }
        Uri result = create(parent, source.name, source.directory ? Document.MIME_TYPE_DIR : mimeType(source.name));
        if (source.directory) {
            for (Entry child : children(source.uri)) copyInto(child, result, visited, count, depth + 1);
        } else {
            long bytes = 0;
            try (InputStream input = resolver.openInputStream(source.uri);
                 OutputStream output = resolver.openOutputStream(result, "w")) {
                if (input == null || output == null) throw new FileNotFoundException("无法读取或写入复制文件");
                byte[] buffer = new byte[65536];
                int n;
                while ((n = input.read(buffer)) != -1) { output.write(buffer, 0, n); bytes += n; }
            }
            try (Cursor cursor = resolver.query(source.uri, COLUMNS, null, null, null)) {
                if (cursor == null || !cursor.moveToFirst()
                    || (source.size != null && (source.size != bytes || cursor.getLong(3) != bytes))
                    || (source.modified != null && source.modified != cursor.getLong(4))) {
                    throw new LanServer.Problem(409, "复制期间源文件已改变");
                }
            }
        }
        return result;
    }

    boolean cleanupRecovery(String path, String id, String original, String size, String hash) throws Exception {
        RecoveryCleanupPolicy policy;
        try {
            policy = new RecoveryCleanupPolicy(id, original, size, hash);
        } catch (IllegalArgumentException failure) {
            throw new LanServer.Problem(400, "恢复副本记录无效");
        }
        Uri parent = resolve(path, true);
        List<Entry> entries = children(parent);
        Entry retained = uniqueRecoveryChild(entries, policy.retainedName);
        if (retained == null) return false;
        validateRecoveryContext(entries, policy);
        if (retained.directory || retained.size == null || retained.size.longValue() != policy.byteCount) {
            throw new LanServer.Problem(409, "恢复副本的类型或大小已改变");
        }
        try (InputStream input = resolver.openInputStream(retained.uri)) {
            if (!policy.matches(input)) throw new LanServer.Problem(409, "恢复副本内容已改变，清理已停止");
        }
        List<Entry> fresh = children(parent);
        validateRecoveryContext(fresh, policy);
        Entry current = uniqueRecoveryChild(fresh, policy.retainedName);
        if (current == null || !current.uri.equals(retained.uri) || current.directory
            || current.size == null || current.size.longValue() != policy.byteCount) {
            throw new LanServer.Problem(409, "恢复副本在清理前发生变化");
        }
        if (!DocumentsContract.deleteDocument(resolver, current.uri)
            || uniqueRecoveryChild(children(parent), policy.retainedName) != null) {
            throw new LanServer.Problem(500, "恢复副本尚未删除，可重试清理");
        }
        return true;
    }

    private void validateRecoveryContext(List<Entry> entries, RecoveryCleanupPolicy policy) throws Exception {
        Entry original = uniqueRecoveryChild(entries, policy.originalName);
        if (original == null || original.directory) {
            throw new LanServer.Problem(409, "当前文件已不存在，保留设备恢复副本");
        }
        if (uniqueRecoveryChild(entries, policy.stageName) != null) {
            throw new LanServer.Problem(409, "设备上仍有未完成更新，请先处理传输记录");
        }
    }

    private Entry uniqueRecoveryChild(List<Entry> entries, String name) throws Exception {
        Entry result = null;
        for (Entry entry : entries) {
            if (!entry.name.equalsIgnoreCase(name)) continue;
            if (result != null || !entry.name.equals(name)) {
                throw new LanServer.Problem(409, "目录存在同名或大小写相近项目");
            }
            result = entry;
        }
        return result;
    }

    private Uri create(Uri parent, String name, String mime) throws Exception {
        validateName(name);
        ensureAvailable(parent, name, null);
        Uri result = DocumentsContract.createDocument(resolver, parent, mime, name);
        if (result == null) throw new FileNotFoundException("目录提供器未创建项目");
        return result;
    }

    private void ensureAvailable(Uri folder, String name, Uri except) throws Exception {
        for (Entry item : children(folder)) {
            if (item.name.equalsIgnoreCase(name) && !item.uri.equals(except)) {
                throw new LanServer.Problem(409, "目标中已有同名项目");
            }
        }
    }

    private Uri resolve(String path, boolean directory) throws Exception {
        Uri current = root;
        if (path.isEmpty()) return current;
        String[] components = path.split("/", -1);
        if (components.length > 64) throw new LanServer.Problem(400, "目录层级过深");
        for (int index = 0; index < components.length; index++) {
            Entry child = requireChild(current, components[index]);
            if ((directory || index < components.length - 1) && !child.directory) {
                throw new FileNotFoundException("目标不是目录");
            }
            current = child.uri;
        }
        return current;
    }

    private Entry requireChild(Uri directory, String name) throws Exception {
        validateName(name);
        Entry entry = find(directory, name);
        if (entry == null) throw new FileNotFoundException("设备项目不存在");
        return entry;
    }

    private Entry find(Uri directory, String name) throws Exception {
        for (Entry entry : children(directory)) if (entry.name.equals(name)) return entry;
        return null;
    }

    private List<Entry> children(Uri directory) throws Exception {
        Uri contents = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(directory));
        ArrayList<Entry> entries = new ArrayList<>();
        try (Cursor cursor = resolver.query(contents, COLUMNS, null, null, null)) {
            if (cursor == null) throw new FileNotFoundException("无法读取目录");
            while (cursor.moveToNext()) {
                String name = cursor.getString(1);
                if (name == null) continue;
                entries.add(new Entry(document(cursor.getString(0)), name,
                    Document.MIME_TYPE_DIR.equals(cursor.getString(2)), cursor.isNull(3) ? null : cursor.getLong(3),
                    cursor.isNull(4) ? null : cursor.getLong(4)));
            }
        }
        return entries;
    }

    private Uri document(String id) {
        return DocumentsContract.buildDocumentUriUsingTree(tree, id);
    }

    private static String[] splitItem(String path) throws LanServer.Problem {
        int slash = path.lastIndexOf('/');
        String name = path.substring(slash + 1);
        validateName(name);
        return new String[] {slash < 0 ? "" : path.substring(0, slash), name};
    }

    static void validateName(String name) throws LanServer.Problem {
        if (!isName(name) || stagingName(name)) throw new LanServer.Problem(400, "文件或目录名称无效");
    }

    private static boolean isName(String name) {
        if (name.isEmpty() || name.equals(".") || name.equals("..") || name.indexOf('/') >= 0 ||
            name.indexOf('\\') >= 0 || name.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 255) return false;
        return name.codePoints().noneMatch(Character::isISOControl);
    }

    private static String mimeType(String name) {
        int dot = name.lastIndexOf('.');
        String type = dot < 0 ? null : MimeTypeMap.getSingleton().getMimeTypeFromExtension(
            name.substring(dot + 1).toLowerCase(Locale.ROOT)
        );
        return type == null ? "application/octet-stream" : type;
    }
}

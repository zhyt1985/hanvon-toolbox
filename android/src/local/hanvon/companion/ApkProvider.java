package local.hanvon.companion;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.util.List;

public final class ApkProvider extends ContentProvider {
    static final String AUTHORITY = "local.hanvon.companion.apk";
    static final String MIME = "application/vnd.android.package-archive";

    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return MIME; }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException();
        ApkInbox.Pending pending = requirePending(uri);
        return ParcelFileDescriptor.open(ApkInbox.file(getContext(), pending.token), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        try {
            ApkInbox.Pending pending = requirePending(uri);
            File file = ApkInbox.file(getContext(), pending.token);
            String[] columns = projection == null
                ? new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns);
            Object[] row = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) {
                if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) row[i] = pending.name;
                if (OpenableColumns.SIZE.equals(columns[i])) row[i] = file.length();
            }
            cursor.addRow(row);
            return cursor;
        } catch (FileNotFoundException failure) {
            return null;
        }
    }

    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }

    private ApkInbox.Pending requirePending(Uri uri) throws FileNotFoundException {
        List<String> parts = uri.getPathSegments();
        ApkInbox.Pending pending = ApkInbox.pending(getContext());
        if (parts.size() != 2 || !"apk".equals(parts.get(0)) || pending == null || !pending.token.equals(parts.get(1))) {
            throw new FileNotFoundException();
        }
        return pending;
    }
}

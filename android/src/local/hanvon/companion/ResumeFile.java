package local.hanvon.companion;

import java.io.*;
import java.security.MessageDigest;
import java.util.UUID;

final class ResumeFile {
    static final int CHUNK = 1024 * 1024;
    static final long MAX = 4L * 1024 * 1024 * 1024;
    static String id(String text) {
        if (text.length() != 36 || !UUID.fromString(text).toString().equalsIgnoreCase(text)) throw new IllegalArgumentException("Invalid transfer ID");
        return text.toUpperCase(java.util.Locale.ROOT);
    }
    static String hash(String text) {
        if (!text.matches("[0-9a-fA-F]{64}")) throw new IllegalArgumentException("Invalid SHA-256");
        return text.toLowerCase(java.util.Locale.ROOT);
    }
    static long count(String text) {
        if (!text.matches("0|[1-9][0-9]{0,10}")) throw new IllegalArgumentException("Invalid byte count");
        long n = Long.parseLong(text);
        if (n > MAX) throw new IllegalArgumentException("File too large");
        return n;
    }
    static String digest(InputStream input) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] bytes = new byte[65536]; int n;
        while ((n = input.read(bytes)) != -1) digest.update(bytes, 0, n);
        StringBuilder result = new StringBuilder();
        for (byte b : digest.digest()) result.append(String.format("%02x", b & 255));
        return result.toString();
    }
    static void append(File file, long offset, long total, long length, InputStream input) throws Exception {
        if (offset < 0 || total < 0 || total > MAX || length < 0 || length > CHUNK || offset + length > total || file.length() != offset) {
            throw new IllegalArgumentException("Invalid chunk offset or length");
        }
        try (RandomAccessFile output = new RandomAccessFile(file, "rw")) {
            output.seek(offset);
            try {
                byte[] bytes = new byte[65536]; long remaining = length;
                while (remaining > 0) {
                    int n = input.read(bytes, 0, (int)Math.min(remaining, bytes.length));
                    if (n < 0) throw new EOFException("Incomplete chunk");
                    output.write(bytes, 0, n); remaining -= n;
                }
            } finally { output.getFD().sync(); }
        }
    }
}

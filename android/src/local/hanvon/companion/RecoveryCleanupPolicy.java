package local.hanvon.companion;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.UUID;

final class RecoveryCleanupPolicy {
    final String originalName;
    final String retainedName;
    final String stageName;
    final long byteCount;
    private final byte[] expectedHash;

    RecoveryCleanupPolicy(String id, String original, String size, String hash) {
        UUID parsed = UUID.fromString(id);
        if (!parsed.toString().equalsIgnoreCase(id)
            || original.isEmpty() || original.equals(".") || original.equals("..")
            || original.length() > 254 || original.contains("/") || original.indexOf(0) >= 0
            || original.startsWith(".HanvonToolbox-update-")
            || !size.matches("[0-9]+") || !hash.matches("[0-9a-fA-F]{64}")) {
            throw new IllegalArgumentException("恢复副本记录无效");
        }
        originalName = original;
        String prefix = ".HanvonToolbox-update-" + parsed.toString().toUpperCase(java.util.Locale.ROOT);
        retainedName = prefix + ".old";
        stageName = prefix + ".new";
        byteCount = Long.parseLong(size);
        expectedHash = new byte[32];
        for (int index = 0; index < expectedHash.length; index++) {
            expectedHash[index] = (byte) Integer.parseInt(hash.substring(index * 2, index * 2 + 2), 16);
        }
    }

    boolean matches(InputStream input) throws Exception {
        if (input == null) throw new IOException("无法读取恢复副本");
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[65536];
        long total = 0;
        int count;
        while ((count = input.read(buffer)) != -1) {
            if (count > byteCount - total) return false;
            total += count;
            digest.update(buffer, 0, count);
        }
        return total == byteCount && MessageDigest.isEqual(expectedHash, digest.digest());
    }
}

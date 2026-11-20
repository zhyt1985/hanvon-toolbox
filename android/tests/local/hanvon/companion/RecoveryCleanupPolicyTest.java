package local.hanvon.companion;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

public final class RecoveryCleanupPolicyTest {
    public static void main(String[] args) throws Exception {
        String id = "911e39cf-7535-4897-8838-e083c58b2751";
        byte[] old = "old".getBytes(StandardCharsets.UTF_8);
        String hash = hex(MessageDigest.getInstance("SHA-256").digest(old));
        RecoveryCleanupPolicy valid = new RecoveryCleanupPolicy(id, "书籍.txt", "3", hash);
        check(valid.retainedName.equals(".HanvonToolbox-update-" + id.toUpperCase(java.util.Locale.ROOT) + ".old"));
        check(valid.matches(new ByteArrayInputStream(old)));
        check(!valid.matches(new ByteArrayInputStream("bad".getBytes(StandardCharsets.UTF_8))));
        check(!valid.matches(new ByteArrayInputStream("oldmore".getBytes(StandardCharsets.UTF_8))));
        reject(id, "../书籍.txt", "3", hash);
        reject(id, ".", "3", hash);
        reject(id, ".HanvonToolbox-update-" + id + ".old", "3", hash);
        reject("1-1-1-1-1", "book", "3", hash);
        reject(id, "book", "-1", hash);
        reject(id, "book", "9223372036854775808", hash);
        reject(id, "book", "3", "bad");
        RecoveryCleanupPolicy empty = new RecoveryCleanupPolicy(id, "empty", "0",
            hex(MessageDigest.getInstance("SHA-256").digest(new byte[0])));
        check(empty.matches(new ByteArrayInputStream(new byte[0])));
        System.out.println("Recovery cleanup validation, size and SHA-256 checks passed.");
    }

    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder();
        for (byte value : bytes) text.append(String.format("%02x", value & 0xff));
        return text.toString();
    }

    private static void reject(String id, String name, String size, String hash) {
        try {
            new RecoveryCleanupPolicy(id, name, size, hash);
            throw new AssertionError("Accepted invalid cleanup record");
        } catch (IllegalArgumentException expected) {
            // Invalid records must fail before resolving or deleting a document.
        }
    }

    private static void check(boolean value) {
        if (!value) throw new AssertionError("Recovery cleanup check failed");
    }
}

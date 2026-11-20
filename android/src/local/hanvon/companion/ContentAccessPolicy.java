package local.hanvon.companion;

import java.util.Set;
import java.util.UUID;

final class ContentAccessPolicy {
    static boolean allowed(String currentRevision, String requestedRevision, String owner,
                           boolean knownPairing, Set<String> grants) {
        return knownPairing && owner != null && currentRevision.equals(requestedRevision) && grants.contains(owner);
    }
    static String id(String value) {
        if (value == null || value.length() != 36 || !UUID.fromString(value).toString().equals(value)) {
            throw new IllegalArgumentException("Invalid content identifier");
        }
        return value;
    }
    static boolean live(long created, long now) {
        return now >= created && now - created < 10L * 60 * 1000;
    }
}

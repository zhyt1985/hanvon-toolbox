package local.hanvon.companion;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

final class PairedMacs {
    private static final String TOKENS = "token-digests";
    private static final Object UPDATE_LOCK = new Object();
    private final SharedPreferences store;

    PairedMacs(Context context) {
        store = context.getSharedPreferences("paired-macs-v2", Context.MODE_PRIVATE);
    }

    boolean contains(String token) {
        if (token == null || token.length() != 43) return false;
        return digests().contains(digest(token));
    }

    String add() throws LanServer.Problem {
        synchronized (UPDATE_LOCK) {
            Set<String> known = new HashSet<>(digests());
            if (known.size() >= 8) throw new LanServer.Problem(409, "已记住 8 台 Mac，请在电纸书上清除配对后再试");
            byte[] bytes = new byte[32];
            new SecureRandom().nextBytes(bytes);
            String token = encode(bytes);
            known.add(digest(token));
            if (!store.edit().putStringSet(TOKENS, known).commit()) {
                throw new LanServer.Problem(500, "无法保存配对");
            }
            return token;
        }
    }

    int count() { return digests().size(); }
    boolean knowsDigest(String digest) { return digests().contains(digest); }

    void clear() {
        synchronized (UPDATE_LOCK) { store.edit().remove(TOKENS).apply(); }
    }

    private Set<String> digests() {
        return store.getStringSet(TOKENS, Collections.emptySet());
    }

    static String digest(String token) {
        try {
            return encode(MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.US_ASCII)));
        } catch (NoSuchAlgorithmException failure) {
            throw new IllegalStateException(failure);
        }
    }

    private static String encode(byte[] data) {
        return Base64.encodeToString(data, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
    }
}

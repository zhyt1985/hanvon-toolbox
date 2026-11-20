package local.hanvon.companion;

import android.content.Context;
import android.util.AtomicFile;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.math.BigInteger;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.security.auth.x500.X500Principal;

final class TlsIdentity {
    private static final byte[] SHA256_WITH_RSA = {
        0x30, 0x0d, 0x06, 0x09, 0x2a, (byte) 0x86, 0x48, (byte) 0x86, (byte) 0xf7, 0x0d, 0x01, 0x01, 0x0b, 0x05, 0
    };
    private static final byte[] SUBJECT_ALT_NAME = {0x06, 0x03, 0x55, 0x1d, 0x11};

    final SSLContext context;
    final String fingerprint;
    final String deviceId;

    TlsIdentity(Context app, InetAddress address) throws Exception {
        SecureRandom random = new SecureRandom();
        KeyPair pair = readOrCreateKey(app, random);
        Certificate certificate = certificate(pair, address, random);
        RSAPublicKey publicKey = (RSAPublicKey) pair.getPublic();
        byte[] encoded = der(0x30,
            der(0x02, publicKey.getModulus().toByteArray()),
            der(0x02, publicKey.getPublicExponent().toByteArray()));
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(encoded);
        StringBuilder hash = new StringBuilder(64);
        for (byte value : digest) hash.append(String.format(Locale.ROOT, "%02X", value & 0xff));
        deviceId = hash.toString();
        fingerprint = deviceId.substring(0, 16);

        char[] password = new BigInteger(160, random).toString(16).toCharArray();
        try {
            // Keep this session's key and certificate in memory for the platform TLS provider.
            KeyStore store = KeyStore.getInstance("PKCS12");
            store.load(null, null);
            store.setKeyEntry("companion", pair.getPrivate(), password, new Certificate[] {certificate});
            KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            keys.init(store, password);
            context = SSLContext.getInstance("TLS");
            context.init(keys.getKeyManagers(), null, random);
        } finally {
            java.util.Arrays.fill(password, '\0');
        }
    }

    private static synchronized KeyPair readOrCreateKey(Context app, SecureRandom random) throws Exception {
        AtomicFile file = new AtomicFile(new File(app.getNoBackupFilesDir(), "wireless-identity-v2"));
        try (DataInputStream input = new DataInputStream(file.openRead())) {
            KeyFactory rsa = KeyFactory.getInstance("RSA");
            return new KeyPair(rsa.generatePublic(new X509EncodedKeySpec(readKey(input))),
                rsa.generatePrivate(new PKCS8EncodedKeySpec(readKey(input))));
        } catch (FileNotFoundException missing) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048, random);
            KeyPair created = generator.generateKeyPair();
            FileOutputStream raw = file.startWrite();
            try {
                DataOutputStream output = new DataOutputStream(raw);
                writeKey(output, created.getPublic().getEncoded());
                writeKey(output, created.getPrivate().getEncoded());
                output.flush();
                file.finishWrite(raw);
            } catch (IOException failure) {
                file.failWrite(raw);
                throw failure;
            }
            return created;
        }
    }

    private static byte[] readKey(DataInputStream input) throws IOException {
        int count = input.readInt();
        if (count <= 0 || count > 8192) throw new IOException("Invalid identity record");
        byte[] data = new byte[count];
        input.readFully(data);
        return data;
    }

    private static void writeKey(DataOutputStream output, byte[] key) throws IOException {
        output.writeInt(key.length);
        output.write(key);
    }

    private static Certificate certificate(KeyPair pair, InetAddress address, SecureRandom random) throws Exception {
        byte[] subject = new X500Principal("CN=Hanvon Toolbox Companion").getEncoded();
        long now = System.currentTimeMillis();
        byte[] validity = der(0x30, time(now - 86400000L), time(now + 7 * 86400000L));
        byte[] subjectAltName = der(0x30, SUBJECT_ALT_NAME, der(0x04, der(0x30, der(0x87, address.getAddress()))));
        byte[] record = der(0x30,
            der(0xa0, der(0x02, new byte[] {2})),
            der(0x02, new BigInteger(159, random).add(BigInteger.ONE).toByteArray()),
            SHA256_WITH_RSA, subject, validity, subject, pair.getPublic().getEncoded(),
            der(0xa3, der(0x30, subjectAltName)));
        Signature signer = Signature.getInstance("SHA256withRSA");
        signer.initSign(pair.getPrivate(), random);
        signer.update(record);
        byte[] encoded = der(0x30, record, SHA256_WITH_RSA, der(0x03, new byte[] {0}, signer.sign()));
        Certificate result = CertificateFactory.getInstance("X.509")
            .generateCertificate(new ByteArrayInputStream(encoded));
        result.verify(pair.getPublic());
        return result;
    }

    private static byte[] time(long timestamp) {
        SimpleDateFormat format = new SimpleDateFormat("yyMMddHHmmss'Z'", Locale.ROOT);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return der(0x17, format.format(new Date(timestamp)).getBytes(StandardCharsets.US_ASCII));
    }

    private static byte[] der(int tag, byte[]... parts) {
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        result.write(tag);
        int length = 0;
        for (byte[] part : parts) length += part.length;
        if (length < 128) {
            result.write(length);
        } else {
            int bytes = (32 - Integer.numberOfLeadingZeros(length) + 7) / 8;
            result.write(0x80 | bytes);
            for (int index = bytes - 1; index >= 0; index--) result.write((length >> (index * 8)) & 0xff);
        }
        for (byte[] part : parts) result.write(part, 0, part.length);
        return result.toByteArray();
    }
}

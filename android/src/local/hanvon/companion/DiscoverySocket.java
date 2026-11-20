package local.hanvon.companion;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.util.Log;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

final class DiscoverySocket implements AutoCloseable {
    private static final int DISCOVERY_PORT = 49310;
    private static final String PREFIX = "HANVON-DISCOVER/2 ";
    private final DatagramSocket socket;
    private final WifiManager.MulticastLock lock;
    private final String response;

    DiscoverySocket(Context context, String deviceId, int port) throws IOException {
        WifiManager manager = context.getApplicationContext().getSystemService(WifiManager.class);
        lock = manager.createMulticastLock("hanvon-toolbox-discovery");
        lock.setReferenceCounted(false);
        socket = new DatagramSocket(null);
        try {
            socket.bind(new InetSocketAddress(DISCOVERY_PORT));
            lock.acquire();
        } catch (IOException | RuntimeException failure) {
            socket.close();
            throw failure;
        }
        String name = ("Hanvon " + Build.MODEL).replaceAll("[\\p{Cntrl}]", "");
        response = " " + deviceId + " " + port + " " + name;
        new Thread(this::listen, "hanvon-discovery").start();
    }

    private void listen() {
        byte[] data = new byte[160];
        while (!socket.isClosed()) {
            DatagramPacket packet = new DatagramPacket(data, data.length);
            try {
                socket.receive(packet);
                String content = new String(data, 0, packet.getLength(), StandardCharsets.US_ASCII);
                if (!content.startsWith(PREFIX) || !packet.getAddress().isSiteLocalAddress()) continue;
                String nonce = content.substring(PREFIX.length());
                if (!nonce.matches("[A-F0-9-]{36}")) continue;
                byte[] body = ("HANVON-HERE/2 " + nonce + response).getBytes(StandardCharsets.UTF_8);
                socket.send(new DatagramPacket(body, body.length, packet.getAddress(), packet.getPort()));
            } catch (IOException failure) {
                if (!socket.isClosed()) Log.w("HanvonCompanion", "LAN discovery datagram failed");
            }
        }
    }

    @Override public void close() {
        socket.close();
        if (lock.isHeld()) lock.release();
    }
}

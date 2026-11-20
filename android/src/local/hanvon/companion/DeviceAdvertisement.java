package local.hanvon.companion;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;

final class DeviceAdvertisement implements AutoCloseable {
    static final String TYPE = "_hanvon-toolbox._tcp";
    private final NsdManager nsd;
    private final NsdManager.RegistrationListener registration;
    private volatile boolean closed;

    DeviceAdvertisement(Context context, String deviceId, int port, Runnable onFailure) {
        nsd = context.getSystemService(NsdManager.class);
        NsdServiceInfo service = new NsdServiceInfo();
        service.setServiceName("Hanvon " + Build.MODEL + " " + deviceId.substring(0, 6));
        service.setServiceType(TYPE);
        service.setPort(port);
        service.setAttribute("id", deviceId);
        service.setAttribute("v", "2");

        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo info) {
                if (closed) unregister();
            }
            @Override public void onRegistrationFailed(NsdServiceInfo info, int error) {
                if (!closed) onFailure.run();
            }
            @Override public void onServiceUnregistered(NsdServiceInfo info) {}
            @Override public void onUnregistrationFailed(NsdServiceInfo info, int error) {}
        };
        nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    @Override public void close() {
        closed = true;
        unregister();
    }

    private void unregister() {
        try { nsd.unregisterService(registration); }
        catch (IllegalArgumentException ignored) {}
    }
}

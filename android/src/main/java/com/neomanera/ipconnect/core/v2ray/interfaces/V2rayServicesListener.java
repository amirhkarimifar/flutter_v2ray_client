package com.neomanera.ipconnect.core.v2ray.interfaces;

import android.app.Service;

public interface V2rayServicesListener {
    boolean onProtect(final int socket);
    Service getService();
    void startService();
    void stopService();

    /**
     * Builds the VPN interface before the core starts and returns its fd for
     * xray's native TUN inbound, or -1 when this service has no interface
     * (proxy-only) or it could not be established. The service keeps owning
     * the descriptor and closes it in stopService().
     */
    default int establishTun() {
        return -1;
    }
}

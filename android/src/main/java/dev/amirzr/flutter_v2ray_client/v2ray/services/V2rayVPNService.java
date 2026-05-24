package dev.amirzr.flutter_v2ray_client.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import dev.amirzr.flutter_v2ray_client.v2ray.core.V2rayCoreManager;
import dev.amirzr.flutter_v2ray_client.v2ray.interfaces.V2rayServicesListener;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.V2rayConfig;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileDescriptor;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;

public class V2rayVPNService extends VpnService implements V2rayServicesListener {
    private static final String TAG = "V2rayVPNService";
    private ParcelFileDescriptor mInterface;
    private Process process;
    private V2rayConfig v2rayConfig;
    private volatile boolean isRunning = false;
    // Guard against concurrent/double cleanup — once set, all cleanup paths are no-ops
    private final AtomicBoolean isCleaning = new AtomicBoolean(false);

    @Override
    public void onCreate() {
        super.onCreate();
        V2rayCoreManager.getInstance().setUpListener(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Handle null intent case - can happen when service is restarted by system
        if (intent == null) {
            Log.w(TAG, "onStartCommand called with null intent, stopping service");
            stopSelf();
            return START_NOT_STICKY;
        }

        AppConfigs.V2RAY_SERVICE_COMMANDS startCommand = null;
        try {
            startCommand = (AppConfigs.V2RAY_SERVICE_COMMANDS) intent.getSerializableExtra("COMMAND");
        } catch (Exception e) {
            Log.w(TAG, "Failed to parse COMMAND from intent", e);
        }

        // Handle null command case
        if (startCommand == null) {
            Log.w(TAG, "No command found in intent, stopping service");
            stopSelf();
            return START_NOT_STICKY;
        }

        try {
            if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE)) {
                v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
                if (v2rayConfig == null) {
                    Log.w(TAG, "V2RAY_CONFIG is null, cannot start service");
                    stopSelf();
                    return START_NOT_STICKY;
                }
                // startCore() handles stopping any existing core atomically under the lock
                if (V2rayCoreManager.getInstance().startCore(v2rayConfig)) {
                    Log.i(TAG, "onStartCommand success => v2ray core started.");
                } else {
                    Log.e(TAG, "Failed to start v2ray core");
                    stopSelf();
                    return START_NOT_STICKY;
                }
            } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)) {
                V2rayCoreManager.getInstance().stopCore();
                AppConfigs.V2RAY_CONFIG = null;
            } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY)) {
                new Thread(() -> {
                    try {
                        String packageName = getPackageName();
                        Intent sendB = new Intent(packageName + ".CONNECTED_V2RAY_SERVER_DELAY");
                        sendB.setPackage(packageName);
                        sendB.putExtra("DELAY",
                                String.valueOf(V2rayCoreManager.getInstance().getConnectedV2rayServerDelay()));
                        sendBroadcast(sendB);
                    } catch (Exception e) {
                        Log.w(TAG, "Failed to send delay broadcast", e);
                    }
                }, "MEASURE_CONNECTED_V2RAY_SERVER_DELAY").start();
            } else {
                Log.w(TAG, "Unknown command received, stopping service");
                stopSelf();
                return START_NOT_STICKY;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error handling command: " + startCommand, e);
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    /**
     * Single cleanup method — all shutdown paths funnel here.
     * AtomicBoolean ensures it only runs once, even if called from
     * multiple threads (onDestroy, onRevoke, stopService, etc.).
     */
    private void cleanup() {
        if (!isCleaning.compareAndSet(false, true)) {
            // Another thread is already cleaning up
            return;
        }
        Log.i(TAG, "cleanup: starting resource teardown");
        isRunning = false;

        // 1. Stop the V2ray core
        try {
            V2rayCoreManager.getInstance().stopCore();
        } catch (Exception e) {
            Log.w(TAG, "cleanup: error stopping V2ray core", e);
        }

        // 2. Stop foreground service and remove notification
        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.w(TAG, "cleanup: stopForeground failed", e);
        }

        // 3. Destroy tun2socks process
        try {
            Process p = process;
            process = null;
            if (p != null) {
                p.destroy();
            }
        } catch (Exception e) {
            Log.w(TAG, "cleanup: error destroying tun2socks process", e);
        }

        // 4. Close VPN interface
        try {
            ParcelFileDescriptor pfd = mInterface;
            mInterface = null;
            if (pfd != null) {
                pfd.close();
            }
        } catch (Exception e) {
            Log.w(TAG, "cleanup: error closing VPN interface", e);
        }
    }

    private void setup() {
        Intent prepare_intent = prepare(this);
        if (prepare_intent != null) {
            return;
        }
        Builder builder = new Builder();
        builder.setSession(v2rayConfig.REMARK);
        builder.setMtu(1500);
        builder.addAddress("26.26.26.1", 30);

        if (v2rayConfig.BYPASS_SUBNETS == null || v2rayConfig.BYPASS_SUBNETS.isEmpty()) {
            builder.addRoute("0.0.0.0", 0);
        } else {
            for (String subnet : v2rayConfig.BYPASS_SUBNETS) {
                try {
                    String[] parts = subnet.split("/");
                    if (parts.length == 2) {
                        String address = parts[0];
                        int prefixLength = Integer.parseInt(parts[1]);
                        builder.addRoute(address, prefixLength);
                    }
                } catch (Exception e) {
                    Log.w(TAG, "setup: invalid bypass subnet: " + subnet, e);
                }
            }
        }
        if (v2rayConfig.BLOCKED_APPS != null) {
            for (int i = 0; i < v2rayConfig.BLOCKED_APPS.size(); i++) {
                try {
                    builder.addDisallowedApplication(v2rayConfig.BLOCKED_APPS.get(i));
                } catch (Exception e) {
                    // ignore — app not installed
                }
            }
        }
        try {
            JSONObject json = new JSONObject(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            if (json.has("dns")) {
                JSONObject dnsObject = json.getJSONObject("dns");
                if (dnsObject.has("servers")) {
                    JSONArray serversArray = dnsObject.getJSONArray("servers");
                    for (int i = 0; i < serversArray.length(); i++) {
                        try {
                            Object entry = serversArray.get(i);
                            if (entry instanceof String) {
                                String dnsStr = (String) entry;
                                // Skip non-IP DNS entries like 'fakedns' — Android VPN builder needs real IPs
                                if (dnsStr.equals("fakedns") || dnsStr.equals("localhost")) continue;
                                builder.addDnsServer(dnsStr);
                            } else if (entry instanceof JSONObject) {
                                JSONObject obj = (JSONObject) entry;
                                if (obj.has("address")) {
                                    builder.addDnsServer(obj.getString("address"));
                                }
                            }
                        } catch (Exception ignored) {
                        }
                    }
                }
            }
        } catch (Exception e) {
            // If parsing fails, add sane fallback DNS
            try {
                builder.addDnsServer("1.1.1.1");
            } catch (Exception ignored) {
            }
            try {
                builder.addDnsServer("8.8.8.8");
            } catch (Exception ignored) {
            }
        }
        try {
            if (mInterface != null) {
                mInterface.close();
            }
        } catch (Exception e) {
            // ignore
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
        }

        try {
            mInterface = builder.establish();
            if (mInterface == null) {
                Log.e(TAG, "setup: VPN interface is null — VPN permission may have been revoked");
                stopSelf();
                return;
            }
            isRunning = true;
            runTun2socks();
        } catch (Exception e) {
            Log.e(TAG, "setup: failed to establish VPN interface", e);
            stopSelf();
        }
    }

    private void runTun2socks() {
        if (!isRunning) return;
        ArrayList<String> cmd = new ArrayList<>(
                Arrays.asList(new File(getApplicationInfo().nativeLibraryDir, "libtun2socks.so").getAbsolutePath(),
                        "--netif-ipaddr", "26.26.26.2",
                        "--netif-netmask", "255.255.255.252",
                        "--socks-server-addr", "127.0.0.1:" + v2rayConfig.LOCAL_SOCKS5_PORT,
                        "--tunmtu", "1500",
                        "--sock-path", "sock_path",
                        "--enable-udprelay",
                        "--loglevel", "error"));
        try {
            ProcessBuilder processBuilder = new ProcessBuilder(cmd);
            processBuilder.redirectErrorStream(true);
            process = processBuilder.directory(getApplicationContext().getFilesDir()).start();
            new Thread(() -> {
                try {
                    Process p = process;
                    if (p != null) {
                        p.waitFor();
                    }
                    if (isRunning) {
                        runTun2socks();
                    }
                } catch (InterruptedException e) {
                    // ignore — thread interrupted during shutdown
                }
            }, "Tun2socks_Thread").start();
            sendFileDescriptor();
        } catch (Exception e) {
            Log.e(TAG, "runTun2socks: failed to start tun2socks", e);
            stopSelf();
        }
    }

    private void sendFileDescriptor() {
        final ParcelFileDescriptor pfd = mInterface;
        if (pfd == null) {
            Log.e(TAG, "sendFileDescriptor: mInterface is null, cannot send fd");
            return;
        }
        final FileDescriptor tunFd;
        try {
            tunFd = pfd.getFileDescriptor();
        } catch (Exception e) {
            Log.e(TAG, "sendFileDescriptor: failed to get file descriptor", e);
            return;
        }
        if (tunFd == null || !tunFd.valid()) {
            Log.e(TAG, "sendFileDescriptor: tunFd is invalid");
            return;
        }
        String localSocksFile = new File(getApplicationContext().getFilesDir(), "sock_path").getAbsolutePath();
        new Thread(() -> {
            int tries = 0;
            while (isRunning && tries <= 5) {
                try {
                    Thread.sleep(50L * tries);
                    LocalSocket clientLocalSocket = new LocalSocket();
                    clientLocalSocket
                            .connect(new LocalSocketAddress(localSocksFile, LocalSocketAddress.Namespace.FILESYSTEM));
                    if (!clientLocalSocket.isConnected()) {
                        Log.w(TAG, "sendFd: unable to connect to sock file [" + localSocksFile + "]");
                    } else {
                        Log.d(TAG, "sendFd: connected to sock file [" + localSocksFile + "]");
                    }
                    OutputStream clientOutStream = clientLocalSocket.getOutputStream();
                    clientLocalSocket.setFileDescriptorsForSend(new FileDescriptor[] { tunFd });
                    clientOutStream.write(32);
                    clientLocalSocket.setFileDescriptorsForSend(null);
                    clientLocalSocket.shutdownOutput();
                    clientLocalSocket.close();
                    break;
                } catch (Exception e) {
                    Log.w(TAG, "sendFd: attempt " + tries + " failed", e);
                    tries += 1;
                }
            }
        }, "sendFd_Thread").start();
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "onDestroy called");
        cleanup();
        try {
            super.onDestroy();
        } catch (Exception e) {
            Log.w(TAG, "super.onDestroy() threw", e);
        }
    }

    @Override
    public void onRevoke() {
        Log.i(TAG, "onRevoke called — VPN permission revoked");
        cleanup();
        stopSelf();
    }

    @Override
    public boolean onProtect(int socket) {
        return protect(socket);
    }

    @Override
    public Service getService() {
        return this;
    }

    @Override
    public void startService() {
        setup();
    }

    @Override
    public void stopService() {
        cleanup();
        stopSelf();
    }
}

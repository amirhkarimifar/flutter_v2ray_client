package dev.amirzr.flutter_v2ray_client.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;

import androidx.annotation.Nullable;

import dev.amirzr.flutter_v2ray_client.v2ray.core.V2rayCoreManager;
import dev.amirzr.flutter_v2ray_client.v2ray.interfaces.V2rayServicesListener;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.V2rayConfig;

public class V2rayProxyOnlyService extends Service implements V2rayServicesListener {
    private static final String TAG = "V2rayProxyOnlyService";

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
                V2rayConfig v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
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

    @Override
    public void onDestroy() {
        try {
            V2rayCoreManager.getInstance().stopCore();
        } catch (Exception e) {
            Log.w(TAG, "Error stopping core in onDestroy", e);
        }
        try {
            super.onDestroy();
        } catch (Exception e) {
            Log.w(TAG, "super.onDestroy() threw", e);
        }
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public boolean onProtect(int socket) {
        return true;
    }

    @Override
    public Service getService() {
        return this;
    }

    @Override
    public void startService() {
        // ignore — proxy-only mode doesn't need VPN tunnel setup
    }

    @Override
    public void stopService() {
        try {
            stopSelf();
        } catch (Exception e) {
            Log.w(TAG, "stopSelf failed", e);
        }
    }
}

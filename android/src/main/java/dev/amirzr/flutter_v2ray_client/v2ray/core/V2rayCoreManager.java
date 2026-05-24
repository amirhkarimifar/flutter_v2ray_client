package dev.amirzr.flutter_v2ray_client.v2ray.core;

import static dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities.getUserAssetsPath;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.CountDownTimer;
import android.util.Log;
import android.util.Pair;

import androidx.annotation.RequiresApi;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;

import dev.amirzr.flutter_v2ray_client.v2ray.interfaces.V2rayServicesListener;
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayProxyOnlyService;
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayVPNService;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.V2rayConfig;

import org.json.JSONObject;

import java.util.concurrent.locks.ReentrantLock;

import libv2ray.CoreCallbackHandler;
import libv2ray.CoreController;
import libv2ray.Libv2ray;
import libv2ray.V2RayProtector;

public final class V2rayCoreManager {
    private static final int NOTIFICATION_ID = 1;
    private volatile static V2rayCoreManager INSTANCE;
    // Lock to serialize all native xray core operations (startLoop, stopLoop, measureOutboundDelay)
    // Concurrent access to libv2jni.so causes native crashes (SIGSEGV)
    private final ReentrantLock coreLock = new ReentrantLock();
    public V2rayServicesListener v2rayServicesListener = null;
    private CoreController coreController;
    public AppConfigs.V2RAY_STATES V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;
    private boolean isLibV2rayCoreInitialized = false;
    // Whether initCoreEnv has been called (needed for measureOutboundDelay even without VPN service)
    private volatile boolean isCoreEnvInitialized = false;
    private Context appContext;
    private CountDownTimer countDownTimer;
    private int seconds, minutes, hours;
    private long totalDownload, totalUpload, uploadSpeed, downloadSpeed;
    private String SERVICE_DURATION = "00:00:00";

    public static V2rayCoreManager getInstance() {
        if (INSTANCE == null) {
            synchronized (V2rayCoreManager.class) {
                if (INSTANCE == null) {
                    INSTANCE = new V2rayCoreManager();
                }
            }
        }
        return INSTANCE;
    }

    private void makeDurationTimer(final Context context, final boolean enable_traffic_statics) {
        // Cancel any existing timer to prevent leaked timer instances
        if (countDownTimer != null) {
            countDownTimer.cancel();
        }
        countDownTimer = new CountDownTimer(7200, 1000) {
            @RequiresApi(api = Build.VERSION_CODES.M)
            public void onTick(long millisUntilFinished) {

                seconds++;
                if (seconds == 59) {
                    minutes++;
                    seconds = 0;
                }
                if (minutes == 59) {
                    minutes = 0;
                    hours++;
                }
                if (hours == 23) {
                    hours = 0;
                }
                if (enable_traffic_statics) {
                    // Use tryLock to avoid blocking the timer and to prevent native crashes
                    // when queryStats overlaps with startLoop/stopLoop
                    if (coreLock.tryLock()) {
                        try {
                            downloadSpeed = (coreController != null ? coreController.queryStats("block", "downlink") : 0)
                                    + (coreController != null ? coreController.queryStats("proxy", "downlink") : 0);
                            uploadSpeed = (coreController != null ? coreController.queryStats("block", "uplink") : 0)
                                    + (coreController != null ? coreController.queryStats("proxy", "uplink") : 0);
                            totalDownload = totalDownload + downloadSpeed;
                            totalUpload = totalUpload + uploadSpeed;
                        } finally {
                            coreLock.unlock();
                        }
                    }
                    // If lock not available, skip stats this tick (core is busy with start/stop)
                }
                SERVICE_DURATION = Utilities.convertIntToTwoDigit(hours) + ":" + Utilities.convertIntToTwoDigit(minutes)
                        + ":" + Utilities.convertIntToTwoDigit(seconds);
                String packageName = context.getPackageName();
                Intent connection_info_intent = new Intent(packageName + ".V2RAY_CONNECTION_INFO");
                connection_info_intent.setPackage(packageName);
                connection_info_intent.putExtra("STATE", V2rayCoreManager.getInstance().V2RAY_STATE);
                connection_info_intent.putExtra("DURATION", SERVICE_DURATION);
                connection_info_intent.putExtra("UPLOAD_SPEED", uploadSpeed);
                connection_info_intent.putExtra("DOWNLOAD_SPEED", downloadSpeed);
                connection_info_intent.putExtra("UPLOAD_TRAFFIC", totalUpload);
                connection_info_intent.putExtra("DOWNLOAD_TRAFFIC", totalDownload);
                try {
                    context.sendBroadcast(connection_info_intent);
                } catch (Exception e) {
                    Log.w("V2rayCoreManager", "Failed to send connection info broadcast", e);
                }
            }

            public void onFinish() {
                countDownTimer.cancel();
                if (V2rayCoreManager.getInstance().isV2rayCoreRunning())
                    makeDurationTimer(context, enable_traffic_statics);
            }
        }.start();
    }

    /**
     * Store app context for lazy Go core initialization.
     * Called from V2rayController.init() before any pings.
     */
    public void setAppContext(Context context) {
        this.appContext = context.getApplicationContext();
    }

    /**
     * Ensure Go core environment is initialized. Safe to call multiple times.
     * Required before any Libv2ray static method (measureOutboundDelay, etc.).
     */
    private void ensureCoreEnvInitialized() {
        if (isCoreEnvInitialized) return;
        synchronized (this) {
            if (isCoreEnvInitialized) return;
            if (appContext != null) {
                try {
                    Libv2ray.initCoreEnv(getUserAssetsPath(appContext), "");
                    isCoreEnvInitialized = true;
                    Log.i(V2rayCoreManager.class.getSimpleName(), "initCoreEnv called for ping-only path");
                } catch (Exception e) {
                    Log.e(V2rayCoreManager.class.getSimpleName(), "ensureCoreEnvInitialized failed", e);
                }
            } else {
                Log.w(V2rayCoreManager.class.getSimpleName(),
                        "ensureCoreEnvInitialized: appContext is null — call setAppContext first");
            }
        }
    }

    public void setUpListener(Service targetService) {
        try {
            v2rayServicesListener = (V2rayServicesListener) targetService;
            appContext = targetService.getApplicationContext();
            Libv2ray.initCoreEnv(getUserAssetsPath(targetService.getApplicationContext()), "");
            isCoreEnvInitialized = true;

            // Register Android VPN socket protector with libv2ray (Go)
            Libv2ray.useProtector(new V2RayProtector() {
                @Override
                public boolean protect(long fd) {
                    if (v2rayServicesListener != null) {
                        return v2rayServicesListener.onProtect((int) fd);
                    }
                    return true;
                }
            });
            // Initialize controller with callback handler
            coreController = Libv2ray.newCoreController(new CoreCallbackHandler() {
                @Override
                public long onEmitStatus(long p0, String p1) {
                    // Currently unused; log for debugging
                    Log.d(V2rayCoreManager.class.getSimpleName(), "onEmitStatus => " + p0 + ": " + p1);
                    return 0;
                }

                @Override
                public long shutdown() {
                    if (v2rayServicesListener == null) {
                        Log.e(V2rayCoreManager.class.getSimpleName(), "shutdown failed => can`t find initial service.");
                        return -1;
                    }
                    try {
                        v2rayServicesListener.stopService();
                        v2rayServicesListener = null;
                        return 0;
                    } catch (Exception e) {
                        Log.e(V2rayCoreManager.class.getSimpleName(), "shutdown failed =>", e);
                        return -1;
                    }
                }

                @Override
                public long startup() {
                    if (v2rayServicesListener != null) {
                        try {
                            v2rayServicesListener.startService();
                        } catch (Exception e) {
                            Log.e(V2rayCoreManager.class.getSimpleName(), "startup failed => ", e);
                            return -1;
                        }
                    }
                    return 0;
                }
            });
            isLibV2rayCoreInitialized = true;
            SERVICE_DURATION = "00:00:00";
            seconds = 0;
            minutes = 0;
            hours = 0;
            uploadSpeed = 0;
            downloadSpeed = 0;
            totalDownload = 0;
            totalUpload = 0;
            Log.e(V2rayCoreManager.class.getSimpleName(), "setUpListener => new initialize from "
                    + v2rayServicesListener.getService().getClass().getSimpleName());
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "setUpListener failed => ", e);
            isLibV2rayCoreInitialized = false;
        }
    }

    public boolean startCore(final V2rayConfig v2rayConfig) {
        V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING;
        if (!isLibV2rayCoreInitialized) {
            Log.e(V2rayCoreManager.class.getSimpleName(),
                    "startCore failed => LibV2rayCore should be initialize before start.");
            return false;
        }
        coreLock.lock();
        try {
            if (isV2rayCoreRunning()) {
                stopCoreInternal();
            }
            if (coreController == null) {
                Log.e(V2rayCoreManager.class.getSimpleName(), "startCore failed => coreController is null.");
                return false;
            }
            // Configure protector target server and IP family preference before starting
            // core
            try {
                String server = v2rayConfig.CONNECTED_V2RAY_SERVER_ADDRESS + ":"
                        + v2rayConfig.CONNECTED_V2RAY_SERVER_PORT;
                Libv2ray.setProtectorServer(server, false);
            } catch (Exception ignored) {
            }
            coreController.startLoop(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED;
            if (isV2rayCoreRunning()) {
                // Always try to show notification, but handle failures gracefully
                // VPN will continue working even if notification fails
                showNotification(v2rayConfig);
            }
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "startCore failed =>", e);
            return false;
        } finally {
            coreLock.unlock();
        }
        // Start timer AFTER lock is released so queryStats won't race with startLoop
        makeDurationTimer(v2rayServicesListener.getService().getApplicationContext(),
                v2rayConfig.ENABLE_TRAFFIC_STATICS);
        return true;
    }

    public void stopCore() {
        coreLock.lock();
        try {
            stopCoreInternal();
        } finally {
            coreLock.unlock();
        }
    }

    /** Internal stop without acquiring lock - caller must hold coreLock */
    private void stopCoreInternal() {
        try {
            // Safely cancel notification - handle cases where service might be null
            if (v2rayServicesListener != null && v2rayServicesListener.getService() != null) {
                NotificationManager notificationManager = (NotificationManager) v2rayServicesListener.getService()
                        .getSystemService(Context.NOTIFICATION_SERVICE);
                if (notificationManager != null) {
                    notificationManager.cancel(NOTIFICATION_ID);
                }
            }
        } catch (Exception e) {
            Log.w("V2rayCoreManager", "Failed to cancel notification", e);
        }

        try {
            if (isV2rayCoreRunning()) {
                if (coreController != null) {
                    coreController.stopLoop();
                }
                v2rayServicesListener.stopService();
                Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore success => v2ray core stopped.");
            } else {
                Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore failed => v2ray core not running.");
            }
            sendDisconnectedBroadCast();
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore failed =>", e);
        }
    }

    private void sendDisconnectedBroadCast() {
        V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;
        SERVICE_DURATION = "00:00:00";
        seconds = 0;
        minutes = 0;
        hours = 0;
        uploadSpeed = 0;
        downloadSpeed = 0;
        if (v2rayServicesListener != null) {
            Context context = v2rayServicesListener.getService().getApplicationContext();
            String packageName = context.getPackageName();
            Intent connection_info_intent = new Intent(packageName + ".V2RAY_CONNECTION_INFO");
            connection_info_intent.setPackage(packageName);
            connection_info_intent.putExtra("STATE", V2rayCoreManager.getInstance().V2RAY_STATE);
            connection_info_intent.putExtra("DURATION", SERVICE_DURATION);
            connection_info_intent.putExtra("UPLOAD_SPEED", uploadSpeed);
            connection_info_intent.putExtra("DOWNLOAD_SPEED", downloadSpeed);
            connection_info_intent.putExtra("UPLOAD_TRAFFIC", totalUpload);
            connection_info_intent.putExtra("DOWNLOAD_TRAFFIC", totalDownload);
            try {
                context.sendBroadcast(connection_info_intent);
            } catch (Exception e) {
                Log.w("V2rayCoreManager", "Failed to send disconnected broadcast", e);
            }
        }
        if (countDownTimer != null) {
            countDownTimer.cancel();
        }
    }

    private String createNotificationChannelID(String appName) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            String channelId = "A_FLUTTER_V2RAY_SERVICE_CH_ID"; // default and constant ID
            try {
                if (v2rayServicesListener == null || v2rayServicesListener.getService() == null) {
                    return channelId;
                }

                NotificationManager notificationManager = (NotificationManager) v2rayServicesListener.getService()
                        .getSystemService(Context.NOTIFICATION_SERVICE);

                String channelName = appName + " Background Service";
                // Use IMPORTANCE_LOW (not DEFAULT) - this makes notification less intrusive
                // and works even when notifications are "blocked" (Android still allows low priority)
                NotificationChannel channel = new NotificationChannel(channelId, channelName,
                        NotificationManager.IMPORTANCE_LOW);
                channel.setDescription(channelName);
                channel.setLightColor(Color.DKGRAY);
                channel.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
                channel.setShowBadge(false); // Don't show badge
                channel.enableVibration(false); // No vibration
                channel.enableLights(false); // No lights
                channel.setSound(null, null); // No sound

                if (notificationManager != null) {
                    notificationManager.createNotificationChannel(channel);
                }
            } catch (Exception e) {
                Log.w("V2rayCoreManager", "Failed to create notification channel", e);
            }

            return channelId;
        }
        return "";
    }

    private void showNotification(final V2rayConfig v2rayConfig) {
        Service context = v2rayServicesListener.getService();
        if (context == null) {
            Log.w("V2rayCoreManager", "Cannot show notification - service context is null");
            return;
        }

        boolean isVpnService = (context instanceof V2rayVPNService);
        
        // Build notification regardless of permission status
        // VPN services MUST call startForeground() on Android 8.0+
        try {
            Intent launchIntent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
            if (launchIntent != null) {
                launchIntent.setAction("FROM_DISCONNECT_BTN");
                launchIntent.setFlags(
                        Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_NEW_TASK);
            }
            
            final int flags;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;
            } else {
                flags = PendingIntent.FLAG_UPDATE_CURRENT;
            }
            
            PendingIntent notificationContentPendingIntent = PendingIntent.getActivity(
                    context, 0, launchIntent, flags);

            String notificationChannelID = createNotificationChannelID(v2rayConfig.APPLICATION_NAME);

            Intent stopIntent;
            if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
                stopIntent = new Intent(context, V2rayProxyOnlyService.class);
            } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
                stopIntent = new Intent(context, V2rayVPNService.class);
            } else {
                return;
            }
            stopIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE);

            PendingIntent pendingIntent = PendingIntent.getService(
                    context, 0, stopIntent, flags);

            // Create minimal, silent notification
            NotificationCompat.Builder notificationBuilder = new NotificationCompat.Builder(context,
                    notificationChannelID)
                    .setSmallIcon(v2rayConfig.APPLICATION_ICON)
                    .setContentTitle(v2rayConfig.REMARK)
                    .setContentText("") // Minimal text
                    .setPriority(NotificationCompat.PRIORITY_LOW) // Low priority
                    .setShowWhen(false)
                    .setOnlyAlertOnce(true)
                    .setContentIntent(notificationContentPendingIntent)
                    .setSilent(true)
                    .setOngoing(true)
                    .setSound(null) // No sound
                    .setVibrate(null); // No vibration

            // Only add action button if we have the text for it
            if (v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME != null && 
                !v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME.isEmpty()) {
                notificationBuilder.addAction(0, v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME, 
                    notificationContentPendingIntent);
            }

            // CRITICAL: VPN services MUST call startForeground
            // Catch all possible exceptions to prevent crashes
            try {
                context.startForeground(NOTIFICATION_ID, notificationBuilder.build());
                Log.i("V2rayCoreManager", "Foreground service started successfully");
            } catch (SecurityException se) {
                // Android 14+ SecurityException when POST_NOTIFICATIONS denied
                Log.w("V2rayCoreManager", "SecurityException - notification permission denied", se);
                if (isVpnService) {
                    // Still crashes even with SecurityException - this is Android limitation
                    // Best we can do is log it
                    Log.e("V2rayCoreManager", "VPN service may crash due to notification permission denial");
                }
            } catch (IllegalStateException ise) {
                // Can happen if app is in background
                // Also catches ForegroundServiceStartNotAllowedException on Android 12+ (which extends IllegalStateException)
                Log.w("V2rayCoreManager", "IllegalStateException starting foreground", ise);
            } catch (RuntimeException re) {
                // Catch any other runtime exceptions
                Log.w("V2rayCoreManager", "RuntimeException starting foreground", re);
            } catch (Exception e) {
                Log.w("V2rayCoreManager", "Unexpected exception starting foreground", e);
            }
            
        } catch (Exception e) {
            Log.e("V2rayCoreManager", "Error building notification", e);
        }
    }

    public boolean isV2rayCoreRunning() {
        if (coreController != null) {
            return coreController.getIsRunning();
        }
        return false;
    }

    public Long getConnectedV2rayServerDelay() {
        coreLock.lock();
        try {
            if (coreController == null)
                return -1L;
            return coreController.measureDelay(AppConfigs.DELAY_URL);
        } catch (Exception e) {
            return -1L;
        } finally {
            coreLock.unlock();
        }
    }

    public Long getV2rayServerDelay(final String config, final String url) {
        // Ensure Go runtime is initialized before calling measureOutboundDelay.
        // On first app launch, pings can fire before VPN service creates (setUpListener),
        // calling into uninitialized Go code → SIGSEGV.
        ensureCoreEnvInitialized();
        coreLock.lock();
        try {
            // If core is currently running (user connected), skip ping to avoid conflict
            if (isV2rayCoreRunning()) {
                return -1L;
            }
            try {
                JSONObject config_json = new JSONObject(config);
                JSONObject new_routing_json = config_json.getJSONObject("routing");
                new_routing_json.remove("rules");
                config_json.remove("routing");
                config_json.put("routing", new_routing_json);
                return Libv2ray.measureOutboundDelay(config_json.toString(), url);
            } catch (Exception json_error) {
                Log.e("getV2rayServerDelay", json_error.toString());
                return Libv2ray.measureOutboundDelay(config, url);
            }
        } catch (Exception e) {
            Log.e("getV2rayServerDelayCore", e.toString());
            return -1L;
        } finally {
            coreLock.unlock();
        }
    }

}

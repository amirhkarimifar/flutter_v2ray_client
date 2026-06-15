package dev.amirzr.flutter_v2ray_client.v2ray.utils;

import android.util.Log;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;

/**
 * Manages logcat operations for V2Ray logs
 * Captures, filters, and provides access to system logs
 */
public class LogcatManager {
    private static final String TAG = "LogcatManager";
    private static volatile LogcatManager INSTANCE;

    // Buffer to store logs in memory (configurable limit)
    private List<String> logBuffer = Collections.synchronizedList(new ArrayList<>());
    private static final int MAX_LOG_LINES = 500;

    private LogcatManager() {
        // Private constructor for singleton
    }

    public static LogcatManager getInstance() {
        if (INSTANCE == null) {
            synchronized (LogcatManager.class) {
                if (INSTANCE == null) {
                    INSTANCE = new LogcatManager();
                }
            }
        }
        return INSTANCE;
    }

    /**
     * Fetches logs from logcat filtered by V2Ray related tags
     * 
     * @param packageName The application package name
     * @return List of log lines
     */
    public List<String> getLogs(String packageName) {
        List<String> logs = new ArrayList<>();

        try {
            LinkedHashSet<String> commandSet = new LinkedHashSet<>();
            commandSet.add("logcat");
            commandSet.add("-d"); // Dump mode - get all logs and exit
            commandSet.add("-v");
            commandSet.add("time"); // Time format
            commandSet.add("-s"); // Silent mode - only show specified tags
            // Filter for V2Ray related logs.
            // Includes native-crash tags (libc, DEBUG, Go, linker) so that a
            // crash inside libv2jni.so is actually visible: without these, a
            // native SIGSEGV / "dlopen failed" / Go fatal produces only empty
            // "beginning of crash" buffer headers, hiding why some devices
            // fail to connect.
            commandSet.add("GoLog,tun2socks," + packageName
                    + ",AndroidRuntime,System.err,V2rayCoreManager,FlutterV2rayPlugin"
                    + ",libc,DEBUG,Go,linker");

            Process process = Runtime.getRuntime().exec(commandSet.toArray(new String[0]));
            BufferedReader bufferedReader = new BufferedReader(
                    new InputStreamReader(process.getInputStream()));

            String line;
            while ((line = bufferedReader.readLine()) != null) {
                logs.add(line);
            }

            bufferedReader.close();

            // Update internal buffer
            synchronized (logBuffer) {
                logBuffer.clear();
                // Keep only the most recent MAX_LOG_LINES while retaining chronological order
                // (oldest -> newest)
                if (logs.size() > MAX_LOG_LINES) {
                    // Take the tail of the list (latest entries), but maintain order
                    logBuffer.addAll(logs.subList(logs.size() - MAX_LOG_LINES, logs.size()));
                } else {
                    logBuffer.addAll(logs);
                }
            }

        } catch (IOException e) {
            Log.e(TAG, "Failed to get logcat", e);
            logs.add("Error: Failed to retrieve logs - " + e.getMessage());
        }

        // Return logs in chronological order: oldest -> newest
        return logs;
    }

    /**
     * Clears the logcat buffer
     * 
     * @return true if successful, false otherwise
     */
    public boolean clearLogs() {
        try {
            LinkedHashSet<String> commandSet = new LinkedHashSet<>();
            commandSet.add("logcat");
            commandSet.add("-c"); // Clear logcat buffer

            Process process = Runtime.getRuntime().exec(commandSet.toArray(new String[0]));
            process.waitFor();

            // Clear internal buffer
            synchronized (logBuffer) {
                logBuffer.clear();
            }

            return true;
        } catch (IOException | InterruptedException e) {
            Log.e(TAG, "Failed to clear logcat", e);
            return false;
        }
    }

    /**
     * Gets logs from internal buffer (faster than fetching from logcat)
     * 
     * @return List of cached log lines
     */
    public List<String> getCachedLogs() {
        synchronized (logBuffer) {
            return new ArrayList<>(logBuffer);
        }
    }

    /**
     * Filters logs by search query
     * 
     * @param query Search string
     * @return Filtered list of log lines
     */
    public List<String> filterLogs(String query) {
        if (query == null || query.trim().isEmpty()) {
            return getCachedLogs();
        }

        List<String> filtered = new ArrayList<>();
        String lowerQuery = query.toLowerCase().trim();

        synchronized (logBuffer) {
            for (String log : logBuffer) {
                if (log.toLowerCase().contains(lowerQuery)) {
                    filtered.add(log);
                }
            }
        }

        return filtered;
    }

    /**
     * Gets the number of log lines in buffer
     * 
     * @return Number of log lines
     */
    public int getLogCount() {
        synchronized (logBuffer) {
            return logBuffer.size();
        }
    }
}

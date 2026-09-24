package com.neomanera.ipconnect.core.v2ray.utils;

import android.content.Context;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Makes the Go runtime's dying words survivable.
 *
 * <p>When xray-core hits an unrecoverable error the Go runtime writes
 * {@code fatal error: ...} or {@code panic: ...} followed by a goroutine dump to
 * file descriptor 2, restores the default signal handler, and re-raises the
 * signal so the OS produces a tombstone. Everything useful is in that fd 2
 * text. Everything that survives is the tombstone, whose only frame is
 * {@code runtime.raise} inside libgojni.so — the suicide call itself, which
 * names no cause.
 *
 * <p>On Android an app's stdout/stderr go to /dev/null unless the app is
 * debuggable, so in a release build that text is discarded by the OS before
 * anything can read it. This class redirects fd 2 into a pipe, mirrors every
 * line to logcat, and — once a line looks like the start of a Go fatal report —
 * persists the report to disk. The Go process dies moments later, so the file is
 * the only way the text outlives it; the next app launch picks it up.
 *
 * <p>Install this in the :RunSoLibV2RayDaemon process only, and before the Go
 * library is loaded, or the first fault is still lost.
 */
public final class GoCrashCapture {
    private static final String TAG = "GoStderr";
    private static final String CRASH_FILE = "last_go_crash.txt";
    /** Lines kept before the fatal marker, for the context leading up to it. */
    private static final int PRE_CONTEXT_LINES = 40;
    /** Hard cap so a runaway goroutine dump cannot fill the user's storage. */
    private static final int MAX_CAPTURED_LINES = 600;

    private static volatile boolean installed = false;

    private GoCrashCapture() {
    }

    /**
     * Redirects native stderr into logcat and captures any Go fatal report.
     * Safe to call more than once; only the first call takes effect. Failure is
     * never fatal — losing the diagnostics must not cost the user their VPN.
     */
    public static synchronized void install(final Context context) {
        if (installed) return;
        installed = true;

        final File crashFile = new File(context.getFilesDir(), CRASH_FILE);
        try {
            final FileDescriptor[] pipe = Os.pipe();
            // fd 2 now refers to the write end; the Go runtime writes there
            // without knowing anything has changed.
            Os.dup2(pipe[1], 2);

            final Thread pump = new Thread(() -> drain(pipe[0], crashFile), "go-stderr-pump");
            pump.setDaemon(true);
            pump.start();
            Log.i(TAG, "native stderr redirected to logcat");
        } catch (ErrnoException | RuntimeException e) {
            // Nothing is redirected, so Go's output keeps going to /dev/null —
            // exactly the status quo this class exists to improve on.
            Log.w(TAG, "could not redirect native stderr; Go diagnostics stay lost", e);
        }
    }

    private static void drain(final FileDescriptor readEnd, final File crashFile) {
        final Deque<String> preContext = new ArrayDeque<>(PRE_CONTEXT_LINES);
        StringBuilder report = null;
        int capturedLines = 0;

        try (BufferedReader reader =
                     new BufferedReader(new InputStreamReader(new FileInputStream(readEnd)))) {
            String line;
            while ((line = reader.readLine()) != null) {
                Log.e(TAG, line);

                if (report == null) {
                    if (isFatalMarker(line)) {
                        report = new StringBuilder();
                        for (String earlier : preContext) {
                            report.append(earlier).append('\n');
                        }
                        report.append(line).append('\n');
                        capturedLines = 1;
                    } else {
                        if (preContext.size() == PRE_CONTEXT_LINES) preContext.removeFirst();
                        preContext.addLast(line);
                    }
                } else if (capturedLines < MAX_CAPTURED_LINES) {
                    report.append(line).append('\n');
                    capturedLines++;
                    // Flush as we go: the process is about to be killed by the
                    // re-raised signal and there is no chance to finish reading.
                    writeReport(crashFile, report.toString());
                }
            }
        } catch (IOException e) {
            Log.w(TAG, "stderr pump stopped", e);
        }
    }

    /** The two ways the Go runtime opens an unrecoverable report. */
    private static boolean isFatalMarker(final String line) {
        return line.startsWith("fatal error:")
                || line.startsWith("panic:")
                || line.startsWith("runtime: ");
    }

    private static void writeReport(final File crashFile, final String text) {
        try (FileOutputStream out = new FileOutputStream(crashFile, false)) {
            out.write(text.getBytes("UTF-8"));
            out.flush();
            out.getFD().sync();
        } catch (IOException e) {
            Log.w(TAG, "could not persist Go crash report", e);
        }
    }

    /**
     * Returns the Go fatal report left by a previous run and deletes it, or null
     * if the last run did not die this way. Called from the main process, which
     * is the one still alive to report it.
     */
    public static String consumeLastCrash(final Context context) {
        final File crashFile = new File(context.getFilesDir(), CRASH_FILE);
        if (!crashFile.exists()) return null;
        try (BufferedReader reader =
                     new BufferedReader(new InputStreamReader(new FileInputStream(crashFile)))) {
            final StringBuilder text = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                text.append(line).append('\n');
            }
            return text.length() == 0 ? null : text.toString();
        } catch (IOException e) {
            Log.w(TAG, "could not read Go crash report", e);
            return null;
        } finally {
            //noinspection ResultOfMethodCallIgnored
            crashFile.delete();
        }
    }
}

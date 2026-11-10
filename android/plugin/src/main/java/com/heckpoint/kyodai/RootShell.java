package com.heckpoint.kyodai;

import android.content.Context;
import android.provider.Settings;
import android.os.IBinder;
import android.os.Parcel;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.Charset;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.UUID;

/**
 * Runs shell scripts as root through the vendor daemons shipped on gaming handhelds:
 * AYN/Retroid expose a "PServerBinder" system service; Ayaneo ships /product/bin/xsu.
 * Neither daemon reports a script's exit code and both return only the first line of
 * output, so scripts are written to a file and run through a wrapper that captures
 * full output to a file and echoes the exit code as the last line.
 *
 * Approach ported from argosy-launcher (com.nendo.argosy.util.RootShell/PServerExecutor/
 * XsuExecutor), which uses the same route for LED control and save-folder access.
 */
public final class RootShell {

    public static final class Result {
        public final Integer exitCode;
        public final String output;

        Result(Integer exitCode, String output) {
            this.exitCode = exitCode;
            this.output = output;
        }

        public boolean succeeded() {
            return exitCode != null && exitCode == 0;
        }
    }

    private static final String TAG = "KyodaiBridge";
    private static final String WORK_DIR = "root-shell";
    private static final String SCRIPT_NAME = "root-op.sh";
    private static final String WRAPPER_NAME = "root-run.sh";
    private static final String OUTPUT_NAME = "run-output.txt";
    private static final String RC_NAME = "run-rc.txt";
    private static final AtomicInteger SETTINGS_WRAPPER_ID = new AtomicInteger(1);

    private RootShell() {}

    public static boolean isAvailable() {
        return PServer.isAvailable() || Xsu.isAvailable();
    }

    public static boolean isAvailable(Context context) {
        return PServer.isAvailable() || Xsu.isAvailable() || SettingsRoot.isAvailable(context);
    }

    /** Single-string quoting for shell script bodies. */
    public static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }

    private static String execute(Context context, File wrapper, File rcFile) throws Exception {
        if (PServer.isAvailable()) {
            return PServer.execute("sh " + wrapper.getAbsolutePath());
        }
        if (Xsu.isAvailable()) {
            return Xsu.execute("sh " + wrapper.getAbsolutePath());
        }
        return SettingsRoot.execute(context, wrapper, rcFile);
    }

    /**
     * Runs {@code body} as root. Returns null when no vendor daemon exists or the
     * route refused the call. Scripts must be built from fixed strings with
     * {@link #quote(String)} for any path; never interpolate user/ROM-derived text.
     */
    public static Future<Result> submit(Context context, String body) {
        ExecutorService executor = Executors.newSingleThreadExecutor(runnable -> {
            Thread thread = new Thread(runnable, "KyodaiRootShell");
            thread.setDaemon(true);
            return thread;
        });
        Future<Result> future = executor.submit(() -> runInternal(context, body));
        executor.shutdown();
        return future;
    }

    public static Result run(Context context, String body) {
        Future<Result> future = submit(context, body);
        try {
            return future.get(20, TimeUnit.SECONDS);
        } catch (TimeoutException e) {
            future.cancel(true);
            Log.w(TAG, "root shell timed out");
            return new Result(null, "timeout");
        } catch (Exception e) {
            Log.w(TAG, "root shell failed: " + e.getMessage());
            return null;
        } finally {
            future.cancel(true);
        }
    }

    private static Result runInternal(Context context, String body) {
        File dir = null;
        if (!isAvailable(context)) return null;
        boolean settingsRoute = !PServer.isAvailable() && !Xsu.isAvailable();
        File wrapper = null;
        try {
            // Unique per invocation: concurrent task/session operations, including
            // calls from different Kyodai processes, never share request files.
            dir = new File(context.getCacheDir(), WORK_DIR + "/" + UUID.randomUUID().toString());
            dir.mkdirs();
            dir.setExecutable(true, false);

            File script = new File(dir, SCRIPT_NAME);
            writeText(script, body + "\n");

            File output = new File(dir, OUTPUT_NAME);
            output.delete();

            // The settings bridge rejects long commands, so its wrapper uses a
            // short app-private path. Output and exit-code files stay unique.
            wrapper = settingsRoute
                    ? new File(context.getCacheDir(), "r" + SETTINGS_WRAPPER_ID.getAndIncrement())
                    : new File(dir, WRAPPER_NAME);
            File rcFile = new File(dir, RC_NAME);
            writeText(wrapper,
                    "sh " + script.getAbsolutePath() + " > " + output.getAbsolutePath() + " 2>&1\n" +
                    "rc=$?\n" +
                    "chmod 644 " + output.getAbsolutePath() + "\n" +
                    (settingsRoute ? "echo $rc > " + rcFile.getAbsolutePath() + "\n" +
                            "chmod 644 " + rcFile.getAbsolutePath() + "\n" : "echo $rc\n"));

            script.setReadable(true, false);
            wrapper.setReadable(true, false);

            String exitStr = execute(context, wrapper, rcFile);
            Integer exit = null;
            if (exitStr != null) {
                try {
                    exit = Integer.parseInt(exitStr.trim());
                } catch (NumberFormatException ignored) {}
            }
            String out = output.canRead() ? readAll(output) : "";
            return new Result(exit, out);
        } catch (Exception e) {
            Log.w(TAG, "root shell failed: " + e.getMessage());
            return null;
        } finally {
            if (settingsRoute && wrapper != null) wrapper.delete();
            deleteRecursively(dir);
        }
    }

    private static void deleteRecursively(File file) {
        if (file == null || !file.exists()) return;
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) deleteRecursively(child);
        }
        file.delete();
    }

    private static void writeText(File file, String text) throws Exception {
        FileOutputStream fos = new FileOutputStream(file);
        try {
            fos.write(text.getBytes(Charset.forName("UTF-8")));
        } finally {
            fos.close();
        }
    }

    private static String readAll(File file) throws Exception {
        FileInputStream fis = new FileInputStream(file);
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = fis.read(buf)) != -1) {
                bos.write(buf, 0, n);
            }
            return bos.toString("UTF-8");
        } finally {
            fis.close();
        }
    }

    /** AYN/Retroid: root command execution via the PServerBinder system service. */
    static final class PServer {
        private static IBinder binder;
        private static boolean probed = false;
        private static Boolean callWorks = null;

        static synchronized boolean isAvailable() {
            if (binder != null && !binder.isBinderAlive()) {
                binder = null;
                probed = false;
                callWorks = null;
            }
            if (!probed) {
                probed = true;
                try {
                    Class<?> serviceManager = Class.forName("android.os.ServiceManager");
                    binder = (IBinder) serviceManager
                            .getDeclaredMethod("getService", String.class)
                            .invoke(null, "PServerBinder");
                } catch (Throwable t) {
                    binder = null;
                }
            }
            if (binder == null || !binder.isBinderAlive()) return false;
            if (callWorks == null) {
                boolean ok = false;
                try {
                    String out = transact("id");
                    ok = out != null && out.contains("uid=0");
                } catch (Throwable t) {
                    ok = false;
                }
                callWorks = ok;
                if (!ok) Log.i(TAG, "PServerBinder present but calls are denied; root daemon unusable");
            }
            return callWorks;
        }

        /** The daemon returns only the first line of command output. */
        static String execute(String cmd) throws Exception {
            if (!isAvailable()) throw new IllegalStateException("PServerBinder not available");
            return transact(cmd);
        }

        private static String transact(String cmd) throws Exception {
            Parcel data = Parcel.obtain();
            Parcel reply = Parcel.obtain();
            try {
                data.writeStringArray(new String[]{cmd, "1"});
                boolean transacted = binder.transact(0, data, reply, 0);
                if (!transacted) throw new IllegalStateException("PServerBinder rejected transaction");
                byte[] bytes = reply.createByteArray();
                if (bytes == null) return null;
                String result = new String(bytes, Charset.defaultCharset()).trim();
                return "null".equals(result) ? null : result;
            } finally {
                data.recycle();
                reply.recycle();
            }
        }
    }

    /** AYN Android 13: OdinSettings' unescaped display_pwm_value observer. */
    static final class SettingsRoot {
        private static final String KEY = "display_pwm_value";
        private static final Object LOCK = new Object();
        private static Boolean available;

        static synchronized boolean isAvailable(Context context) {
            if (available != null) return available;
            synchronized (LOCK) {
                if (available != null) return available;
                if (!Settings.System.canWrite(context)) {
                    available = false;
                    Log.i(TAG, "SettingsRoot unavailable: modify-system-settings not granted");
                    return false;
                }
                File dir = new File(context.getCacheDir(), "rp");
                try {
                    dir.mkdirs();
                    File wrapper = new File(dir, "r");
                    File output = new File(dir, "o");
                    File rc = new File(dir, "c");
                    writeText(wrapper,
                            "id > " + output.getAbsolutePath() + " 2>&1\n" +
                            "echo $? > " + rc.getAbsolutePath() + "\n" +
                            "chmod 644 " + output.getAbsolutePath() + " " + rc.getAbsolutePath() + "\n");
                    String rcText = execute(context, wrapper, rc);
                    String outputText = readAll(output);
                    available = "0".equals(rcText) && outputText.contains("uid=0");
                    if (!available) Log.i(TAG, "SettingsRoot probe did not return root");
                } catch (Exception e) {
                    available = false;
                    Log.i(TAG, "SettingsRoot probe failed: " + e.getMessage());
                } finally {
                    deleteRecursively(dir);
                }
                return available;
            }
        }

        /** Executes the short wrapper and reads its exit-code file. */
        static String execute(Context context, File wrapper, File rcFile) throws Exception {
            synchronized (LOCK) {
                rcFile.delete();
                String old = Settings.System.getString(context.getContentResolver(), KEY);
                try {
                    boolean injected = Settings.System.putString(context.getContentResolver(), KEY,
                            "\";sh " + wrapper.getAbsolutePath() + ";#");
                    if (!injected) throw new IllegalStateException("settings injection rejected");
                    String rc = null;
                    long deadline = System.currentTimeMillis() + 15000;
                    while (System.currentTimeMillis() < deadline) {
                        if (rcFile.isFile()) {
                            try {
                                String value = readAll(rcFile).trim();
                                if (!value.isEmpty()) {
                                    rc = value;
                                    break;
                                }
                            } catch (Exception ignored) {}
                        }
                        Thread.sleep(25);
                    }
                    if (rc == null) throw new IllegalStateException("settings root timed out");
                    return rc;
                } finally {
                    Settings.System.putString(context.getContentResolver(), KEY, old);
                }
            }
        }
    }

    /** Ayaneo: root via the vendor /product/bin/xsu binary (always exits 0). */
    static final class Xsu {
        private static final String XSU_PATH = "/product/bin/xsu";
        private static final String ROOT_UID_MARKER = "uid=0(";
        private static Boolean available = null;

        static synchronized boolean isAvailable() {
            if (available == null) {
                boolean ok = false;
                try {
                    if (new File(XSU_PATH).canExecute()) {
                        String out = execute("id");
                        ok = out != null && out.contains(ROOT_UID_MARKER);
                    }
                } catch (Throwable t) {
                    ok = false;
                }
                available = ok;
            }
            return available;
        }

        static String execute(String command) throws Exception {
            Process process = new ProcessBuilder(XSU_PATH, command)
                    .redirectErrorStream(true)
                    .start();
            try {
                if (!process.waitFor(15, TimeUnit.SECONDS)) {
                    process.destroyForcibly();
                    throw new IllegalStateException("xsu timed out");
                }
                return readAll(process.getInputStream());
            } finally {
                if (process.isAlive()) process.destroyForcibly();
            }
        }

        private static String readAll(java.io.InputStream in) throws Exception {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) {
                bos.write(buf, 0, n);
            }
            return bos.toString("UTF-8");
        }
    }
}

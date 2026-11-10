package com.heckpoint.kyodai;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.net.wifi.WifiManager;
import android.os.BatteryManager;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;

import androidx.core.content.ContextCompat;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Always-on battery savers that act while the display is off (no settings UI):
 *
 *  - Wi-Fi saver: 30 s after the screen turns off, disable Wi-Fi via root
 *    ({@code svc wifi disable}) and re-enable it when the screen wakes.
 *  - Bluetooth saver: same 30 s mark, {@code svc bluetooth disable} when BT
 *    was on; re-enabled on wake. State is read via root
 *    ({@code settings get global bluetooth_on}) so no BT permissions are needed.
 *  - Governor saver: at the same 30 s mark, drop every cpufreq policy to
 *    "powersave" (or "schedutil" when powersave is unavailable) and restore
 *    the previous governor on wake. Vendor performance modes can otherwise
 *    keep clocks boosted through sleep.
 *
 * While a download/sync/extraction foreground service is active, NOTHING is
 * cut (radios or governor) — those jobs hold the shared wake lock anyway and
 * slowing them via powersave would only cost time. A retained game session
 * vetoes only the radios: a suspended game does no CPU work, so the governor
 * drop remains safe savings there.
 *
 * Docked/charging devices are left alone: nothing is cut while charging, and
 * plugging in mid-sleep restores anything the saver had disabled (a docked
 * sleeping device stays reachable). Unplugging mid-sleep starts a fresh 30 s
 * countdown.
 *
 * All of this requires a vendor root daemon (see {@link RootShell}); on
 * devices without one the receiver is never armed and everything no-ops.
 *
 * What Kyodai disabled is persisted in SharedPreferences so a process death
 * while asleep can't leave radios/governors stranded: {@link #init(Context)}
 * (called from the plugin constructor, i.e. every app launch, which implies
 * the screen is on) restores anything the saver had turned off.
 *
 * This class is also the central job-lock holder: while any download / sync /
 * extraction foreground service reports an active job ({@link #jobStarted()}),
 * a shared partial wake lock + WifiLock keep the CPU and the Wi-Fi radio alive
 * so the job survives the display turning off. The foreground services alone
 * only protect the process from the LMK — without a wake lock the kernel
 * suspends the device seconds after screen-off and the job freezes mid-socket.
 * Mirrors the lock pattern in GameSessionForegroundService.
 */
public final class SleepSaver {

    private static final String TAG = "KyodaiSleepSaver";
    private static final String PREFS = "kyodai_sleep_saver";
    private static final String KEY_WIFI_DISABLED = "wifi_disabled_by_saver";
    private static final String KEY_BT_DISABLED = "bt_disabled_by_saver";
    private static final String KEY_GOVERNOR_SAVED = "governor_saved"; // "path=governor;path=governor"
    // Cross-process job flag: the game-session service lives in its own
    // process (:session), where the AtomicInteger below is invisible. It
    // records its activity here instead; same UID => same prefs file.
    private static final String KEY_SESSION_ACTIVE = "session_job_active";

    private static final long DELAY_MS = 30_000L;
    private static final String CPUFREQ_ROOT = "/sys/devices/system/cpu/cpufreq";
    // Delay is delivered by AlarmManager, NOT a Handler timer: on battery the
    // kernel suspends seconds after screen-off and Handler (uptime-based)
    // timers freeze until the next wakeup — the apply would never run.
    // setAndAllowWhileIdle fires even in doze and needs no permission.
    private static final String ACTION_SLEEP_CHECK = "com.heckpoint.kyodai.SLEEP_CHECK";
    // Partial wake lock held while apply/restore root calls run on the worker:
    // the alarm's own wake lock only covers onReceive.
    private static final long APPLY_WAKE_LOCK_MS = 20_000L;
    // Safety timeout for the background-job wake lock; mirrors the session
    // service's cap. Released when the last job finishes in the normal path.
    private static final long JOB_WAKE_LOCK_TIMEOUT_MS = 12L * 60 * 60 * 1000;

    private static final Object LOCK = new Object();
    private static final AtomicInteger activeJobs = new AtomicInteger(0);
    private static final ExecutorService worker = Executors.newSingleThreadExecutor();

    private static Context appContext;
    private static BroadcastReceiver screenReceiver;
    private static PendingIntent sleepAlarm;
    // Last plugged-in state from ACTION_BATTERY_CHANGED; -1 = not yet known.
    private static int lastPlugged = -1;
    // Held (process-locally) while activeJobs > 0. Guarded by LOCK.
    private static PowerManager.WakeLock jobWakeLock;
    private static WifiManager.WifiLock jobWifiLock;

    private SleepSaver() {}

    // ------------------------------------------------------------------
    // Active-job tracking (download / sync / extractor foreground services)
    // The 0->1 / ->0 transitions acquire/release the shared job locks; the
    // transitions are serialized on LOCK so a racing start/finish pair can't
    // strand an acquired lock (release-before-acquire completing).
    // ------------------------------------------------------------------

    public static void jobStarted() {
        synchronized (LOCK) {
            if (activeJobs.getAndIncrement() == 0) {
                acquireJobLocksLocked();
            }
        }
    }

    public static void jobFinished() {
        synchronized (LOCK) {
            if (activeJobs.updateAndGet(v -> Math.max(0, v - 1)) == 0) {
                releaseJobLocksLocked();
            }
        }
    }

    /**
     * Holds a partial wake lock (time-boxed) and a high-perf WiFi lock while
     * any background job is active, so downloads/syncs/extractions continue
     * with the display off. Same pattern as
     * GameSessionForegroundService.acquireSessionLocks(). Failure degrades to
     * pre-lock behavior (jobs stall while suspended) — never fatal.
     */
    private static void acquireJobLocksLocked() {
        Context ctx = appContext;
        if (ctx == null) return;
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm != null && jobWakeLock == null) {
                jobWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kyodai:background_jobs");
                jobWakeLock.setReferenceCounted(false);
                jobWakeLock.acquire(JOB_WAKE_LOCK_TIMEOUT_MS);
                Log.d(TAG, "Background-job wake lock acquired");
            }
            WifiManager wm = (WifiManager) ctx.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wm != null && jobWifiLock == null) {
                jobWifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "kyodai:background_jobs");
                jobWifiLock.setReferenceCounted(false);
                jobWifiLock.acquire();
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to acquire background-job locks: " + e.getMessage());
        }
    }

    private static void releaseJobLocksLocked() {
        if (jobWakeLock != null) {
            try {
                if (jobWakeLock.isHeld()) jobWakeLock.release();
            } catch (Exception ignored) {}
            jobWakeLock = null;
            Log.d(TAG, "Background-job wake lock released");
        }
        if (jobWifiLock != null) {
            try {
                if (jobWifiLock.isHeld()) jobWifiLock.release();
            } catch (Exception ignored) {}
            jobWifiLock = null;
        }
    }

    /**
     * Cross-process job tracking for the game-session service, which runs in
     * its own process (:session) and therefore can't touch the AtomicInteger
     * above. Writes go to SharedPreferences (shared per-UID).
     */
    public static void sessionJobStarted(Context ctx) {
        if (ctx == null) return;
        ctx.getApplicationContext()
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_SESSION_ACTIVE, true).apply();
    }

    public static void sessionJobFinished(Context ctx) {
        if (ctx == null) return;
        ctx.getApplicationContext()
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_SESSION_ACTIVE, false).apply();
    }

    public static boolean hasActiveJobs() {
        if (activeJobs.get() > 0) return true;
        Context ctx = appContext;
        if (ctx == null) return false;
        if (!prefs().getBoolean(KEY_SESSION_ACTIVE, false)) return false;
        // Stale-flag guard: a violently killed session process never clears
        // its flag, so verify the :session process actually exists before
        // letting it veto the Wi-Fi saver.
        if (!isSessionProcessAlive(ctx)) {
            prefs().edit().putBoolean(KEY_SESSION_ACTIVE, false).apply();
            return false;
        }
        return true;
    }

    private static boolean isSessionProcessAlive(Context ctx) {
        try {
            android.app.ActivityManager am =
                (android.app.ActivityManager) ctx.getSystemService(Context.ACTIVITY_SERVICE);
            if (am == null) return false;
            String sessionProc = ctx.getPackageName() + ":session";
            for (android.app.ActivityManager.RunningAppProcessInfo p : am.getRunningAppProcesses()) {
                if (sessionProc.equals(p.processName)) return true;
            }
        } catch (Exception ignored) {}
        return false;
    }

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    public static boolean isSupported() {
        return appContext != null && RootShell.isAvailable(appContext);
    }

    public static boolean isDisplayInteractive(Context context) {
        if (context == null) return true;
        PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        return pm == null || pm.isInteractive();
    }

    /** Called once from the plugin constructor; safe to call again. */
    public static void init(Context context) {
        if (context == null) return;
        synchronized (LOCK) {
            appContext = context.getApplicationContext();
            armReceiverLocked();
        }
        // Every app launch implies the screen is on: restore anything a
        // previous process left disabled (e.g. we were killed while asleep).
        worker.execute(SleepSaver::restoreAll);
    }

    // ------------------------------------------------------------------
    // Receiver management
    // ------------------------------------------------------------------

    /** Always-on: armed whenever a vendor root daemon exists. */
    private static void armReceiverLocked() {
        if (screenReceiver != null || !isSupported()) return;
        screenReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (intent == null || intent.getAction() == null) return;
                switch (intent.getAction()) {
                    case Intent.ACTION_SCREEN_OFF:
                        onScreenOff();
                        break;
                    case Intent.ACTION_SCREEN_ON:
                        onScreenOn();
                        break;
                    case ACTION_SLEEP_CHECK:
                        onSleepAlarm();
                        break;
                    case Intent.ACTION_BATTERY_CHANGED:
                        onBatteryChanged(intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0));
                        break;
                }
            }
        };
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(ACTION_SLEEP_CHECK);
        // Sticky: registration immediately replays the current battery state.
        filter.addAction(Intent.ACTION_BATTERY_CHANGED);
        ContextCompat.registerReceiver(appContext, screenReceiver, filter,
                ContextCompat.RECEIVER_NOT_EXPORTED);
        Log.d(TAG, "Screen/battery receiver armed (always-on savers)");
    }

    private static void onScreenOff() {
        synchronized (LOCK) {
            scheduleAlarmLocked();
        }
        Log.d(TAG, "Screen off; sleep savers scheduled in " + DELAY_MS + "ms");
    }

    private static void onScreenOn() {
        synchronized (LOCK) {
            cancelAlarmLocked();
        }
        runWithWakeLock(SleepSaver::restoreAll);
    }

    /** Alarm-fired entry point (system wakes the device/process to deliver). */
    private static void onSleepAlarm() {
        Log.d(TAG, "Sleep alarm fired");
        runWithWakeLock(SleepSaver::applySleepState);
    }

    private static void scheduleAlarmLocked() {
        cancelAlarmLocked();
        AlarmManager am = (AlarmManager) appContext.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        sleepAlarm = PendingIntent.getBroadcast(appContext, 0,
                new Intent(ACTION_SLEEP_CHECK).setPackage(appContext.getPackageName()),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + DELAY_MS, sleepAlarm);
    }

    private static void cancelAlarmLocked() {
        if (sleepAlarm == null) return;
        AlarmManager am = (AlarmManager) appContext.getSystemService(Context.ALARM_SERVICE);
        if (am != null) am.cancel(sleepAlarm);
        sleepAlarm.cancel();
        sleepAlarm = null;
    }

    /** Runs work on the worker under a short partial wake lock. */
    private static void runWithWakeLock(Runnable work) {
        Context ctx = appContext;
        if (ctx == null) return;
        PowerManager.WakeLock lock = null;
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm != null) {
                lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kyodai:sleep_saver");
                lock.setReferenceCounted(false);
                lock.acquire(APPLY_WAKE_LOCK_MS);
            }
        } catch (Exception e) {
            Log.w(TAG, "apply wake lock failed: " + e.getMessage());
        }
        final PowerManager.WakeLock held = lock;
        worker.execute(() -> {
            try {
                work.run();
            } finally {
                if (held != null) {
                    try {
                        if (held.isHeld()) held.release();
                    } catch (Exception ignored) {}
                }
            }
        });
    }

    /** Dock semantics: charging == docked on these handhelds. */
    private static void onBatteryChanged(int plugged) {
        int previous;
        synchronized (LOCK) {
            previous = lastPlugged;
            lastPlugged = plugged;
        }
        if (previous == -1 || previous == plugged) return; // initial sticky replay / no change
        if (plugged != 0) {
            // Docked mid-sleep: cancel any pending cut and restore whatever
            // the saver disabled, so the device stays reachable on the dock.
            synchronized (LOCK) {
                cancelAlarmLocked();
            }
            Log.d(TAG, "Charging started; restoring sleep-saver state");
            runWithWakeLock(SleepSaver::restoreAll);
        } else if (!isDisplayInteractive(appContext)) {
            // Undocked while asleep: nothing has been cut yet (charging skips
            // apply), so start a fresh countdown.
            Log.d(TAG, "Charging stopped while asleep; rescheduling savers");
            onScreenOff();
        }
    }

    // ------------------------------------------------------------------
    // Sleep / wake transitions (worker thread)
    // ------------------------------------------------------------------

    private static void applySleepState() {
        Context ctx = appContext;
        if (ctx == null) return;
        if (isDisplayInteractive(ctx)) {
            // Screen came back on without a SCREEN_ON broadcast (rare) — bail.
            return;
        }
        if (isCharging(ctx)) {
            Log.d(TAG, "Charging/docked; sleep savers skipped");
            return;
        }
        SharedPreferences p = prefs();

        // Download/sync/extraction jobs: skip EVERYTHING (radios + governor).
        // These jobs hold the shared wake lock anyway, so the device isn't
        // truly deep-sleeping; dropping to powersave would just slow the job.
        if (activeJobs.get() > 0) {
            Log.d(TAG, "Skipping sleep savers: background job active");
            return;
        }
        // Retained game sessions veto the radios only: a suspended game does
        // no CPU work, so the governor drop below is safe savings.
        if (hasActiveJobs()) {
            Log.d(TAG, "Skipping radio savers: game session active");
        } else {
            if (isWifiOn(ctx)) {
                RootShell.Result r = RootShell.run(ctx, "svc wifi disable");
                if (r != null && r.succeeded()) {
                    p.edit().putBoolean(KEY_WIFI_DISABLED, true).apply();
                    Log.d(TAG, "Wi-Fi disabled for sleep");
                } else {
                    Log.w(TAG, "svc wifi disable failed (root route unavailable?)");
                }
            }
            if (isBluetoothOn(ctx)) {
                RootShell.Result r = RootShell.run(ctx, "svc bluetooth disable");
                if (r != null && r.succeeded()) {
                    p.edit().putBoolean(KEY_BT_DISABLED, true).apply();
                    Log.d(TAG, "Bluetooth disabled for sleep");
                } else {
                    Log.w(TAG, "svc bluetooth disable failed (root route unavailable?)");
                }
            }
        }

        dropGovernors(ctx);
    }

    private static void restoreAll() {
        restoreWifi();
        restoreBluetooth();
        restoreGovernors();
    }

    private static void restoreWifi() {
        Context ctx = appContext;
        if (ctx == null) return;
        SharedPreferences p = prefs();
        if (!p.getBoolean(KEY_WIFI_DISABLED, false)) return;
        // Clear first: a failed restore must not retry forever on every launch.
        p.edit().putBoolean(KEY_WIFI_DISABLED, false).apply();
        RootShell.Result r = RootShell.run(ctx, "svc wifi enable");
        if (r != null && r.succeeded()) {
            Log.d(TAG, "Wi-Fi restored after sleep");
        } else {
            Log.w(TAG, "svc wifi enable failed");
        }
    }

    private static void restoreBluetooth() {
        Context ctx = appContext;
        if (ctx == null) return;
        SharedPreferences p = prefs();
        if (!p.getBoolean(KEY_BT_DISABLED, false)) return;
        // Clear first: a failed restore must not retry forever on every launch.
        p.edit().putBoolean(KEY_BT_DISABLED, false).apply();
        RootShell.Result r = RootShell.run(ctx, "svc bluetooth enable");
        if (r != null && r.succeeded()) {
            Log.d(TAG, "Bluetooth restored after sleep");
        } else {
            Log.w(TAG, "svc bluetooth enable failed");
        }
    }

    // ------------------------------------------------------------------
    // CPU governor
    // ------------------------------------------------------------------

    private static void dropGovernors(Context ctx) {
        // Query current + available governors for every cpufreq policy.
        RootShell.Result query = RootShell.run(ctx,
                "for p in " + CPUFREQ_ROOT + "/policy*; do "
                        + "g=$(cat \"$p/scaling_governor\" 2>/dev/null); "
                        + "a=$(cat \"$p/scaling_available_governors\" 2>/dev/null); "
                        + "[ -n \"$g\" ] && echo \"POLICY|$p|$g|$a\"; "
                        + "done");
        if (query == null || query.output == null) {
            Log.w(TAG, "Governor query failed (no root route?)");
            return;
        }

        List<String> writes = new ArrayList<>();
        StringBuilder saved = new StringBuilder();
        for (String line : query.output.split("\n")) {
            String[] parts = line.trim().split("\\|");
            if (parts.length < 3 || !"POLICY".equals(parts[0])) continue;
            String path = parts[1];
            String current = parts[2];
            String available = parts.length > 3 ? parts[3] : "";

            String target = null;
            if ((" " + available + " ").contains(" powersave ")) {
                target = "powersave";
            } else if ((" " + available + " ").contains(" schedutil ")
                    && !"schedutil".equals(current)) {
                target = "schedutil";
            }
            if (target == null || target.equals(current)) continue;

            if (saved.length() > 0) saved.append(";");
            saved.append(path).append("=").append(current);
            writes.add("echo " + RootShell.quote(target) + " > "
                    + RootShell.quote(path + "/scaling_governor"));
        }

        if (writes.isEmpty()) {
            Log.d(TAG, "No governor change needed");
            return;
        }

        SharedPreferences p = prefs();
        // Only overwrite the saved map when no sleep drop is currently active,
        // so a stale saved map can't clobber the true pre-sleep governors.
        String previous = p.getString(KEY_GOVERNOR_SAVED, "");
        if (previous == null || previous.isEmpty()) {
            p.edit().putString(KEY_GOVERNOR_SAVED, saved.toString()).apply();
        }

        StringBuilder script = new StringBuilder();
        for (String w : writes) {
            script.append(w).append('\n');
        }
        RootShell.Result r = RootShell.run(ctx, script.toString());
        if (r != null && r.succeeded()) {
            Log.d(TAG, "Governors dropped for sleep: " + saved);
        } else {
            Log.w(TAG, "Governor write failed");
        }
    }

    private static void restoreGovernors() {
        Context ctx = appContext;
        if (ctx == null) return;
        SharedPreferences p = prefs();
        String saved = p.getString(KEY_GOVERNOR_SAVED, "");
        if (saved == null || saved.isEmpty()) return;
        // Clear first: a failed restore must not retry forever on every launch.
        p.edit().putString(KEY_GOVERNOR_SAVED, "").apply();

        StringBuilder script = new StringBuilder();
        boolean any = false;
        for (String entry : saved.split(";")) {
            int eq = entry.indexOf('=');
            if (eq <= 0) continue;
            String path = entry.substring(0, eq);
            String governor = entry.substring(eq + 1);
            if (governor.isEmpty()) continue;
            script.append("echo ").append(RootShell.quote(governor)).append(" > ")
                    .append(RootShell.quote(path + "/scaling_governor")).append('\n');
            any = true;
        }
        if (!any) return;
        RootShell.Result r = RootShell.run(ctx, script.toString());
        if (r != null && r.succeeded()) {
            Log.d(TAG, "Governors restored after sleep: " + saved);
        } else {
            Log.w(TAG, "Governor restore failed");
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static SharedPreferences prefs() {
        return appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static boolean isCharging(Context ctx) {
        try {
            Intent battery = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (battery == null) return false;
            return battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0;
        } catch (Exception e) {
            return false;
        }
    }

    private static boolean isWifiOn(Context ctx) {
        try {
            WifiManager wm = (WifiManager) ctx.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            return wm != null && wm.isWifiEnabled();
        } catch (Exception e) {
            Log.w(TAG, "isWifiOn failed: " + e.getMessage());
            return false;
        }
    }

    /** Read via root so no BLUETOOTH/BLUETOOTH_CONNECT permission is needed. */
    private static boolean isBluetoothOn(Context ctx) {
        RootShell.Result r = RootShell.run(ctx, "settings get global bluetooth_on");
        if (r == null || r.output == null) return false;
        for (String line : r.output.split("\n")) {
            String value = line.trim();
            if (value.equals("1") || value.equals("0")) {
                return value.equals("1");
            }
        }
        return false;
    }
}

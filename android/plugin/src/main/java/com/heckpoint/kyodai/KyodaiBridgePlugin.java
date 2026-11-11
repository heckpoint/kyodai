package com.heckpoint.kyodai;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ComponentCallbacks2;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.UriPermission;
import android.content.res.AssetFileDescriptor;
import android.content.res.Configuration;
import android.content.pm.PackageManager;
import android.content.pm.PackageInfo;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.hardware.display.DisplayManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.net.wifi.WifiManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.FileObserver;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import androidx.core.content.FileProvider;
import org.godotengine.godot.Godot;
import org.godotengine.godot.Dictionary;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import com.heckpoint.kyodai.task.TaskBackendRouter;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

public class KyodaiBridgePlugin extends GodotPlugin {
    
    private static final String TAG = "KyodaiBridge";
    private static final String ACTION_EXTRACTION_COMPLETE = "com.heckpoint.kyodai.EXTRACTION_COMPLETE";
    private static final String SAF_PREFS = "kyodai_saf";
    private static final String SAF_TREE_URIS_KEY = "android_data_tree_uris";
    private static final int REQUEST_SAF_TREE = 0x5AF1;
    private static final String DOCS_AUTHORITY = "com.android.externalstorage.documents";
    private Activity activity;
    private BroadcastReceiver extractionReceiver;
    private WindowFocusGuard windowFocusGuard;
    private ComponentCallbacks2 trimMemoryCallbacks;
    private TaskBackendRouter taskBackend;
    private java.util.concurrent.ScheduledExecutorService activityHeartbeatExecutor;
    private String lastSessionId = "";
    private volatile boolean destroyed;
    private volatile int retainedTaskId = -1;
    private volatile String retainedPackage = "";
    private volatile String retainedTopActivity = "";
    private volatile boolean earlyHomeEnabled;
    private volatile int homeSnapshotTaskId = -1;
    private volatile String homeSnapshotRequestId = "";
    private volatile String homeSnapshotJson;
    private FileObserver homeResultObserver;
    private FileObserver taskEventObserver;
    private String taskEventObserverNonce = "";
    private volatile int observerRequestedTaskId = -1;
    private volatile String observerNonce = "";
    private volatile String observerStartRequestId = "";
    private static KyodaiBridgePlugin instance;
    private static java.lang.ref.WeakReference<Activity> foregroundActivity;

    public static KyodaiBridgePlugin getInstance() {
        return instance;
    }

    /** Called by GodotApp whenever any Kyodai activity resumes. */
    public static void setCurrentActivity(Activity activity) {
        foregroundActivity = new java.lang.ref.WeakReference<>(activity);
    }

    private Activity currentActivity() {
        Activity current = foregroundActivity != null ? foregroundActivity.get() : null;
        return current != null ? current : activity;
    }

    private void startActivity(Intent intent) {
        Activity current = currentActivity();
        if (current == null) throw new IllegalStateException("No foreground activity");
        current.startActivity(intent);
    }

    public KyodaiBridgePlugin(Godot godot) {
        super(godot);
        destroyed = false;
        instance = this;
        Log.d(TAG, "KyodaiBridgePlugin constructor called");
        this.activity = godot.getActivity();
        setCurrentActivity(this.activity);
        Log.d(TAG, "Activity obtained: " + (activity != null ? "YES" : "NO"));
        if (this.activity != null) {
            this.windowFocusGuard = new WindowFocusGuard(activity);
            // Lazy background initialization emits no readiness signal and never
            // participates in Godot's plugin registration or cold-launch timing.
            startBackendInitialization();
            // Arms the screen-off savers from persisted state and restores
            // anything a previous process left disabled while asleep.
            SleepSaver.init(activity.getApplicationContext());
            registerTrimMemoryCallbacks(activity);
        }
        Log.i(TAG, "[StorageTier] startup: ext_data_rw=" + StorageTier.selfHasExtDataRw()
                + " rootDaemon=deferred"
                + " sdk=" + Build.VERSION.SDK_INT);
        registerExtractionReceiver();
    }

    private void startBackendInitialization() {
        if (destroyed || activity == null) return;
        // Privileged daemon probing can block. Never do it on the activity
        // thread: a slow daemon must not prevent the first Godot frame.
        Thread backendInit = new Thread(() -> {
            try {
                TaskBackendRouter router = new TaskBackendRouter(activity, this::onTaskBackendResult);
                if (destroyed) {
                    router.close();
                    return;
                }
                this.taskBackend = router;
                if (destroyed) {
                    this.taskBackend.close();
                    this.taskBackend = null;
                    return;
                }
                // Subsequent calls are serialized behind this maintenance by
                // the router, independently of UI and emulator launch.
                this.taskBackend.cleanupHelpers();
                if (!destroyed) {
                    // Dedicated Home/console mode: snapshot curtains alone own
                    // emulator <-> launcher presentation.
                    this.taskBackend.setTransitionScale(0.0f);
                }
            } catch (Throwable error) {
                Log.w(TAG, "Privileged backend initialization failed", error);
            }
        }, "KyodaiTaskBackendInit");
        backendInit.setDaemon(true);
        backendInit.start();
    }
    
    @Override
    public String getPluginName() {
        return "KyodaiBridge";
    }
    
    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<>();
        signals.add(new SignalInfo("extraction_complete", Boolean.class, String.class, String.class));
        signals.add(new SignalInfo("copy_progress", String.class, Long.class, Long.class));
        signals.add(new SignalInfo("copy_complete", String.class, Boolean.class, String.class, String.class));
        signals.add(new SignalInfo("chunk_flush_complete", String.class, Boolean.class, String.class));
        signals.add(new SignalInfo("saf_grant_result", Boolean.class));
        signals.add(new SignalInfo("trim_memory", Integer.class));
        signals.add(new SignalInfo("android_task_result", String.class, String.class, String.class));
        signals.add(new SignalInfo("android_task_event", String.class, Integer.class, String.class));
        signals.add(new SignalInfo("android_home_requested"));
        return signals;
    }

    /**
     * Forwards ComponentCallbacks2 memory-pressure callbacks to Godot as the
     * "trim_memory" signal. The Godot side decides what (if anything) to
     * release at each level; escalations matter most while a game session
     * holds the process in the background under a memory-hungry emulator.
     */
    private void registerTrimMemoryCallbacks(Activity host) {
        trimMemoryCallbacks = new ComponentCallbacks2() {
            @Override
            public void onConfigurationChanged(Configuration newConfig) {
                // Not our concern; the activity handles configuration itself.
            }

            @Override
            public void onLowMemory() {
                // Deprecated coarse signal; treat as CRITICAL-level pressure.
                Log.d(TAG, "onLowMemory received");
                emitSignal("trim_memory", 80);
            }

            @Override
            public void onTrimMemory(int level) {
                Log.d(TAG, "onTrimMemory level=" + level);
                emitSignal("trim_memory", level);
            }
        };
        host.registerComponentCallbacks(trimMemoryCallbacks);
        Log.d(TAG, "Registered trim-memory callbacks");
    }
    
    /// Hides the native IME and re-hardens the window against soft-input takeover.
    @UsedByGodot
    public void forceHideKeyboard() {
        if (windowFocusGuard != null) {
            windowFocusGuard.hardenWindow();
        }
    }
    
    /// True while the activity window holds input focus.
    @UsedByGodot
    public boolean hasWindowFocus() {
        return windowFocusGuard != null && windowFocusGuard.hasWindowFocus();
    }

    // ------------------------------------------------------------------
    // Sleep savers (always-on; see SleepSaver). No on/off bridge methods:
    // arming happens in SleepSaver.init() whenever a vendor root daemon exists.
    // ------------------------------------------------------------------

    /// True while the display is on/interactive. Used by GDScript to tell
    /// "screen off" apart from "another app took focus" (e.g. game launch).
    @UsedByGodot
    public boolean isDisplayInteractive() {
        return SleepSaver.isDisplayInteractive(activity);
    }
    
    private void registerExtractionReceiver() {
        if (activity == null) return;
        
        extractionReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (ACTION_EXTRACTION_COMPLETE.equals(intent.getAction())) {
                    boolean success = intent.getBooleanExtra("success", false);
                    String zipPath = intent.getStringExtra("zip_path");
                    String extractDir = intent.getStringExtra("extract_dir");
                    Log.d(TAG, "Extraction complete broadcast received: success=" + success + 
                        ", zip=" + zipPath + ", dir=" + extractDir);
                    emitSignal("extraction_complete", success, zipPath, extractDir);
                }
            }
        };
        
        IntentFilter filter = new IntentFilter(ACTION_EXTRACTION_COMPLETE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(extractionReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            activity.registerReceiver(extractionReceiver, filter);
        }
        Log.d(TAG, "Registered extraction completion receiver");
    }

    @Override
    public void onMainDestroy() {
        destroyed = true;
        // The receiver is registered against the Activity context; without an
        // unregister the Activity leaks it on recreation (IntentReceiverLeaked)
        // and the destroy stalls long enough to race resume-time restore work.
        if (extractionReceiver != null && activity != null) {
            try {
                activity.unregisterReceiver(extractionReceiver);
            } catch (IllegalArgumentException e) {
                // Never registered or already unregistered - nothing to do
            }
            extractionReceiver = null;
        }
        if (trimMemoryCallbacks != null && activity != null) {
            activity.unregisterComponentCallbacks(trimMemoryCallbacks);
            trimMemoryCallbacks = null;
        }
        if (taskBackend != null) {
            taskBackend.close();
            taskBackend = null;
        }
        androidTaskClearRetainedIdentity();
        stopActivityHeartbeat();
        if (chunkFlushExecutor != null) {
            chunkFlushExecutor.shutdownNow();
            chunkFlushExecutor = null;
        }
        if (instance == this) instance = null;
        super.onMainDestroy();
    }
    
    @UsedByGodot
    public boolean isPackageInstalled(String packageName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "isPackageInstalled() called with: " + packageName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        Log.d(TAG, "Activity is valid, getting PackageManager...");
        
        try {
            PackageManager pm = activity.getPackageManager();
            Log.d(TAG, "PackageManager obtained");
            
            // Try to get package info - use modern API for Android 13+ (API 33+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Log.d(TAG, "Using modern API (Android 13+)");
                pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0));
            } else {
                Log.d(TAG, "Using legacy API");
                pm.getPackageInfo(packageName, 0);
            }
            
            Log.d(TAG, "SUCCESS: Package '" + packageName + "' is INSTALLED");
            Log.d(TAG, "==========================================");
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            Log.d(TAG, "Package '" + packageName + "' is NOT installed");
            Log.d(TAG, "==========================================");
            return false;
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking package '" + packageName + "': " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return false;
        }
    }
    
    @UsedByGodot
    public String getInstalledLaunchableApps() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "getInstalledLaunchableApps() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return "[]";
        }
        
        try {
            PackageManager pm = activity.getPackageManager();
            Intent intent = new Intent(Intent.ACTION_MAIN);
            intent.addCategory(Intent.CATEGORY_LAUNCHER);
            List<ResolveInfo> apps = pm.queryIntentActivities(intent, 0);
            
            org.json.JSONArray result = new org.json.JSONArray();
            float density = activity.getResources().getDisplayMetrics().density;
            int iconSize = Math.round(48 * density);
            
            for (ResolveInfo info : apps) {
                String packageName = info.activityInfo.applicationInfo.packageName;
                String name = info.loadLabel(pm).toString();
                String iconBase64 = "";
                
                try {
                    Drawable icon = info.loadIcon(pm);
                    if (icon != null) {
                        Bitmap bitmap = drawableToBitmap(icon);
                        bitmap = Bitmap.createScaledBitmap(bitmap, iconSize, iconSize, true);
                        ByteArrayOutputStream baos = new ByteArrayOutputStream();
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, baos);
                        byte[] bytes = baos.toByteArray();
                        iconBase64 = Base64.encodeToString(bytes, Base64.NO_WRAP);
                    }
                } catch (Exception e) {
                    Log.w(TAG, "Failed to load icon for " + packageName + ": " + e.getMessage());
                }
                
                org.json.JSONObject app = new org.json.JSONObject();
                app.put("name", name);
                app.put("package", packageName);
                app.put("icon", iconBase64);
                result.put(app);
            }
            
            Log.d(TAG, "Found " + result.length() + " launchable apps");
            Log.d(TAG, "==========================================");
            return result.toString();
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR getting installed apps: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return "[]";
        }
    }
    
    private Bitmap drawableToBitmap(Drawable drawable) {
        if (drawable instanceof BitmapDrawable) {
            return ((BitmapDrawable) drawable).getBitmap();
        }
        int width = Math.max(1, drawable.getIntrinsicWidth());
        int height = Math.max(1, drawable.getIntrinsicHeight());
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, canvas.getWidth(), canvas.getHeight());
        drawable.draw(canvas);
        return bitmap;
    }
    
    /**
     * Launch a Steam game via GameNative app.
     *
     * @param appId The Steam App ID to launch
     * @return true if intent was launched successfully
     */
    @UsedByGodot
    public boolean launchGameNativeGame(int appId) {
        return launchSteamGame("app.gamenative", "app.gamenative.MainActivity",
                "app.gamenative.LAUNCH_GAME", appId);
    }

    /**
     * Launch a Steam game via an explicit-component LAUNCH_GAME intent.
     * Works with GameNative (app.gamenative) and DroidDeck
     * (com.droiddeck.launcher) - both accept the LAUNCH_GAME action with an
     * int "app_id" extra on their MainActivity. DroidDeck additionally accepts
     * GameNative's own action when the component targets it explicitly.
     *
     * @param packageName  Target app package (e.g. "app.gamenative")
     * @param activityName Target activity class (e.g. "app.gamenative.MainActivity")
     * @param action       Intent action (e.g. "app.gamenative.LAUNCH_GAME")
     * @param appId        The Steam App ID to launch
     * @return true if intent was launched successfully
     */
    @UsedByGodot
    public boolean launchSteamGame(String packageName, String activityName, String action, int appId) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchSteamGame() called");
        Log.d(TAG, "Target: " + packageName + "/" + activityName);
        Log.d(TAG, "App ID: " + appId);

        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }

        try {
            Intent intent = new Intent();
            intent.setComponent(new ComponentName(packageName, activityName));
            intent.setAction(action);
            intent.addCategory(Intent.CATEGORY_DEFAULT);
            intent.putExtra("app_id", appId);
            intent.putExtra("game_source", "STEAM");

            // Add flags for launching from another app
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

            Log.d(TAG, "Intent action: " + intent.getAction());
            Log.d(TAG, "Intent component: " + intent.getComponent());

            startActivity(intent);

            Log.d(TAG, "SUCCESS: Steam game launch intent sent");
            Log.d(TAG, "==========================================");
            return true;

        } catch (Exception e) {
            Log.e(TAG, "ERROR launching Steam game: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            return false;
        }
    }
    
    /**
     * Vibrates the device for haptic feedback.
     * Requires the VIBRATE permission.
     * 
     * @param durationMs Duration of vibration in milliseconds
     * @return true if vibration was triggered successfully
     */
    @UsedByGodot
    public boolean vibrateDevice(int durationMs) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "vibrateDevice() called");
        Log.d(TAG, "Duration: " + durationMs + "ms");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            android.os.Vibrator vibrator = (android.os.Vibrator) activity.getSystemService(Context.VIBRATOR_SERVICE);
            
            if (vibrator == null) {
                Log.e(TAG, "ERROR: Vibrator service is null");
                return false;
            }
            
            if (!vibrator.hasVibrator()) {
                Log.w(TAG, "WARNING: Device does not have a vibrator");
                return false;
            }
            
            // Vibrate for the specified duration with lower intensity
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                // Use VibrationEffect for API 26+ with lower amplitude (80 instead of DEFAULT_AMPLITUDE)
                vibrator.vibrate(android.os.VibrationEffect.createOneShot(durationMs, 80));
            } else {
                // Deprecated method for older APIs
                vibrator.vibrate(durationMs);
            }
            
            Log.d(TAG, "SUCCESS: Vibration triggered");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR vibrating device: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    // ============================================================================
    // Dual Screen / Display Detection Methods
    // ============================================================================
    
    /**
     * Get the number of displays connected to the device.
     * This is useful for detecting dual screen devices like Ayn Thor.
     * 
     * @return The number of displays (1 for single screen, 2+ for dual/multi screen)
     */
    @UsedByGodot
    public int getDisplayCount() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "getDisplayCount() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return 1;
        }
        
        try {
            // Use DisplayManager to get all displays
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                Log.e(TAG, "ERROR: DisplayManager is null");
                return 1;
            }
            
            // Get all displays (including virtual displays)
            android.view.Display[] displays = displayManager.getDisplays();
            int displayCount = displays.length;
            
            Log.d(TAG, "Found " + displayCount + " displays:");
            for (int i = 0; i < displays.length; i++) {
                android.view.Display display = displays[i];
                Log.d(TAG, "  Display " + i + ": ID=" + display.getDisplayId() +
                      ", Name=" + display.getName() +
                      ", IsValid=" + display.isValid());
                
                // Get display metrics
                android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                display.getRealMetrics(metrics);
                Log.d(TAG, "    Resolution: " + metrics.widthPixels + "x" + metrics.heightPixels);
            }
            
            Log.d(TAG, "==========================================");
            return displayCount;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR getting display count: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return 1;
        }
    }
    
    /**
     * Check if the device has multiple physical displays.
     * Filters out virtual displays by checking:
     * 1. Display must be valid and not the default display
     * 2. Display must have a different resolution than the built-in screen
     * 3. Display name must not contain virtual/overlay keywords
     * 4. Display state must be ON (not OFF or DOZE)
     * 
     * @return true if a real secondary physical display is connected
     */
    @UsedByGodot
    public boolean hasMultipleDisplays() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "hasMultipleDisplays() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                Log.e(TAG, "ERROR: DisplayManager is null");
                return false;
            }
            
            // Get default display resolution for comparison
            android.view.Display defaultDisplay = displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY);
            if (defaultDisplay == null) {
                Log.e(TAG, "ERROR: Default display is null");
                return false;
            }
            
            android.util.DisplayMetrics defaultMetrics = new android.util.DisplayMetrics();
            defaultDisplay.getRealMetrics(defaultMetrics);
            Log.d(TAG, "Default display: " + defaultMetrics.widthPixels + "x" + defaultMetrics.heightPixels);
            
            // Get all displays and filter
            android.view.Display[] allDisplays = displayManager.getDisplays();
            Log.d(TAG, "Total displays found: " + allDisplays.length);
            
            for (int i = 0; i < allDisplays.length; i++) {
                android.view.Display display = allDisplays[i];
                int displayId = display.getDisplayId();
                String displayName = display.getName();
                int displayState = display.getState();
                
                // Skip default display
                if (displayId == android.view.Display.DEFAULT_DISPLAY) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + "]: SKIPPED (default display)");
                    continue;
                }
                
                // Skip invalid displays
                if (!display.isValid()) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + "]: SKIPPED (not valid)");
                    continue;
                }
                
                // Skip displays that are off
                if (displayState != android.view.Display.STATE_ON) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + "]: SKIPPED (state=" + displayState + ", not ON)");
                    continue;
                }
                
                // Get metrics
                android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                display.getRealMetrics(metrics);
                
                // Skip virtual displays with same resolution as default
                // (mirrored/virtual displays typically match the primary screen resolution)
                boolean sameResolution = (metrics.widthPixels == defaultMetrics.widthPixels && 
                                          metrics.heightPixels == defaultMetrics.heightPixels) ||
                                         (metrics.widthPixels == defaultMetrics.heightPixels && 
                                          metrics.heightPixels == defaultMetrics.widthPixels);
                
                if (sameResolution) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + ", Name=" + displayName + "]: SKIPPED (same resolution " + 
                          metrics.widthPixels + "x" + metrics.heightPixels + ")");
                    continue;
                }
                
                // Skip displays with virtual/overlay keywords in name
                String nameLower = displayName.toLowerCase();
                if (nameLower.contains("virtual") || nameLower.contains("overlay") || 
                    nameLower.contains("scrcpy") || nameLower.contains("screenrecorder")) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + ", Name=" + displayName + "]: SKIPPED (virtual keyword)");
                    continue;
                }
                
                // This looks like a real secondary display
                Log.d(TAG, "  Display " + i + " [ID=" + displayId + ", Name=" + displayName + "]: VALID secondary display (" + 
                      metrics.widthPixels + "x" + metrics.heightPixels + ")");
                Log.d(TAG, "hasMultipleDisplays result: true");
                Log.d(TAG, "==========================================");
                return true;
            }
            
            Log.d(TAG, "No valid secondary displays found");
            Log.d(TAG, "hasMultipleDisplays result: false");
            Log.d(TAG, "==========================================");
            return false;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking for multiple displays: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    /**
     * Get debug information about all displays as a formatted string.
     * Returns a Dictionary with a "info" key containing the display details.
     * This avoids issues with ArrayList/Dictionary conversion between Java and Godot.
     * 
     * @return Dictionary with "info" string and "count" int
     */
    @UsedByGodot
    public Dictionary getDisplayDebugInfo() {
        Dictionary result = new Dictionary();
        StringBuilder info = new StringBuilder();
        
        if (activity == null) {
            result.put("info", "Activity is null");
            result.put("count", 0);
            return result;
        }
        
        try {
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                result.put("info", "DisplayManager is null");
                result.put("count", 0);
                return result;
            }
            
            android.view.Display[] allDisplays = displayManager.getDisplays();
            result.put("count", allDisplays.length);
            
            // Get default display metrics
            android.view.Display defaultDisplay = displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY);
            android.util.DisplayMetrics defaultMetrics = new android.util.DisplayMetrics();
            if (defaultDisplay != null) {
                defaultDisplay.getRealMetrics(defaultMetrics);
            }
            
            info.append("Total displays: ").append(allDisplays.length).append("\n");
            info.append("Default: ").append(defaultMetrics.widthPixels).append("x").append(defaultMetrics.heightPixels).append("\n");
            
            for (int i = 0; i < allDisplays.length; i++) {
                android.view.Display display = allDisplays[i];
                android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                display.getRealMetrics(metrics);
                
                boolean isDefault = display.getDisplayId() == android.view.Display.DEFAULT_DISPLAY;
                boolean sameResolution = (metrics.widthPixels == defaultMetrics.widthPixels && 
                                          metrics.heightPixels == defaultMetrics.heightPixels) ||
                                         (metrics.widthPixels == defaultMetrics.heightPixels && 
                                          metrics.heightPixels == defaultMetrics.widthPixels);
                
                info.append("Display ").append(i)
                    .append(": ID=").append(display.getDisplayId())
                    .append(", Name=").append(display.getName())
                    .append(", State=").append(display.getState())
                    .append(", ").append(metrics.widthPixels).append("x").append(metrics.heightPixels)
                    .append(", Default=").append(isDefault)
                    .append(", SameRes=").append(sameResolution)
                    .append("\n");
            }
            
            result.put("info", info.toString());
            return result;
            
        } catch (Exception e) {
            result.put("info", "Error: " + e.getMessage());
            result.put("count", 0);
            return result;
        }
    }
    
    /**
     * Get information about the second display (if available).
     * Returns a dictionary with display properties.
     * 
     * @return Dictionary with display info, or empty dict if no second display
     */
    @UsedByGodot
    public Dictionary getSecondDisplayInfo() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "getSecondDisplayInfo() called");
        
        Dictionary result = new Dictionary();
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return result;
        }
        
        try {
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                Log.e(TAG, "ERROR: DisplayManager is null");
                return result;
            }
            
            // Find the second display (non-default display)
            android.view.Display[] displays = displayManager.getDisplays();
            android.view.Display secondDisplay = null;
            
            for (android.view.Display display : displays) {
                if (display.getDisplayId() != android.view.Display.DEFAULT_DISPLAY && display.isValid()) {
                    secondDisplay = display;
                    break;
                }
            }
            
            if (secondDisplay == null) {
                Log.d(TAG, "No second display found");
                return result;
            }
            
            // Get display metrics
            android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
            secondDisplay.getRealMetrics(metrics);
            
            // Populate result dictionary
            result.put("id", secondDisplay.getDisplayId());
            result.put("name", secondDisplay.getName());
            result.put("width", metrics.widthPixels);
            result.put("height", metrics.heightPixels);
            result.put("density", metrics.density);
            result.put("xdpi", metrics.xdpi);
            result.put("ydpi", metrics.ydpi);
            
            Log.d(TAG, "Second display info:");
            Log.d(TAG, "  ID: " + secondDisplay.getDisplayId());
            Log.d(TAG, "  Name: " + secondDisplay.getName());
            Log.d(TAG, "  Resolution: " + metrics.widthPixels + "x" + metrics.heightPixels);
            
            Log.d(TAG, "==========================================");
            return result;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR getting second display info: " + e.getMessage());
            return result;
        }
    }
    
    /**
     * Checks if the app has MANAGE_EXTERNAL_STORAGE permission (All Files Access on Android 11+)
     * 
     * @return true if permission is granted, false otherwise
     */
    @UsedByGodot
    public boolean hasManageExternalStoragePermission() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "hasManageExternalStoragePermission() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            boolean hasPermission = android.os.Environment.isExternalStorageManager();
            Log.d(TAG, "MANAGE_EXTERNAL_STORAGE permission: " + hasPermission);
            Log.d(TAG, "==========================================");
            return hasPermission;
        } else {
            // On older versions, check for WRITE_EXTERNAL_STORAGE
            int permission = activity.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE);
            boolean hasPermission = permission == PackageManager.PERMISSION_GRANTED;
            Log.d(TAG, "WRITE_EXTERNAL_STORAGE permission: " + hasPermission);
            Log.d(TAG, "==========================================");
            return hasPermission;
        }
    }
    
    /**
     * Requests MANAGE_EXTERNAL_STORAGE permission by opening system settings.
     * The user must manually grant this permission.
     * 
     * @return true if settings intent was launched successfully
     */
    @UsedByGodot
    public boolean requestManageExternalStoragePermission() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "requestManageExternalStoragePermission() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Open system settings for All Files Access permission.
                // NO_HISTORY, no NEW_TASK: the page must open inside our
                // task (a task of its own leaves a recents card wearing our
                // icon) and finish when it leaves the foreground (else it
                // parks on top of our task and intercepts every return).
                // See requestInstallUnknownAppsPermission.
                Intent intent = new Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                intent.setData(Uri.parse("package:" + activity.getPackageName()));
                intent.addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY);
                startActivity(intent);
                Log.d(TAG, "Launched system settings for MANAGE_EXTERNAL_STORAGE");
            } else {
                // On older versions, request WRITE_EXTERNAL_STORAGE normally
                activity.requestPermissions(
                    new String[]{android.Manifest.permission.WRITE_EXTERNAL_STORAGE},
                    1001
                );
                Log.d(TAG, "Requested WRITE_EXTERNAL_STORAGE permission");
            }
            
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR requesting permission: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    /**
     * Checks whether the user has granted the runtime "Install unknown apps"
     * toggle for this app (Android 8+). The manifest permission
     * REQUEST_INSTALL_PACKAGES must also be declared for installs to work.
     *
     * @return true if the app is allowed to trigger APK installs
     */
    @UsedByGodot
    public boolean canInstallUnknownApps() {
        if (activity == null) {
            Log.e(TAG, "canInstallUnknownApps: Activity is null");
            return false;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return activity.getPackageManager().canRequestPackageInstalls();
        }
        return true;
    }

    /** True when either root or Android's normal unknown-apps grant can install. */
    @UsedByGodot
    public boolean canInstallPackages() {
        return activity != null && (RootShell.isAvailable(activity) || canInstallUnknownApps());
    }

    /**
     * Opens the dedicated "Install unknown apps" settings screen for this app
     * (ACTION_MANAGE_UNKNOWN_APP_SOURCES). Falls back to the app details page
     * if the dedicated screen is unavailable on the current ROM.
     *
     * @return true if a settings intent was launched successfully
     */
    @UsedByGodot
    public boolean requestInstallUnknownAppsPermission() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "requestInstallUnknownAppsPermission() called");

        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }

        Uri packageUri = Uri.parse("package:" + activity.getPackageName());
        // NO_HISTORY, and crucially no NEW_TASK. The toggle page must open
        // INSIDE our own task: in a task of its own it leaves a recents card
        // that wears our icon and name, and tapping that card relaunches the
        // page fresh - it looked exactly like the app re-opening the page on
        // every boot/resume (AYN's recents keeps the zombie card even with
        // EXCLUDE_FROM_RECENTS). But inside our task a plain page parks on
        // top of it forever - it survives lock/unlock, task re-entry, even
        // our own death (it is a Settings process) - and intercepts every
        // return to the app. NO_HISTORY makes it finish the moment it leaves
        // the foreground (Back, Home, lock, app switch), so it can neither
        // leave a card nor shadow the task.
        try {
            Intent intent = new Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES);
            intent.setData(packageUri);
            intent.addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY);
            startActivity(intent);
            Log.d(TAG, "Launched manage unknown app sources settings");
            Log.d(TAG, "==========================================");
            return true;
        } catch (Exception e) {
            Log.w(TAG, "ACTION_MANAGE_UNKNOWN_APP_SOURCES unavailable, falling back to app details: " + e.getMessage());
        }

        try {
            Intent intent = new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
            intent.setData(packageUri);
            intent.addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY);
            startActivity(intent);
            Log.d(TAG, "Launched application details settings for install unknown apps");
            Log.d(TAG, "==========================================");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "ERROR opening install unknown apps settings: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }

    /**
     * Hard-restarts the app in a guaranteed-fresh process: schedules the
     * launcher intent via AlarmManager and kills this process immediately.
     * A plain startActivity while this process is alive lets AMS reuse the
     * process for the new activity, which would keep the stripped
     * supplementary gids this method exists to shed (AYN Odin firmware
     * restores the ext_data_rw / sdcard_rw gids only at fork time, after the
     * user revokes the "Install unknown apps" grant). The alarm fires after
     * process death, so AMS forks a new process with fresh gids.
     *
     * @return true if the restart was scheduled
     */
    @UsedByGodot
    public boolean restartApp() {
        Log.d(TAG, "restartApp() called");
        if (activity == null) {
            Log.e(TAG, "restartApp: Activity is null");
            return false;
        }
        try {
            Intent intent = activity.getPackageManager()
                    .getLaunchIntentForPackage(activity.getPackageName());
            if (intent == null) {
                Log.e(TAG, "restartApp: no launch intent for own package");
                return false;
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
            android.app.PendingIntent restartIntent = android.app.PendingIntent.getActivity(
                    activity, 0x5EAD, intent,
                    android.app.PendingIntent.FLAG_CANCEL_CURRENT
                            | android.app.PendingIntent.FLAG_IMMUTABLE);
            android.app.AlarmManager alarm =
                    (android.app.AlarmManager) activity.getSystemService(android.content.Context.ALARM_SERVICE);
            alarm.set(android.app.AlarmManager.RTC,
                    System.currentTimeMillis() + 250, restartIntent);
            // Die now so the alarm-started activity gets a fresh process.
            android.os.Process.killProcess(android.os.Process.myPid());
            System.exit(0);
            return true;
        } catch (Exception e) {
            Log.e(TAG, "restartApp failed: " + e.getMessage());
            return false;
        }
    }

    /**
     * Checks whether the app is exempt from battery optimizations (doze /
     * background restrictions). Requires the REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
     * manifest permission.
     *
     * @return true if the app is on the battery optimization whitelist
     */
    @UsedByGodot
    public boolean isIgnoringBatteryOptimizations() {
        if (activity == null) {
            Log.e(TAG, "isIgnoringBatteryOptimizations: Activity is null");
            return false;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.os.PowerManager pm =
                (android.os.PowerManager) activity.getSystemService(Context.POWER_SERVICE);
            return pm != null && pm.isIgnoringBatteryOptimizations(activity.getPackageName());
        }
        return true;
    }

    /**
     * Shows the system dialog asking the user to exempt this app from battery
     * optimizations (ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS). Requires the
     * REQUEST_IGNORE_BATTERY_OPTIMIZATIONS manifest permission, otherwise the
     * dialog is silently suppressed.
     *
     * @return true if the dialog intent was launched successfully
     */
    @UsedByGodot
    public boolean requestIgnoreBatteryOptimizations() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "requestIgnoreBatteryOptimizations() called");

        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true;
        }

        try {
            Intent intent = new Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            intent.setData(Uri.parse("package:" + activity.getPackageName()));
            startActivity(intent);
            Log.d(TAG, "Launched ignore battery optimizations dialog");
            Log.d(TAG, "==========================================");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "ERROR requesting battery optimization exemption: " + e.getMessage());
            return false;
        }
    }

    /**
     * Battery state via the sticky ACTION_BATTERY_CHANGED broadcast. This is
     * legal on every Android build, unlike the GDScript sysfs probe
     * (/sys/class/power_supply): SELinux denies untrusted_app access to
     * vendor_sysfs_battery_supply on some handheld firmwares (AYN Odin 2
     * Mini). No permissions required.
     *
     * @return Dictionary: "percent" int (0-100, -1 unknown), "status" int
     *         matching StatusBar.PowerState in GDScript
     *         (0 unknown, 1 on battery, 3 charging, 4 charged)
     */
    @UsedByGodot
    public Dictionary getBatteryState() {
        Dictionary result = new Dictionary();
        result.put("percent", -1);
        result.put("status", 0);
        if (activity == null) {
            Log.e(TAG, "getBatteryState: Activity is null");
            return result;
        }
        try {
            // Null receiver: only fetches the sticky intent, no callback
            // delivery, so no Looper is needed on the calling thread.
            Intent battery = activity.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (battery == null) {
                return result;
            }
            int level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
            if (level >= 0 && scale > 0) {
                result.put("percent", Math.round(level * 100f / scale));
            }
            int status;
            switch (battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
                case BatteryManager.BATTERY_STATUS_CHARGING:
                    status = 3; // CHARGING
                    break;
                case BatteryManager.BATTERY_STATUS_FULL:
                    status = 4; // CHARGED
                    break;
                case BatteryManager.BATTERY_STATUS_DISCHARGING:
                case BatteryManager.BATTERY_STATUS_NOT_CHARGING:
                    status = 1; // ON_BATTERY
                    break;
                default:
                    status = 0; // UNKNOWN
            }
            result.put("status", status);
        } catch (Exception e) {
            Log.e(TAG, "getBatteryState failed", e);
        }
        return result;
    }

    /**
     * Network state via ConnectivityManager. This is legal on every Android
     * build, unlike the GDScript sysfs probe (/sys/class/net +
     * /proc/net/wireless): SELinux denies untrusted_app access to sysfs_net
     * on some handheld firmwares (AYN Odin 2 Mini). No permissions required.
     *
     * @return Dictionary: "state" int matching StatusBar.WifiState in
     *         GDScript (0 unknown, 1 off, 2 wifi connected, 3 ethernet up),
     *         "percent" int (0-100 signal strength, -1 unknown)
     */
    @UsedByGodot
    public Dictionary getWifiState() {
        Dictionary result = new Dictionary();
        result.put("state", 0);
        result.put("percent", -1);
        if (activity == null) {
            Log.e(TAG, "getWifiState: Activity is null");
            return result;
        }
        try {
            ConnectivityManager cm =
                (ConnectivityManager) activity.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) {
                return result;
            }
            Network network = cm.getActiveNetwork();
            NetworkCapabilities caps = network != null ? cm.getNetworkCapabilities(network) : null;
            if (caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    result.put("state", 2); // CONNECTED
                    // Signal strength 0-100, API 29+, no permission needed.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        int strength = caps.getSignalStrength();
                        if (strength != NetworkCapabilities.SIGNAL_STRENGTH_UNSPECIFIED) {
                            result.put("percent", strength);
                        }
                    }
                } else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
                    result.put("state", 3); // ETHERNET_UP
                }
            }
            if ((int) result.get("state") == 0) {
                // No usable network: distinguish "wifi off" from "unknown".
                WifiManager wm = (WifiManager) activity.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
                if (wm != null && !wm.isWifiEnabled()) {
                    result.put("state", 1); // OFF
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "getWifiState failed", e);
        }
        return result;
    }

    // ============================================================================
    // Content URI Resolution (No SAF - requires MANAGE_EXTERNAL_STORAGE)
    // ============================================================================
    
    /**
     * Resolves a content:// URI to a real filesystem path.
     * Parses external storage document URIs without using SAF or ContentResolver.
     * Requires MANAGE_EXTERNAL_STORAGE permission for the returned path to be usable.
     * 
     * Supports:
     * - Document URIs: content://.../document/primary:path/to/file
     * - Tree URIs: content://.../tree/primary:path/to/file
     * 
     * @param contentUri The content:// URI to resolve
     * @return The real filesystem path, or the original URI if it cannot be resolved
     */
    @UsedByGodot
    public String resolveContentUriToRealPath(String contentUri) {
        if (contentUri == null || contentUri.isEmpty()) {
            return "";
        }
        
        if (!contentUri.startsWith("content://")) {
            return contentUri;
        }
        
        try {
            // Handle external storage document URIs
            // Format: content://com.android.externalstorage.documents/document/primary:path/to/file
            if (contentUri.contains("com.android.externalstorage.documents")) {
                String docId = null;
                
                // Try /document/ format first
                int docPos = contentUri.lastIndexOf("/document/");
                if (docPos != -1) {
                    docId = contentUri.substring(docPos + 10); // Skip "/document/"
                } else {
                    // Try /tree/ format
                    int treePos = contentUri.lastIndexOf("/tree/");
                    if (treePos != -1) {
                        docId = contentUri.substring(treePos + 6); // Skip "/tree/"
                    }
                }
                
                if (docId != null && !docId.isEmpty()) {
                    // URL decode the docId
                    docId = java.net.URLDecoder.decode(docId, "UTF-8");
                    
                    // Parse format: "primary:path/to/file" or "XXXX-XXXX:path/to/file"
                    int colonPos = docId.indexOf(':');
                    if (colonPos != -1) {
                        String storage = docId.substring(0, colonPos);
                        String path = docId.substring(colonPos + 1);
                        
                        if ("primary".equalsIgnoreCase(storage)) {
                            return "/storage/emulated/0/" + path;
                        } else {
                            // For other storage volumes (SD cards, etc.)
                            return "/storage/" + storage + "/" + path;
                        }
                    }
                }
            }
            
            // Handle media documents
            if (contentUri.contains("com.android.providers.media.documents")) {
                // Try to query the MediaStore for the file path
                Uri uri = Uri.parse(contentUri);
                String[] projection = {android.provider.MediaStore.MediaColumns.DATA};
                try (android.database.Cursor cursor = activity.getContentResolver().query(uri, projection, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst()) {
                        int columnIndex = cursor.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATA);
                        String dataPath = cursor.getString(columnIndex);
                        if (dataPath != null && !dataPath.isEmpty()) {
                            return dataPath;
                        }
                    }
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error resolving content URI: " + contentUri + " - " + e.getMessage());
        }
        
        // Return original if we couldn't resolve it
        return contentUri;
    }

    /**
     * Imports a content:// URI into app storage by streaming its bytes through
     * the ContentResolver. Used for URIs that cannot be resolved to a real
     * filesystem path (e.g. Downloads provider "msf:" documents) and whose
     * temporary read permission would not survive an app restart.
     *
     * @param contentUri The content:// URI to import
     * @param destDir    Absolute destination directory (created if missing)
     * @return The absolute path of the imported file, or "" on failure
     */
    @UsedByGodot
    public String importContentUri(String contentUri, String destDir) {
        if (contentUri == null || !contentUri.startsWith("content://")) {
            return "";
        }
        if (activity == null || destDir == null || destDir.isEmpty()) {
            return "";
        }

        InputStream inputStream = null;
        OutputStream outputStream = null;
        try {
            Uri uri = Uri.parse(contentUri);

            // Query the display name so the imported file keeps its name/extension
            String displayName = null;
            try (android.database.Cursor cursor = activity.getContentResolver().query(
                    uri, new String[]{android.provider.OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    int idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                    if (idx != -1) {
                        displayName = cursor.getString(idx);
                    }
                }
            }
            if (displayName == null || displayName.isEmpty()) {
                displayName = "imported_file";
            }
            // Sanitize path separators out of the display name
            displayName = displayName.replace("/", "_").replace("\\", "_");

            File dir = new File(destDir);
            if (!dir.exists() && !dir.mkdirs()) {
                Log.e(TAG, "importContentUri: could not create dest dir: " + destDir);
                return "";
            }

            File destFile = new File(dir, displayName);
            inputStream = activity.getContentResolver().openInputStream(uri);
            if (inputStream == null) {
                Log.e(TAG, "importContentUri: could not open input stream for: " + contentUri);
                return "";
            }
            outputStream = new FileOutputStream(destFile);

            byte[] buffer = new byte[65536];
            int bytesRead;
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, bytesRead);
            }
            outputStream.flush();

            Log.d(TAG, "importContentUri: imported " + contentUri + " -> " + destFile.getAbsolutePath());
            return destFile.getAbsolutePath();

        } catch (Exception e) {
            Log.e(TAG, "importContentUri: error importing " + contentUri + " - " + e.getMessage());
            return "";
        } finally {
            try {
                if (outputStream != null) outputStream.close();
                if (inputStream != null) inputStream.close();
            } catch (Exception ignored) {
            }
        }
    }

    // ==================== FOREGROUND SERVICE FOR DOWNLOADS ====================
    
    /**
     * Reassembles chunked download files into a single file.
     * This runs natively to avoid Godot memory overhead during large file operations.
     * 
     * @param chunkPathsJson JSON array of chunk file paths in order
     * @param outputPath Final output file path
     * @return true if successful
     */
    @UsedByGodot
    public boolean reassembleChunks(String chunkPathsJson, String outputPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "reassembleChunks() called");
        Log.d(TAG, "Output path: " + outputPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        java.io.FileOutputStream outputStream = null;
        java.io.FileInputStream inputStream = null;
        
        try {
            // Parse chunk paths from JSON
            org.json.JSONArray chunkPaths = new org.json.JSONArray(chunkPathsJson);
            int chunkCount = chunkPaths.length();
            Log.d(TAG, "Reassembling " + chunkCount + " chunks");
            
            // Create output file
            java.io.File outputFile = new java.io.File(outputPath);
            java.io.File parentDir = outputFile.getParentFile();
            if (parentDir != null && !parentDir.exists()) {
                parentDir.mkdirs();
            }
            
            outputStream = new java.io.FileOutputStream(outputFile);
            
            // 16MB buffer for efficient copying
            byte[] buffer = new byte[16 * 1024 * 1024];
            long totalBytesWritten = 0;
            long lastProgressLog = 0;
            
            // Copy each chunk
            for (int i = 0; i < chunkCount; i++) {
                String chunkPath = chunkPaths.getString(i);
                java.io.File chunkFile = new java.io.File(chunkPath);
                
                if (!chunkFile.exists()) {
                    Log.e(TAG, "ERROR: Chunk file not found: " + chunkPath);
                    outputStream.close();
                    outputFile.delete();
                    return false;
                }
                
                inputStream = new java.io.FileInputStream(chunkFile);
                int bytesRead;
                long chunkBytesWritten = 0;
                
                while ((bytesRead = inputStream.read(buffer)) != -1) {
                    outputStream.write(buffer, 0, bytesRead);
                    totalBytesWritten += bytesRead;
                    chunkBytesWritten += bytesRead;
                }
                
                inputStream.close();
                inputStream = null;
                
                // Log progress every 100MB
                if (totalBytesWritten - lastProgressLog > 100 * 1024 * 1024) {
                    Log.d(TAG, "Reassembly progress: " + (i + 1) + "/" + chunkCount + 
                          " chunks, " + (totalBytesWritten / (1024 * 1024)) + " MB written");
                    lastProgressLog = totalBytesWritten;
                }
            }
            
            outputStream.flush();
            outputStream.close();
            outputStream = null;
            
            Log.d(TAG, "SUCCESS: Reassembled " + chunkCount + " chunks, " + 
                  totalBytesWritten + " bytes total");
            Log.d(TAG, "Output file: " + outputFile.getAbsolutePath());
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR reassembling chunks: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            
            // Clean up on failure
            try {
                if (outputStream != null) outputStream.close();
                if (inputStream != null) inputStream.close();
                // Delete partial output file
                java.io.File outputFile = new java.io.File(outputPath);
                if (outputFile.exists()) {
                    outputFile.delete();
                }
            } catch (Exception cleanupError) {
                Log.e(TAG, "Error during cleanup: " + cleanupError.getMessage());
            }
            
            return false;
        }
    }
    
    /**
     * Copies a file asynchronously, emitting progress and completion signals.
     * Used for the final copy from the app-private temp dir to the destination,
     * including restricted /Android/data/ paths via DocumentsContract.
     * 
     * @param sourcePath Source file path (must be directly readable)
     * @param destPath Destination file path
     * @param itemName Display name for signals
     * @return true if the async copy was started
     */
    @UsedByGodot
    public boolean copyFileAsync(String sourcePath, String destPath, String itemName) {
        SafCache.invalidateTree(destPath);
        Log.d(TAG, "==========================================");
        Log.d(TAG, "copyFileAsync() called");
        Log.d(TAG, "Source: " + sourcePath);
        Log.d(TAG, "Dest: " + destPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        new Thread(() -> {
            if (StorageTier.tierFor(activity, destPath) == StorageTier.TIER_ROOT) {
                copyFileAsyncRoot(sourcePath, destPath, itemName);
                return;
            }
            java.io.FileInputStream inputStream = null;
            java.io.OutputStream outputStream = null;
            
            try {
                java.io.File sourceFile = new File(sourcePath);
                if (!sourceFile.exists()) {
                    throw new Exception("Source file not found: " + sourcePath);
                }
                
                long totalBytes = sourceFile.length();
                long copiedBytes = 0;
                long lastProgressBytes = 0;
                
                inputStream = new java.io.FileInputStream(sourceFile);
                
                // Create output stream: direct File first, DocumentsContract
                // as fallback for restricted paths
                java.io.File outputFile = new File(destPath);
                java.io.File parentDir = outputFile.getParentFile();
                if (parentDir != null && !parentDir.exists()) {
                    parentDir.mkdirs();
                }
                if (parentDir != null && parentDir.canWrite()) {
                    outputStream = new java.io.FileOutputStream(outputFile);
                } else if (requiresDocumentsContract(destPath)) {
                    Uri docUri = pathToDocumentUri(destPath);
                    if (docUri == null) {
                        throw new Exception("Could not create document URI for: " + destPath);
                    }
                    outputStream = activity.getContentResolver().openOutputStream(docUri);
                    if (outputStream == null) {
                        throw new Exception("Could not open output stream for: " + destPath);
                    }
                } else {
                    outputStream = new java.io.FileOutputStream(outputFile);
                }
                
                // 16MB buffer for efficient copying
                byte[] buffer = new byte[16 * 1024 * 1024];
                int bytesRead;
                
                while ((bytesRead = inputStream.read(buffer)) != -1) {
                    outputStream.write(buffer, 0, bytesRead);
                    copiedBytes += bytesRead;
                    
                    // Emit progress every 50MB
                    if (copiedBytes - lastProgressBytes > 50 * 1024 * 1024) {
                        final long progressCopied = copiedBytes;
                        final long progressTotal = totalBytes;
                        activity.runOnUiThread(() -> emitSignal("copy_progress", itemName, progressCopied, progressTotal));
                        lastProgressBytes = copiedBytes;
                    }
                }
                
                outputStream.flush();
                outputStream.close();
                outputStream = null;
                inputStream.close();
                inputStream = null;

                Log.d(TAG, "SUCCESS: Copied " + copiedBytes + " bytes to " + destPath);
                Log.d(TAG, "==========================================");
                postSafFixup(destPath);
                activity.runOnUiThread(() -> emitSignal("copy_complete", itemName, true, destPath, ""));
                
            } catch (Exception e) {
                Log.e(TAG, "ERROR copying file: " + e.getMessage());
                Log.e(TAG, "Exception type: " + e.getClass().getName());
                
                try {
                    if (outputStream != null) outputStream.close();
                    if (inputStream != null) inputStream.close();
                    // Clean up partial destination file
                    if (!requiresDocumentsContract(destPath)) {
                        java.io.File outputFile = new File(destPath);
                        if (outputFile.exists()) {
                            outputFile.delete();
                        }
                    }
                } catch (Exception cleanupError) {
                    Log.e(TAG, "Error during copy cleanup: " + cleanupError.getMessage());
                }
                
                final String errorMsg = e.getMessage();
                activity.runOnUiThread(() -> emitSignal("copy_complete", itemName, false, destPath, errorMsg));
            }
        }).start();
        
        return true;
    }

    /**
     * Root-tier copyFileAsync: streams into our own cache with the usual
     * progress signals, then the vendor daemon moves the finished file into
     * the restricted destination and chowns it to the target package.
     */
    private void copyFileAsyncRoot(String sourcePath, String destPath, String itemName) {
        java.io.FileInputStream inputStream = null;
        java.io.FileOutputStream outputStream = null;
        File staging = null;
        try {
            File sourceFile = new File(sourcePath);
            if (!sourceFile.exists()) {
                throw new Exception("Source file not found: " + sourcePath);
            }
            long totalBytes = sourceFile.length();
            staging = new File(activity.getCacheDir(),
                    "root-copy-" + itemName.hashCode() + "-" + System.nanoTime());
            inputStream = new java.io.FileInputStream(sourceFile);
            outputStream = new java.io.FileOutputStream(staging);

            byte[] buffer = new byte[16 * 1024 * 1024];
            long copiedBytes = 0;
            long lastProgressBytes = 0;
            int bytesRead;
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, bytesRead);
                copiedBytes += bytesRead;
                if (copiedBytes - lastProgressBytes > 50 * 1024 * 1024) {
                    final long progressCopied = copiedBytes;
                    final long progressTotal = totalBytes;
                    activity.runOnUiThread(() -> emitSignal("copy_progress", itemName, progressCopied, progressTotal));
                    lastProgressBytes = copiedBytes;
                }
            }
            outputStream.flush();
            outputStream.close();
            outputStream = null;
            inputStream.close();
            inputStream = null;

            StorageTier.logOp("copy", destPath, StorageTier.TIER_ROOT);
            if (!StorageTier.rootCopyFile(activity, staging.getAbsolutePath(), destPath)) {
                throw new Exception("root copy failed for: " + destPath);
            }

            Log.d(TAG, "SUCCESS (root tier): Copied " + copiedBytes + " bytes to " + destPath);
            activity.runOnUiThread(() -> emitSignal("copy_complete", itemName, true, destPath, ""));
        } catch (Exception e) {
            Log.e(TAG, "ERROR copying file (root tier): " + e.getMessage());
            final String errorMsg = e.getMessage();
            activity.runOnUiThread(() -> emitSignal("copy_complete", itemName, false, destPath, errorMsg));
        } finally {
            try {
                if (outputStream != null) outputStream.close();
                if (inputStream != null) inputStream.close();
            } catch (Exception ignored) {}
            if (staging != null && staging.exists()) {
                staging.delete();
            }
        }
    }

    // ========================================================================
    // Chunked flush mode: chunk temp files are written directly into the
    // final destination at their byte offsets as each chunk completes, so the
    // end-of-download full-file copy disappears. Works for direct paths
    // (RandomAccessFile) and SAF DocumentsContract paths (ParcelFileDescriptor
    // "rw" + positioned FileChannel writes). Root-tier destinations decline
    // here; the caller falls back to temp-dir assembly + copyFileAsync.
    // ========================================================================

    /** Single-thread executor: sequential flushes avoid flash write thrash. */
    private java.util.concurrent.ExecutorService chunkFlushExecutor = null;

    /**
     * Probes whether a destination supports positioned writes. Shrinks stale
     * oversized leftovers (instant), but never eagerly extends: growing a
     * file zero-fills the gap on exFAT/FUSE, which can block for minutes on
     * multi-GB files. Positioned flush writes grow the file lazily instead.
     * Returns false if chunked flush mode cannot be used (caller falls back
     * to temp-dir assembly + final copy).
     */
    @UsedByGodot
    public boolean prepareChunkedDestination(String destPath, long totalSize) {
        SafCache.invalidateTree(destPath);
        if (activity == null || destPath == null || destPath.isEmpty()) {
            return false;
        }
        try {
            if (StorageTier.tierFor(activity, destPath) == StorageTier.TIER_ROOT) {
                // No positioned writes through the daemon; caller falls back
                // to temp-dir assembly + copyFileAsync (root tier).
                return false;
            }
            File file = new File(destPath);
            File parent = file.getParentFile();
            if (parent != null && !parent.exists()) {
                parent.mkdirs();
            }
            if (parent != null && parent.canWrite()) {
                java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
                if (totalSize > 0 && raf.length() > totalSize) {
                    raf.setLength(totalSize);
                }
                // Fresh file: prove beyond-EOF positioned writes with a cheap
                // small-offset write (chunk 0 overwrites this byte anyway).
                if (raf.length() == 0) {
                    raf.seek(Math.min(Math.max(totalSize - 1, 0), 1024));
                    raf.write(0);
                }
                raf.close();
                return true;
            }
            if (requiresDocumentsContract(destPath)) {
                Uri uri = ensureDocumentExists(destPath);
                if (uri == null) {
                    return false;
                }
                android.os.ParcelFileDescriptor pfd =
                        activity.getContentResolver().openFileDescriptor(uri, "rw");
                if (pfd == null) {
                    return false;
                }
                java.nio.channels.FileChannel channel =
                        new FileOutputStream(pfd.getFileDescriptor()).getChannel();
                long size = channel.size();
                if (totalSize > 0 && size > totalSize) {
                    channel.truncate(totalSize);
                }
                if (size == 0) {
                    channel.position(Math.min(Math.max(totalSize - 1, 0), 1024));
                    channel.write(java.nio.ByteBuffer.allocate(1));
                }
                channel.close();
                pfd.close();
                return true;
            }
            // Last resort: plain direct access
            java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
            if (totalSize > 0 && raf.length() > totalSize) {
                raf.setLength(totalSize);
            }
            if (raf.length() == 0) {
                raf.seek(Math.min(Math.max(totalSize - 1, 0), 1024));
                raf.write(0);
            }
            raf.close();
            return true;
        } catch (Exception e) {
            Log.w(TAG, "prepareChunkedDestination failed for " + destPath + ": " + e.getMessage());
            return false;
        }
    }

    /** Creates the destination document via DocumentsContract if missing. */
    private Uri ensureDocumentExists(String path) {
        SafCache.invalidateTree(path);
        Uri uri = documentUriFor(path);
        if (uri == null) {
            return null;
        }
        try {
            android.os.ParcelFileDescriptor probe =
                    activity.getContentResolver().openFileDescriptor(uri, "r");
            if (probe != null) {
                probe.close();
                return uri;
            }
        } catch (Exception e) {
            Log.d(TAG, "ensureDocumentExists: doc missing, creating: " + e.getMessage());
        }
        String parentPath = path.substring(0, path.lastIndexOf('/'));
        String name = path.substring(path.lastIndexOf('/') + 1);
        Uri parentUri = documentUriFor(parentPath);
        if (parentUri == null) {
            return null;
        }
        try {
            return DocumentsContract.createDocument(
                    activity.getContentResolver(), parentUri, "application/octet-stream", name);
        } catch (Exception e) {
            Log.w(TAG, "ensureDocumentExists: createDocument failed: " + e.getMessage());
            return null;
        }
    }

    /**
     * Flushes a downloaded chunk temp file into the destination at the given
     * byte offset, asynchronously. Emits chunk_flush_complete(token, success, error).
     */
    @UsedByGodot
    public boolean flushChunkAsync(String chunkPath, String destPath, long offset, String token) {
        if (activity == null) {
            return false;
        }
        if (chunkFlushExecutor == null) {
            chunkFlushExecutor = java.util.concurrent.Executors.newSingleThreadExecutor();
        }
        chunkFlushExecutor.execute(() -> {
            boolean success = false;
            String error = "";
            try {
                success = writeChunkAt(chunkPath, destPath, offset);
                if (!success) {
                    error = "No writable destination for: " + destPath;
                }
            } catch (Exception e) {
                error = String.valueOf(e.getMessage());
                Log.e(TAG, "flushChunk failed: " + chunkPath + " -> " + destPath + " @" + offset + ": " + error);
            }
            final boolean s = success;
            final String err = error;
            activity.runOnUiThread(() -> emitSignal("chunk_flush_complete", token, s, err));
        });
        return true;
    }

    /** Streams a chunk file into the destination at a byte offset. */
    private boolean writeChunkAt(String chunkPath, String destPath, long offset) throws Exception {
        SafCache.invalidateTree(destPath);
        if (StorageTier.tierFor(activity, destPath) == StorageTier.TIER_ROOT) {
            return false;
        }
        File chunkFile = new File(chunkPath);
        if (!chunkFile.exists()) {
            throw new Exception("Chunk file not found: " + chunkPath);
        }
        byte[] buffer = new byte[8 * 1024 * 1024];
        FileInputStream in = new FileInputStream(chunkFile);
        try {
            File file = new File(destPath);
            File parent = file.getParentFile();
            if (parent != null && parent.canWrite()) {
                java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
                try {
                    raf.seek(offset);
                    int r;
                    while ((r = in.read(buffer)) != -1) {
                        raf.write(buffer, 0, r);
                    }
                } finally {
                    raf.close();
                }
                return true;
            }
            if (requiresDocumentsContract(destPath)) {
                Uri uri = documentUriFor(destPath);
                if (uri == null) {
                    return false;
                }
                android.os.ParcelFileDescriptor pfd =
                        activity.getContentResolver().openFileDescriptor(uri, "rw");
                if (pfd == null) {
                    return false;
                }
                java.nio.channels.FileChannel channel =
                        new FileOutputStream(pfd.getFileDescriptor()).getChannel();
                try {
                    channel.position(offset);
                    java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(buffer);
                    int r;
                    while ((r = in.read(buffer)) != -1) {
                        bb.clear();
                        bb.limit(r);
                        while (bb.hasRemaining()) {
                            channel.write(bb);
                        }
                    }
                } finally {
                    channel.close();
                    pfd.close();
                }
                return true;
            }
            java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
            try {
                raf.seek(offset);
                int r;
                while ((r = in.read(buffer)) != -1) {
                    raf.write(buffer, 0, r);
                }
            } finally {
                raf.close();
            }
            return true;
        } finally {
            in.close();
        }
    }

    /**
     * Returns the size of a file in bytes, using DocumentsContract for
     * restricted paths. Returns -1 if the file is missing or unreadable.
     */
    @UsedByGodot
    public long androidFileSize(String path) {
        if (path == null || path.isEmpty()) {
            return -1;
        }
        File file = new File(path);
        if (file.exists()) {
            return file.length();
        }
        if (requiresDocumentsContract(path)) {
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                            docUri,
                            new String[]{DocumentsContract.Document.COLUMN_SIZE},
                            null, null, null);
                    if (cursor != null) {
                        long size = -1;
                        if (cursor.moveToFirst() && !cursor.isNull(0)) {
                            size = cursor.getLong(0);
                        }
                        cursor.close();
                        return size;
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "androidFileSize failed for " + path + ": " + e.getMessage());
            }
        }
        return -1;
    }

    /**
     * Starts the foreground service to prevent Android from killing the app during downloads.
     * Shows a persistent notification while downloads are active.
     */
    @UsedByGodot
    public void startDownloadForegroundService(String gameName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "startDownloadForegroundService() called");
        Log.d(TAG, "Game: " + gameName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, DownloadForegroundService.class);
            intent.setAction("START_DOWNLOAD");
            intent.putExtra("game_name", gameName);
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent);
            } else {
                activity.startService(intent);
            }
            
            Log.d(TAG, "Foreground service started successfully");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR starting foreground service: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
        }
    }
    
    /**
     * Updates the foreground service notification with download progress.
     */
    @UsedByGodot
    public void updateDownloadForegroundService(String gameName, int progress) {
        if (activity == null) {
            return;
        }
        
        try {
            Intent intent = new Intent(activity, DownloadForegroundService.class);
            intent.setAction("UPDATE_PROGRESS");
            intent.putExtra("game_name", gameName);
            intent.putExtra("progress", progress);
            
            activity.startService(intent);
        } catch (Exception e) {
            Log.e(TAG, "ERROR updating foreground service: " + e.getMessage());
        }
    }
    
    // ============================================================================
    // DocumentsContract File Access for /Android/data/ and /Android/obb/
    // ============================================================================
    
    /**
     * Checks if a path requires DocumentsContract to access.
     * On Android 11+, /Android/data/ and /Android/obb/ are restricted
     * even with MANAGE_EXTERNAL_STORAGE.
     */
    @UsedByGodot
    public boolean requiresDocumentsContract(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return false; // Android 10 and below can access directly
        }
        
        // Check if path is in restricted directories
        return path.contains("/Android/data/") || path.contains("/Android/obb/");
    }

    // ========================================================================
    // Storage tiers for /Android/data|obb writes: DIRECT (we hold ext_data_rw),
    // SAF (DocumentsContract; target holds ext_data_rw), ROOT (vendor daemon
    // writes + chown to the target uid). See StorageTier.
    // ========================================================================

    @UsedByGodot
    public boolean hasExtDataRwAccess() {
        return StorageTier.selfHasExtDataRw();
    }

    /** 0=direct, 1=saf, 2=root - the write tier for a path (diagnostics). */
    @UsedByGodot
    public int storageTierForPath(String path) {
        return StorageTier.tierFor(activity, path);
    }

    /**
     * 0=direct, 1=saf, 2=root, 3=none - the access route for a path. This is
     * the single source of truth for GDScript flow decisions: NONE means no
     * route exists (prompt for a grant); non-DIRECT means plain File I/O
     * (e.g. HTTPRequest downloads) cannot write the path and must stage.
     */
    @UsedByGodot
    public int accessRouteForPath(String path) {
        return StorageTier.accessRouteFor(activity, path);
    }

    /** Ownership repair after SAF-tier writes; see StorageTier. */
    private void postSafFixup(String path) {
        if (requiresDocumentsContract(path)) {
            StorageTier.chownToOwnerBestEffort(activity, path);
        }
    }

    // ========================================================================
    // SAF tree grant for /Android/data/ and /Android/obb/
    // Mirrors argosy-launcher's ManagedStorageAccessor: a persisted document-tree
    // grant (user picks the "Android" or "Android/data" folder once) is preferred;
    // without it we fall back to bare document URIs with the manage=true query
    // parameter, which ExternalStorageProvider honors for MANAGE_EXTERNAL_STORAGE
    // holders.
    // ========================================================================

    /**
     * Launches the system folder picker so the user can grant access to an
     * emulator's app-data folder. When targetPath is under Android/data/<pkg>
     * (or obb), the picker is pointed at that package subfolder — subfolders
     * are not on DocumentsUI's blocklist even though the data/obb roots are.
     * Result arrives via the saf_grant_result signal.
     */
    @UsedByGodot
    public void requestAndroidDataAccess(String targetPath) {
        if (activity == null) {
            emitSignal("saf_grant_result", false);
            return;
        }
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        String docId = targetPath != null ? packageDocIdFor(targetPath) : null;
        if (docId == null) {
            docId = "primary:Android/data";
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Uri initial = DocumentsContract.buildDocumentUri(DOCS_AUTHORITY, docId);
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial);
        }
        try {
            activity.startActivityForResult(intent, REQUEST_SAF_TREE);
        } catch (Exception e) {
            Log.e(TAG, "requestAndroidDataAccess failed: " + e.getMessage());
            emitSignal("saf_grant_result", false);
        }
    }

    @Override
    public void onMainActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_SAF_TREE) return;
        boolean granted = false;
        if (resultCode == Activity.RESULT_OK && data != null && data.getData() != null) {
            Uri treeUri = data.getData();
            try {
                activity.getContentResolver().takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                Set<String> uris = new HashSet<>(getStoredTreeUriStrings());
                uris.add(treeUri.toString());
                activity.getSharedPreferences(SAF_PREFS, Context.MODE_PRIVATE)
                        .edit().putStringSet(SAF_TREE_URIS_KEY, uris).apply();
                StorageTier.invalidateGrantBases();
                granted = true;
                Log.d(TAG, "SAF tree grant persisted: " + treeUri);
            } catch (Exception e) {
                Log.e(TAG, "Failed to persist SAF grant: " + e.getMessage());
            }
        }
        emitSignal("saf_grant_result", granted);
    }

    /** Returns true if any persisted read+write document-tree grant exists. */
    @UsedByGodot
    public boolean hasSafGrant() {
        if (activity == null) return false;
        for (UriPermission p : activity.getContentResolver().getPersistedUriPermissions()) {
            if (p.isReadPermission() && p.isWritePermission()
                    && p.getUri().toString().startsWith("content://" + DOCS_AUTHORITY + "/tree/")) {
                return true;
            }
        }
        return false;
    }

    /** Returns true if a persisted tree grant covers the given path. */
    @UsedByGodot
    public boolean hasSafGrantFor(String path) {
        return treeUriForPath(path) != null;
    }

    private Set<String> getStoredTreeUriStrings() {
        if (activity == null) return new HashSet<>();
        return activity.getSharedPreferences(SAF_PREFS, Context.MODE_PRIVATE)
                .getStringSet(SAF_TREE_URIS_KEY, new HashSet<String>());
    }

    /**
     * Extracts the Android/data|obb package subfolder docId for a path.
     * e.g. /storage/emulated/0/Android/data/com.foo/files/x -> "primary:Android/data/com.foo"
     */
    private String packageDocIdFor(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String[] segs = vp[1].split("/");
        if (segs.length >= 3 && segs[0].equals("Android")
                && (segs[1].equals("data") || segs[1].equals("obb"))) {
            return vp[0] + ":" + segs[0] + "/" + segs[1] + "/" + segs[2];
        }
        return null;
    }

    /** Finds a persisted read+write tree grant whose tree covers the given path. */
    private Uri treeUriForPath(String path) {
        if (activity == null) return null;
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String targetDocId = vp[0] + ":" + vp[1];
        for (UriPermission p : activity.getContentResolver().getPersistedUriPermissions()) {
            if (!p.isReadPermission() || !p.isWritePermission()) continue;
            Uri uri = p.getUri();
            if (!uri.toString().startsWith("content://" + DOCS_AUTHORITY + "/tree/")) continue;
            try {
                String treeDocId = DocumentsContract.getTreeDocumentId(uri);
                if (targetDocId.equals(treeDocId) || targetDocId.startsWith(treeDocId + "/")) {
                    return uri;
                }
            } catch (Exception ignored) {}
        }
        return null;
    }

    /**
     * Splits an absolute path into {volumeId, relativePath}.
     * /storage/emulated/0/... -> volume "primary"; /storage/XXXX-XXXX/... -> that id.
     */
    private String[] splitVolumePath(String path) {
        if (path == null) return null;
        if (path.startsWith("/storage/emulated/0/")) {
            return new String[]{"primary", path.substring("/storage/emulated/0/".length())};
        }
        if (path.startsWith("/sdcard/")) {
            return new String[]{"primary", path.substring("/sdcard/".length())};
        }
        if (path.startsWith("/storage/")) {
            String[] parts = path.split("/");
            if (parts.length >= 4) {
                String volumeId = parts[2];
                return new String[]{volumeId, path.substring(("/storage/" + volumeId + "/").length())};
            }
        }
        return null;
    }

    /** Appends manage=true for /Android/data|obb paths (honored by ExternalStorageProvider for MES holders). */
    private Uri applyManagedParameter(Uri uri, String relativePath) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return uri;
        boolean needsManaged = relativePath.startsWith("Android/data")
                || relativePath.startsWith("Android/obb")
                || relativePath.equals("Android");
        return needsManaged ? uri.buildUpon().appendQueryParameter("manage", "true").build() : uri;
    }

    /**
     * Builds a document URI for an absolute path. Order: covering persisted
     * tree grant, legacy tree/<volume>-scoped URI (served by some providers
     * for MANAGE_EXTERNAL_STORAGE holders), bare URI + manage=true.
     */
    private Uri documentUriFor(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String docId = vp[0] + ":" + vp[1];
        Uri treeUri = treeUriForPath(path);
        if (treeUri != null) {
            try {
                return DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
            } catch (Exception e) {
                Log.w(TAG, "buildDocumentUriUsingTree failed: " + e.getMessage());
            }
        }
        // Legacy tree-scoped form (no grant required on lenient providers)
        try {
            return DocumentsContract.buildDocumentUriUsingTree(
                    Uri.parse("content://" + DOCS_AUTHORITY + "/tree/" + vp[0]), docId);
        } catch (Exception e) {
            Log.w(TAG, "legacy tree-scoped URI failed: " + e.getMessage());
        }
        return applyManagedParameter(DocumentsContract.buildDocumentUri(DOCS_AUTHORITY, docId), vp[1]);
    }

    /** Builds a children-listing URI for an absolute directory path. */
    private Uri childrenUriFor(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String docId = vp[0] + ":" + vp[1];
        Uri treeUri = treeUriForPath(path);
        if (treeUri != null) {
            try {
                Uri dirDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
                return DocumentsContract.buildChildDocumentsUriUsingTree(dirDocUri, docId);
            } catch (Exception e) {
                Log.w(TAG, "buildChildDocumentsUriUsingTree failed: " + e.getMessage());
            }
        }
        // Legacy tree-scoped form
        try {
            Uri legacyTree = Uri.parse("content://" + DOCS_AUTHORITY + "/tree/" + vp[0]);
            return DocumentsContract.buildChildDocumentsUriUsingTree(legacyTree, docId);
        } catch (Exception e) {
            Log.w(TAG, "legacy children URI failed: " + e.getMessage());
        }
        return applyManagedParameter(
                DocumentsContract.buildChildDocumentsUri(DOCS_AUTHORITY, docId), vp[1]);
    }

    /** Opens an SAF asset stream and closes its descriptor with the stream. */
    private InputStream openAssetInput(Uri uri) throws Exception {
        final AssetFileDescriptor descriptor = activity.getContentResolver().openAssetFileDescriptor(uri, "r");
        if (descriptor == null) return null;
        try {
            return new java.io.FilterInputStream(new FileInputStream(descriptor.getFileDescriptor())) {
                @Override public void close() throws java.io.IOException {
                    try { super.close(); } finally { descriptor.close(); }
                }
            };
        } catch (Exception e) {
            descriptor.close();
            throw e;
        }
    }

    /** Opens a truncating SAF asset stream and closes its descriptor with the stream. */
    private OutputStream openAssetOutput(Uri uri) throws Exception {
        final AssetFileDescriptor descriptor = activity.getContentResolver().openAssetFileDescriptor(uri, "wt");
        if (descriptor == null) return null;
        try {
            return new java.io.FilterOutputStream(new FileOutputStream(descriptor.getFileDescriptor())) {
                @Override public void close() throws java.io.IOException {
                    try { super.close(); } finally { descriptor.close(); }
                }
            };
        } catch (Exception e) {
            descriptor.close();
            throw e;
        }
    }

    /** Opens a read stream: direct File first, then DocumentsContract. */
    private InputStream openInputFor(String path) throws Exception {
        long t0 = SafPerf.start();
        try { return openInputForImpl(path); }
        finally { SafPerf.record("openInputFor", t0); }
    }

    private InputStream openInputForImpl(String path) throws Exception {
        File file = new File(path);
        if (file.exists() && file.canRead()) {
            return new FileInputStream(file);
        }
        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                return openAssetInput(uri);
            }
        }
        return null;
    }

    /** Opens a write stream (truncating): direct File first, then DocumentsContract with create-if-missing. */
    private OutputStream openOutputFor(String path) throws Exception {
        long t0 = SafPerf.start();
        try { return openOutputForImpl(path); }
        finally { SafPerf.record("openOutputFor", t0); }
    }

    private OutputStream openOutputForImpl(String path) throws Exception {
        File file = new File(path);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }
        if (parent != null && parent.canWrite()) {
            return new FileOutputStream(file);
        }
        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    OutputStream out = openAssetOutput(uri);
                    if (out != null) return out;
                } catch (Exception e) {
                    Log.d(TAG, "openOutputFor: existing doc open failed, creating: " + e.getMessage());
                }
                // File doesn't exist yet: create it under its parent document
                String parentPath = path.substring(0, path.lastIndexOf('/'));
                String name = path.substring(path.lastIndexOf('/') + 1);
                Uri parentUri = documentUriFor(parentPath);
                if (parentUri != null) {
                    Uri created = DocumentsContract.createDocument(
                            activity.getContentResolver(), parentUri, "application/octet-stream", name);
                    if (created != null) {
                        return openAssetOutput(created);
                    }
                }
            }
        }
        return null;
    }

    /**
     * Converts a file path to a DocumentsContract URI for accessing /Android/data/.
     * Format: content://com.android.externalstorage.documents/document/primary:Android/data/...
     */
    private Uri pathToDocumentUri(String path) {
        if (path == null || path.isEmpty()) {
            return null;
        }
        return documentUriFor(path);
    }
    
    /**
     * Checks if a file exists, using DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public String safPerfSnapshot() {
        return SafPerf.snapshotAndReset();
    }

    @UsedByGodot
    public boolean androidFileExists(String path) {
        long t0 = SafPerf.start();
        try { return androidFileExistsImpl(path); }
        finally { SafPerf.record("androidFileExists", t0); }
    }

    private boolean androidFileExistsImpl(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        // Try direct access first
        File file = new File(path);
        if (file.exists()) {
            return true;
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            boolean[] cached = SafCache.lookup(path);
            if (cached != null) {
                return cached[0];
            }
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        docUri,
                        new String[]{
                            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                        },
                        null, null, null
                    );
                    if (cursor != null) {
                        boolean exists = cursor.moveToFirst();
                        boolean isDir = false;
                        if (exists) {
                            int mimeIndex = cursor.getColumnIndex(
                                    android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE);
                            if (mimeIndex >= 0) {
                                isDir = android.provider.DocumentsContract.Document.MIME_TYPE_DIR
                                        .equals(cursor.getString(mimeIndex));
                            }
                        }
                        cursor.close();
                        // Cache positive existence and type as well as misses;
                        // all plugin mutations invalidate their affected tree.
                        SafCache.put(path, exists, isDir);
                        return exists;
                    }
                }
                } catch (Exception e) {
                    String msg = String.valueOf(e.getMessage());
                    if (msg.contains("FileNotFoundException") || msg.contains("Missing file")
                            || msg.contains("No such file")) {
                        // Expected during marker polling — file simply doesn't exist yet
                        SafCache.put(path, false, false);
                        return false;
                    }
                    Log.w(TAG, "DocumentsContract fileExists failed: " + msg);
                }
        }
        
        return false;
    }
    
    /**
     * Checks if a directory exists, using DocumentsContract for restricted paths.
     * Verifies the document is actually a directory (MIME_TYPE_DIR), not just any document.
     */
    @UsedByGodot
    public boolean androidDirExists(String path) {
        long t0 = SafPerf.start();
        try { return androidDirExistsImpl(path); }
        finally { SafPerf.record("androidDirExists", t0); }
    }

    private boolean androidDirExistsImpl(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        // Try direct access first
        File file = new File(path);
        if (file.exists() && file.isDirectory()) {
            return true;
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            boolean[] cached = SafCache.lookup(path);
            if (cached != null) {
                return cached[0] && cached[1];
            }
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        docUri,
                        new String[]{
                            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                        },
                        null, null, null
                    );
                    if (cursor != null) {
                        boolean exists = false;
                        boolean isDir = false;
                        if (cursor.moveToFirst()) {
                            exists = true;
                            int mimeTypeIndex = cursor.getColumnIndex(
                                android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                            );
                            if (mimeTypeIndex >= 0) {
                                String mimeType = cursor.getString(mimeTypeIndex);
                                isDir = android.provider.DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
                            }
                        }
                        cursor.close();
                        SafCache.put(path, exists, isDir);
                        return isDir;
                    }
                }
            } catch (Exception e) {
                String msg = String.valueOf(e.getMessage());
                if (msg.contains("FileNotFoundException") || msg.contains("Missing file")
                        || msg.contains("No such file")) {
                    SafCache.put(path, false, false);
                    return false;
                }
                Log.w(TAG, "DocumentsContract dirExists failed: " + msg);
            }
        }
        
        return false;
    }
    
    /**
     * Reads a file and returns its contents as a base64-encoded string.
     * Uses DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public String androidReadFile(String path) {
        long t0 = SafPerf.start();
        try { return androidReadFileImpl(path); }
        finally { SafPerf.record("androidReadFile", t0); }
    }

    private String androidReadFileImpl(String path) {
        if (path == null || path.isEmpty()) {
            return "";
        }
        
        try {
            java.io.InputStream inputStream = null;
            
            // Try direct access first
            File file = new File(path);
            if (file.exists() && file.canRead()) {
                inputStream = new java.io.FileInputStream(file);
            } else if (requiresDocumentsContract(path)) {
                // Use DocumentsContract
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    inputStream = activity.getContentResolver().openInputStream(docUri);
                }
            }
            
            if (inputStream == null) {
                return "";
            }
            
            // Read all bytes
            java.io.ByteArrayOutputStream byteStream = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int bytesRead;
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                byteStream.write(buffer, 0, bytesRead);
            }
            inputStream.close();
            
            // Encode as base64
            String base64 = android.util.Base64.encodeToString(byteStream.toByteArray(), android.util.Base64.NO_WRAP);
            return base64;
            
        } catch (Exception e) {
            Log.e(TAG, "Error reading file: " + path + " - " + e.getMessage());
            return "";
        }
    }
    
    /**
     * Writes base64-encoded data to a file.
     * Uses DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public boolean androidWriteFile(String path, String base64Data) {
        long t0 = SafPerf.start();
        try { return androidWriteFileImpl(path, base64Data); }
        finally { SafPerf.record("androidWriteFile", t0); }
    }

    private boolean androidWriteFileImpl(String path, String base64Data) {
        SafCache.invalidateTree(path);
        if (path == null || path.isEmpty() || base64Data == null) {
            return false;
        }
        
        try {
            byte[] data = android.util.Base64.decode(base64Data, android.util.Base64.NO_WRAP);
            
            // Try direct access first
            File file = new File(path);
            File parentDir = file.getParentFile();
            if (parentDir != null && !parentDir.exists()) {
                parentDir.mkdirs();
            }
            
            if (parentDir != null && parentDir.canWrite()) {
                java.io.FileOutputStream outputStream = new java.io.FileOutputStream(file);
                outputStream.write(data);
                outputStream.close();
                return true;
            }
            
            // Restricted-path fallback: root daemon when no SAF grant covers
            // the path, else DocumentsContract.
            if (requiresDocumentsContract(path)) {
                int tier = StorageTier.tierFor(activity, path);
                if (tier == StorageTier.TIER_ROOT) {
                    StorageTier.logOp("write", path, tier);
                    return StorageTier.rootWriteFile(activity, path, data);
                }
                java.io.OutputStream outputStream = openOutputFor(path);
                if (outputStream != null) {
                    outputStream.write(data);
                    outputStream.close();
                    postSafFixup(path);
                    return true;
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error writing file: " + path + " - " + e.getMessage());
        }
        
        return false;
    }
    
    /** Opens a bounded read stream; use androidReadChunk/androidCloseRead. */
    @UsedByGodot
    public int androidOpenRead(String path) {
        if (path == null || path.isEmpty()) return -1;
        try {
            InputStream input = openInputFor(path);
            if (input == null) return -1;
            return SafStreams.openRead(path, input);
        } catch (Exception e) {
            Log.w(TAG, "androidOpenRead failed: " + e.getMessage());
            return -1;
        }
    }

    /** Returns null on error, an empty string on EOF, or a base64 chunk. */
    @UsedByGodot
    public String androidReadChunk(int handle, int maxBytes) {
        return SafStreams.readChunk(handle, maxBytes);
    }

    @UsedByGodot
    public boolean androidCloseRead(int handle) {
        return SafStreams.closeRead(handle);
    }

    /** Opens a bounded write stream; use androidWriteChunk/androidCloseWrite. */
    @UsedByGodot
    public int androidOpenWrite(String path) {
        if (path == null || path.isEmpty()) return -1;
        SafCache.invalidateTree(path);
        File rootStaging = null;
        try {
            OutputStream output;
            if (requiresDocumentsContract(path)
                    && StorageTier.tierFor(activity, path) == StorageTier.TIER_ROOT) {
                rootStaging = new File(activity.getCacheDir(),
                        "root-stream-" + java.util.UUID.randomUUID());
                output = new FileOutputStream(rootStaging);
            } else {
                output = openOutputFor(path);
            }
            if (output == null) return -1;
            return SafStreams.openWrite(path, output, rootStaging);
        } catch (Exception e) {
            if (rootStaging != null) rootStaging.delete();
            Log.w(TAG, "androidOpenWrite failed: " + e.getMessage());
            return -1;
        }
    }

    @UsedByGodot
    public boolean androidWriteChunk(int handle, String base64Data) {
        return SafStreams.writeChunk(handle, base64Data);
    }

    /** Flushes and finalizes the destination; a root-tier file is copied by the daemon. */
    @UsedByGodot
    public boolean androidCloseWrite(int handle) {
        SafStreams.Session session = SafStreams.closeWrite(handle);
        if (session == null) return false;
        boolean ok = !session.failed;
        if (session.rootStaging != null) {
            if (ok) {
                StorageTier.logOp("write", session.path, StorageTier.TIER_ROOT);
                ok = StorageTier.rootCopyFile(activity, session.rootStaging.getAbsolutePath(), session.path);
            }
            session.rootStaging.delete();
        } else if (ok) {
            postSafFixup(session.path);
        }
        SafCache.invalidateTree(session.path);
        return ok;
    }

    /** Streaming MD5 used by save sync; avoids a base64/JNI file round trip. */
    @UsedByGodot
    public String androidComputeFileHash(String path) {
        if (path == null || path.isEmpty()) return "";
        try {
            InputStream input = openInputFor(path);
            if (input == null) return "";
            try {
                java.security.MessageDigest digest = java.security.MessageDigest.getInstance("MD5");
                byte[] buffer = new byte[1024 * 1024];
                int read;
                while ((read = input.read(buffer)) != -1) {
                    digest.update(buffer, 0, read);
                }
                return hex(digest.digest());
            } finally {
                input.close();
            }
        } catch (Exception e) {
            Log.w(TAG, "androidComputeFileHash failed: " + e.getMessage());
            return "";
        }
    }

    /** Streaming RomM-parity ZIP hash: sorted "entry:md5(content)" lines. */
    @UsedByGodot
    public String androidComputeZipHash(String path) {
        if (path == null || path.isEmpty()) return "";
        try {
            InputStream input = openInputFor(path);
            if (input == null) return "";
            java.util.ArrayList<String> lines = new java.util.ArrayList<>();
            try (ZipInputStream zip = new ZipInputStream(input)) {
                byte[] buffer = new byte[1024 * 1024];
                java.security.MessageDigest entryDigest = java.security.MessageDigest.getInstance("MD5");
                ZipEntry entry;
                while ((entry = zip.getNextEntry()) != null) {
                    if (entry.isDirectory() || entry.getName().endsWith("/")) continue;
                    entryDigest.reset();
                    int read;
                    while ((read = zip.read(buffer)) != -1) {
                        entryDigest.update(buffer, 0, read);
                    }
                    lines.add(entry.getName() + ":" + hex(entryDigest.digest()));
                    zip.closeEntry();
                }
            }
            java.util.Collections.sort(lines);
            java.security.MessageDigest outer = java.security.MessageDigest.getInstance("MD5");
            for (int i = 0; i < lines.size(); i++) {
                if (i > 0) outer.update((byte) '\n');
                outer.update(lines.get(i).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            return hex(outer.digest());
        } catch (Exception e) {
            Log.w(TAG, "androidComputeZipHash failed: " + e.getMessage());
            return "";
        }
    }

    private static String hex(byte[] bytes) {
        final char[] digits = "0123456789abcdef".toCharArray();
        char[] out = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int value = bytes[i] & 0xff;
            out[i * 2] = digits[value >>> 4];
            out[i * 2 + 1] = digits[value & 0x0f];
        }
        return new String(out);
    }

    /**
     * Lists files in a directory.
     * Returns a JSON array of filenames.
     * Uses DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public String androidListDir(String path) {
        long t0 = SafPerf.start();
        try { return androidListDirImpl(path); }
        finally { SafPerf.record("androidListDir", t0); }
    }

    private String androidListDirImpl(String path) {
        if (path == null || path.isEmpty()) {
            return "[]";
        }
        
        java.util.List<String> files = new java.util.ArrayList<>();
        
        // Try direct access first
        File dir = new File(path);
        if (dir.exists() && dir.isDirectory() && dir.canRead()) {
            String[] children = dir.list();
            if (children != null) {
                for (String child : children) {
                    files.add(child);
                }
            }
            return new org.json.JSONArray(files).toString();
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            java.util.List<String> cachedListing = SafCache.lookupListing(path);
            if (cachedListing != null) {
                return new org.json.JSONArray(cachedListing).toString();
            }
            try {
                Uri childrenUri = childrenUriFor(path);
                if (childrenUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        childrenUri,
                        new String[]{
                            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                        },
                        null, null, null
                    );

                    if (cursor != null) {
                        java.util.HashMap<String, Boolean> childTypes = new java.util.HashMap<>();
                        while (cursor.moveToNext()) {
                            String name = cursor.getString(0);
                            String mime = cursor.getString(1);
                            files.add(name);
                            childTypes.put(name,
                                android.provider.DocumentsContract.Document.MIME_TYPE_DIR.equals(mime));
                        }
                        cursor.close();
                        // Cache the listing AND prime per-child exists/isDir, so
                        // recursive walks don't re-query every entry one by one.
                        SafCache.putListing(path, new java.util.ArrayList<>(files), childTypes);
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "DocumentsContract listDir failed: " + e.getMessage());
            }
        }
        
        return new org.json.JSONArray(files).toString();
    }
    
    /**
     * Gets the last modified time of a file.
     * Returns 0 if file doesn't exist or can't be accessed.
     */
    @UsedByGodot
    public long androidGetModifiedTime(String path) {
        long t0 = SafPerf.start();
        try { return androidGetModifiedTimeImpl(path); }
        finally { SafPerf.record("androidGetModifiedTime", t0); }
    }

    private long androidGetModifiedTimeImpl(String path) {
        if (path == null || path.isEmpty()) {
            return 0;
        }
        
        // Try direct access first
        File file = new File(path);
        if (file.exists()) {
            return file.lastModified();
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        docUri,
                        new String[]{android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED},
                        null, null, null
                    );
                    if (cursor != null && cursor.moveToFirst()) {
                        long modified = cursor.getLong(0);
                        cursor.close();
                        return modified;
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "DocumentsContract getModifiedTime failed: " + e.getMessage());
            }
        }
        
        return 0;
    }
    
    /**
     * Creates a directory (and parents), using direct File first and
     * DocumentsContract segment-by-segment creation for restricted paths.
     */
    @UsedByGodot
    public boolean androidCreateDir(String path) {
        SafCache.invalidateTree(path);
        if (path == null || path.isEmpty()) {
            return false;
        }

        // Try direct access first
        File dir = new File(path);
        if (dir.exists() && dir.isDirectory()) {
            return true;
        }
        if (dir.mkdirs()) {
            return true;
        }

        // Restricted-path fallback: root daemon when no SAF grant covers the
        // path, else DocumentsContract segment-by-segment creation.
        if (requiresDocumentsContract(path)) {
            int tier = StorageTier.tierFor(activity, path);
            if (tier == StorageTier.TIER_ROOT) {
                StorageTier.logOp("mkdir", path, tier);
                return StorageTier.rootMkdirs(activity, path);
            }
            boolean created = createDirViaSaf(path);
            if (created) postSafFixup(path);
            return created;
        }
        return false;
    }

    private boolean createDirViaSaf(String path) {
        long t0 = SafPerf.start();
        try { return createDirViaSafImpl(path); }
        finally { SafPerf.record("createDirViaSaf", t0); }
    }

    private boolean createDirViaSafImpl(String path) {
        Uri treeUri = treeUriForPath(path);
        if (treeUri == null) return false;
        String[] vp = splitVolumePath(path);
        if (vp == null) return false;
        String targetDocId = vp[0] + ":" + vp[1];
        String treeDocId;
        try {
            treeDocId = DocumentsContract.getTreeDocumentId(treeUri);
        } catch (Exception e) {
            return false;
        }
        if (!targetDocId.equals(treeDocId) && !targetDocId.startsWith(treeDocId + "/")) return false;

        String remainder = targetDocId.equals(treeDocId) ? "" : targetDocId.substring(treeDocId.length() + 1);
        String currentDocId = treeDocId;
        for (String segment : remainder.split("/")) {
            if (segment.isEmpty()) continue;
            String nextDocId = currentDocId + "/" + segment;
            if (!safDocExists(treeUri, nextDocId)) {
                try {
                    Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDocId);
                    DocumentsContract.createDocument(
                            activity.getContentResolver(), parentUri,
                            DocumentsContract.Document.MIME_TYPE_DIR, segment);
                } catch (Exception e) {
                    Log.w(TAG, "createDirViaSaf failed for " + nextDocId + ": " + e.getMessage());
                }
                if (!safDocExists(treeUri, nextDocId)) {
                    Log.w(TAG, "createDirViaSaf: could not create " + nextDocId);
                    return false;
                }
            }
            currentDocId = nextDocId;
        }
        return true;
    }

    private boolean safDocExists(Uri treeUri, String docId) {
        long t0 = SafPerf.start();
        try { return safDocExistsImpl(treeUri, docId); }
        finally { SafPerf.record("safDocExists", t0); }
    }

    private boolean safDocExistsImpl(Uri treeUri, String docId) {
        try {
            Uri docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
            android.database.Cursor cursor = activity.getContentResolver().query(
                    docUri,
                    new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID},
                    null, null, null);
            if (cursor != null) {
                boolean exists = cursor.moveToFirst();
                cursor.close();
                return exists;
            }
        } catch (Exception ignored) {}
        return false;
    }

    /**
     * Recursively deletes a file or directory. DocumentsContract's deleteDocument
     * removes directory subtrees on ExternalStorageProvider.
     */
    @UsedByGodot
    public boolean androidDeleteRecursive(String path) {
        SafCache.invalidateTree(path);
        if (path == null || path.isEmpty()) {
            return false;
        }

        // Try direct access first
        File file = new File(path);
        if (file.exists()) {
            return deleteRecursively(file);
        }

        if (requiresDocumentsContract(path)) {
            int tier = StorageTier.tierFor(activity, path);
            if (tier == StorageTier.TIER_ROOT) {
                StorageTier.logOp("delete", path, tier);
                return StorageTier.rootDelete(activity, path);
            }
            Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    return DocumentsContract.deleteDocument(activity.getContentResolver(), uri);
                } catch (Exception e) {
                    Log.w(TAG, "androidDeleteRecursive failed: " + e.getMessage());
                }
            }
            return false;
        }
        // Nothing existed to delete
        return true;
    }

    private boolean deleteRecursively(File f) {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        return f.delete();
    }

    /**
     * Streams a file copy, using DocumentsContract streams for whichever side is
     * restricted. Works for large files (no base64 / in-memory buffering).
     */
    @UsedByGodot
    public boolean androidCopyFile(String sourcePath, String destPath) {
        SafCache.invalidateTree(destPath);
        if (sourcePath == null || sourcePath.isEmpty() || destPath == null || destPath.isEmpty()) {
            return false;
        }
        // A provider stream opened on a directory EOFs immediately, which would
        // "copy" a 0-byte file to the destination; reject directories outright.
        if (isDirectoryPath(sourcePath)) {
            Log.w(TAG, "androidCopyFile: source is a directory: " + sourcePath);
            return false;
        }
        // Root tier: the daemon reads the source and writes the destination
        // directly, then chowns the copy to the target package.
        if (requiresDocumentsContract(destPath)) {
            int tier = StorageTier.tierFor(activity, destPath);
            if (tier == StorageTier.TIER_ROOT) {
                StorageTier.logOp("copy", destPath, tier);
                return StorageTier.rootCopyFile(activity, sourcePath, destPath);
            }
        }
        try {
            InputStream in = openInputFor(sourcePath);
            if (in == null) {
                Log.w(TAG, "androidCopyFile: cannot open source: " + sourcePath);
                return false;
            }
            OutputStream out = openOutputFor(destPath);
            if (out == null) {
                in.close();
                Log.w(TAG, "androidCopyFile: cannot open dest: " + destPath);
                return false;
            }
            byte[] buffer = new byte[1024 * 1024];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            out.flush();
            out.close();
            in.close();
            postSafFixup(destPath);
            return true;
        } catch (Exception e) {
            Log.e(TAG, "androidCopyFile failed: " + e.getMessage());
            return false;
        }
    }

    /**
     * Renames/moves a file or directory. Uses direct rename, then
     * DocumentsContract.renameDocument for same-parent renames, then
     * copy+delete for cross-directory moves involving restricted paths.
     */
    @UsedByGodot
    public boolean androidRename(String sourcePath, String destPath) {
        SafCache.invalidateTree(sourcePath);
        SafCache.invalidateTree(destPath);
        if (sourcePath == null || sourcePath.isEmpty() || destPath == null || destPath.isEmpty()) {
            return false;
        }

        File src = new File(sourcePath);
        if (src.exists()) {
            File dst = new File(destPath);
            File dstParent = dst.getParentFile();
            if (dstParent != null && !dstParent.exists()) {
                dstParent.mkdirs();
            }
            if (src.renameTo(dst)) {
                return true;
            }
        }

        // Root tier: one daemon call moves files and whole directory trees,
        // then chowns the result to the target package.
        if (requiresDocumentsContract(sourcePath) || requiresDocumentsContract(destPath)) {
            int tier = StorageTier.tierFor(activity, destPath);
            if (tier == StorageTier.TIER_ROOT) {
                StorageTier.logOp("move", destPath, tier);
                return StorageTier.rootMove(activity, sourcePath, destPath);
            }
        }

        // Directories can't be streamed through androidCopyFile (a provider
        // stream on a directory EOFs immediately, leaving a 0-byte file at the
        // destination); move them recursively, entry by entry.
        if (isDirectoryPath(sourcePath)) {
            return moveDirectoryRecursive(sourcePath, destPath);
        }

        if (requiresDocumentsContract(sourcePath) || requiresDocumentsContract(destPath)) {
            // Same-parent rename via renameDocument
            String srcParent = sourcePath.substring(0, sourcePath.lastIndexOf('/'));
            String dstParentPath = destPath.substring(0, destPath.lastIndexOf('/'));
            if (srcParent.equals(dstParentPath)) {
                Uri uri = documentUriFor(sourcePath);
                String newName = destPath.substring(destPath.lastIndexOf('/') + 1);
                if (uri != null) {
                    try {
                        Uri renamed = DocumentsContract.renameDocument(
                                activity.getContentResolver(), uri, newName);
                        if (renamed != null) {
                            postSafFixup(destPath);
                            return true;
                        }
                    } catch (Exception e) {
                        Log.w(TAG, "androidRename renameDocument failed: " + e.getMessage());
                    }
                }
            }
            // Cross-directory move: copy + delete. A file cannot overwrite a
            // directory at the destination; clear a stale tree first.
            if (androidDirExists(destPath) && !androidDeleteRecursive(destPath)) {
                return false;
            }
            if (androidCopyFile(sourcePath, destPath)) {
                return androidDeleteRecursive(sourcePath);
            }
            return false;
        }
        return false;
    }

    /**
     * Validates and merges a direct-filesystem extraction tree in one call.
     * Validation is completed before the first mutation. The returned
     * "validated" flag tells GDScript whether it may safely use its fallback;
     * a failure after validation must not trigger a second merge attempt.
     */
    @UsedByGodot
    public String androidMergeDirect(String sourceRoot, String destRoot) {
        long t0 = SafPerf.start();
        java.util.ArrayList<String> overwritten = new java.util.ArrayList<>();
        try {
            File source = new File(sourceRoot == null ? "" : sourceRoot);
            File destination = new File(destRoot == null ? "" : destRoot);
            if (sourceRoot == null || destRoot == null
                    || requiresDocumentsContract(sourceRoot) || requiresDocumentsContract(destRoot)
                    || !directDirectory(source) || !directDirectory(destination)) {
                return directMergeResult(false, false, 0, overwritten, "not a direct directory merge");
            }
            try {
                if (android.system.Os.stat(sourceRoot).st_dev != android.system.Os.stat(destRoot).st_dev) {
                    return directMergeResult(false, false, 0, overwritten, "different filesystems");
                }
            } catch (Exception statError) {
                return directMergeResult(false, false, 0, overwritten, "cannot compare merge filesystems");
            }
            StringBuilder validationError = new StringBuilder();
            int[] sourceFiles = new int[]{0};
            if (!validateDirectMerge(source, destination, overwritten, validationError, sourceFiles)) {
                return directMergeResult(false, false, 0, overwritten, validationError.toString());
            }
            int destinationFiles = countDirectFiles(destination);
            if (destinationFiles < 0) {
                return directMergeResult(false, false, 0, overwritten, "could not size direct merge trees");
            }
            if (sourceFiles[0] > Math.max(64, destinationFiles * 2)) {
                if (!validateDirectSourceTree(destination, validationError, null)) {
                    return directMergeResult(false, false, 0, overwritten, validationError.toString());
                }
                return swapDirectMerge(source, destination, overwritten);
            }
            int[] completed = new int[]{0};
            StringBuilder moveError = new StringBuilder();
            boolean success = moveDirectMerge(source, destination, completed, moveError);
            return directMergeResult(success, true, completed[0], overwritten, moveError.toString());
        } catch (Exception error) {
            Log.w(TAG, "androidMergeDirect failed", error);
            return directMergeResult(false, true, 0, overwritten, error.toString());
        } finally {
            SafPerf.record("androidMergeDirect", t0);
        }
    }

    private boolean directDirectory(File file) {
        try {
            android.system.StructStat stat = android.system.Os.lstat(file.getAbsolutePath());
            return (stat.st_mode & android.system.OsConstants.S_IFMT) == android.system.OsConstants.S_IFDIR;
        } catch (Exception error) {
            return false;
        }
    }

    private boolean directExists(File file) {
        try {
            android.system.Os.lstat(file.getAbsolutePath());
            return true;
        } catch (Exception error) {
            return false;
        }
    }

    private boolean directSymlink(File file) {
        try {
            android.system.StructStat stat = android.system.Os.lstat(file.getAbsolutePath());
            return (stat.st_mode & android.system.OsConstants.S_IFMT) == android.system.OsConstants.S_IFLNK;
        } catch (Exception error) {
            return false;
        }
    }

    private boolean validateDirectMerge(File source, File destination,
            java.util.ArrayList<String> overwritten, StringBuilder error, int[] sourceFiles) {
        if (directSymlink(source) || directSymlink(destination) || !directDirectory(source)) {
            error.append("unsafe source or destination entry");
            return false;
        }
        File[] children = source.listFiles();
        if (children == null) {
            error.append("cannot list source: ").append(source.getPath());
            return false;
        }
        for (File child : children) {
            if (directSymlink(child)) {
                error.append("symbolic link in source: ").append(child.getPath());
                return false;
            }
            File target = new File(destination, child.getName());
            boolean childDirectory = directDirectory(child);
            boolean targetExists = directExists(target);
            boolean targetDirectory = targetExists && directDirectory(target);
            if (targetExists && directSymlink(target)) {
                error.append("symbolic link in destination: ").append(target.getPath());
                return false;
            }
            if (childDirectory && targetExists && !targetDirectory) {
                error.append("file/directory collision: ").append(target.getPath());
                return false;
            }
            if (!childDirectory && targetDirectory) {
                error.append("directory/file collision: ").append(target.getPath());
                return false;
            }
            if (childDirectory) {
                if (targetDirectory) {
                    if (!validateDirectMerge(child, target, overwritten, error, sourceFiles)) return false;
                } else if (!validateDirectSourceTree(child, error, sourceFiles)) {
                    return false;
                }
            } else {
                sourceFiles[0]++;
                if (targetExists) overwritten.add(target.getPath());
            }
        }
        return true;
    }

    private boolean validateDirectSourceTree(File source, StringBuilder error, int[] sourceFiles) {
        if (directSymlink(source) || !directDirectory(source)) {
            error.append("unsafe source entry: ").append(source.getPath());
            return false;
        }
        File[] children = source.listFiles();
        if (children == null) {
            error.append("cannot list source: ").append(source.getPath());
            return false;
        }
        for (File child : children) {
            if (directSymlink(child)) {
                error.append("symbolic link in source: ").append(child.getPath());
                return false;
            }
            if (directDirectory(child)) {
                if (!validateDirectSourceTree(child, error, sourceFiles)) return false;
            } else if (sourceFiles != null) {
                sourceFiles[0]++;
            }
        }
        return true;
    }

    private boolean moveDirectMerge(File source, File destination, int[] completed, StringBuilder error) {
        File[] children = source.listFiles();
        if (children == null) {
            error.append("cannot list source during merge: ").append(source.getPath());
            return false;
        }
        for (File child : children) {
            File target = new File(destination, child.getName());
            if (directDirectory(child) && directDirectory(target)) {
                if (!moveDirectMerge(child, target, completed, error)) return false;
                if (!child.delete() && directExists(child)) {
                    error.append("could not remove merged directory: ").append(child.getPath());
                    return false;
                }
                continue;
            }
            try {
                android.system.Os.rename(child.getAbsolutePath(), target.getAbsolutePath());
                completed[0]++;
            } catch (Exception exception) {
                error.append("native rename failed: ").append(child.getPath())
                        .append(" (").append(exception.toString()).append(")");
                return false;
            }
        }
        if (!source.delete() && directExists(source)) {
            error.append("could not remove merged source: ").append(source.getPath());
            return false;
        }
        return true;
    }

    private int countDirectFiles(File file) {
        if (directSymlink(file)) return -1;
        if (!directDirectory(file)) return directExists(file) ? 1 : 0;
        File[] children = file.listFiles();
        if (children == null) return -1;
        int count = 0;
        for (File child : children) {
            int childCount = countDirectFiles(child);
            if (childCount < 0) return -1;
            count += childCount;
        }
        return count;
    }

    /** Large-source merge: two root renames plus old-only entries, rather than
     *  one rename for every new file. The backup is not deleted until success. */
    private String swapDirectMerge(File source, File destination,
            java.util.ArrayList<String> overwritten) {
        File parent = destination.getParentFile();
        if (parent == null) {
            return directMergeResult(false, false, 0, overwritten, "destination has no parent");
        }
        File backup = new File(parent, ".kyodai-merge-backup-" + destination.getName() + "-" + System.nanoTime());
        if (directExists(backup)) {
            return directMergeResult(false, false, 0, overwritten, "merge backup already exists");
        }
        try {
            android.system.Os.rename(destination.getAbsolutePath(), backup.getAbsolutePath());
        } catch (Exception error) {
            return directMergeResult(false, false, 0, overwritten, "could not move old payload aside: " + error);
        }
        try {
            android.system.Os.rename(source.getAbsolutePath(), destination.getAbsolutePath());
        } catch (Exception error) {
            StringBuilder rollbackError = new StringBuilder();
            boolean restored = restoreDirectRoot(backup, destination, rollbackError);
            return directMergeResult(false, true, 0, overwritten,
                    "could not install new payload: " + error + "; rollback=" + restored + " " + rollbackError);
        }

        java.util.ArrayList<String> movedOld = new java.util.ArrayList<>();
        StringBuilder mergeError = new StringBuilder();
        if (!moveMissingDirect(backup, destination, "", movedOld, mergeError)) {
            StringBuilder rollbackError = new StringBuilder();
            boolean restored = rollbackDirectSwap(source, destination, backup, movedOld, rollbackError);
            if (!restored) {
                File recovery = preserveDirectRecoverySource(source);
                String recoveryPath = recovery != null ? recovery.getAbsolutePath()
                        : directDirectory(destination) ? destination.getAbsolutePath() : backup.getAbsolutePath();
                return directMergeResult(false, true, movedOld.size(), overwritten,
                        mergeError + "; rollback=false " + rollbackError
                                + "; backup=" + backup.getAbsolutePath()
                                + "; mixed recovery tree=" + recoveryPath,
                        true, recoveryPath);
            }
            return directMergeResult(false, true, movedOld.size(), overwritten,
                    mergeError + "; rollback=true " + rollbackError);
        }
        // Old conflicting versions stay in the backup until every old-only
        // entry has been restored. Cleanup is best-effort after commit.
        if (!deleteDirectTree(backup)) {
            Log.w(TAG, "Committed direct merge but could not remove backup " + backup);
        }
        return directMergeResult(true, true, movedOld.size() + 2, overwritten, "");
    }

    private boolean moveMissingDirect(File oldRoot, File newRoot, String relative,
            java.util.ArrayList<String> movedOld, StringBuilder error) {
        File[] children = oldRoot.listFiles();
        if (children == null) {
            error.append("cannot list old payload: ").append(oldRoot.getPath());
            return false;
        }
        for (File child : children) {
            String childRelative = relative.isEmpty() ? child.getName() : relative + "/" + child.getName();
            File target = new File(newRoot, child.getName());
            if (!directExists(target)) {
                try {
                    android.system.Os.rename(child.getAbsolutePath(), target.getAbsolutePath());
                    movedOld.add(childRelative);
                } catch (Exception exception) {
                    error.append("could not restore old-only entry: ").append(child.getPath())
                            .append(" (").append(exception.toString()).append(")");
                    return false;
                }
            } else if (directDirectory(child) && directDirectory(target)) {
                if (!moveMissingDirect(child, target, childRelative, movedOld, error)) return false;
            }
            // A same-path old file is the superseded version. Leave it in the
            // backup until the merge succeeds so rollback never loses it.
        }
        return true;
    }

    private boolean rollbackDirectSwap(File source, File destination, File backup,
            java.util.ArrayList<String> movedOld, StringBuilder error) {
        try {
            android.system.Os.rename(destination.getAbsolutePath(), source.getAbsolutePath());
        } catch (Exception exception) {
            error.append("could not move new payload back to staging: ").append(exception.toString());
            return false;
        }
        boolean success = true;
        for (int i = movedOld.size() - 1; i >= 0; i--) {
            String relative = movedOld.get(i);
            try {
                android.system.Os.rename(new File(source, relative).getAbsolutePath(),
                        new File(backup, relative).getAbsolutePath());
            } catch (Exception exception) {
                success = false;
                error.append("could not restore old-only entry ").append(relative)
                        .append(": ").append(exception.toString());
            }
        }
        return restoreDirectRoot(backup, destination, error) && success;
    }

    private File preserveDirectRecoverySource(File source) {
        if (!directDirectory(source)) return null;
        File recovery = new File(source.getParentFile(),
                source.getName() + ".recovery-" + System.nanoTime());
        try {
            android.system.Os.rename(source.getAbsolutePath(), recovery.getAbsolutePath());
            return recovery;
        } catch (Exception error) {
            Log.w(TAG, "Could not move failed merge recovery tree aside", error);
            return null;
        }
    }

    private boolean restoreDirectRoot(File backup, File destination, StringBuilder error) {
        try {
            android.system.Os.rename(backup.getAbsolutePath(), destination.getAbsolutePath());
            return true;
        } catch (Exception exception) {
            error.append("could not restore old payload: ").append(exception.toString());
            return false;
        }
    }

    private boolean deleteDirectTree(File file) {
        if (directSymlink(file)) return false;
        if (directDirectory(file)) {
            File[] children = file.listFiles();
            if (children == null) return false;
            for (File child : children) {
                if (!deleteDirectTree(child)) return false;
            }
        }
        return file.delete() || !directExists(file);
    }

    private String directMergeResult(boolean success, boolean validated, int completed,
            java.util.ArrayList<String> overwritten, String error) {
        return directMergeResult(success, validated, completed, overwritten, error, false, "");
    }

    private String directMergeResult(boolean success, boolean validated, int completed,
            java.util.ArrayList<String> overwritten, String error,
            boolean preserveSource, String recoveryPath) {
        org.json.JSONObject result = new org.json.JSONObject();
        try {
            result.put("success", success);
            result.put("validated", validated);
            result.put("completed", completed);
            result.put("error", error == null ? "" : error);
            result.put("overwritten", new org.json.JSONArray(overwritten));
            result.put("preserve_source", preserveSource);
            result.put("recovery_path", recoveryPath == null ? "" : recoveryPath);
        } catch (org.json.JSONException ignored) {
            return "{\"success\":false,\"validated\":true,\"preserve_source\":true,\"error\":\"result encoding failed\"}";
        }
        return result.toString();
    }

    /** True when the path exists and is a directory, via direct File access or
     *  the DocumentsContract MIME type for restricted paths. */
    private boolean isDirectoryPath(String path) {
        File file = new File(path);
        if (file.exists()) {
            return file.isDirectory();
        }
        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                            uri,
                            new String[]{DocumentsContract.Document.COLUMN_MIME_TYPE},
                            null, null, null);
                    if (cursor != null) {
                        boolean isDir = false;
                        if (cursor.moveToFirst()) {
                            String mimeType = cursor.getString(0);
                            isDir = DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
                        }
                        cursor.close();
                        return isDir;
                    }
                } catch (Exception e) {
                    Log.w(TAG, "isDirectoryPath failed: " + e.getMessage());
                }
            }
        }
        return false;
    }

    /** Recursive directory move for providers without cross-parent directory
     *  rename: create the destination tree, move each entry through
     *  androidRename (files copy+delete, subdirectories recurse), then delete
     *  the emptied source. On any child failure the source is left in place. */
    private boolean moveDirectoryRecursive(String srcDir, String dstDir) {
        // A leftover file at the destination (e.g. from a previously failed
        // directory copy) blocks directory creation; remove it first.
        if (androidFileExists(dstDir) && !androidDirExists(dstDir)) {
            if (!androidDeleteRecursive(dstDir)) {
                return false;
            }
        }
        if (!androidCreateDir(dstDir)) {
            return false;
        }
        java.util.List<String> children = new java.util.ArrayList<>();
        try {
            org.json.JSONArray arr = new org.json.JSONArray(androidListDir(srcDir));
            for (int i = 0; i < arr.length(); i++) {
                children.add(arr.getString(i));
            }
        } catch (Exception e) {
            Log.w(TAG, "moveDirectoryRecursive: cannot list " + srcDir + ": " + e.getMessage());
            return false;
        }
        for (String child : children) {
            if (!androidRename(srcDir + "/" + child, dstDir + "/" + child)) {
                Log.w(TAG, "moveDirectoryRecursive: failed to move " + child + " from " + srcDir);
                return false;
            }
        }
        if (!androidDeleteRecursive(srcDir)) {
            return false;
        }
        // The whole moved tree is provider-owned after SAF moves; repair once.
        postSafFixup(dstDir);
        return true;
    }

    /**
     * Gets a file's size in bytes. Returns -1 if unknown/inaccessible.
     */
    @UsedByGodot
    public long androidGetFileSize(String path) {
        long t0 = SafPerf.start();
        try { return androidGetFileSizeImpl(path); }
        finally { SafPerf.record("androidGetFileSize", t0); }
    }

    private long androidGetFileSizeImpl(String path) {
        if (path == null || path.isEmpty()) {
            return -1;
        }
        File file = new File(path);
        if (file.exists()) {
            return file.length();
        }
        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                            uri,
                            new String[]{DocumentsContract.Document.COLUMN_SIZE},
                            null, null, null);
                    if (cursor != null) {
                        long size = cursor.moveToFirst() ? cursor.getLong(0) : -1;
                        cursor.close();
                        return size;
                    }
                } catch (Exception e) {
                    Log.w(TAG, "androidGetFileSize failed: " + e.getMessage());
                }
            }
        }
        return -1;
    }

    /**
     * Deletes a file using DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public boolean androidDeleteFile(String path) {
        SafCache.invalidateTree(path);
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        // Try direct access first
        File file = new File(path);
        if (file.exists() && file.isFile()) {
            return file.delete();
        }

        // Fall back for restricted paths: root daemon, then DocumentsContract
        if (requiresDocumentsContract(path)) {
            int tier = StorageTier.tierFor(activity, path);
            if (tier == StorageTier.TIER_ROOT) {
                StorageTier.logOp("deleteFile", path, tier);
                return StorageTier.rootDelete(activity, path);
            }
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    return android.provider.DocumentsContract.deleteDocument(
                        activity.getContentResolver(), docUri
                    );
                }
            } catch (Exception e) {
                Log.w(TAG, "DocumentsContract delete failed: " + e.getMessage());
            }
        }
        
        return false;
    }
    
    /**
     * Makes a file executable (chmod +x).
     * Required for running native binaries extracted from APK assets.
     */
    @UsedByGodot
    public boolean chmodExecutable(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        try {
            File file = new File(path);
            if (!file.exists()) {
                Log.w(TAG, "chmodExecutable: file does not exist: " + path);
                return false;
            }
            
            boolean success = file.setExecutable(true, false);
            if (success) {
                Log.d(TAG, "chmodExecutable: made executable: " + path);
            } else {
                Log.w(TAG, "chmodExecutable: failed to make executable: " + path);
            }
            return success;
        } catch (Exception e) {
            Log.e(TAG, "chmodExecutable error: " + e.getMessage());
            return false;
        }
    }
    
    /**
     * Returns the app's native library directory (nativeLibraryDir).
     * Binaries shipped as jniLibs are extracted here by the package manager
     * and — unlike files in the private data dir — may be executed under
     * SELinux policy for targetSdk 29+.
     */
    @UsedByGodot
    public String getNativeLibraryDir() {
        if (activity == null) {
            Log.w(TAG, "getNativeLibraryDir: activity is null");
            return "";
        }
        return activity.getApplicationInfo().nativeLibraryDir;
    }

    /**
     * Launches an Android intent with the specified parameters.
     * Uses FileProvider for content:// URIs when needed.
     */
    @UsedByGodot
    public boolean launchAndroidIntent(String action, String packageName, String className,
                                        String romPath, String corePath, String romDelivery,
                                        String extrasJson, String mimeType, boolean clearTask,
                                        boolean grantUriPermission, boolean useDocumentUri,
                                        boolean useFileUri) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchAndroidIntent() called");
        Log.d(TAG, "Action: " + action);
        Log.d(TAG, "Package: " + packageName);
        Log.d(TAG, "Class: " + className);
        Log.d(TAG, "ROM path: " + romPath);
        Log.d(TAG, "Core path: " + corePath);
        Log.d(TAG, "ROM delivery: " + romDelivery);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            Intent intent = new Intent();
            
            // Set action
            if (action != null && !action.isEmpty()) {
                intent.setAction(action);
            }
            
            // Set component (package/class)
            if (packageName != null && !packageName.isEmpty()) {
                if (className != null && !className.isEmpty()) {
                    intent.setComponent(new ComponentName(packageName, className));
                } else {
                    intent.setPackage(packageName);
                }
            }
            
            // Handle ROM data based on delivery method
            if (romPath != null && !romPath.isEmpty()) {
                if ("intent_data".equals(romDelivery)) {
                    // ROM as intent data
                    Uri romUri;
                    File romFile = new File(romPath);
                    
                    if (useFileUri) {
                        // Use file:// URI (only for specific cases)
                        romUri = Uri.fromFile(romFile);
                    } else {
                        // Use FileProvider content:// URI
                        romUri = FileProvider.getUriForFile(activity, 
                            activity.getPackageName() + ".kyodai.fileprovider", romFile);
                    }
                    
                    intent.setDataAndType(romUri, mimeType);
                    
                    if (grantUriPermission) {
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    }
                } else if ("extra".equals(romDelivery)) {
                    // ROM as extra parameter
                    Uri romUri;
                    File romFile = new File(romPath);
                    
                    if (useFileUri) {
                        romUri = Uri.fromFile(romFile);
                    } else {
                        romUri = FileProvider.getUriForFile(activity,
                            activity.getPackageName() + ".kyodai.fileprovider", romFile);
                    }
                    
                    intent.putExtra("ROM", romUri.toString());
                    
                    if (grantUriPermission) {
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    }
                }
            }
            
            // Add core path as extra if provided
            if (corePath != null && !corePath.isEmpty()) {
                intent.putExtra("LIBRETRO", corePath);
            }
            
            // Parse and add extras from JSON
            if (extrasJson != null && !extrasJson.isEmpty() && !"[]".equals(extrasJson)) {
                try {
                    org.json.JSONArray extrasArray = new org.json.JSONArray(extrasJson);
                    for (int i = 0; i < extrasArray.length(); i++) {
                        org.json.JSONObject extra = extrasArray.getJSONObject(i);
                        String key = extra.getString("key");
                        String value = extra.getString("value");
                        String type = extra.getString("type");
                        
                        // Replace {rom} placeholder with actual ROM path
                        if (value != null && value.contains("{rom}")) {
                            value = value.replace("{rom}", romPath != null ? romPath : "");
                            Log.d(TAG, "Replaced {rom} placeholder in extra " + key + ": " + value);
                        }
                        
                        if ("file_path".equals(type)) {
                            // Pass raw file path - with MANAGE_EXTERNAL_STORAGE, target apps can read directly
                            intent.putExtra(key, value);
                            Log.d(TAG, "Added file path extra: " + key + "=" + value);
                        } else if ("int".equals(type)) {
                            intent.putExtra(key, Integer.parseInt(value));
                        } else if ("bool".equals(type) || "boolean".equals(type)) {
                            intent.putExtra(key, Boolean.parseBoolean(value));
                        } else if ("string_array".equals(type)) {
                            // Parse JSON array string into String[]
                            try {
                                org.json.JSONArray jsonArray = new org.json.JSONArray(value);
                                String[] stringArray = new String[jsonArray.length()];
                                for (int j = 0; j < jsonArray.length(); j++) {
                                    stringArray[j] = jsonArray.getString(j);
                                }
                                intent.putExtra(key, stringArray);
                                Log.d(TAG, "Added string array extra: " + key + "=" + value);
                            } catch (Exception e) {
                                Log.w(TAG, "Failed to parse string array extra " + key + ": " + e.getMessage());
                                intent.putExtra(key, value);
                            }
                        } else {
                            // Default to string
                            intent.putExtra(key, value);
                        }
                    }
                } catch (Exception e) {
                    Log.w(TAG, "Failed to parse extras JSON: " + e.getMessage());
                }
            }
            
            // Add flags
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            
            if (clearTask) {
                intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK);
            }
            
            // Launch the intent
            startActivity(intent);
            
            Log.d(TAG, "SUCCESS: Intent launched");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR launching intent: " + e.getMessage());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return false;
        }
    }
    
    @UsedByGodot
    public boolean launchAppByPackageName(String packageName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchAppByPackageName() called");
        Log.d(TAG, "Package: " + packageName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            PackageManager pm = activity.getPackageManager();
            Intent intent = pm.getLaunchIntentForPackage(packageName);
            if (intent == null) {
                Log.e(TAG, "No launch intent for package: " + packageName);
                return false;
            }
            
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
            
            Log.d(TAG, "SUCCESS: App launched");
            Log.d(TAG, "==========================================");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "ERROR launching app: " + e.getMessage());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return false;
        }
    }
    
    /**
     * Stops the foreground service when downloads are complete.
     */
    @UsedByGodot
    public void stopDownloadForegroundService() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "stopDownloadForegroundService() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, DownloadForegroundService.class);
            intent.setAction("STOP_DOWNLOAD");
            activity.startService(intent);
            
            Log.d(TAG, "Foreground service stop requested");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR stopping foreground service: " + e.getMessage());
        }
    }
    
    // ==================== FOREGROUND SERVICE FOR METADATA SYNC ====================
    
    /**
     * Starts the foreground service to prevent Android from killing the app during metadata sync.
     * Shows a persistent notification with sync progress.
     * 
     * @param platformName Name of the platform currently being synced
     * @param current Current game count
     * @param total Total game count across all platforms
     */
    @UsedByGodot
    public void startSyncForegroundService(String platformName, int current, int total) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "startSyncForegroundService() called");
        Log.d(TAG, "Platform: " + platformName + ", Progress: " + current + "/" + total);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, SyncForegroundService.class);
            intent.setAction("START_SYNC");
            intent.putExtra("platform_name", platformName);
            intent.putExtra("current", current);
            intent.putExtra("total", total);
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent);
            } else {
                activity.startService(intent);
            }
            
            Log.d(TAG, "Sync foreground service started successfully");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR starting sync foreground service: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
        }
    }
    
    /**
     * Updates the sync foreground service notification with current progress.
     * 
     * @param platformName Name of the platform currently being synced
     * @param current Current game count
     * @param total Total game count across all platforms
     */
    @UsedByGodot
    public void updateSyncForegroundService(String platformName, int current, int total) {
        if (activity == null) {
            return;
        }
        
        try {
            Intent intent = new Intent(activity, SyncForegroundService.class);
            intent.setAction("UPDATE_PROGRESS");
            intent.putExtra("platform_name", platformName);
            intent.putExtra("current", current);
            intent.putExtra("total", total);
            
            activity.startService(intent);
        } catch (Exception e) {
            Log.e(TAG, "ERROR updating sync foreground service: " + e.getMessage());
        }
    }
    
    /**
     * Stops the sync foreground service when sync is complete or cancelled.
     */
    @UsedByGodot
    public void stopSyncForegroundService() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "stopSyncForegroundService() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, SyncForegroundService.class);
            intent.setAction("STOP_SYNC");
            activity.startService(intent);
            
            Log.d(TAG, "Sync foreground service stop requested");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR stopping sync foreground service: " + e.getMessage());
        }
    }
    
    // ==================== USAGE STATS (ANDROID PRESENCE WATCH) ====================

    /**
     * Whether the user granted Usage Access (Settings > Usage access).
     * The presence watch degrades to resume-only session tracking without it.
     */
    @UsedByGodot
    public boolean hasUsageStatsPermission() {
        if (activity == null) {
            return false;
        }
        try {
            android.app.AppOpsManager appOps =
                (android.app.AppOpsManager) activity.getSystemService(Context.APP_OPS_SERVICE);
            int mode = appOps.unsafeCheckOpNoThrow(
                android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                activity.getPackageName()
            );
            return mode == android.app.AppOpsManager.MODE_ALLOWED;
        } catch (Exception e) {
            Log.e(TAG, "hasUsageStatsPermission check failed: " + e.getMessage());
            return false;
        }
    }

    /**
     * Opens the system Usage Access settings page for the user to grant access.
     */
    @UsedByGodot
    public void openUsageAccessSettings() {
        if (activity == null) {
            return;
        }
        try {
            // NO_HISTORY, no NEW_TASK: keep the page inside our task (no
            // recents card) and make it finish when it leaves the foreground
            // (no shadowing our task). See requestInstallUnknownAppsPermission.
            Intent intent = new Intent(android.provider.Settings.ACTION_USAGE_ACCESS_SETTINGS);
            intent.addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY);
            startActivity(intent);
        } catch (Exception e) {
            Log.e(TAG, "openUsageAccessSettings failed: " + e.getMessage());
        }
    }

    /**
     * Returns the package that most recently moved to the foreground within
     * the given lookback window, or "" when unknown/ungranted. Callers should
     * treat "" as "no information", never as a presence miss.
     */
    @UsedByGodot
    public String getForegroundPackageName(int lookbackMs) {
        if (activity == null) {
            return "";
        }
        try {
            android.app.usage.UsageStatsManager usm =
                (android.app.usage.UsageStatsManager) activity.getSystemService(Context.USAGE_STATS_SERVICE);
            long now = System.currentTimeMillis();
            android.app.usage.UsageEvents events = usm.queryEvents(now - lookbackMs, now);
            android.app.usage.UsageEvents.Event ev = new android.app.usage.UsageEvents.Event();
            String foreground = "";
            while (events.hasNextEvent()) {
                events.getNextEvent(ev);
                int type = ev.getEventType();
                if (type == android.app.usage.UsageEvents.Event.MOVE_TO_FOREGROUND
                        || type == android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED) {
                    foreground = ev.getPackageName();
                }
            }
            return foreground;
        } catch (Exception e) {
            Log.e(TAG, "getForegroundPackageName failed: " + e.getMessage());
            return "";
        }
    }

    /**
     * True when the keyguard is locked. A locked screen during gameplay must
     * not count as an emulator-presence miss.
     */
    @UsedByGodot
    public boolean isKeyguardLocked() {
        if (activity == null) {
            return false;
        }
        try {
            android.app.KeyguardManager km =
                (android.app.KeyguardManager) activity.getSystemService(Context.KEYGUARD_SERVICE);
            return km != null && km.isKeyguardLocked();
        } catch (Exception e) {
            return false;
        }
    }

    // ==================== ANDROID TASK BACKEND ====================

    public void onHomeIntent() {
        if (destroyed) return;
        // Start capture before Godot resumes its activity. The privileged
        // helper raises the snapshot curtain while Android is still performing
        // the task transition; GDScript consumes this same result on retain.
        if (earlyHomeEnabled && taskBackend != null && retainedTaskId > 0) {
            earlyHomeEnabled = false;
            homeSnapshotTaskId = retainedTaskId;
            if (!observerNonce.isEmpty()) {
                homeSnapshotRequestId = "observer:" + observerNonce;
            } else {
                homeSnapshotRequestId = taskBackend.captureTaskSnapshot(
                        retainedTaskId, retainedPackage, retainedTopActivity);
            }
            homeSnapshotJson = null;
            if (homeSnapshotRequestId.startsWith("observer:")) watchObserverResult();
        }
        emitSignal("android_home_requested");
    }

    @UsedByGodot
    public void androidTaskSetRetainedIdentity(int taskId, String packageName, String topActivity, boolean gameForeground) {
        if (retainedTaskId != taskId) {
            // A bootstrap activity may hand the game to a new Android task.
            // Retire the old observer before binding the replacement identity.
            androidTaskReleaseObserver();
            clearHomeSnapshot();
        }
        retainedTaskId = taskId;
        retainedPackage = packageName != null ? packageName : "";
        retainedTopActivity = topActivity != null ? topActivity : "";
        earlyHomeEnabled = gameForeground;
        if (gameForeground && taskBackend != null && observerRequestedTaskId != taskId) {
            observerRequestedTaskId = taskId;
            observerStartRequestId = taskBackend.startObserver(taskId, retainedPackage, retainedTopActivity,
                    activity.getPackageName(), android.os.Process.myPid());
        }
    }

    @UsedByGodot
    public void androidTaskClearRetainedIdentity() {
        androidTaskReleaseObserver();
        retainedTaskId = -1;
        retainedPackage = "";
        retainedTopActivity = "";
        earlyHomeEnabled = false;
        clearHomeSnapshot();
    }

    @UsedByGodot
    public void androidTaskReleaseObserver() {
        stopObserverEvents();
        observerRequestedTaskId = -1;
        observerStartRequestId = "";
        String nonce = observerNonce;
        observerNonce = "";
        if (!nonce.isEmpty()) writeObserverRelease(nonce);
    }

    @UsedByGodot
    public String androidTaskHomeSnapshotStatus(int taskId) {
        if (taskId != homeSnapshotTaskId || homeSnapshotRequestId.isEmpty()) return "none";
        if (homeSnapshotRequestId.startsWith("observer:")) {
            File result = observerResultFile();
            if (result != null && new File(result.getParentFile(), "observer-exited").isFile()) return "error";
            if (result == null || !result.isFile()) return "pending";
            try {
                org.json.JSONObject parsed = new org.json.JSONObject(readTaskResult(result));
                return parsed.has("snapshot") || !parsed.optBoolean("ok", false) ? "ready" : "pending";
            } catch (Exception ignored) {
                return "pending";
            }
        }
        return homeSnapshotJson != null ? "ready" : "pending";
    }

    @UsedByGodot
    public String androidTaskConsumeHomeSnapshot(int taskId) {
        if (!"ready".equals(androidTaskHomeSnapshotStatus(taskId))) return "";
        String result;
        if (homeSnapshotRequestId.startsWith("observer:")) {
            File file = observerResultFile();
            result = file != null ? readTaskResult(file) : "";
        } else {
            result = homeSnapshotJson;
        }
        clearHomeSnapshot();
        return result != null ? result : "";
    }

    private File observerResultFile() {
        if (activity == null || !homeSnapshotRequestId.startsWith("observer:")) return null;
        String nonce = homeSnapshotRequestId.substring("observer:".length());
        return new File(activity.getFilesDir(), "task-requests/" + nonce + "/result.json");
    }

    private String readTaskResult(File file) {
        try (FileInputStream input = new FileInputStream(file)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            int read;
            while ((read = input.read(buffer)) >= 0) output.write(buffer, 0, read);
            return output.toString("UTF-8");
        } catch (Exception ignored) {
            return "";
        }
    }

    private void watchObserverResult() {
        if (homeResultObserver != null) homeResultObserver.stopWatching();
        File result = observerResultFile();
        if (result == null || result.getParentFile() == null) return;
        final String requestId = homeSnapshotRequestId;
        homeResultObserver = new FileObserver(result.getParentFile().getAbsolutePath(),
                FileObserver.CREATE | FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO) {
            @Override
            public void onEvent(int event, String path) {
                if (!"result.json".equals(path)) return;
                publishObserverResultIfReady(result, requestId);
            }
        };
        homeResultObserver.startWatching();
        // The helper may have published before the watcher was installed.
        publishObserverResultIfReady(result, requestId);
    }

    private void publishObserverResultIfReady(File result, String requestId) {
        if (!requestId.equals(homeSnapshotRequestId)) return;
        try {
            org.json.JSONObject parsed = new org.json.JSONObject(readTaskResult(result));
            if (!parsed.has("snapshot") && parsed.optBoolean("ok", true)) return;
            String expectedNonce = requestId.substring("observer:".length());
            if (!expectedNonce.equals(parsed.optString("nonce", ""))) return;
            onTaskBackendResult(requestId, "captureTaskSnapshot", parsed);
            if (homeResultObserver != null) homeResultObserver.stopWatching();
        } catch (Exception ignored) {
        }
    }

    private void watchObserverEvents(String nonce) {
        stopObserverEvents();
        if (activity == null || nonce.isEmpty()) return;
        File directory = new File(activity.getFilesDir(), "task-requests/" + nonce);
        File eventFile = new File(directory, "task-event.json");
        taskEventObserverNonce = nonce;
        taskEventObserver = new FileObserver(directory.getAbsolutePath(),
                FileObserver.CREATE | FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO) {
            @Override
            public void onEvent(int event, String path) {
                if ("task-event.json".equals(path)) publishObserverEventIfReady(eventFile, nonce);
            }
        };
        taskEventObserver.startWatching();
        publishObserverEventIfReady(eventFile, nonce);
    }

    private void publishObserverEventIfReady(File eventFile, String nonce) {
        if (!nonce.equals(observerNonce) || !nonce.equals(taskEventObserverNonce)) return;
        try {
            org.json.JSONObject event = new org.json.JSONObject(readTaskResult(eventFile));
            if (!nonce.equals(event.optString("nonce", ""))) return;
            String name = event.optString("event", "");
            int taskId = event.optInt("taskId", -1);
            String packageName = event.optString("packageName", "");
            if (name.isEmpty() || taskId < 0) return;
            if (eventFile.delete()) {
                activity.runOnUiThread(() -> emitSignal("android_task_event", name, taskId, packageName));
            }
        } catch (Exception ignored) {
        }
    }

    private void stopObserverEvents() {
        if (taskEventObserver != null) {
            taskEventObserver.stopWatching();
            taskEventObserver = null;
        }
        taskEventObserverNonce = "";
    }

    private void writeObserverRelease(String nonce) {
        if (activity == null || nonce.isEmpty()) return;
        try (java.io.FileOutputStream out = new java.io.FileOutputStream(
                new File(activity.getFilesDir(), "task-requests/" + nonce + "/release-curtain"))) {
            out.write("release\n".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            out.getFD().sync();
        } catch (Exception error) {
            Log.w(TAG, "Could not release task observer", error);
        }
    }

    private void clearHomeSnapshot() {
        if (homeResultObserver != null) {
            homeResultObserver.stopWatching();
            homeResultObserver = null;
        }
        homeSnapshotTaskId = -1;
        homeSnapshotRequestId = "";
        homeSnapshotJson = null;
    }

    private void onTaskBackendResult(String requestId, String operation, org.json.JSONObject result) {
        if (destroyed) return;
        if ("startObserver".equals(operation)) {
            String nonce = result.optString("nonce", "");
            if (!requestId.equals(observerStartRequestId)) {
                // The task was rebound or released while this start was in
                // flight. Close only the stale helper; never let it replace the
                // current task's observer.
                if (!nonce.isEmpty()) writeObserverRelease(nonce);
            } else {
                observerStartRequestId = "";
                if (result.optBoolean("ok", false) && result.optBoolean("observer", false) && !nonce.isEmpty()) {
                    observerNonce = nonce;
                    watchObserverEvents(nonce);
                } else {
                    observerRequestedTaskId = -1;
                }
            }
        }
        if (requestId.equals(homeSnapshotRequestId)) {
            homeSnapshotJson = result.toString();
        }
        if (activity == null || taskBackend == null) return;
        activity.runOnUiThread(() -> emitSignal("android_task_result", requestId, operation, result.toString()));
    }

    @UsedByGodot
    public String androidTaskProbeCapabilities() {
        return taskBackend != null ? taskBackend.probeCapabilities() : unsupportedTaskCall();
    }

    @UsedByGodot
    public String androidTaskListTasks() {
        return taskBackend != null ? taskBackend.listTasks() : unsupportedTaskCall();
    }

    @UsedByGodot
    public String androidTaskCaptureSnapshot(int taskId, String packageName, String topActivity) {
        return taskBackend != null ? taskBackend.captureTaskSnapshot(taskId, packageName, topActivity) : unsupportedTaskCall();
    }

    @UsedByGodot
    public String androidTaskFocus(int taskId, String packageName, String topActivity) {
        return taskBackend != null ? taskBackend.focusTask(taskId, packageName, topActivity) : unsupportedTaskCall();
    }

    @UsedByGodot
    public String androidTaskForceStop(int taskId, String packageName, int userId) {
        return taskBackend != null ? taskBackend.forceStopPackage(taskId, packageName, userId) : unsupportedTaskCall();
    }

    @UsedByGodot
    public String androidTaskRemove(int taskId, String packageName) {
        return taskBackend != null ? taskBackend.removeTask(taskId, packageName) : unsupportedTaskCall();
    }

    @UsedByGodot
    public String androidTaskMoveDisplay(int taskId, String packageName, int displayId) {
        return taskBackend != null ? taskBackend.moveTaskToDisplay(taskId, packageName, displayId) : unsupportedTaskCall();
    }

    private String unsupportedTaskCall() {
        try {
            onTaskBackendResult("unsupported", "unsupported", new org.json.JSONObject()
                    .put("ok", false)
                    .put("code", "unsupported")
                    .put("error", "Android task backend unavailable"));
        } catch (org.json.JSONException ignored) {}
        return "unsupported";
    }

    // ==================== ROMM ACTIVITY HEARTBEAT ====================

    @UsedByGodot
    public synchronized void startActivityHeartbeat(String baseUrl, String authorization, int rommId, String deviceId) {
        stopActivityHeartbeat();
        if (destroyed || baseUrl == null || baseUrl.isEmpty() || authorization == null
                || authorization.isEmpty() || rommId <= 0 || deviceId == null || deviceId.isEmpty()) {
            return;
        }
        final String endpoint = baseUrl + "/api/activity/heartbeat";
        activityHeartbeatExecutor = java.util.concurrent.Executors.newSingleThreadScheduledExecutor(runnable -> {
            Thread thread = new Thread(runnable, "KyodaiActivityHeartbeat");
            thread.setDaemon(true);
            return thread;
        });
        activityHeartbeatExecutor.scheduleWithFixedDelay(
                () -> sendActivityHeartbeat(endpoint, authorization, rommId, deviceId),
                0, 30, java.util.concurrent.TimeUnit.SECONDS);
    }

    @UsedByGodot
    public synchronized void stopActivityHeartbeat() {
        if (activityHeartbeatExecutor != null) {
            activityHeartbeatExecutor.shutdownNow();
            activityHeartbeatExecutor = null;
        }
    }

    private void sendActivityHeartbeat(String endpoint, String authorization, int rommId, String deviceId) {
        if (destroyed) return;
        java.net.HttpURLConnection connection = null;
        try {
            connection = (java.net.HttpURLConnection) new java.net.URL(endpoint).openConnection();
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(10000);
            connection.setReadTimeout(10000);
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setRequestProperty("Authorization", authorization);
            connection.setDoOutput(true);
            org.json.JSONObject body = new org.json.JSONObject();
            body.put("rom_id", rommId);
            body.put("device_id", deviceId);
            byte[] bytes = body.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(bytes.length);
            try (java.io.OutputStream output = connection.getOutputStream()) {
                output.write(bytes);
            }
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                Log.w(TAG, "RomM activity heartbeat returned HTTP " + status);
            }
        } catch (Exception error) {
            Log.w(TAG, "RomM activity heartbeat failed: " + error.getMessage());
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    // ==================== FOREGROUND SERVICE FOR GAME SESSIONS ====================

    /**
     * Starts the foreground service to prevent Android's LMK from killing the
     * launcher while a game runs in another (memory-hungry) app.
     * The notification shows a live session clock starting from startTimeMs.
     *
     * @param gameName Display name of the running game
     * @param startTimeMs Session start time in epoch milliseconds
     */
    @UsedByGodot
    public void startGameSessionForegroundService(String gameName, long startTimeMs, String emulatorPackage, long rommId) {
        startGameSessionWithIdentity(gameName, startTimeMs, emulatorPackage, rommId, "", false);
    }

    @UsedByGodot
    public void startGameSessionWithIdentity(String gameName, long startTimeMs, String emulatorPackage, long rommId, String sessionId, boolean retainedMode) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "startGameSessionWithIdentity() called");
        Log.d(TAG, "Game: " + gameName + ", emulator: " + emulatorPackage);

        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }

        try {
            lastSessionId = sessionId != null ? sessionId : "";
            Intent intent = new Intent(activity, GameSessionForegroundService.class);
            intent.setAction("START_SESSION");
            intent.putExtra("game_name", gameName);
            intent.putExtra("start_time_ms", startTimeMs);
            intent.putExtra("emulator_package", emulatorPackage != null ? emulatorPackage : "");
            intent.putExtra("romm_id", rommId);
            intent.putExtra("session_id", sessionId != null ? sessionId : "");
            intent.putExtra("retained_mode", retainedMode);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent);
            } else {
                activity.startService(intent);
            }

            // Anchor in the main process: startForeground() only promotes
            // the hosting process, so without this the Godot process stays
            // in the cached tier (adj 700) despite the session service.
            Intent anchor = new Intent(activity, SessionAnchorForegroundService.class);
            anchor.setAction("START_ANCHOR");
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(anchor);
            } else {
                activity.startService(anchor);
            }

            Log.d(TAG, "Game session foreground service started successfully");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR starting game session foreground service: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
        }
    }

    /**
     * Stops the game session foreground service when the launcher resumes.
     */
    @UsedByGodot
    public void stopGameSessionForegroundService() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "stopGameSessionForegroundService() called");

        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }

        try {
            Intent intent = new Intent(activity, GameSessionForegroundService.class);
            intent.setAction("STOP_SESSION");
            intent.putExtra("session_id", lastSessionId);
            activity.startService(intent);

            Intent anchor = new Intent(activity, SessionAnchorForegroundService.class);
            anchor.setAction("STOP_ANCHOR");
            activity.startService(anchor);

            Log.d(TAG, "Game session foreground service stop requested");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR stopping game session foreground service: " + e.getMessage());
        }
    }

    /**
     * Self-update variant. The settings-root transport must be restored before
     * PackageManager kills Kyodai, otherwise its injected command is replayed
     * on the next launch. Detach a delayed install and relaunch on success.
     */
    @UsedByGodot
    public boolean installApkSelfUpdate(String apkPath) {
        if (activity == null || apkPath == null || apkPath.isEmpty()) return false;
        if (!RootShell.isAvailable(activity)) return installApk(apkPath);
        try {
            File apkFile = new File(apkPath).getCanonicalFile();
            if (!apkFile.isFile() || !apkFile.getName().toLowerCase().endsWith(".apk")) {
                Log.e(TAG, "installApkSelfUpdate: Not an APK file: " + apkFile);
                return false;
            }
            File logFile = new File(activity.getCacheDir(), "self-update-root.log");
            File rcFile = new File(activity.getCacheDir(), "self-update-root.rc");
            logFile.delete();
            rcFile.delete();
            String quotedLog = RootShell.quote(logFile.getAbsolutePath());
            String quotedRc = RootShell.quote(rcFile.getAbsolutePath());
            String launch = activity.getPackageName() + "/com.godot.game.GodotAppLauncher";
            String script = "(sleep 2; pm install -r " + RootShell.quote(apkFile.getAbsolutePath())
                    + "; rc=$?; if [ $rc -eq 0 ]; then am start -n " + RootShell.quote(launch) + "; fi; "
                    + "echo $rc > " + quotedRc + "; chmod 644 " + quotedLog + " " + quotedRc + ") > "
                    + quotedLog + " 2>&1 </dev/null & echo Scheduled";
            RootShell.Result result = RootShell.run(activity, script);
            boolean scheduled = result != null && result.succeeded()
                    && result.output != null && result.output.contains("Scheduled");
            if (!scheduled) {
                Log.e(TAG, "installApkSelfUpdate: Could not schedule root install: exit="
                        + (result == null ? "null" : result.exitCode)
                        + " output=" + (result == null ? "null" : result.output));
            }
            return scheduled;
        } catch (Exception e) {
            Log.e(TAG, "installApkSelfUpdate: " + e.getMessage());
            return false;
        }
    }

    /**
     * Installs an APK through the privileged route when available, otherwise
     * uses PackageInstaller with a FileProvider content URI. Root installs do
     * not require Android's "Install unknown apps" grant and preserve app data.
     */
    @UsedByGodot
    public boolean installApk(String apkPath) {
        if (apkPath == null || apkPath.isEmpty()) {
            Log.e(TAG, "installApk: Empty path");
            return false;
        }

        if (activity == null) {
            Log.e(TAG, "installApk: Activity is null");
            return false;
        }

        try {
            File apkFile = new File(apkPath).getCanonicalFile();
            if (!apkFile.isFile() || !apkFile.getName().toLowerCase().endsWith(".apk")) {
                Log.e(TAG, "installApk: Not an APK file: " + apkFile);
                return false;
            }

            if (RootShell.isAvailable(activity)) {
                RootShell.Result result = RootShell.run(activity,
                        "pm install -r " + RootShell.quote(apkFile.getAbsolutePath()));
                if (result != null && result.succeeded() && result.output != null
                        && result.output.contains("Success")) {
                    Log.d(TAG, "installApk: Root install succeeded");
                    return true;
                }
                Log.e(TAG, "installApk: Root install failed: exit="
                        + (result == null ? "null" : result.exitCode)
                        + " output=" + (result == null ? "null" : result.output));
                return false;
            }

            // Unrooted fallback: Android 8+ requires the runtime grant before
            // the system installer intent will be accepted.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    && !activity.getPackageManager().canRequestPackageInstalls()) {
                Log.e(TAG, "installApk: 'Install unknown apps' not granted for this app");
                return false;
            }

            Uri apkUri = FileProvider.getUriForFile(activity,
                activity.getPackageName() + ".kyodai.fileprovider", apkFile);
            Log.d(TAG, "installApk: Using URI: " + apkUri);

            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            activity.grantUriPermission("com.android.packageinstaller", apkUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION);

            startActivity(intent);
            Log.d(TAG, "installApk: Install intent launched successfully");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "installApk: Failed to install APK: " + e.getMessage());
            e.printStackTrace();
            return false;
        }
    }
    
    /**
     * Extracts a ZIP file using streaming to minimize memory usage.
     * Uses Java's ZipInputStream with an 8KB buffer instead of loading entire files into memory.
     * This prevents OOM kills during extraction of large game files on Android.
     * 
     * @param zipPath Absolute path to the ZIP file
     * @param extractDir Absolute path to the extraction directory
     * @return true if extraction succeeded, false otherwise
     */
    @UsedByGodot
    public boolean extractZipStreaming(String zipPath, String extractDir) {
        Log.d(TAG, "extractZipStreaming: Starting extraction of " + zipPath + " to " + extractDir);
        
        ZipInputStream zis = null;
        InputStream fis = null;
        byte[] buffer = new byte[8192]; // 8KB buffer
        int extractedCount = 0;
        long totalBytes = 0;
        
        try {
            // Create extraction directory if it doesn't exist
            File destDir = new File(extractDir);
            if (!destDir.exists()) {
                destDir.mkdirs();
            }
            
            fis = new FileInputStream(zipPath);
            zis = new ZipInputStream(fis);
            
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                String entryName = entry.getName();
                File outputFile = new File(destDir, entryName);
                
                // Security check: ensure the output file is within the destination directory.
                // Compare against canonicalDest + separator so a sibling directory
                // sharing the name prefix (e.g. /a/tmp2 vs /a/tmp) cannot pass.
                String canonicalDest = destDir.getCanonicalPath();
                String canonicalOutput = outputFile.getCanonicalPath();
                if (!canonicalOutput.equals(canonicalDest) && !canonicalOutput.startsWith(canonicalDest + File.separator)) {
                    Log.e(TAG, "extractZipStreaming: ZIP entry tried to escape destination: " + entryName);
                    continue;
                }
                
                if (entry.isDirectory()) {
                    outputFile.mkdirs();
                    continue;
                }
                
                // Create parent directories
                File parentDir = outputFile.getParentFile();
                if (parentDir != null && !parentDir.exists()) {
                    parentDir.mkdirs();
                }
                
                // Extract file using streaming with 8KB buffer
                FileOutputStream fos = null;
                try {
                    fos = new FileOutputStream(outputFile);
                    int count;
                    while ((count = zis.read(buffer)) != -1) {
                        fos.write(buffer, 0, count);
                    }
                    fos.flush();
                    
                    // Relieve memory pressure:
                    // Force sync to disk every 50 files to prevent kernel buffer bloat
                    if (extractedCount % 50 == 0) {
                        try {
                            fos.getFD().sync();
                        } catch (Exception ignored) {}
                    }
                    
                    extractedCount++;
                    totalBytes += entry.getSize();
                } finally {
                    if (fos != null) {
                        try {
                            fos.close();
                        } catch (Exception ignored) {}
                    }
                }
                
                zis.closeEntry();
                
                // Relieve memory pressure between files
                try {
                    Thread.sleep(1); // 1ms sleep to let system reclaim memory
                    if (extractedCount % 100 == 0) {
                        System.gc(); // Request garbage collection
                    }
                } catch (Exception ignored) {}
                
                // Log progress every 100 files or 100MB
                if (extractedCount % 100 == 0 || totalBytes > 104857600) {
                    Log.d(TAG, "extractZipStreaming: Progress - " + extractedCount + " files, " + 
                        (totalBytes / 1048576) + " MB extracted");
                }
            }
            
            Log.d(TAG, "extractZipStreaming: Extraction complete. " + extractedCount + " files, " + 
                (totalBytes / 1048576) + " MB total.");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "extractZipStreaming: Extraction failed: " + e.getMessage());
            e.printStackTrace();
            return false;
        } finally {
            // Clean up streams
            if (zis != null) {
                try {
                    zis.close();
                } catch (Exception ignored) {}
            }
            if (fis != null) {
                try {
                    fis.close();
                } catch (Exception ignored) {}
            }
        }
    }
    
    /**
     * Starts the ExtractorService in a separate process for memory-intensive extractions.
     * The service runs in its own process (":extractor") and sends a broadcast when done.
     * 
     * @param zipPath Absolute path to ZIP file
     * @param extractDir Absolute path to extraction directory
     * @param gameName Display name for the notification
     * @return true if service was started successfully
     */
    @UsedByGodot
    public boolean startExtractorService(String zipPath, String extractDir, String gameName) {
        Log.d(TAG, "startExtractorService: zip=" + zipPath + ", dir=" + extractDir);
        
        if (activity == null) {
            Log.e(TAG, "Activity is null, cannot start extractor service");
            return false;
        }
        
        try {
            Intent intent = new Intent(activity, ExtractorService.class);
            intent.setAction("EXTRACT");
            intent.putExtra("zip_path", zipPath);
            intent.putExtra("extract_dir", extractDir);
            intent.putExtra("game_name", gameName);
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent);
            } else {
                activity.startService(intent);
            }
            
            Log.d(TAG, "ExtractorService started successfully");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Failed to start ExtractorService: " + e.getMessage());
            e.printStackTrace();
            return false;
        }
    }

    // ========================================================================
    // Vendor root daemon (AYN/Retroid PServerBinder, Ayaneo xsu)
    // Used to provision emulator-private prefs (OOBE skips) on handhelds.
    // ========================================================================

    @UsedByGodot
    public int getAppTargetSdkVersion() {
        return activity == null ? -1 : activity.getApplicationInfo().targetSdkVersion;
    }

    @UsedByGodot
    public boolean rootAvailable() {
        boolean available = activity != null && RootShell.isAvailable(activity);
        Log.d(TAG, "rootAvailable: " + available);
        return available;
    }

    /**
     * Runs a shell script as root via the vendor daemon. Returns a JSON string
     * {"exit": <int|null>, "output": "<full output>"} or "" when no root route
     * exists. Callers must build scripts from fixed strings only.
     */
    @UsedByGodot
    public String rootRunScript(String script) {
        if (activity == null || script == null || script.isEmpty()) {
            return "";
        }
        RootShell.Result result = RootShell.run(activity, script);
        if (result == null) {
            return "";
        }
        try {
            org.json.JSONObject json = new org.json.JSONObject();
            if (result.exitCode != null) {
                json.put("exit", result.exitCode.intValue());
            } else {
                json.put("exit", org.json.JSONObject.NULL);
            }
            json.put("output", result.output);
            return json.toString();
        } catch (org.json.JSONException e) {
            Log.w(TAG, "rootRunScript JSON build failed: " + e.getMessage());
            return "";
        }
    }
}

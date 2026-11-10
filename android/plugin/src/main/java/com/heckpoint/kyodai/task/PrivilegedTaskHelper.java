package com.heckpoint.kyodai.task;

import android.app.ActivityManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ColorSpace;
import android.hardware.HardwareBuffer;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.view.SurfaceControl;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;

/** Entry point executed by app_process through the vendor privilege bridge. */
public final class PrivilegedTaskHelper {
    private static final int PROTOCOL = 1;
    private static final String TAG = "KyodaiTaskHelper";

    private JSONObject request;
    private HardwareBuffer curtainBuffer;
    private ColorSpace curtainColorSpace;
    private boolean curtainRealSnapshot;
    private volatile SurfaceControl observerCurtain;
    private Object observerRegistration;
    private final ExecutorService observerExecutor = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "KyodaiObserverWork");
        thread.setDaemon(true);
        return thread;
    });
    private volatile boolean observerStopped;
    private JSONObject expected;
    private File requestDir;
    private String nonce;

    public static void main(String[] args) {
        PrivilegedTaskHelper helper = new PrivilegedTaskHelper();
        boolean homeCurtain = args.length == 2 && "--home-curtain".equals(args[1]);
        boolean observer = args.length == 2 && "--observe".equals(args[1]);
        int status = 0;
        try {
            if (args.length != 1 && !homeCurtain && !observer) {
                throw new Exception("invalid_request", new Exception("Expected request directory"));
            }
            helper.requestDir = new File(args[0]).getCanonicalFile();
            helper.readRequest();
            helper.requirePrivileged();
            if (homeCurtain) {
                helper.runHomeCurtain();
            } else if (observer) {
                helper.runObserver();
            } else {
                helper.execute();
            }
        } catch (Throwable t) {
            status = 1;
            if (!homeCurtain) helper.writeFailure(t);
        } finally {
            // This is a one-shot command-line process, not an Android activity.
            // Do not let a runtime/binder thread keep the vendor root shell open
            // after the result has been published.
            System.exit(status);
        }
    }

    private void readRequest() throws Exception {
        String text = readText(new File(requestDir, "request.json"));
        request = new JSONObject(text);
        if (request.optInt("protocol", -1) != PROTOCOL) {
            throw new Exception("invalid_request", new Exception("Unsupported protocol"));
        }
        nonce = request.getString("nonce");
        if (nonce.isEmpty() || nonce.length() > 80 || nonce.contains("..")) {
            throw new Exception("invalid_request", new Exception("Invalid nonce"));
        }
        expected = request.optJSONObject("expected");
        if (expected == null) expected = new JSONObject();
    }

    private void requirePrivileged() throws Exception {
        int uid = Process.myUid();
        if (uid == 0) return;
        // Shell diagnostics are read-only; root daemon invocations still use
        // UID 0 for the full tier.
        if (uid == 2000) {
            String op = request.getString("op");
            if ("probe".equals(op) || "list".equals(op)) return;
        }
        throw new Exception("denied", new Exception("Privileged helper identity required"));
    }

    private void execute() throws Exception {
        String op = request.getString("op");
        switch (op) {
            case "probe": probe(); break;
            case "list": list(); break;
            case "snapshot": snapshot(); break;
            case "focus": focus(); break;
            case "force_stop": forceStop(); break;
            case "remove_task": removeTask(); break;
            case "move_display": moveDisplay(); break;
            case "observe_start": spawnObserver(); break;
            case "transition_scale": setTransitionScale(); break;
            case "cleanup_helpers": cleanupHelpers(); break;
            default: throw new Exception("invalid_request", new Exception("Unknown operation"));
        }
    }

    private void probe() throws Exception {
        JSONObject caps = new JSONObject();
        caps.put("privileged", Process.myUid() == 0);
        caps.put("listTasks", hasTaskManagerMethod("getTasks"));
        caps.put("snapshots", hasTaskSnapshotSignature());
        caps.put("focus", hasTaskManagerMethod("setFocusedTask"));
        caps.put("forceStop", hasActivityManagerMethod("forceStopPackage"));
        caps.put("removeTask", hasTaskManagerMethod("removeTask"));
        caps.put("moveDisplay", hasTaskManagerMethod("moveRootTaskToDisplay"));
        JSONObject result = baseResult();
        result.put("capabilities", caps);
        writeResult(result);
    }

    private void list() throws Exception {
        JSONArray tasks = new JSONArray();
        for (ActivityManager.RunningTaskInfo info : getTasks()) {
            tasks.put(taskJson(info));
        }
        JSONObject result = baseResult();
        result.put("tasks", tasks);
        writeResult(result);
    }

    private void snapshot() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        // Match Cocoon's ordering: raise the SurfaceControl curtain before
        // doing any JPEG conversion, file I/O, or launcher callbacks.
        boolean homeCurtain = spawnHomeCurtain();
        File output = new File(requestDir, "frame.jpg");
        Bitmap bitmap;
        boolean real;
        if (homeCurtain && output.isFile()) {
            // The curtain child already captured and published this exact
            // frame. Reuse it instead of requesting a second task snapshot.
            bitmap = BitmapFactory.decodeFile(output.getAbsolutePath());
            String[] marker = readText(new File(requestDir, "frame-ready")).trim().split(" ");
            real = marker.length < 3 || !"0".equals(marker[2]);
        } else {
            Object snapshot = getTaskSnapshot(taskId);
            if (snapshot == null) throw new Exception("capture_failed", new Exception("No task snapshot"));
            HardwareBuffer buffer = (HardwareBuffer) snapshot.getClass().getMethod("getHardwareBuffer").invoke(snapshot);
            if (buffer == null) throw new Exception("capture_failed", new Exception("Empty snapshot buffer"));
            ColorSpace colorSpace = (ColorSpace) snapshot.getClass().getMethod("getColorSpace").invoke(snapshot);
            real = (boolean) snapshot.getClass().getMethod("isRealSnapshot").invoke(snapshot);
            bitmap = Bitmap.wrapHardwareBuffer(buffer, colorSpace);
            writeJpeg(bitmap, output);
        }
        if (bitmap == null) throw new Exception("capture_failed", new Exception("Could not wrap snapshot"));
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        JSONObject image = new JSONObject();
        image.put("path", output.getAbsolutePath());
        image.put("width", bitmap.getWidth());
        image.put("height", bitmap.getHeight());
        image.put("real", real);
        result.put("snapshot", image);
        result.put("homeCurtain", homeCurtain);
        writeResult(result);
    }

    private boolean awaitFile(File target, long timeoutMs) throws InterruptedException {
        // FileObserver leaves a non-daemon thread behind in standalone
        // app_process helpers, preventing the VM and root wrapper from exiting.
        // These waits are short, so bounded polling is cheaper and deterministic.
        long deadline = SystemClock.uptimeMillis() + timeoutMs;
        while (!target.isFile()) {
            long remaining = deadline - SystemClock.uptimeMillis();
            if (remaining <= 0) break;
            Thread.sleep(Math.min(25, remaining));
        }
        return target.isFile();
    }

    private boolean spawnHomeCurtain() {
        try {
            ProcessBuilder builder = new ProcessBuilder(
                    "/system/bin/app_process", "/system/bin",
                    PrivilegedTaskHelper.class.getName(), requestDir.getAbsolutePath(), "--home-curtain");
            builder.redirectErrorStream(true);
            builder.redirectOutput(new File("/dev/null"));
            builder.start();
            // Do not let GDScript start updating behind the curtain until the
            // child has a real SurfaceFlinger layer on screen.
            File ready = new File(requestDir, "curtain-ready");
            if (awaitFile(ready, 300)) return true;
        } catch (Throwable ignored) {
        }
        return false;
    }

    private void runHomeCurtain() throws Exception {
        int taskId = requireTaskId();
        requireTask(taskId);
        SurfaceControl curtain = showResumeCurtain(taskId);
        if (curtain == null) return;
        try {
            writeCurtainFrame();
            try (FileOutputStream ready = new FileOutputStream(new File(requestDir, "curtain-ready"))) {
                ready.write("1".getBytes(StandardCharsets.UTF_8));
            }
            File release = new File(requestDir, "release-curtain");
            awaitFile(release, 5000);
        } finally {
            hideResumeCurtain(curtain);
        }
    }

    private void spawnObserver() throws Exception {
        ProcessBuilder builder = new ProcessBuilder(
                "/system/bin/app_process", "/system/bin",
                PrivilegedTaskHelper.class.getName(), requestDir.getAbsolutePath(), "--observe");
        builder.redirectErrorStream(true);
        builder.redirectOutput(new File("/dev/null"));
        java.lang.Process child = builder.start();
        File ready = new File(requestDir, "observer-ready");
        if (!awaitFile(ready, 3000)) {
            child.destroy();
            throw new Exception("unavailable", new Exception("Task observer failed to start"));
        }
        JSONObject result = baseResult();
        result.put("observer", true);
        writeResult(result);
    }

    private void runObserver() throws Exception {
        int gameTaskId = requireTaskId();
        requireTask(gameTaskId);
        String homePackage = expected.getString("homePackage");
        int ownerPid = expected.getInt("ownerPid");
        try {
            registerObserver(homePackage, gameTaskId);
            try (FileOutputStream ready = new FileOutputStream(new File(requestDir, "observer-ready"))) {
                ready.write("1".getBytes(StandardCharsets.UTF_8));
            }
            File release = new File(requestDir, "release-curtain");
            awaitObserverRelease(release, ownerPid);
        } finally {
            observerStopped = true;
            stopObserverExecutor();
            unregisterObserver();
            hideResumeCurtain(observerCurtain);
            observerCurtain = null;
            try (FileOutputStream exited = new FileOutputStream(new File(requestDir, "observer-exited"))) {
                exited.write("1".getBytes(StandardCharsets.UTF_8));
            } catch (Throwable ignored) {
            }
        }
    }

    private void stopObserverExecutor() {
        observerExecutor.shutdown();
        try {
            observerExecutor.awaitTermination(2, TimeUnit.SECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    private void cleanupHelpers() throws Exception {
        int reaped = 0;
        File[] processes = new File("/proc").listFiles();
        if (processes != null) {
            for (File process : processes) {
                if (!process.getName().matches("\\d+")) continue;
                int pid = Integer.parseInt(process.getName());
                if (pid == Process.myPid()) continue;
                try {
                    String command = readTextStream(new File(process, "cmdline"));
                    if (!command.contains(PrivilegedTaskHelper.class.getName())) continue;
                    int ownerPid = -1;
                    File requestDir = null;
                    String[] args = command.split("\\u0000");
                    for (String arg : args) {
                        if (!arg.contains("/task-requests/")) continue;
                        requestDir = new File(arg);
                        File request = new File(requestDir, "request.json");
                        if (!request.isFile()) continue;
                        try {
                            ownerPid = new JSONObject(readText(request))
                                    .getJSONObject("expected").optInt("ownerPid", -1);
                        } catch (Throwable ignored) {
                        }
                        break;
                    }
                    if (ownerPid > 0 && new File("/proc/" + ownerPid).exists()) continue;
                    if (ownerPid < 0 && System.currentTimeMillis() - process.lastModified() < 60000) continue;
                    Process.killProcess(pid);
                    if (requestDir != null && new File(requestDir, "observer-ready").isFile()) {
                        try (FileOutputStream out = new FileOutputStream(new File(requestDir, "observer-exited"))) {
                            out.write("1\n".getBytes(StandardCharsets.UTF_8));
                        }
                    }
                    reaped++;
                } catch (Throwable ignored) {
                }
            }
        }
        JSONObject result = baseResult();
        result.put("reaped", reaped);
        writeResult(result);
        Log.d(TAG, "stale helpers reaped=" + reaped);
    }

    private void setTransitionScale() throws Exception {
        float scale = (float) expected.getDouble("scale");
        windowManager().getClass().getMethod("setAnimationScale", int.class, float.class)
                .invoke(windowManager(), 1, scale);
        JSONObject result = baseResult();
        result.put("scale", scale);
        writeResult(result);
        Log.d(TAG, "transition animation scale forced=" + scale);
    }

    private Object windowManager() throws Exception {
        return binder("window", "android.view.IWindowManager$Stub");
    }

    private void awaitObserverRelease(File release, int ownerPid) throws InterruptedException {
        long curtainDeadline = 0;
        File owner = new File("/proc/" + ownerPid);
        while (!observerStopped && !release.isFile() && owner.exists()) {
            if (observerCurtain != null && curtainDeadline == 0) {
                curtainDeadline = SystemClock.uptimeMillis() + 10000;
            }
            long sleepMs = 100;
            if (curtainDeadline > 0) {
                long remaining = curtainDeadline - SystemClock.uptimeMillis();
                if (remaining <= 0) return;
                sleepMs = Math.min(sleepMs, remaining);
            }
            Thread.sleep(sleepMs);
        }
    }

    private void registerObserver(String homePackage, int gameTaskId) throws Exception {
        Class<?> listenerType = Class.forName("android.app.ITaskStackListener");
        Class<?> stubType = Class.forName("android.app.ITaskStackListener$Stub");
        Map<Integer, String> methods = new HashMap<>();
        for (java.lang.reflect.Field field : stubType.getDeclaredFields()) {
            if (!field.getName().startsWith("TRANSACTION_")) continue;
            field.setAccessible(true);
            methods.put(field.getInt(null), field.getName().substring("TRANSACTION_".length()));
        }
        Binder binder = new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                if (code == INTERFACE_TRANSACTION) {
                    reply.writeString(listenerType.getName());
                    return true;
                }
                String method = methods.get(code);
                if (method == null) return false;
                data.enforceInterface(listenerType.getName());
                if ("onTaskMovedToFront".equals(method)) {
                    ActivityManager.RunningTaskInfo moved = null;
                    try {
                        moved = ActivityManager.RunningTaskInfo.CREATOR.createFromParcel(data);
                    } catch (Throwable ignored) {
                    }
                    final ActivityManager.RunningTaskInfo movedSnapshot = moved;
                    enqueueObserverWork(() -> raiseForHome(homePackage, gameTaskId, movedSnapshot));
                } else if ("onTaskRemoved".equals(method)) {
                    int removedTaskId = data.readInt();
                    if (removedTaskId == gameTaskId) {
                        enqueueObserverWork(() -> publishObserverEvent("task_removed", removedTaskId));
                    }
                } else if ("onTaskStackChanged".equals(method) || "onTaskFocusChanged".equals(method)) {
                    enqueueObserverWork(() -> raiseForHome(homePackage, gameTaskId, null));
                }
                if (reply != null) reply.writeNoException();
                return true;
            }
        };
        Object proxy = Proxy.newProxyInstance(listenerType.getClassLoader(), new Class<?>[]{listenerType},
                (ignored, method, args) -> {
                    if ("asBinder".equals(method.getName())) return binder;
                    if ("toString".equals(method.getName())) return "Kyodai task observer";
                    if ("hashCode".equals(method.getName())) return System.identityHashCode(this);
                    if ("equals".equals(method.getName())) return false;
                    return null;
                });
        taskManager().getClass().getMethod("registerTaskStackListener", listenerType)
                .invoke(taskManager(), proxy);
        observerRegistration = proxy;
        Log.d(TAG, "observer registered task=" + gameTaskId + " home=" + homePackage);
    }

    private void enqueueObserverWork(Runnable work) {
        if (observerStopped) return;
        try {
            observerExecutor.execute(work);
        } catch (RejectedExecutionException ignored) {
        }
    }

    private void unregisterObserver() {
        if (observerRegistration == null) return;
        try {
            Class<?> listenerType = Class.forName("android.app.ITaskStackListener");
            taskManager().getClass().getMethod("unregisterTaskStackListener", listenerType)
                    .invoke(taskManager(), observerRegistration);
            Log.d(TAG, "observer unregistered");
        } catch (Throwable error) {
            Log.w(TAG, "observer unregister failed", error);
        } finally {
            observerRegistration = null;
        }
    }

    private void publishObserverEvent(String event, int taskId) {
        if (observerStopped) return;
        try {
            JSONObject value = baseResult();
            value.put("event", event);
            value.put("taskId", taskId);
            value.put("packageName", expected.optString("package", ""));
            writeJsonAtomic(new File(requestDir, "task-event.json"), value);
        } catch (Throwable error) {
            Log.w(TAG, "Could not publish task event", error);
        }
    }

    private void raiseForHome(String homePackage, int gameTaskId, ActivityManager.RunningTaskInfo moved) {
        if (observerStopped || observerCurtain != null) return;
        if (moved != null && (moved.taskId <= 0 || moved.topActivity == null)) moved = null;
        try {
            if (moved != null) {
                String packageName = moved.topActivity == null ? "" : moved.topActivity.getPackageName();
                if (homePackage.equals(packageName)) {
                    // The task-move callback precedes visibility stabilization;
                    // do not wait for isVisible and lose the first Home frames.
                    SurfaceControl newCurtain = showResumeCurtain(gameTaskId);
                    if (observerStopped) {
                        hideResumeCurtain(newCurtain);
                        return;
                    }
                    observerCurtain = newCurtain;
                    publishObserverFrame(gameTaskId);
                    Log.d(TAG, "observer raised Home curtain task=" + gameTaskId
                            + " movedTask=" + moved.taskId + " visible=" + booleanField(moved, "isVisible", false));
                }
                return;
            }
            for (ActivityManager.RunningTaskInfo info : getTasks()) {
                String packageName = info.topActivity == null ? "" : info.topActivity.getPackageName();
                if (homePackage.equals(packageName) && booleanField(info, "isVisible", false)) {
                    SurfaceControl newCurtain = showResumeCurtain(gameTaskId);
                    if (observerStopped) {
                        hideResumeCurtain(newCurtain);
                        return;
                    }
                    observerCurtain = newCurtain;
                    publishObserverFrame(gameTaskId);
                    Log.d(TAG, "observer raised Home curtain task=" + gameTaskId);
                    return;
                }
            }
        } catch (Throwable error) {
            Log.w(TAG, "observer Home check failed", error);
        }
    }

    private void publishObserverFrame(int gameTaskId) {
        try {
            if (observerCurtain == null) {
                writeFailure(new Exception("capture_failed", new Exception("Observer curtain unavailable")));
                return;
            }
            File frame = writeCurtainFrame();
            if (frame == null) {
                writeFailure(new Exception("capture_failed", new Exception("Observer frame unavailable")));
                return;
            }
            JSONObject result = baseResult();
            result.put("task", taskJson(requireTask(gameTaskId)));
            JSONObject image = new JSONObject();
            image.put("path", frame.getAbsolutePath());
            image.put("width", curtainBuffer.getWidth());
            image.put("height", curtainBuffer.getHeight());
            image.put("real", curtainRealSnapshot);
            result.put("snapshot", image);
            result.put("homeCurtain", true);
            writeResult(result);
        } catch (Throwable error) {
            Log.w(TAG, "Observer result publish failed", error);
        }
    }

    private void focus() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        SurfaceControl curtain = showResumeCurtain(taskId);
        try {
            taskManager().getClass().getMethod("setFocusedTask", int.class).invoke(taskManager(), taskId);
            // Cover the OS task-slide and the first frames of the resumed game.
            // This is a real SurfaceFlinger layer, not an in-app fake PiP view.
            SystemClock.sleep(650);
        } finally {
            hideResumeCurtain(curtain);
        }
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        result.put("curtain", curtain != null);
        writeResult(result);
    }

    private SurfaceControl showResumeCurtain(int taskId) {
        SurfaceControl curtain = null;
        try {
            Object snapshot = getTaskSnapshot(taskId);
            if (snapshot == null) return null;
            HardwareBuffer buffer = (HardwareBuffer) snapshot.getClass().getMethod("getHardwareBuffer").invoke(snapshot);
            if (buffer == null) return null;
            // Keep the buffer alive until the curtain is lowered. Closing it
            // immediately after apply() can leave a ready but empty layer.
            curtainBuffer = buffer;
            curtainColorSpace = (ColorSpace) snapshot.getClass().getMethod("getColorSpace").invoke(snapshot);
            curtainRealSnapshot = (boolean) snapshot.getClass().getMethod("isRealSnapshot").invoke(snapshot);
            curtain = new SurfaceControl.Builder()
                    .setName("KyodaiResumeCurtain")
                    .setBufferSize(buffer.getWidth(), buffer.getHeight())
                    .setFormat(1)
                    .build();
            Integer layerStack = null;
            try (SurfaceControl.Transaction transaction = new SurfaceControl.Transaction()) {
                try {
                    Object display = displayInfo(0);
                    layerStack = display.getClass().getField("layerStack").getInt(display);
                    transaction.getClass().getMethod("setLayerStack", SurfaceControl.class, int.class)
                            .invoke(transaction, curtain, layerStack);
                } catch (Throwable error) {
                    Log.w(TAG, "Curtain layerStack fallback", error);
                }
                transaction.setBuffer(curtain, buffer)
                        .setPosition(curtain, 0, 0)
                        .setLayer(curtain, Integer.MAX_VALUE - 1)
                        .setVisibility(curtain, true)
                        .apply();
            }
            Log.d(TAG, "curtain raised task=" + taskId + " layerStack=" + layerStack
                    + " buffer=" + buffer.getWidth() + "x" + buffer.getHeight());
            return curtain;
        } catch (Throwable error) {
            Log.w(TAG, "curtain raise failed task=" + taskId, error);
            if (curtain != null) curtain.release();
            if (curtainBuffer != null) {
                curtainBuffer.close();
                curtainBuffer = null;
                curtainColorSpace = null;
            }
            return null; // curtain is best-effort; task focus must still work
        }
    }

    private File writeCurtainFrame() {
        try {
            if (curtainBuffer == null) return null;
            Bitmap bitmap = Bitmap.wrapHardwareBuffer(curtainBuffer, curtainColorSpace);
            if (bitmap == null) return null;
            File output = new File(requestDir, "frame.jpg");
            writeJpeg(bitmap, output);
            try (FileOutputStream ready = new FileOutputStream(new File(requestDir, "frame-ready"))) {
                String marker = bitmap.getWidth() + " " + bitmap.getHeight() + " " + (curtainRealSnapshot ? "1" : "0");
                ready.write(marker.getBytes(StandardCharsets.UTF_8));
            }
            return output;
        } catch (Throwable error) {
            Log.w(TAG, "Could not publish curtain frame", error);
            return null;
        }
    }

    private void hideResumeCurtain(SurfaceControl curtain) {
        if (curtain == null) return;
        try (SurfaceControl.Transaction transaction = new SurfaceControl.Transaction()) {
            transaction.setVisibility(curtain, false).apply();
            Log.d(TAG, "curtain lowered");
        } catch (Throwable error) {
            Log.w(TAG, "curtain lower failed", error);
        } finally {
            curtain.release();
            if (curtainBuffer != null) {
                curtainBuffer.close();
                curtainBuffer = null;
                curtainColorSpace = null;
            }
        }
    }

    private void forceStop() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        if (requiredBooleanField(info, "isVisible")) throw new Exception("unsafe_operation", new Exception("Refusing to close a visible game"));
        String packageName = expectedPackage(info);
        int userId = expected.getInt("userId");
        for (ActivityManager.RunningTaskInfo candidate : getTasks()) {
            if (packageName.equals(expectedPackage(candidate))
                    && requiredIntField(candidate, "userId") == userId
                    && requiredBooleanField(candidate, "isVisible")) {
                throw new Exception("unsafe_operation", new Exception("Package has a visible task"));
            }
        }
        int taskUserId = requiredIntField(info, "userId");
        if (userId != taskUserId) {
            throw new Exception("stale_task", new Exception("Task user/profile changed"));
        }
        activityManager().getClass().getMethod("forceStopPackage", String.class, int.class)
                .invoke(activityManager(), packageName, userId);
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        writeResult(result);
    }

    private void removeTask() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        boolean removed = (boolean) taskManager().getClass().getMethod("removeTask", int.class)
                .invoke(taskManager(), taskId);
        if (!removed) throw new Exception("stale_task", new Exception("Task could not be removed"));
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        writeResult(result);
    }

    private void moveDisplay() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        int displayId = expected.getInt("displayId");
        if (displayId < 0) throw new Exception("invalid_request", new Exception("Invalid display"));
        taskManager().getClass().getMethod("moveRootTaskToDisplay", int.class, int.class)
                .invoke(taskManager(), taskId, displayId);
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        writeResult(result);
    }

    private int requireTaskId() throws Exception {
        int taskId = expected.getInt("taskId");
        if (taskId <= 0) throw new Exception("invalid_request", new Exception("Invalid task ID"));
        return taskId;
    }

    private ActivityManager.RunningTaskInfo requireTask(int taskId) throws Exception {
        for (ActivityManager.RunningTaskInfo info : getTasks()) {
            if (info.taskId != taskId) continue;
            String expectedPackage = expected.optString("packageName", "");
            if (expectedPackage.isEmpty()) {
                throw new Exception("invalid_request", new Exception("Expected package identity required"));
            }
            String top = info.topActivity == null ? "" : info.topActivity.getClassName();
            if (info.topActivity == null || !expectedPackage.equals(info.topActivity.getPackageName())) {
                throw new Exception("stale_task", new Exception("Task package changed"));
            }
            // topActivity is informational and may change as the emulator
            // navigates. Stable task/package identity is validated above.
            // The returned metadata always reflects the current top activity.
            return info;
        }
        throw new Exception("stale_task", new Exception("Task no longer exists"));
    }

    private String expectedPackage(ActivityManager.RunningTaskInfo info) throws Exception {
        String value = expected.optString("packageName", "");
        if (!value.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+")) {
            throw new Exception("invalid_request", new Exception("Invalid package name"));
        }
        if (info.topActivity != null && !value.equals(info.topActivity.getPackageName())) {
            throw new Exception("stale_task", new Exception("Task package changed"));
        }
        return value;
    }

    @SuppressWarnings("unchecked")
    private List<ActivityManager.RunningTaskInfo> getTasks() throws Exception {
        Object manager = taskManager();
        try {
            return (List<ActivityManager.RunningTaskInfo>) manager.getClass()
                    .getMethod("getTasks", int.class, boolean.class, boolean.class, int.class)
                    .invoke(manager, 64, false, false, -1);
        } catch (NoSuchMethodException ignored) {
            return (List<ActivityManager.RunningTaskInfo>) manager.getClass()
                    .getMethod("getTasks", int.class, boolean.class, boolean.class)
                    .invoke(manager, 64, false, false);
        }
    }

    private Object getTaskSnapshot(int taskId) throws Exception {
        Object manager = taskManager();
        try {
            return manager.getClass().getMethod("getTaskSnapshot", int.class, boolean.class)
                    .invoke(manager, taskId, false);
        } catch (NoSuchMethodException ignored) {
            return manager.getClass().getMethod("getTaskSnapshot", int.class, boolean.class, boolean.class)
                    .invoke(manager, taskId, false, false);
        }
    }

    private boolean hasTaskSnapshotSignature() {
        try {
            Class<?> type = Class.forName("android.app.IActivityTaskManager");
            type.getMethod("getTaskSnapshot", int.class, boolean.class);
            return true;
        } catch (Throwable ignored) {
            try {
                Class.forName("android.app.IActivityTaskManager")
                        .getMethod("getTaskSnapshot", int.class, boolean.class, boolean.class);
                return true;
            } catch (Throwable ignoredAgain) {
                return false;
            }
        }
    }

    private Object displayInfo(int displayId) throws Exception {
        Object manager = binder("display", "android.hardware.display.IDisplayManager$Stub");
        return manager.getClass().getMethod("getDisplayInfo", int.class).invoke(manager, displayId);
    }

    private Object taskManager() throws Exception {
        return binder("activity_task", "android.app.IActivityTaskManager$Stub");
    }

    private Object activityManager() throws Exception {
        return binder("activity", "android.app.IActivityManager$Stub");
    }

    private Object binder(String name, String stub) throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) serviceManager.getMethod("getService", String.class).invoke(null, name);
        if (binder == null || !binder.isBinderAlive()) throw new Exception("unavailable", new Exception(name));
        return Class.forName(stub).getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    private boolean hasTaskManagerMethod(String name) {
        return hasMethod("android.app.IActivityTaskManager", name);
    }

    private boolean hasActivityManagerMethod(String name) {
        return hasMethod("android.app.IActivityManager", name);
    }

    private boolean hasMethod(String className, String name) {
        try {
            for (Method method : Class.forName(className).getMethods()) {
                if (method.getName().equals(name)) return true;
            }
        } catch (Throwable ignored) {}
        return false;
    }

    private JSONObject taskJson(ActivityManager.RunningTaskInfo info) throws JSONException {
        JSONObject out = new JSONObject();
        out.put("taskId", info.taskId);
        out.put("packageName", info.topActivity == null ? "" : info.topActivity.getPackageName());
        out.put("topActivity", info.topActivity == null ? "" : info.topActivity.getClassName());
        out.put("baseActivity", info.baseActivity == null ? "" : info.baseActivity.flattenToShortString());
        out.put("displayId", intField(info, "displayId", 0));
        out.put("userId", intField(info, "userId", 0));
        out.put("visible", booleanField(info, "isVisible", false));
        return out;
    }

    private int intField(Object object, String name, int fallback) {
        try {
            Field field = object.getClass().getField(name);
            return field.getInt(object);
        } catch (Throwable ignored) {
            return fallback;
        }
    }

    private boolean booleanField(Object object, String name, boolean fallback) {
        try {
            Field field = object.getClass().getField(name);
            return field.getBoolean(object);
        } catch (Throwable ignored) {
            return fallback;
        }
    }

    private int requiredIntField(Object object, String name) throws Exception {
        try {
            Field field = object.getClass().getField(name);
            return field.getInt(object);
        } catch (Throwable t) {
            throw new Exception("unsupported", new Exception("Could not verify task " + name));
        }
    }

    private boolean requiredBooleanField(Object object, String name) throws Exception {
        try {
            Field field = object.getClass().getField(name);
            return field.getBoolean(object);
        } catch (Throwable t) {
            throw new Exception("unsafe_operation", new Exception("Could not verify task visibility"));
        }
    }

    private JSONObject baseResult() throws JSONException {
        JSONObject result = new JSONObject();
        result.put("ok", true);
        result.put("code", "ok");
        result.put("nonce", nonce);
        return result;
    }

    private void writeFailure(Throwable throwable) {
        try {
            while (throwable instanceof InvocationTargetException
                    && ((InvocationTargetException) throwable).getTargetException() != null) {
                throwable = ((InvocationTargetException) throwable).getTargetException();
            }
            String code;
            if (throwable instanceof SecurityException) code = "denied";
            else if (throwable instanceof NoSuchMethodException) code = "unsupported";
            else {
                String message = throwable.getMessage();
                switch (message == null ? "" : message) {
                    case "invalid_request":
                    case "stale_task":
                    case "capture_failed":
                    case "unsafe_operation":
                    case "io_error":
                    case "unavailable":
                        code = message;
                        break;
                    default:
                        code = "unknown";
                }
            }
            JSONObject result = new JSONObject();
            result.put("ok", false);
            result.put("code", code);
            result.put("nonce", nonce == null ? "" : nonce);
            result.put("error", throwable.toString());
            if (requestDir != null) writeResult(result);
        } catch (Throwable ignored) {}
    }

    private void writeResult(JSONObject result) throws Exception {
        writeJsonAtomic(new File(requestDir, "result.json"), result);
    }

    private void writeJsonAtomic(File output, JSONObject value) throws Exception {
        File tmp = new File(output.getParentFile(), output.getName() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(value.toString().getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        }
        tmp.setReadable(true, false);
        if (!tmp.renameTo(output)) throw new Exception("io_error", new Exception("Could not publish result"));
    }

    private void writeJpeg(Bitmap bitmap, File output) throws Exception {
        File tmp = new File(output.getParentFile(), output.getName() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)) {
                throw new Exception("capture_failed", new Exception("JPEG encoding failed"));
            }
            out.getFD().sync();
        }
        tmp.setReadable(true, false);
        if (!tmp.renameTo(output)) throw new Exception("io_error", new Exception("Could not publish frame"));
    }

    private static String readTextStream(File file) throws Exception {
        try (FileInputStream in = new FileInputStream(file);
             java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int read;
            while ((read = in.read(buffer)) >= 0) out.write(buffer, 0, read);
            return out.toString("UTF-8");
        }
    }

    private static String readText(File file) throws Exception {
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] bytes = new byte[(int) file.length()];
            int offset = 0;
            while (offset < bytes.length) {
                int read = in.read(bytes, offset, bytes.length - offset);
                if (read < 0) break;
                offset += read;
            }
            return new String(bytes, 0, offset, StandardCharsets.UTF_8);
        }
    }
}

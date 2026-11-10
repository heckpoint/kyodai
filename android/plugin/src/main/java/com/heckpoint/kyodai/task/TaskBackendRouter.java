package com.heckpoint.kyodai.task;

import android.content.Context;

import com.heckpoint.kyodai.RootShell;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Serializes backend work off the UI thread and returns structured results. */
public final class TaskBackendRouter {
    public interface ResultListener {
        void onResult(String requestId, String operation, JSONObject result);
    }

    private final Context context;
    private volatile AndroidTaskBackend backend;
    private final ExecutorService executor = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "KyodaiTaskBackend");
        thread.setDaemon(true);
        return thread;
    });
    private final ResultListener listener;
    private volatile boolean closed;

    public TaskBackendRouter(Context context, ResultListener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
        backend = RootShell.isAvailable(context)
                ? new VendorTaskBackend(context)
                : new PublicTaskBackend();
    }

    private AndroidTaskBackend backend() {
        AndroidTaskBackend current = backend;
        if (current instanceof VendorTaskBackend) return current;
        if (!RootShell.isAvailable(context)) return current;
        synchronized (this) {
            if (!(backend instanceof VendorTaskBackend)) {
                backend = new VendorTaskBackend(context);
            }
            return backend;
        }
    }

    public String probeCapabilities() {
        return submit("probeCapabilities", () -> backend().probeCapabilities().toJson());
    }

    public String listTasks() {
        return submit("listTasks", () -> {
            List<AndroidTaskBackend.TaskInfo> tasks = backend().listTasks();
            JSONArray array = new JSONArray();
            for (AndroidTaskBackend.TaskInfo task : tasks) array.put(task.toJson());
            JSONObject out = new JSONObject();
            out.put("tasks", array);
            return out;
        });
    }

    public String captureTaskSnapshot(int taskId, String packageName, String topActivity) {
        return submit("captureTaskSnapshot", () -> backend().captureTaskSnapshot(taskId, packageName, topActivity).toJson());
    }

    public String focusTask(int taskId, String packageName, String topActivity) {
        return submit("focusTask", () -> backend().focusTask(taskId, packageName, topActivity).toJson());
    }

    public String forceStopPackage(int taskId, String packageName, int userId) {
        return submit("forceStopPackage", () -> backend().forceStopPackage(taskId, packageName, userId).toJson());
    }

    public String removeTask(int taskId, String packageName) {
        return submit("removeTask", () -> backend().removeTask(taskId, packageName).toJson());
    }

    public String moveTaskToDisplay(int taskId, String packageName, int displayId) {
        return submit("moveTaskToDisplay", () -> backend().moveTaskToDisplay(taskId, packageName, displayId).toJson());
    }

    public String startObserver(int taskId, String packageName, String topActivity,
                                String homePackage, int ownerPid) {
        return submit("startObserver", () -> backend().startObserver(
                taskId, packageName, topActivity, homePackage, ownerPid).toJson());
    }

    public String setTransitionScale(float scale) {
        return submit("setTransitionScale", () -> backend().setTransitionScale(scale).toJson());
    }

    public String cleanupHelpers() {
        return submit("cleanupHelpers", () -> backend().cleanupHelpers().toJson());
    }

    public void close() {
        closed = true;
        executor.shutdownNow();
    }

    private String submit(String operation, JsonCall call) {
        if (closed) return "closed";
        String requestId = UUID.randomUUID().toString();
        try {
            executor.execute(() -> {
                JSONObject result;
                try {
                    result = call.run();
                    if (!result.has("ok")) result.put("ok", true);
            } catch (AndroidTaskBackend.TaskBackendException e) {
                result = failure(e.code, e.getMessage());
            } catch (Exception e) {
                result = failure("unknown", e.toString());
            }
            try {
                result.put("requestId", requestId);
                result.put("operation", operation);
            } catch (org.json.JSONException ignored) {}
            if (!closed) listener.onResult(requestId, operation, result);
        });
        return requestId;
        } catch (java.util.concurrent.RejectedExecutionException e) {
            return "closed";
        }
    }

    private static JSONObject failure(String code, String error) {
        JSONObject result = new JSONObject();
        try {
            result.put("ok", false);
            result.put("code", code);
            result.put("error", error);
        } catch (org.json.JSONException ignored) {}
        return result;
    }

    private interface JsonCall {
        JSONObject run() throws Exception;
    }
}

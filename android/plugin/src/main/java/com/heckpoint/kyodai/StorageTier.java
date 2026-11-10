package com.heckpoint.kyodai;

import android.content.Context;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Base64;
import android.util.Log;

import java.io.BufferedReader;
import java.io.FileReader;
import java.net.URLDecoder;

/**
 * Decides how a write into another app's /Android/data|obb/ gets executed.
 *
 * The FUSE daemon force-groups everything under Android/data to ext_data_rw
 * (1078) with setgid dirs, so any process carrying 1078 in its supplementary
 * groups has direct R/W there regardless of owner uid. Whether a given app
 * holds 1078 is firmware-dependent and NOT queryable from userspace on
 * API 33+ (getPackageGids returns only install-time gids, and AYN firmware
 * grants the storage gids to apps holding no storage permissions at all), so
 * the target side is never probed.
 *
 * Three tiers:
 *   DIRECT - kyodai itself holds 1078: plain File I/O works (e.g. Odin 3).
 *   SAF    - a persisted document-tree grant covers the target path:
 *            DocumentsContract writes land provider-owned but group-1078,
 *            readable by any target holding 1078 (every emulator on a
 *            permissive handheld firmware). When the vendor root daemon is
 *            alive, a best-effort chown pass follows each SAF write so the
 *            files become target-owned (covers 1078-less targets).
 *   ROOT   - no grant coverage but the vendor root daemon is alive: the
 *            daemon performs the whole operation and chowns the result to the
 *            target package's uid - correct under every firmware policy.
 *
 * Tier selection is per-op and logged, so "why did this launch fail" is always
 * answerable from logcat/session.log.
 */
final class StorageTier {
    private static final String TAG = "KyodaiBridge";

    static final int TIER_DIRECT = 0;
    static final int TIER_SAF = 1;
    static final int TIER_ROOT = 2;
    /** Flow-decision state: no route can reach the path (prompt for a grant). */
    static final int ROUTE_NONE = 3;

    /** ext_data_rw - the group the FUSE daemon assigns to all Android/data files. */
    static final int EXT_DATA_RW_GID = 1078;

    private static final String DOCS_TREE_PREFIX =
            "content://com.android.externalstorage.documents/tree/";

    /** Root writes above this size go through file staging instead of base64-in-script. */
    private static final int ROOT_INLINE_WRITE_MAX = 512 * 1024;

    private static volatile Boolean selfHasExtDataRw = null;
    private static volatile boolean chownFailureLogged = false;

    private StorageTier() {}

    // ------------------------------------------------------------------
    // Probes
    // ------------------------------------------------------------------

    /** True when our own process carries the ext_data_rw supplementary gid. */
    static boolean selfHasExtDataRw() {
        Boolean cached = selfHasExtDataRw;
        if (cached != null) return cached;
        boolean has = false;
        BufferedReader reader = null;
        try {
            reader = new BufferedReader(new FileReader("/proc/self/status"));
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.startsWith("Groups:")) {
                    for (String gid : line.substring("Groups:".length()).trim().split("\\s+")) {
                        if (String.valueOf(EXT_DATA_RW_GID).equals(gid)) {
                            has = true;
                            break;
                        }
                    }
                    break;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "[StorageTier] /proc/self/status probe failed: " + e.getMessage());
        } finally {
            try {
                if (reader != null) reader.close();
            } catch (Exception ignored) {}
        }
        selfHasExtDataRw = has;
        return has;
    }

    /** True for paths under another app's /Android/data/ or /Android/obb/ (Android 11+). */
    static boolean isRestrictedPath(String path) {
        if (path == null || path.isEmpty()) return false;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false;
        return path.contains("/Android/data/") || path.contains("/Android/obb/");
    }

    /** Extracts the owning package from an /Android/data|<obb>/<pkg>/... path, or null. */
    static String restrictedPackage(String path) {
        if (path == null) return null;
        final String[] markers = {"/Android/data/", "/Android/obb/"};
        for (String marker : markers) {
            int idx = path.indexOf(marker);
            if (idx >= 0) {
                String rest = path.substring(idx + marker.length());
                int slash = rest.indexOf('/');
                String pkg = slash >= 0 ? rest.substring(0, slash) : rest;
                return pkg.isEmpty() ? null : pkg;
            }
        }
        return null;
    }

    /**
     * The package's data-dir root for a restricted path
     * (/storage/emulated/0/Android/data/com.foo), or null.
     */
    private static String restrictedPackageDir(String path) {
        String pkg = restrictedPackage(path);
        if (pkg == null) return null;
        final String[] markers = {"/Android/data/", "/Android/obb/"};
        for (String marker : markers) {
            int idx = path.indexOf(marker);
            if (idx >= 0) {
                return path.substring(0, idx + marker.length()) + pkg;
            }
        }
        return null;
    }

    /**
     * True when a persisted read+write document-tree grant covers the path.
     * On stock Android 13+ the bare manage=true URIs are rejected, so this is
     * the exact SAF-viability test there; eng/userdebug firmwares that accept
     * bare URIs also accept them alongside any grant.
     */
    static boolean hasGrantCoverage(Context context, String path) {
        long t0 = SafPerf.start();
        try { return hasGrantCoverageImpl(context, path); }
        finally { SafPerf.record("grantCoverage", t0); }
    }

    private static boolean hasGrantCoverageImpl(Context context, String path) {
        if (context == null || path == null) return false;
        try {
            for (String prefix : grantBases(context)) {
                if (path.equals(prefix) || path.startsWith(prefix + "/")) {
                    return true;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "[StorageTier] grant coverage check failed: " + e.getMessage());
        }
        return false;
    }

    // Decoded grant path prefixes, cached for the session: reading persisted
    // URI permissions is itself a binder call, and tierFor runs per op.
    // Invalidated when a new grant is taken (KyodaiBridgePlugin SAF result).
    private static volatile java.util.ArrayList<String> grantBasesCache = null;

    static void invalidateGrantBases() {
        grantBasesCache = null;
    }

    private static java.util.ArrayList<String> grantBases(Context context) {
        java.util.ArrayList<String> bases = grantBasesCache;
        if (bases != null) return bases;
        bases = new java.util.ArrayList<>();
        for (UriPermission p : context.getContentResolver().getPersistedUriPermissions()) {
            if (!p.isReadPermission() || !p.isWritePermission()) continue;
            String uri = p.getUri().toString();
            if (!uri.startsWith(DOCS_TREE_PREFIX)) continue;
            String docId;
            try {
                docId = URLDecoder.decode(uri.substring(DOCS_TREE_PREFIX.length()), "UTF-8");
            } catch (Exception e) {
                continue;
            }
            int colon = docId.indexOf(':');
            if (colon <= 0) continue;
            String volume = docId.substring(0, colon);
            String rel = docId.substring(colon + 1);
            String base = volume.equals("primary")
                    ? "/storage/emulated/0" : "/storage/" + volume;
            bases.add(base + "/" + rel);
        }
        grantBasesCache = bases;
        return bases;
    }

    /** The uid of an installed package, or -1 when unknown. */
    static int uidForPackage(Context context, String packageName) {
        try {
            PackageManager pm = context.getPackageManager();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                return pm.getApplicationInfo(packageName, PackageManager.ApplicationInfoFlags.of(0)).uid;
            }
            return pm.getApplicationInfo(packageName, 0).uid;
        } catch (Exception e) {
            Log.w(TAG, "[StorageTier] uid lookup failed for " + packageName + ": " + e.getMessage());
            return -1;
        }
    }

    /**
     * Resolves the write tier for a path. DIRECT means plain File I/O is
     * expected to work; callers still attempt direct first and only consult
     * the tier when that fails, so DIRECT-tier devices keep their exact
     * current behavior (with the SAF code as the transient-failure fallback).
     */
    static int tierFor(Context context, String path) {
        long t0 = SafPerf.start();
        try { return tierForImpl(context, path); }
        finally { SafPerf.record("tierFor", t0); }
    }

    private static int tierForImpl(Context context, String path) {
        if (!isRestrictedPath(path)) return TIER_DIRECT;
        if (selfHasExtDataRw()) return TIER_DIRECT;
        if (hasGrantCoverage(context, path)) return TIER_SAF;
        if (RootShell.isAvailable(context)) return TIER_ROOT;
        // No route can succeed; SAF fails loudly and the GDScript grant-prompt
        // flow owns the recovery UX.
        return TIER_SAF;
    }

    /**
     * The access route for a path, for GDScript flow decisions (prompt for a
     * grant, stage a download, proceed). Unlike tierFor - which folds "no
     * route" into TIER_SAF so ops fail loudly - this distinguishes ROUTE_NONE
     * (no grant coverage, no direct I/O, no root) from a viable SAF route.
     */
    static int accessRouteFor(Context context, String path) {
        long t0 = SafPerf.start();
        try {
            int tier = tierForImpl(context, path);
            if (tier == TIER_SAF && !hasGrantCoverageImpl(context, path)) {
                return ROUTE_NONE;
            }
            return tier;
        } finally { SafPerf.record("accessRoute", t0); }
    }

    static String tierName(int tier) {
        switch (tier) {
            case TIER_DIRECT: return "direct";
            case TIER_SAF: return "saf";
            case TIER_ROOT: return "root";
            case ROUTE_NONE: return "none";
            default: return "unknown";
        }
    }

    /** One-line per-op diagnostic for writes into restricted paths. */
    static void logOp(String op, String path, int tier) {
        String pkg = restrictedPackage(path);
        Log.i(TAG, "[StorageTier] op=" + op + " tier=" + tierName(tier)
                + (pkg != null ? " target=" + pkg : "") + " path=" + path);
    }

    /**
     * Best-effort ownership repair after a SAF-tier write: SAF files land
     * provider-owned (com.android.externalstorage:ext_data_rw, 0660), which a
     * target holding ext_data_rw reads fine - but a target without it cannot
     * read at all. When the vendor root daemon is alive, chown the written
     * path (recursively) plus any ancestor dirs the provider created, up to
     * and including the package dir, to the target's uid. Failures are silent
     * by design: the write itself already succeeded for 1078-holding targets.
     */
    static void chownToOwnerBestEffort(Context context, String path) {
        if (context == null || path == null) return;
        String pkg = restrictedPackage(path);
        String pkgDir = restrictedPackageDir(path);
        if (pkg == null || pkgDir == null) return;
        if (!RootShell.isAvailable(context)) return;
        int uid = uidForPackage(context, pkg);
        if (uid < 0) return;
        String owner = uid + ":" + EXT_DATA_RW_GID;
        StringBuilder sb = new StringBuilder();
        // The written path itself (deep).
        sb.append("[ -e ").append(RootShell.quote(path)).append(" ] && chown -R ")
                .append(owner).append(" ").append(RootShell.quote(path)).append("\n");
        // Ancestors the provider may have created, stopping at the package dir
        // and at the first ancestor already owned by the target.
        sb.append("p=").append(RootShell.quote(path)).append("\n");
        sb.append("pkgd=").append(RootShell.quote(pkgDir)).append("\n");
        sb.append("while [ \"$p\" != \"$pkgd\" ] && [ \"$p\" != \"/\" ]; do\n");
        sb.append("  p=$(dirname \"$p\")\n");
        sb.append("  o=$(stat -c %u \"$p\" 2>/dev/null) || break\n");
        sb.append("  [ \"$o\" = \"").append(uid).append("\" ] && break\n");
        sb.append("  chown ").append(owner).append(" \"$p\"\n");
        sb.append("done\n");
        sb.append("exit 0\n");
        RootShell.Result result = RootShell.run(context, sb.toString());
        if (result == null && !chownFailureLogged) {
            chownFailureLogged = true;
            Log.d(TAG, "[StorageTier] post-SAF chown unavailable (daemon down); "
                    + "SAF files stay provider-owned");
        }
    }

    // ------------------------------------------------------------------
    // Root-tier operations (vendor daemon; result chowned to the target uid)
    // ------------------------------------------------------------------

    /** Writes a small file as root and chowns it (plus any root-created parents) to the target. */
    static boolean rootWriteFile(Context context, String path, byte[] data) {
        if (data.length > ROOT_INLINE_WRITE_MAX) {
            Log.e(TAG, "[StorageTier] rootWriteFile: refusing inline write of " + data.length + " bytes");
            return false;
        }
        String parent = path.substring(0, path.lastIndexOf('/'));
        String b64 = Base64.encodeToString(data, Base64.NO_WRAP);
        StringBuilder sb = new StringBuilder();
        sb.append("mkdir -p ").append(RootShell.quote(parent)).append("\n");
        sb.append("echo ").append(RootShell.quote(b64)).append(" | base64 -d > ").append(RootShell.quote(path)).append("\n");
        sb.append("rc=$?\n");
        sb.append(chownScript(context, path, false));
        sb.append("exit $rc\n");
        RootShell.Result result = RootShell.run(context, sb.toString());
        return result != null && result.succeeded();
    }

    /** Creates a directory tree as root and chowns the new segments to the target. */
    static boolean rootMkdirs(Context context, String path) {
        StringBuilder sb = new StringBuilder();
        sb.append("mkdir -p ").append(RootShell.quote(path)).append("\n");
        sb.append("rc=$?\n");
        sb.append(chownScript(context, path, false));
        sb.append("exit $rc\n");
        RootShell.Result result = RootShell.run(context, sb.toString());
        return result != null && result.succeeded();
    }

    /** Moves a file or directory as root and chowns the moved tree to the target. */
    static boolean rootMove(Context context, String sourcePath, String destPath) {
        String parent = destPath.substring(0, destPath.lastIndexOf('/'));
        StringBuilder sb = new StringBuilder();
        sb.append("mkdir -p ").append(RootShell.quote(parent)).append("\n");
        sb.append("mv ").append(RootShell.quote(sourcePath)).append(" ").append(RootShell.quote(destPath)).append("\n");
        sb.append("rc=$?\n");
        sb.append(chownScript(context, destPath, true));
        sb.append("exit $rc\n");
        RootShell.Result result = RootShell.run(context, sb.toString());
        return result != null && result.succeeded();
    }

    /** Copies a single file as root and chowns the copy to the target. */
    static boolean rootCopyFile(Context context, String sourcePath, String destPath) {
        String parent = destPath.substring(0, destPath.lastIndexOf('/'));
        StringBuilder sb = new StringBuilder();
        sb.append("mkdir -p ").append(RootShell.quote(parent)).append("\n");
        sb.append("cp ").append(RootShell.quote(sourcePath)).append(" ").append(RootShell.quote(destPath)).append("\n");
        sb.append("rc=$?\n");
        sb.append(chownScript(context, destPath, false));
        sb.append("exit $rc\n");
        RootShell.Result result = RootShell.run(context, sb.toString());
        return result != null && result.succeeded();
    }

    /** Recursively deletes as root. */
    static boolean rootDelete(Context context, String path) {
        RootShell.Result result = RootShell.run(context,
                "rm -rf " + RootShell.quote(path) + "\nexit $?\n");
        return result != null && result.succeeded();
    }

    /**
     * Moves an extraction staging tree into the restricted destination as root
     * and chowns everything to the destination package's uid. The staging dir
     * is removed afterwards (direct delete - it lives in our own storage).
     */
    static boolean rootFinalizeExtraction(Context context, String stagingDir, String destDir) {
        StringBuilder sb = new StringBuilder();
        sb.append("mkdir -p ").append(RootShell.quote(destDir)).append("\n");
        sb.append("cp -a ").append(RootShell.quote(stagingDir + "/.")).append(" ")
                .append(RootShell.quote(destDir)).append("\n");
        sb.append("rc=$?\n");
        sb.append(chownScript(context, destDir, true));
        sb.append("exit $rc\n");
        RootShell.Result result = RootShell.run(context, sb.toString());
        boolean ok = result != null && result.succeeded();
        // Staging is in our own external files dir - plain delete works.
        deleteRecursively(new java.io.File(stagingDir));
        return ok;
    }

    /**
     * chowns the path to the destination package's uid (+ ext_data_rw group,
     * matching the FUSE-forged neighborhood), then walks up and chowns any
     * root-owned ancestors our mkdir -p created, stopping at the first
     * ancestor not owned by root. No-op when the package/uid is unknown.
     */
    private static String chownScript(Context context, String path, boolean recursive) {
        String pkg = restrictedPackage(path);
        if (pkg == null) return "";
        int uid = uidForPackage(context, pkg);
        if (uid < 0) return "";
        String owner = uid + ":" + EXT_DATA_RW_GID;
        String quoted = RootShell.quote(path);
        StringBuilder sb = new StringBuilder();
        sb.append("[ $rc -eq 0 ] && chown ").append(recursive ? "-R " : "")
                .append(owner).append(" ").append(quoted).append("\n");
        sb.append("p=$(dirname ").append(quoted).append(")\n");
        sb.append("while [ -d \"$p\" ] && [ \"$(stat -c %u \"$p\")\" = \"0\" ]; do\n");
        sb.append("  chown ").append(owner).append(" \"$p\"\n");
        sb.append("  p=$(dirname \"$p\")\n");
        sb.append("done\n");
        return sb.toString();
    }

    private static void deleteRecursively(java.io.File f) {
        if (f.isDirectory()) {
            java.io.File[] children = f.listFiles();
            if (children != null) {
                for (java.io.File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        f.delete();
    }
}

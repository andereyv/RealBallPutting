package com.godot.game;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Putting-corridor ball tracker (pure Java, no Android dependencies).
 *
 * Extracted from HeadsetCameraBridge so exactly the same code runs on the Quest and in the Mac replay
 * (tools/replay). The bridge feeds camera frames and forwards the Godot API calls; everything Android-specific
 * (logging, exposure lock, dashboard snapshots, session recorder) goes through {@link Hooks}.
 */
public class PuttTracker {

    public interface Hooks {
        void log(String msg);
        void setExposureLock(boolean locked);
        void event(String json);
        void runAsync(Runnable r);
        void renderDashboard(int w, int h, int rowStride, int pxStride, List<HighSpeedPoint> pts,
                             byte[] frame1, float sx1, float sy1,
                             byte[] frame2, float sx2, float sy2,
                             byte[] frame3, byte[] u3, byte[] v3, float sx3, float sy3,
                             boolean hasColor, int uStride, int uPx, int vStride, int vPx,
                             float speedMps, float angleDeg, float fps);
    }

    /** Clock used for latency / sample age (the Quest uses System.nanoTime; replay injects the recorded arrival time). */
    public static java.util.function.LongSupplier nanoClock = System::nanoTime;
    /** CLOCK_BOOTTIME source (the bridge installs SystemClock.elapsedRealtimeNanos on Android). */
    public static java.util.function.LongSupplier bootClockNs = System::nanoTime;
    /** If >= 0, used as sensor->processing latency instead of estimating it (replay). */
    public static long latencyOverrideNs = -1;

    public Hooks hooks;

    // Colour planes and frame counter of the current frame (set by the caller before processHighSpeedCorridorFrame)
    public byte[] latestUBuffer = null, latestVBuffer = null;
    public boolean hasColorPlanes = false;
    public int uPixelStride = 0, vPixelStride = 0, uRowStride = 0, vRowStride = 0;
    public long frameCount = 0;

    private void log(String msg) { if (hooks != null) hooks.log(msg); }
    private void logE(String msg) { if (hooks != null) hooks.log("ERROR " + msg); }
    private void logE(String msg, Throwable t) { if (hooks != null) hooks.log("ERROR " + msg + ": " + t); }
    private void exposureLock(boolean locked) { if (hooks != null) hooks.setExposureLock(locked); }

    /** Mean of the (2r+1)^2 box around (cx, cy) from an integral image covering [x0..x1] x [y0..y1] (clamped). */
    static float boxMean(long[] integ, int iw, int x0, int y0, int x1, int y1, int cx, int cy, int r) {
        int ax = Math.max(x0, cx - r) - x0, bx = Math.min(x1, cx + r) - x0 + 1;
        int ay = Math.max(y0, cy - r) - y0, by = Math.min(y1, cy + r) - y0 + 1;
        long sum = integ[by * iw + bx] - integ[ay * iw + bx] - integ[by * iw + ax] + integ[ay * iw + ax];
        int n = (bx - ax) * (by - ay);
        return n > 0 ? (float) sum / n : 0f;
    }

    /** Mean of the square ring between box radius rA (exclusive) and rB (inclusive), clamped like boxMean. */
    static float ringMean(long[] integ, int iw, int x0, int y0, int x1, int y1, int cx, int cy, int rA, int rB) {
        int axB = Math.max(x0, cx - rB) - x0, bxB = Math.min(x1, cx + rB) - x0 + 1;
        int ayB = Math.max(y0, cy - rB) - y0, byB = Math.min(y1, cy + rB) - y0 + 1;
        int axA = Math.max(x0, cx - rA) - x0, bxA = Math.min(x1, cx + rA) - x0 + 1;
        int ayA = Math.max(y0, cy - rA) - y0, byA = Math.min(y1, cy + rA) - y0 + 1;
        long sB = integ[byB * iw + bxB] - integ[ayB * iw + bxB] - integ[byB * iw + axB] + integ[ayB * iw + axB];
        long sA = integ[byA * iw + bxA] - integ[ayA * iw + bxA] - integ[byA * iw + axA] + integ[ayA * iw + axA];
        int n = (bxB - axB) * (byB - ayB) - (bxA - axA) * (byA - ayA);
        return n > 0 ? (float) (sB - sA) / n : 0f;
    }

    /** Integral image of the luminance over [ix0..ix1] x [iy0..iy1] (inclusive); row width = ix1 - ix0 + 2. */
    static long[] integral(byte[] yb, int rowStride, int pxStride, int ix0, int iy0, int ix1, int iy1) {
        int iw = ix1 - ix0 + 2, ih = iy1 - iy0 + 2;
        long[] integ = new long[iw * ih];
        for (int yy = 1; yy < ih; yy++) {
            long rowSum = 0;
            int rowOff = (iy0 + yy - 1) * rowStride;
            for (int xx = 1; xx < iw; xx++) {
                rowSum += yb[rowOff + (ix0 + xx - 1) * pxStride] & 0xFF;
                integ[yy * iw + xx] = integ[(yy - 1) * iw + xx] + rowSum;
            }
        }
        return integ;
    }

    /**
     * Fix 14: roundness of the bright spot at (cx, cy): sqrt of the ratio of the principal second moments of the
     * pixels above thr inside a circle of radius r+1. A ball is ~1.0-1.5 (a little more when motion-blurred); the
     * white alignment line on a putter head is compact too, but elongated (rec_20260921_202308 @ 61.5 s).
     */
    static float elongation(byte[] yb, int w, int h, int rowStride, int pxStride, int cx, int cy, float r, int thr) {
        int rr = Math.round(r) + 1;
        double n = 0, sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
        for (int yy = Math.max(2, cy - rr); yy <= Math.min(h - 3, cy + rr); yy++) {
            int rowOff = yy * rowStride;
            for (int xx = Math.max(2, cx - rr); xx <= Math.min(w - 3, cx + rr); xx++) {
                int dx = xx - cx, dy = yy - cy;
                if (dx * dx + dy * dy > rr * rr || (yb[rowOff + xx * pxStride] & 0xFF) < thr) continue;
                n++; sx += dx; sy += dy; sxx += dx * dx; syy += dy * dy; sxy += dx * dy;
            }
        }
        if (n < 8) return 99f;
        double mx = sx / n, my = sy / n;
        double a = sxx / n - mx * mx, c = syy / n - my * my, b = sxy / n - mx * my;
        double tr = a + c, det = a * c - b * b, disc = Math.sqrt(Math.max(0, tr * tr / 4 - det));
        double l1 = tr / 2 + disc, l2 = tr / 2 - disc;
        return l2 <= 1e-6 ? 99f : (float) Math.sqrt(l1 / l2);
    }

    /** A candidate ball: centre-vs-ring contrast and where it sits. */
    static final class BlobHit {
        float score, in, ring, outer, x, y; int count;
    }

    /**
     * Fix 14 (plain floors): find a golf ball as a small COMPACT bright spot. Centre box vs a ring just outside a
     * ball of radius r gives the contrast; that ring vs a wider outer ring must look alike (right outside a real ball
     * is floor). A lamp reflection or a light plank is still bright in the ring, so it fails the compactness test even
     * when it is brighter than the ball (rec_20260921_202308: reflection 5 cm from the ball, wood floor, evening).
     * The centre is then refined to the centroid of the pixels above the half-contrast level.
     * fwd/lat masks (in image-normalised units) restrict candidates to the putting corridor when maxLatN > 0; with
     * pickForward the forward-most candidate wins (the ball leads the putter); with nearX >= 0 the one closest to
     * (nearX, nearY) px; otherwise the highest contrast.
     */
    static BlobHit findBlob(byte[] yb, int w, int h, int rowStride, int pxStride,
                            int x0, int y0, int x1, int y1, int step, float r, float minScore,
                            float oX, float oY, float fX, float fY, float minFwdN, float maxFwdN, float maxLatN,
                            boolean pickForward, float nearX, float nearY) {
        x0 = Math.max(2, x0); y0 = Math.max(2, y0); x1 = Math.min(w - 3, x1); y1 = Math.min(h - 3, y1);
        if (x1 < x0 || y1 < y0) return null;
        int rIn = Math.max(2, Math.round(0.45f * r));
        int r0 = Math.round(1.2f * r) + 1;
        int r1 = r0 + Math.max(3, Math.round(0.6f * r));
        int o0 = r1 + 2;
        int o1 = o0 + Math.max(4, Math.round(0.8f * r));
        int ix0 = Math.max(0, x0 - o1 - 1), ix1 = Math.min(w - 1, x1 + o1 + 1);
        int iy0 = Math.max(0, y0 - o1 - 1), iy1 = Math.min(h - 1, y1 + o1 + 1);
        long[] integ = integral(yb, rowStride, pxStride, ix0, iy0, ix1, iy1);
        int iw = ix1 - ix0 + 2;
        BlobHit best = null;
        float bestKey = -Float.MAX_VALUE;
        for (int cy = y0; cy <= y1; cy += step) {
            for (int cx = x0; cx <= x1; cx += step) {
                float fwd = 0f, lat = 0f;
                if (maxLatN > 0f) {
                    float nx = (float) cx / w - oX, ny = (float) cy / h - oY;
                    fwd = nx * fX + ny * fY;
                    lat = Math.abs(-nx * fY + ny * fX);
                    if (fwd < minFwdN || fwd > maxFwdN || lat > maxLatN) continue;
                }
                float in = boxMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, rIn);
                float ring = ringMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, r0, r1);
                float score = in - ring;
                if (score < minScore) continue;
                float key = nearX >= 0f ? -((cx - nearX) * (cx - nearX) + (cy - nearY) * (cy - nearY))
                        : pickForward ? (fwd - 0.5f * lat) : score;
                if (best != null && key <= bestKey) continue;
                float outer = ringMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, o0, o1);
                if (ring - outer > 0.35f * score + 4f) continue; // not compact: reflection, plank, shoe
                if (elongation(yb, w, h, rowStride, pxStride, cx, cy, r, Math.round(ring + 0.5f * score)) > 1.8f) continue; // not round
                if (best == null) best = new BlobHit();
                best.score = score; best.in = in; best.ring = ring; best.outer = outer; best.x = cx; best.y = cy;
                bestKey = key;
            }
        }
        if (best == null) return null;
        // refine to the contrast PEAK (step-1 search around the pick, then sub-pixel parabola). Not the centroid of
        // bright pixels: a lamp glow next to the ball dragged that centroid ~20 px (5 cm) off the ball.
        int pcx = Math.round(best.x), pcy = Math.round(best.y);
        float ps = best.score;
        for (int yy = pcy - step; yy <= pcy + step; yy++) {
            for (int xx = pcx - step; xx <= pcx + step; xx++) {
                if (xx < ix0 + 1 || yy < iy0 + 1 || xx > ix1 - 1 || yy > iy1 - 1) continue;
                float sc = boxMean(integ, iw, ix0, iy0, ix1, iy1, xx, yy, rIn) - ringMean(integ, iw, ix0, iy0, ix1, iy1, xx, yy, r0, r1);
                if (sc > ps) { ps = sc; pcx = xx; pcy = yy; }
            }
        }
        float fx = pcx, fy = pcy;
        if (pcx - 1 >= ix0 + 1 && pcx + 1 <= ix1 - 1) {
            float sl = boxMean(integ, iw, ix0, iy0, ix1, iy1, pcx - 1, pcy, rIn) - ringMean(integ, iw, ix0, iy0, ix1, iy1, pcx - 1, pcy, r0, r1);
            float sr = boxMean(integ, iw, ix0, iy0, ix1, iy1, pcx + 1, pcy, rIn) - ringMean(integ, iw, ix0, iy0, ix1, iy1, pcx + 1, pcy, r0, r1);
            float den = sl - 2f * ps + sr;
            if (den < -1e-3f) fx += Math.max(-0.5f, Math.min(0.5f, 0.5f * (sl - sr) / den));
        }
        if (pcy - 1 >= iy0 + 1 && pcy + 1 <= iy1 - 1) {
            float su = boxMean(integ, iw, ix0, iy0, ix1, iy1, pcx, pcy - 1, rIn) - ringMean(integ, iw, ix0, iy0, ix1, iy1, pcx, pcy - 1, r0, r1);
            float sd = boxMean(integ, iw, ix0, iy0, ix1, iy1, pcx, pcy + 1, rIn) - ringMean(integ, iw, ix0, iy0, ix1, iy1, pcx, pcy + 1, r0, r1);
            float den = su - 2f * ps + sd;
            if (den < -1e-3f) fy += Math.max(-0.5f, Math.min(0.5f, 0.5f * (su - sd) / den));
        }
        best.x = fx; best.y = fy; best.score = Math.max(best.score, ps);
        // size: pixels above half contrast inside the ball circle (only used for plausibility checks)
        int thr = Math.round(best.ring + 0.5f * best.score);
        int rr = Math.round(r) + 1, cnt = 0;
        for (int yy = Math.max(2, pcy - rr); yy <= Math.min(h - 3, pcy + rr); yy++) {
            int rowOff = yy * rowStride;
            for (int xx = Math.max(2, pcx - rr); xx <= Math.min(w - 3, pcx + rr); xx++) {
                int ddx = xx - pcx, ddy = yy - pcy;
                if (ddx * ddx + ddy * ddy <= rr * rr && (yb[rowOff + xx * pxStride] & 0xFF) >= thr) cnt++;
            }
        }
        best.count = cnt;
        return best;
    }

    /** All compact spots in the box (see findBlob), strongest first, at most one per ball-sized neighbourhood. */
    static java.util.List<BlobHit> findBlobs(byte[] yb, int w, int h, int rowStride, int pxStride,
                                             int x0, int y0, int x1, int y1, float r, float minScore, int maxN) {
        java.util.List<BlobHit> out = new java.util.ArrayList<>();
        x0 = Math.max(2, x0); y0 = Math.max(2, y0); x1 = Math.min(w - 3, x1); y1 = Math.min(h - 3, y1);
        if (x1 < x0 || y1 < y0) return out;
        int rIn = Math.max(2, Math.round(0.45f * r));
        int r0 = Math.round(1.2f * r) + 1;
        int r1 = r0 + Math.max(3, Math.round(0.6f * r));
        int o0 = r1 + 2;
        int o1 = o0 + Math.max(4, Math.round(0.8f * r));
        int ix0 = Math.max(0, x0 - o1 - 1), ix1 = Math.min(w - 1, x1 + o1 + 1);
        int iy0 = Math.max(0, y0 - o1 - 1), iy1 = Math.min(h - 1, y1 + o1 + 1);
        long[] integ = integral(yb, rowStride, pxStride, ix0, iy0, ix1, iy1);
        int iw = ix1 - ix0 + 2;
        int bw = x1 - x0 + 1, bh = y1 - y0 + 1;
        float[] sc = new float[bw * bh];
        for (int cy = y0; cy <= y1; cy++) {
            for (int cx = x0; cx <= x1; cx++) {
                float in = boxMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, rIn);
                float ring = ringMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, r0, r1);
                float score = in - ring;
                if (score < minScore) continue;
                float outer = ringMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, o0, o1);
                if (ring - outer > 0.35f * score + 4f) continue;
                if (elongation(yb, w, h, rowStride, pxStride, cx, cy, r, Math.round(ring + 0.5f * score)) > 1.8f) continue;
                sc[(cy - y0) * bw + (cx - x0)] = score;
            }
        }
        int sup = Math.max(4, Math.round(1.6f * r));
        for (int k = 0; k < maxN; k++) {
            int bi = -1; float bs = 0f;
            for (int i = 0; i < sc.length; i++) if (sc[i] > bs) { bs = sc[i]; bi = i; }
            if (bi < 0) break;
            int px = x0 + bi % bw, py = y0 + bi / bw;
            BlobHit b = findBlob(yb, w, h, rowStride, pxStride, px, py, px, py, 1, r, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f,
                    false, -1f, -1f);
            if (b != null) { b.score = bs; out.add(b); }
            for (int yy = Math.max(0, py - y0 - sup); yy <= Math.min(bh - 1, py - y0 + sup); yy++)
                for (int xx = Math.max(0, px - x0 - sup); xx <= Math.min(bw - 1, px - x0 + sup); xx++) sc[yy * bw + xx] = 0f;
        }
        return out;
    }

    public boolean isActive() { return hsState == HS_STATE_ARMED || hsState == HS_STATE_TRACKING; }

    /** Times a stroke was seen but the ball was lost before it could be measured (drives "putt not measured"). */
    public volatile int hsLostPuttCount = 0; // ball was rolling (tracked) and then lost -> Godot shows "putt not measured"

    /** For the game's "ball seen" light: [state, anchored 0/1, ball contrast vs floor (grey levels), lost-putt count]. */
    public float[] statusSnapshot() {
        boolean a = hsAnchored;
        float contrast = (a && hsBallRefLum >= 0 && hsMatRefLum >= 0) ? (hsBallRefLum - hsMatRefLum) : 0f;
        return new float[]{hsState, a ? 1f : 0f, contrast, hsLostPuttCount};
    }

    // =========================================================================
    // HIGH-SPEED CLASSICAL CV PUTTING CORRIDOR TRACKER (60-90 Hz, ~0.1 ms latency)
    // =========================================================================
    public static final int HS_STATE_IDLE = 0;
    public static final int HS_STATE_ARMED = 1;
    public static final int HS_STATE_TRACKING = 2;
    public static final int HS_STATE_FINISHED = 3;

    public volatile int hsState = HS_STATE_IDLE;
    float hsMinX = 0f, hsMinY = 0f, hsMaxX = 1f, hsMaxY = 1f;
    float hsStartNormX = 0f, hsStartNormY = 0f;
    float hsFwdNormX = 0f, hsFwdNormY = 0f;
    float hsMetersPerNormUnit = 1.0f;
    float hsCorridorLengthNorm = 0.20f;
    float currentBallNormX = 0f, currentBallNormY = 0f;
    // Fix 2: self-anchoring. The ball must be seen resting for a few frames, and impact is then measured
    // from where the ball ACTUALLY is in the image, not from Godot's projected tee spot (which can be ~2-3 cm off).
    volatile boolean hsAnchored = false;
    int hsStationaryFrames = 0;
    // Fix 10: head-motion compensation. Godot re-projects the tee spot every frame; how much that projection moves
    // in the image is exactly how much the resting ball moves because the head moved. Shift the anchor by the same
    // amount, so a head turn doesn't leave the anchor behind (rec_20260920_143646: 96 px head motion -> missed putt).
    float hsProjStartX = -1f, hsProjStartY = -1f;
    int hsAnchorMissFrames = 0;
    float hsBallRadiusPx = 7f; // measured from the anchored ball's pixel count
    float hsAnchorScore = 0f;   // Fix 14: centre-vs-ring contrast of the anchored ball
    long hsAnchorMissStartNs = 0L;
    float hsRestNormX = -1f, hsRestNormY = -1f; // Fix 14: anchored rest position, moved only by head compensation
    java.util.List<float[]> hsPrevSpots = null;  // Fix 14: compact spots in the corridor last frame (head-compensated)
    float hsCandNormX = -1f, hsCandNormY = -1f;  // Fix 14: last anchoring candidate (stillness test)
    /** Fix 14: ball contrast below this (grey levels) = "plain floor" mode: compact-spot detection while rolling. */
    static final int LOW_CONTRAST_LEVELS = 60;
    static final float ANCHOR_MIN_SCORE = 14f;
    static final long ANCHOR_LOST_NS = 500_000_000L; // was 8 frames: only 0.13 s at the 60 fps seen on 2026-09-21
    // Godot's projected tee spot over time (nanoClock domain). Measured on rec_20260920_143646: the ball's image
    // motion matches the projection taken 25 ms BEFORE the frame's capture time (residual 0.8 px vs 23 px raw).
    static final long PROJ_LAG_NS = 25_000_000L;
    final long[] projT = new long[256];
    final float[] projX = new float[256], projY = new float[256];
    int projCount = 0, projHead = 0;
    boolean hsCompValid = false;
    float hsPrevProjX = 0f, hsPrevProjY = 0f;
    /** Accumulated head-motion shift applied since arming (image norm units); stored per point for step math. */
    float hsCompX = 0f, hsCompY = 0f;

    void pushProjection(long t, float x, float y) {
        projT[projHead] = t; projX[projHead] = x; projY[projHead] = y;
        projHead = (projHead + 1) % projT.length;
        if (projCount < projT.length) projCount++;
    }

    void resetProjection() {
        projCount = 0; projHead = 0; hsCompValid = false; hsCompX = 0f; hsCompY = 0f;
    }

    /** Interpolated projected tee spot at time t; returns null if t is outside the history. */
    float[] projectionAt(long t) {
        if (projCount < 2) return null;
        int newest = (projHead - 1 + projT.length) % projT.length;
        int oldest = (projHead - projCount + projT.length) % projT.length;
        if (t < projT[oldest] || t > projT[newest] + 50_000_000L) return null;
        int idx = newest;
        for (int k = 0; k < projCount - 1; k++) {
            int prev = (idx - 1 + projT.length) % projT.length;
            if (projT[prev] <= t) {
                long span = projT[idx] - projT[prev];
                float a = (span > 0 && t <= projT[idx]) ? (float) (t - projT[prev]) / span : 1f;
                return new float[]{projX[prev] + a * (projX[idx] - projX[prev]), projY[prev] + a * (projY[idx] - projY[prev])};
            }
            idx = prev;
        }
        return null;
    }
    static final int HS_MIN_STATIONARY_FRAMES = 5;
    static final int HS_MIN_REAL_POINTS = 3;
    int hsDiagCount = 0, hsDiagBw = 0, hsDiagBh = 0;

    public static class HighSpeedPoint {
        public final float normX, normY;
        public final float cropPixelX, cropPixelY;
        public final float fwdDistNorm;
        public final int pixelArea;
        public final long timestampNs;
        // Speed v2: synthetic points (e.g. the assumed tee position) are excluded from the fit
        public final boolean synthetic;
        // Speed v2: System.nanoTime() when the frame was processed + sensor->processing latency,
        // used to align camera samples with Godot head poses
        public final long arrivalNanoTime;
        public final long captureLatencyNs;
        /** Accumulated head-motion compensation when this point was measured (image norm units). */
        public float compX = 0f, compY = 0f;

        public HighSpeedPoint(float nx, float ny, float cpx, float cpy, float fwd, int area, long tNs) {
            this(nx, ny, cpx, cpy, fwd, area, tNs, false);
        }

        public HighSpeedPoint(float nx, float ny, float cpx, float cpy, float fwd, int area, long tNs, boolean synthetic) {
            this.normX = nx;
            this.normY = ny;
            this.cropPixelX = cpx;
            this.cropPixelY = cpy;
            this.fwdDistNorm = fwd;
            this.pixelArea = area;
            this.timestampNs = tNs;
            this.synthetic = synthetic;
            this.arrivalNanoTime = nanoClock.getAsLong();
            this.captureLatencyNs = (latencyOverrideNs >= 0) ? latencyOverrideNs : estimateCaptureLatencyNs(tNs);
        }
    }

    /**
     * Camera sensor timestamps are either CLOCK_BOOTTIME (elapsedRealtimeNanos) or CLOCK_MONOTONIC (nanoTime)
     * depending on SENSOR_INFO_TIMESTAMP_SOURCE. Pick whichever clock gives a plausible latency.
     */
    public static long estimateCaptureLatencyNs(long sensorTsNs) {
        final long maxPlausible = 300_000_000L;
        long dBoot = bootClockNs.getAsLong() - sensorTsNs;
        long dMono = nanoClock.getAsLong() - sensorTsNs;
        if (dBoot >= 0 && dBoot <= maxPlausible) return dBoot;
        if (dMono >= 0 && dMono <= maxPlausible) return dMono;
        return 30_000_000L; // fallback: typical Quest passthrough camera pipeline latency
    }

    /**
     * Speed v2: raw tracked samples of the last putt for metric floor-plane reconstruction in Godot.
     * Layout: [count, then per real (non-synthetic) point: t_rel_sec, age_sec, norm_x, norm_y]
     *  - t_rel_sec: sensor-timestamp time relative to the first real point (precise inter-frame timing)
     *  - age_sec:   how long ago (from now) the frame was exposed, for matching the head pose
     */

    public float[] getHighSpeedSamples() {
        List<HighSpeedPoint> pts = new ArrayList<>(hsLastPuttPoints);
        List<HighSpeedPoint> real = new ArrayList<>();
        for (HighSpeedPoint p : pts) if (!p.synthetic) real.add(p);
        float[] out = new float[1 + real.size() * 4];
        out[0] = real.size();
        if (real.isEmpty()) return out;
        long t0 = real.get(0).timestampNs;
        long now = nanoClock.getAsLong();
        for (int i = 0; i < real.size(); i++) {
            HighSpeedPoint p = real.get(i);
            out[1 + i * 4] = (p.timestampNs - t0) / 1_000_000_000.0f;
            out[2 + i * 4] = ((now - p.arrivalNanoTime) + p.captureLatencyNs) / 1_000_000_000.0f;
            out[3 + i * 4] = p.normX;
            out[4 + i * 4] = p.normY;
        }
        return out;
    }

    final List<HighSpeedPoint> hsPoints = new java.util.concurrent.CopyOnWriteArrayList<>();
    volatile List<HighSpeedPoint> hsLastPuttPoints = new ArrayList<>();
    int hsConsecutiveLostFrames = 0;

    public volatile boolean isHsPuttReady = false;
    public final float[] hsTelemetryResult = new float[6]; // [speed_mps, angle_deg, sample_count, dt_sec, end_norm_x, end_norm_y]

    byte[] hsSnippetFrame1 = null, hsSnippetFrame2 = null, hsSnippetFrame3 = null;
    byte[] hsSnippetU3 = null, hsSnippetV3 = null;
    float hsSnippetNormX1, hsSnippetNormY1;
    float hsSnippetNormX2, hsSnippetNormY2;
    float hsSnippetNormX3, hsSnippetNormY3;

    // Multi-color ball appearance baseline sampled at address
    int hsBallRefLum = -1;
    int hsBallRefU = -1;
    int hsBallRefV = -1;
    int hsMatRefLum = -1;
    int hsMatRefU = -1;
    int hsMatRefV = -1;
    int hsBallDetectionMode = 0; // 0=contrast, 1=bright, 2=dark, 3=chroma_distinct






    public void armHighSpeedCorridorInternal(float minX, float minY, float maxX, float maxY,
                                              float startNormX, float startNormY,
                                              float fwdNormX, float fwdNormY,
                                              float metersPerNormUnit, float corridorLengthNorm) {
        if (hooks != null) {
            hooks.event(String.format(Locale.US,
                "{\"type\":\"arm\",\"roi\":[%.5f,%.5f,%.5f,%.5f],\"start\":[%.5f,%.5f],\"fwd\":[%.5f,%.5f],\"m_per_norm\":%.5f,\"len_norm\":%.5f}",
                minX, minY, maxX, maxY, startNormX, startNormY, fwdNormX, fwdNormY, metersPerNormUnit, corridorLengthNorm));
        }
        hsProjStartX = startNormX;
        hsProjStartY = startNormY;
        pushProjection(nanoClock.getAsLong(), startNormX, startNormY);
        // Fix 1: Godot re-arms every frame BEFORE reading the result. Re-arming a FINISHED corridor used to wipe
        // the result (isHsPuttReady=false) before Godot could read it, so real putts were silently lost.
        if (hsState == HS_STATE_TRACKING || hsState == HS_STATE_FINISHED) {
            return;
        }
        this.hsMinX = minX;
        this.hsMinY = minY;
        this.hsMaxX = maxX;
        this.hsMaxY = maxY;
        if (!hsAnchored) {
            // Until the resting ball has been found in the image, use Godot's projected start as a search hint
            this.hsStartNormX = startNormX;
            this.hsStartNormY = startNormY;
        }
        this.hsFwdNormX = fwdNormX;
        this.hsFwdNormY = fwdNormY;
        this.hsMetersPerNormUnit = metersPerNormUnit;
        this.hsCorridorLengthNorm = corridorLengthNorm;

        if (hsState != HS_STATE_ARMED) {
            this.hsState = HS_STATE_ARMED;
            exposureLock(true);
            this.hsPoints.clear();
            this.isHsPuttReady = false;
            this.hsConsecutiveLostFrames = 0;
            this.currentBallNormX = startNormX;
            this.currentBallNormY = startNormY;
            this.hsSnippetFrame1 = null;
            this.hsSnippetFrame2 = null;
            this.hsSnippetFrame3 = null;
            this.hsBallRefLum = -1;
            this.hsBallRefU = -1;
            this.hsBallRefV = -1;
            this.hsMatRefLum = -1;
            this.hsMatRefU = -1;
            this.hsMatRefV = -1;
            this.hsBallDetectionMode = 0;
            this.hsAnchored = false;
            this.hsStationaryFrames = 0;
            this.hsStartNormX = startNormX;
            this.hsStartNormY = startNormY;
            log(String.format(Locale.US,
                "[HIGH-SPEED CV] Corridor armed at start=[%.3f, %.3f], fwd=[%.3f, %.3f], scale=%.2f m/norm",
                startNormX, startNormY, fwdNormX, fwdNormY, metersPerNormUnit));
        }
    }

    public void disarmHighSpeedCorridorInternal() {
        hsProjStartX = -1f; hsProjStartY = -1f; hsAnchorMissFrames = 0; resetProjection();
        if (hooks != null) hooks.event("{\"type\":\"disarm\"}");
        if (hsState != HS_STATE_IDLE) {
            hsState = HS_STATE_IDLE;
            exposureLock(false);
            hsPoints.clear();
            isHsPuttReady = false;
            hsAnchored = false;
            hsStationaryFrames = 0;
            hsBallRefLum = -1;
            log("[HIGH-SPEED CV] Corridor disarmed.");
        }
    }

    public void clearHighSpeedPuttInternal() {
        hsProjStartX = -1f; hsProjStartY = -1f; hsAnchorMissFrames = 0; resetProjection();
        if (hooks != null) hooks.event("{\"type\":\"clear\"}");
        isHsPuttReady = false;
        hsAnchored = false;
        hsStationaryFrames = 0;
        hsPoints.clear();
        hsState = HS_STATE_IDLE;
        hsBallRefLum = -1;
        exposureLock(false);
    }

    public void processHighSpeedCorridorFrame(byte[] yBuffer, int w, int h, int rowStride, int pxStride, long timestampNs) {
        if (yBuffer == null || w <= 0 || h <= 0) return;
        lastRowStride = rowStride; lastPxStride = pxStride;

        // Fix 10: head-motion compensation. Shift the anchor (and, while tracking, the corridor start) by how much
        // the head moved the image since the previous frame, using Godot's tee projection at this frame's capture time.
        {
            long lat = (latencyOverrideNs >= 0) ? latencyOverrideNs : estimateCaptureLatencyNs(timestampNs);
            float[] pr = projectionAt(nanoClock.getAsLong() - lat - PROJ_LAG_NS);
            if (pr != null) {
                if (hsCompValid) {
                    float dx = pr[0] - hsPrevProjX, dy = pr[1] - hsPrevProjY;
                    if (Math.abs(dx) < 0.1f && Math.abs(dy) < 0.1f
                            && ((hsState == HS_STATE_ARMED && hsAnchored) || hsState == HS_STATE_TRACKING)) {
                        hsStartNormX += dx; hsStartNormY += dy;
                        currentBallNormX += dx; currentBallNormY += dy;
                        hsCompX += dx; hsCompY += dy;
                        if (hsRestNormX >= 0f) { hsRestNormX += dx; hsRestNormY += dy; }
                    }
                }
                hsPrevProjX = pr[0]; hsPrevProjY = pr[1]; hsCompValid = true;
            }
        }

        // Thread-safe immutable snapshots of shared camera buffers
        final byte[] uBuf = latestUBuffer;
        final byte[] vBuf = latestVBuffer;
        final int uLen = (uBuf != null) ? uBuf.length : 0;
        final int vLen = (vBuf != null) ? vBuf.length : 0;
        final boolean hasUV = (hasColorPlanes && uBuf != null && vBuf != null && uPixelStride > 0 && vPixelStride > 0);

        // Active putting corridor bounds (from Godot 3D projection)
        int cX0 = Math.max(2, (int) (hsMinX * w));
        int cX1 = Math.min(w - 3, (int) (hsMaxX * w));
        int cY0 = Math.max(2, (int) (hsMinY * h));
        int cY1 = Math.min(h - 3, (int) (hsMaxY * h));
        if (cX1 - cX0 < 10 || cY1 - cY0 < 10) return;

        // Fix 14: while still searching for the resting ball, centre on Godot's projected tee spot. A candidate
        // that wandered to the image edge used to end every frame at the bounds check below, for good
        // (rec_20260920_175353 @ 11.8 s: the putt at 16 s was never armed).
        if (hsState == HS_STATE_ARMED && !hsAnchored && hsProjStartX >= 0f) {
            currentBallNormX = hsProjStartX;
            currentBallNormY = hsProjStartY;
        }
        // Current tracked ball center in image pixels
        int ballPxX = (int) (currentBallNormX * w);
        int ballPxY = (int) (currentBallNormY * h);
        if (ballPxX < 4 || ballPxX >= w - 4 || ballPxY < 4 || ballPxY >= h - 4) return;

        float metersPerNorm = Math.max(0.10f, hsMetersPerNormUnit);
        float normPerMeter = 1.0f / metersPerNorm;

        // 1. Measure background mat brightness directly on the putting mat near the tee spot
        // (Offset laterally ±25 px and forward +25 px to stay strictly on the turf)
        float perpNormX = -hsFwdNormY;
        float perpNormY = hsFwdNormX;
        int matOffsetPx = Math.max(14, (int) (0.040f * normPerMeter * w));
        int s1X = Math.max(2, Math.min(w - 3, ballPxX + (int) (perpNormX * matOffsetPx)));
        int s1Y = Math.max(2, Math.min(h - 3, ballPxY + (int) (perpNormY * matOffsetPx)));
        int s2X = Math.max(2, Math.min(w - 3, ballPxX - (int) (perpNormX * matOffsetPx)));
        int s2Y = Math.max(2, Math.min(h - 3, ballPxY - (int) (perpNormY * matOffsetPx)));
        int s3X = Math.max(2, Math.min(w - 3, ballPxX + (int) (hsFwdNormX * matOffsetPx)));
        int s3Y = Math.max(2, Math.min(h - 3, ballPxY + (int) (hsFwdNormY * matOffsetPx)));
        int bgLum = Math.min(yBuffer[s1Y * rowStride + s1X * pxStride] & 0xFF,
                     Math.min(yBuffer[s2Y * rowStride + s2X * pxStride] & 0xFF,
                              yBuffer[s3Y * rowStride + s3X * pxStride] & 0xFF));
        if ((hsState == HS_STATE_TRACKING || (hsState == HS_STATE_ARMED && hsAnchored)) && hsMatRefLum >= 0) {
            // Fix 6: during the stroke the putter/shoe covers the mat sample points (log: bg jumped 20 -> 91),
            // which pushed the threshold above the ball. Use the mat brightness measured at address instead.
            bgLum = hsMatRefLum;
        }

        // 2. Multi-color adaptive ball appearance sampling at address
        if (hsState == HS_STATE_ARMED && hsBallRefLum < 0) {
            int bSumLum = 0, bCount = 0;
            for (int dy = -4; dy <= 4; dy++) {
                int py = ballPxY + dy;
                if (py < 0 || py >= h) continue;
                int rOff = py * rowStride;
                for (int dx = -4; dx <= 4; dx++) {
                    int px = ballPxX + dx;
                    if (px < 0 || px >= w) continue;
                    bSumLum += (yBuffer[rOff + px * pxStride] & 0xFF);
                    bCount++;
                }
            }
            if (bCount > 0) {
                hsBallRefLum = bSumLum / bCount;
            } else {
                hsBallRefLum = 200; // Fallback to white ball assumption
            }
            hsMatRefLum = bgLum;

            // Sample chroma if YUV color planes are active
            if (hasUV) {
                int uBallSum = 0, vBallSum = 0, uvCount = 0;
                int uRow = uRowStride > 0 ? uRowStride : (w / 2);
                int vRow = vRowStride > 0 ? vRowStride : (w / 2);
                for (int dy = -4; dy <= 4; dy += 2) {
                    int py = ballPxY + dy;
                    int uvY = py / 2;
                    if (uvY < 0) continue;
                    int uOff = uvY * uRow;
                    int vOff = uvY * vRow;
                    for (int dx = -4; dx <= 4; dx += 2) {
                        int px = ballPxX + dx;
                        int uvX = px / 2;
                        int uIdx = uOff + uvX * uPixelStride;
                        int vIdx = vOff + uvX * vPixelStride;
                        if (uIdx >= 0 && uIdx < uLen && vIdx >= 0 && vIdx < vLen) {
                            uBallSum += (uBuf[uIdx] & 0xFF);
                            vBallSum += (vBuf[vIdx] & 0xFF);
                            uvCount++;
                        }
                    }
                }
                if (uvCount > 0) {
                    hsBallRefU = uBallSum / uvCount;
                    hsBallRefV = vBallSum / uvCount;
                }
                int uvX0 = s1X / 2, uvY0 = s1Y / 2;
                int uIdx0 = uvY0 * uRow + uvX0 * uPixelStride;
                int vIdx0 = uvY0 * vRow + uvX0 * vPixelStride;
                if (uIdx0 >= 0 && uIdx0 < uLen && vIdx0 >= 0 && vIdx0 < vLen) {
                    hsMatRefU = uBuf[uIdx0] & 0xFF;
                    hsMatRefV = vBuf[vIdx0] & 0xFF;
                }
            }

            if (hsBallRefLum >= hsMatRefLum + 22) {
                hsBallDetectionMode = 1;
            } else if (hsBallRefLum <= hsMatRefLum - 22) {
                hsBallDetectionMode = 2;
            } else if (hsBallRefU >= 0 && hsMatRefU >= 0 &&
                       (Math.abs(hsBallRefU - hsMatRefU) >= 12 || Math.abs(hsBallRefV - hsMatRefV) >= 12)) {
                hsBallDetectionMode = 3;
            } else {
                hsBallDetectionMode = 0;
            }
            log(String.format(Locale.US,
                "[HIGH-SPEED CV] Ball baseline sampled: Y=%d vs mat=%d, U=%d/%d, V=%d/%d -> Mode=%d",
                hsBallRefLum, hsMatRefLum, hsBallRefU, hsMatRefU, hsBallRefV, hsMatRefV, hsBallDetectionMode));
        }

        int brightThresh = Math.max(bgLum + 12, bgLum + Math.max(16, (hsBallRefLum > 0) ? (hsBallRefLum - bgLum) / 2 : 22));
        if (hsState == HS_STATE_TRACKING && hsBallRefLum > 0) {
            // Fix 4: a rolling ball is motion-blurred, so its pixels are dimmer than at rest (dim room = long exposure)
            brightThresh = Math.max(bgLum + 12, bgLum + (hsBallRefLum - bgLum) / 3);
        }
        int darkThresh = Math.min(200, bgLum - Math.max(16, (hsBallRefLum > 0) ? (bgLum - hsBallRefLum) / 2 : 20));
        boolean checkChroma = (hsBallDetectionMode == 3 && hasUV);
        int uRow = uRowStride > 0 ? uRowStride : (w / 2);
        int vRow = vRowStride > 0 ? vRowStride : (w / 2);

        // STEP A0 (Fix 5, Fix 14): before anchoring, FIND the resting ball around the projected spot. Fix 11 compared
        // a 7x7 centre with a 41x41 box that had to be dark (< 95): fine on the black mat, but on a wooden floor in
        // lamp light that box held planks and a reflection, contrast came out 5-14 and the ball was never found.
        // Now a compact-spot detector (centre vs a tight ring, ring vs the floor further out) - see findBlob.
        if (hsState == HS_STATE_ARMED && !hsAnchored) {
            // search around Godot's projected tee spot (follows the head); the last candidate could have wandered
            // off after a discarded blip and was never found again (rec_20260920_173840 @ 11.4 s)
            int scx = hsProjStartX >= 0f ? Math.round(hsProjStartX * w) : ballPxX;
            int scy = hsProjStartX >= 0f ? Math.round(hsProjStartY * h) : ballPxY;
            // Fix 15: that projected spot comes from the game's ball position (a coarser detector) and was 8-10 cm off
            // the real ball (rec_20260922_222427): the ball fell outside the old 30 px window, a small spot near the
            // projection was anchored, or the putter face right behind the ball was nearer and got anchored.
            // Now: ball-sized compact spots within ~15 cm; take the strongest; then, if another ball-sized spot sits 3-15 cm IN FRONT of it on the same line, that one is
            // the ball and the first was the putter face (at address the ball is always ahead of the face).
            float expR = Math.max(5f, Math.min(12f, 0.02135f / metersPerNorm * w));
            float rc = Math.min(expR, 7f) + 1f; // findBlob counts bright pixels inside r+1 (r = 7 here)
            float expA = (float) Math.PI * rc * rc;
            int rad = Math.max(30, Math.round(0.15f / metersPerNorm * w));
            java.util.List<BlobHit> anchorCands = findBlobs(yBuffer, w, h, rowStride, pxStride,
                    scx - rad, scy - rad, scx + rad, scy + rad, 7f, ANCHOR_MIN_SCORE, 6);
            java.util.List<BlobHit> ok = new java.util.ArrayList<>();
            for (BlobHit c : anchorCands) {
                if (c.count < Math.max(30f, 0.3f * expA) || c.count > 380) continue; // tiny = a speck, not the ball
                ok.add(c);
            }
            BlobHit b = null; // the strongest ball-sized compact spot (a weak mat speck nearer the projection lost to it)
            for (BlobHit c : ok) if (b == null || c.score > b.score) b = c;
            if (b != null) {
                BlobHit ahead = null;
                float aheadF = Float.MAX_VALUE;
                for (BlobHit c : ok) {
                    if (c == b || c.score < 0.5f * b.score) continue;
                    float nx = (c.x - b.x) / w, ny = (c.y - b.y) / h;
                    float fM = (nx * hsFwdNormX + ny * hsFwdNormY) * metersPerNorm;
                    float lM = Math.abs(-nx * hsFwdNormY + ny * hsFwdNormX) * metersPerNorm;
                    if (fM >= 0.03f && fM <= 0.15f && lM <= 0.035f && fM < aheadF) { aheadF = fM; ahead = c; }
                }
                if (ahead != null) b = ahead;
            }
            if (b == null) {
                if (frameCount % 30 == 0) {
                    log(String.format(Locale.US,
                        "[HIGH-SPEED CV] Anchoring: no compact ball near projected spot (floor=%d) - need more light/contrast?", bgLum));
                }
                hsStationaryFrames = 0;
                return;
            }
            int cnt = b.count;
            if (cnt > 380) {
                if (frameCount % 30 == 0) {
                    log(String.format(Locale.US, "[HIGH-SPEED CV] Anchoring: best blob too large (%d px) - not a ball", cnt));
                }
                hsStationaryFrames = 0;
                return;
            }
            if (cnt < 30) {
                if (frameCount % 30 == 0) {
                    log(String.format(Locale.US, "[HIGH-SPEED CV] Anchoring: best blob too small (%d px, contrast %.0f)", cnt, b.score));
                }
                hsStationaryFrames = 0;
                return;
            }
            float tNormX = b.x / (float) w;
            float tNormY = b.y / (float) h;
            float fdx = tNormX - hsCandNormX, fdy = tNormY - hsCandNormY;
            float frameMoveM = (float) Math.sqrt(fdx * fdx + fdy * fdy) * metersPerNorm;
            hsStationaryFrames = (frameMoveM < 0.004f) ? hsStationaryFrames + 1 : 0;
            hsCandNormX = tNormX;
            hsCandNormY = tNormY;
            currentBallNormX = tNormX;
            currentBallNormY = tNormY;
            hsStartNormX = tNormX;
            hsStartNormY = tNormY;
            hsBallRefLum = Math.round(b.in);
            hsBallRadiusPx = (float) Math.sqrt(cnt / Math.PI);
            hsMatRefLum = Math.round(b.ring);
            hsAnchorScore = b.score;
            hsBallDetectionMode = 1; // bright ball on a darker surface
            if (hsStationaryFrames >= HS_MIN_STATIONARY_FRAMES) {
                hsAnchored = true;
                hsAnchorMissFrames = 0;
                hsRestNormX = tNormX;
                hsRestNormY = tNormY;
                log(String.format(Locale.US,
                    "[HIGH-SPEED CV] Ball anchored at rest: (%.3f, %.3f), ballY=%d floor=%d contrast=%.0f pixels=%d%s",
                    tNormX, tNormY, hsBallRefLum, hsMatRefLum, b.score, cnt,
                    (hsBallRefLum - hsMatRefLum) < LOW_CONTRAST_LEVELS ? " (plain-floor mode)" : ""));
            }
            return;
        }

        // STEP A (Fix 14): anchored - re-find the resting ball with the same compact-spot detector. The old fixed
        // threshold blob test broke on wood (planks and a reflection inside its 53 px window failed the size/shape
        // checks), so the anchor was dropped while the ball lay still.
        if (hsState == HS_STATE_ARMED) {
            int win = Math.max(8, Math.round(hsBallRadiusPx * 1.3f));
            // nearest compact spot to where the ball was, not the brightest: a lamp reflection core or the
            // approaching putter head next to the ball is often stronger (rec_20260921_202308 @ 63.6 s)
            BlobHit b = findBlob(yBuffer, w, h, rowStride, pxStride, ballPxX - win, ballPxY - win, ballPxX + win, ballPxY + win,
                    1, hsBallRadiusPx, Math.max(8f, 0.45f * hsAnchorScore), 0f, 0f, 0f, 0f, 0f, 0f, 0f, false,
                    currentBallNormX * w, currentBallNormY * h);
            if (b != null && hsRestNormX >= 0f) {
                // the resting ball may only drift a few mm from where head compensation says it lies; the old
                // per-frame follow let a slowly approaching putter drag the anchor 9 cm (same recording)
                float rdx = b.x / (float) w - hsRestNormX, rdy = b.y / (float) h - hsRestNormY;
                if (Math.sqrt(rdx * rdx + rdy * rdy) * metersPerNorm > 0.008f) b = null;
            }
            if (b != null) {
                float tNormX = b.x / (float) w;
                float tNormY = b.y / (float) h;
                float fdx = tNormX - currentBallNormX, fdy = tNormY - currentBallNormY;
                float frameMoveM = (float) Math.sqrt(fdx * fdx + fdy * fdy) * metersPerNorm;
                float adx = tNormX - hsStartNormX, ady = tNormY - hsStartNormY;
                float anchorMoveM = (float) Math.sqrt(adx * adx + ady * ady) * metersPerNorm;
                if (anchorMoveM < 0.010f) {
                    hsAnchorMissFrames = 0;
                    hsMatRefLum = Math.round(b.ring); // floor level right around the ball, for the impact thresholds
                    if (frameMoveM < 0.004f) {
                        // Resting ball: follow slow head-induced drift of its image position
                        currentBallNormX = tNormX;
                        currentBallNormY = tNormY;
                        hsStartNormX = tNormX;
                        hsStartNormY = tNormY;
                        hsRestNormX += 0.1f * (tNormX - hsRestNormX); // absorb slow head-compensation bias
                        hsRestNormY += 0.1f * (tNormY - hsRestNormY);
                    }
                    return; // resting, or a small wobble (putter touching / noise) - wait
                }
            }
        }

        // STEP B: Focused search along the putting line on the green mat
        // Determine physical forward search window [minFwdM, maxFwdM] and lateral limit maxLatM
        float minFwdM, maxFwdM;
        // Fix 13: the corridor is measured from the ball's address spot, so a putt struck a few degrees off line
        // drifts sideways as it travels (a 4.5 deg putt is 3 cm off after 40 cm) and used to fall out of the corridor.
        // Allow a widening cone (~ +-8 deg) instead of a fixed 3.5 cm.
        float maxLatM = 0.035f;

        if (hsState == HS_STATE_ARMED) {
            // First frame after impact: physical displacement in 16.6ms is 10mm to 95mm (0.6 to 5.7 m/s)
            minFwdM = 0.010f;
            maxFwdM = 0.095f;
        } else { // HS_STATE_TRACKING
            HighSpeedPoint lastPt = hsPoints.get(hsPoints.size() - 1);
            float lastFwdM = lastPt.fwdDistNorm * metersPerNorm;
            minFwdM = lastFwdM + 0.003f; // Ball must move forward
            maxFwdM = lastFwdM + 0.095f; // Max realistic step per 16.6ms frame
            maxLatM = 0.035f + 0.14f * Math.max(0f, lastFwdM); // widening cone as the ball travels
        }

        // Convert physical limits [minFwdM..maxFwdM, ±maxLatM] to pixel bounding box on screen
        float minFwdN = minFwdM * normPerMeter;
        float maxFwdN = maxFwdM * normPerMeter;
        float maxLatN = maxLatM * normPerMeter;

        // 4 corner points of search window in screen normalized coords
        float p0x = hsStartNormX + hsFwdNormX * minFwdN - perpNormX * maxLatN;
        float p0y = hsStartNormY + hsFwdNormY * minFwdN - perpNormY * maxLatN;
        float p1x = hsStartNormX + hsFwdNormX * minFwdN + perpNormX * maxLatN;
        float p1y = hsStartNormY + hsFwdNormY * minFwdN + perpNormY * maxLatN;
        float p2x = hsStartNormX + hsFwdNormX * maxFwdN - perpNormX * maxLatN;
        float p2y = hsStartNormY + hsFwdNormY * maxFwdN - perpNormY * maxLatN;
        float p3x = hsStartNormX + hsFwdNormX * maxFwdN + perpNormX * maxLatN;
        float p3y = hsStartNormY + hsFwdNormY * maxFwdN + perpNormY * maxLatN;

        int padPx = 10;
        int sX0 = Math.max(2, (int) (Math.min(Math.min(p0x, p1x), Math.min(p2x, p3x)) * w) - padPx);
        int sX1 = Math.min(w - 3, (int) (Math.max(Math.max(p0x, p1x), Math.max(p2x, p3x)) * w) + padPx);
        int sY0 = Math.max(2, (int) (Math.min(Math.min(p0y, p1y), Math.min(p2y, p3y)) * h) - padPx);
        int sY1 = Math.min(h - 3, (int) (Math.max(Math.max(p0y, p1y), Math.max(p2y, p3y)) * h) + padPx);

        if (sX1 <= sX0 || sY1 <= sY0) return;

        hsDiagCount = 0; hsDiagBw = 0; hsDiagBh = 0;
        // Fix 14: on a plain floor the ball is only ~20-40 grey levels above the planks, so a fixed brightness
        // threshold also lights up light planks and lamp reflections in the corridor. There, find the ball as a
        // compact spot instead (forward-most while rolling: the ball leads the putter). The black mat keeps the
        // original pixel path below, unchanged.
        boolean plainFloor = hsBallRefLum > 0 && hsMatRefLum >= 0 && (hsBallRefLum - hsMatRefLum) < LOW_CONTRAST_LEVELS;
        if (plainFloor) {
            // Only something that MOVES along the line can be the putted ball: compact spots that were already
            // there last frame (planks, a reflection, the resting putter) are ignored, and the forward-most moving
            // spot wins (the ball leads the putter). While armed, look up to 25 cm ahead: in rec_20260921_202308 the
            // putter head settled on the ball's spot in the lamp glow, so "ball still there" held until the real
            // ball was 15 cm down the line.
            float fMin = minFwdM, fMax = maxFwdM;
            if (hsState == HS_STATE_ARMED) { fMin = 0.010f; fMax = 0.25f; }
            float latCap = 0.035f + 0.14f * fMax;
            float[] cxs = {0f, 0f, 0f, 0f};
            float[] cys = {0f, 0f, 0f, 0f};
            float[] fs = {fMin, fMin, fMax, fMax};
            float[] ls = {-latCap, latCap, -latCap, latCap};
            int bx0 = w, bx1 = 0, by0 = h, by1 = 0;
            for (int k = 0; k < 4; k++) {
                float qx = hsStartNormX + hsFwdNormX * fs[k] * normPerMeter + perpNormX * ls[k] * normPerMeter;
                float qy = hsStartNormY + hsFwdNormY * fs[k] * normPerMeter + perpNormY * ls[k] * normPerMeter;
                bx0 = Math.min(bx0, (int) (qx * w)); bx1 = Math.max(bx1, (int) (qx * w));
                by0 = Math.min(by0, (int) (qy * h)); by1 = Math.max(by1, (int) (qy * h));
            }
            float minS = Math.max(7f, 0.30f * hsAnchorScore);
            java.util.List<BlobHit> cands = findBlobs(yBuffer, w, h, rowStride, pxStride, bx0 - 4, by0 - 4, bx1 + 4, by1 + 4,
                    hsBallRadiusPx, minS, 12);
            java.util.List<float[]> spotsNow = new java.util.ArrayList<>();
            boolean found = false;
            float fnx = 0f, fny = 0f, ffwdN = 0f, ffwdM = -1f;
            int fcount = 0;
            for (BlobHit c : cands) {
                float nx = c.x / (float) w, ny = c.y / (float) h;
                spotsNow.add(new float[]{nx - hsCompX, ny - hsCompY});
                float fN = (nx - hsStartNormX) * hsFwdNormX + (ny - hsStartNormY) * hsFwdNormY;
                float fM = fN * metersPerNorm;
                float lM = Math.abs(((nx - hsStartNormX) * (-hsFwdNormY) + (ny - hsStartNormY) * hsFwdNormX) * metersPerNorm);
                if (fM < fMin || fM > fMax || lM > 0.035f + 0.14f * Math.max(0f, fM)) continue;
                boolean isStatic = false;
                if (hsPrevSpots != null) {
                    for (float[] q : hsPrevSpots) {
                        float ddx = nx - hsCompX - q[0], ddy = ny - hsCompY - q[1];
                        if (Math.sqrt(ddx * ddx + ddy * ddy) * metersPerNorm < 0.003f) { isStatic = true; break; }
                    }
                }
                if (isStatic) continue;
                if (fM > ffwdM) { found = true; fnx = nx; fny = ny; ffwdN = fN; ffwdM = fM; fcount = c.count; }
            }
            hsPrevSpots = spotsNow;
            plainFloorResult(found, fnx, fny, ffwdN, Math.max(0f, ffwdM), fcount, yBuffer, w, h, timestampNs,
                    uBuf, vBuf, brightThresh, bgLum);
            return;
        }
        // Find candidate peak pixel in this localized green-mat window
        int bestPeakX = -1, bestPeakY = -1;
        int maxPeakLum = -1;
        float bestPeakFwdM = -1f;
        // Fix 8: while tracking, a bright putter head in the window (peak 170-180 vs ball ~100) stole the detection.
        // Prefer the bright pixel closest to where the ball should be now (constant-velocity prediction).
        boolean predictMode = (hsState == HS_STATE_TRACKING && hsPoints.size() >= 2);
        float predFwdM = 0f;
        float bestPredCost = Float.MAX_VALUE;
        if (predictMode) {
            HighSpeedPoint pA = hsPoints.get(hsPoints.size() - 2);
            HighSpeedPoint pB = hsPoints.get(hsPoints.size() - 1);
            float stepM = Math.max(0.005f, (pB.fwdDistNorm - pA.fwdDistNorm) * metersPerNorm);
            predFwdM = pB.fwdDistNorm * metersPerNorm + stepM;
        }

        for (int y = sY0; y <= sY1; y++) {
            int rowOff = y * rowStride;
            float ny = (float) y / (float) h;
            for (int x = sX0; x <= sX1; x++) {
                float nx = (float) x / (float) w;
                float fwdM = ((nx - hsStartNormX) * hsFwdNormX + (ny - hsStartNormY) * hsFwdNormY) * metersPerNorm;
                if (fwdM < minFwdM || fwdM > maxFwdM) continue;
                float latM = Math.abs(((nx - hsStartNormX) * (-hsFwdNormY) + (ny - hsStartNormY) * hsFwdNormX) * metersPerNorm);
                if (latM > maxLatM) continue;

                int lum = yBuffer[rowOff + x * pxStride] & 0xFF;
                boolean isBallPix = false;
                if (hsBallDetectionMode == 1) {
                    isBallPix = (lum >= brightThresh);
                } else if (hsBallDetectionMode == 2) {
                    isBallPix = (lum <= darkThresh);
                } else if (checkChroma) {
                    int uvX = x / 2;
                    int uvY = y / 2;
                    int uIdx = uvY * uRow + uvX * uPixelStride;
                    int vIdx = uvY * vRow + uvX * vPixelStride;
                    if (uIdx >= 0 && uIdx < uLen && vIdx >= 0 && vIdx < vLen) {
                        int u = uBuf[uIdx] & 0xFF;
                        int v = vBuf[vIdx] & 0xFF;
                        int dBall = (u - hsBallRefU) * (u - hsBallRefU) + (v - hsBallRefV) * (v - hsBallRefV);
                        int dMat = (u - hsMatRefU) * (u - hsMatRefU) + (v - hsMatRefV) * (v - hsMatRefV);
                        isBallPix = (dBall < dMat && dMat >= 100);
                    } else {
                        isBallPix = (Math.abs(lum - bgLum) >= 18);
                    }
                } else {
                    isBallPix = (Math.abs(lum - bgLum) >= 20);
                }

                if (isBallPix && predictMode) {
                    // Fix 12: the ball always LEADS the putter. Right after impact they touch and a "closest to
                    // prediction" pick followed the merged ball+putter blob (rec_20260920_152622 @17.2 s).
                    // Take the forward-most bright pixel (lateral offset penalised) = the ball's leading edge.
                    float cost = -fwdM + 0.5f * latM;
                    if (cost < bestPredCost) {
                        bestPredCost = cost;
                        bestPeakX = x;
                        bestPeakY = y;
                        bestPeakFwdM = fwdM;
                    }
                    if (lum > maxPeakLum) maxPeakLum = lum;
                } else if (isBallPix) {
                    // Forward-most candidate peak breaks ties (golf ball always leads the putter head)
                    if (lum > maxPeakLum || (lum >= maxPeakLum - 8 && fwdM > bestPeakFwdM)) {
                        maxPeakLum = lum;
                        bestPeakX = x;
                        bestPeakY = y;
                        bestPeakFwdM = fwdM;
                    }
                }
            }
        }

        // Measure local cluster around the candidate peak
        boolean isBallFound = false;
        float normX = 0f, normY = 0f;
        float cFwdNorm = 0f, cFwdM = 0f;
        int ballCount = 0;

        if (bestPeakX >= 0) {
            int rR = (hsState == HS_STATE_TRACKING) ? 22 : 14; // Ball radius in pixels (larger when motion-blurred)
            if (predictMode) {
                // centre the cluster window one ball radius BEHIND the leading edge, and keep it ball-sized so the
                // putter head right behind the ball stays outside it
                float fpx = hsFwdNormX * w, fpy = hsFwdNormY * h;
                float fl = (float) Math.sqrt(fpx * fpx + fpy * fpy);
                if (fl > 1e-6f) {
                    bestPeakX = Math.round(bestPeakX - fpx / fl * hsBallRadiusPx);
                    bestPeakY = Math.round(bestPeakY - fpy / fl * hsBallRadiusPx);
                }
                rR = Math.max(8, Math.round(hsBallRadiusPx * 1.6f + 3f));
            }
            int bx0 = Math.max(2, bestPeakX - rR);
            int bx1 = Math.min(w - 3, bestPeakX + rR);
            int by0 = Math.max(2, bestPeakY - rR);
            int by1 = Math.min(h - 3, bestPeakY + rR);

            int bSumX = 0, bSumY = 0;
            int minBx = bx1, maxBx = bx0, minBy = by1, maxBy = by0;

            for (int y = by0; y <= by1; y++) {
                int rowOff = y * rowStride;
                for (int x = bx0; x <= bx1; x++) {
                    int lum = yBuffer[rowOff + x * pxStride] & 0xFF;
                    boolean isP = false;
                    if (hsBallDetectionMode == 1) {
                        isP = (lum >= brightThresh);
                    } else if (hsBallDetectionMode == 2) {
                        isP = (lum <= darkThresh);
                    } else if (checkChroma) {
                        int uvX = x / 2;
                        int uvY = y / 2;
                        int uIdx = uvY * uRow + uvX * uPixelStride;
                        int vIdx = uvY * vRow + uvX * vPixelStride;
                        if (uIdx >= 0 && uIdx < uLen && vIdx >= 0 && vIdx < vLen) {
                            int u = uBuf[uIdx] & 0xFF;
                            int v = vBuf[vIdx] & 0xFF;
                            int dBall = (u - hsBallRefU) * (u - hsBallRefU) + (v - hsBallRefV) * (v - hsBallRefV);
                            int dMat = (u - hsMatRefU) * (u - hsMatRefU) + (v - hsMatRefV) * (v - hsMatRefV);
                            isP = (dBall < dMat && dMat >= 100);
                        } else {
                            isP = (Math.abs(lum - bgLum) >= 18);
                        }
                    } else {
                        isP = (Math.abs(lum - bgLum) >= 20);
                    }

                    if (isP) {
                        ballCount++;
                        bSumX += x;
                        bSumY += y;
                        if (x < minBx) minBx = x;
                        if (x > maxBx) maxBx = x;
                        if (y < minBy) minBy = y;
                        if (y > maxBy) maxBy = y;
                    }
                }
            }

            hsDiagCount = ballCount; hsDiagBw = maxBx - minBx + 1; hsDiagBh = maxBy - minBy + 1;
            if (ballCount >= 14 && ballCount <= 900) {
                int bw = maxBx - minBx + 1;
                int bh = maxBy - minBy + 1;
                float aspect = (float) bw / Math.max(1, bh);
                int maxB = (hsState == HS_STATE_TRACKING) ? 44 : 28;
                if (bw >= 6 && bh >= 6 && bw <= maxB && bh <= maxB && aspect >= 0.30f && aspect <= 3.50f) {
                    normX = ((float) bSumX / ballCount) / (float) w;
                    normY = ((float) bSumY / ballCount) / (float) h;
                    cFwdNorm = (normX - hsStartNormX) * hsFwdNormX + (normY - hsStartNormY) * hsFwdNormY;
                    cFwdM = cFwdNorm * metersPerNorm;
                    float cLatNorm = (normX - hsStartNormX) * (-hsFwdNormY) + (normY - hsStartNormY) * hsFwdNormX;
                    float cLatM = Math.abs(cLatNorm * metersPerNorm);

                    if (cFwdM >= minFwdM && cFwdM <= maxFwdM && cLatM <= maxLatM) {
                        isBallFound = true;
                    }
                }
            }
        }

        stateMachine(isBallFound, normX, normY, cFwdNorm, cFwdM, ballCount, yBuffer, w, h, timestampNs, uBuf, vBuf,
                brightThresh, bgLum, maxPeakLum, rowStride, pxStride);
    }

    /** Fix 14: floor path hands its detection to the same state machine as the mat path. */
    private void plainFloorResult(boolean found, float nx, float ny, float fwdN, float fwdM, int count, byte[] yBuffer,
                                  int w, int h, long timestampNs, byte[] uBuf, byte[] vBuf, int brightThresh, int bgLum) {
        hsDiagCount = count;
        stateMachine(found, nx, ny, fwdN, fwdM, count, yBuffer, w, h, timestampNs, uBuf, vBuf, brightThresh, bgLum, -1,
                lastRowStride, lastPxStride);
    }

    private int lastRowStride = 0, lastPxStride = 1;

    /** STEP C: state machine update (was the tail of processHighSpeedCorridorFrame). */
    private void stateMachine(boolean isBallFound, float normX, float normY, float cFwdNorm, float cFwdM, int ballCount,
                              byte[] yBuffer, int w, int h, long timestampNs, byte[] uBuf, byte[] vBuf,
                              int brightThresh, int bgLum, int maxPeakLum, int rowStride, int pxStride) {
        float metersPerNorm = Math.max(0.10f, hsMetersPerNormUnit);
        // STEP C: State Machine Update
        if (hsState == HS_STATE_ARMED && !isBallFound && hsAnchored) {
            if (hsAnchorMissFrames++ == 0) hsAnchorMissStartNs = timestampNs;
            if (hsAnchorMissFrames >= 8 && timestampNs - hsAnchorMissStartNs >= ANCHOR_LOST_NS) {
                log(String.format(Locale.US, "[HIGH-SPEED CV] Anchor lost (ball not seen near (%.3f, %.3f) for %d frames) - searching again",
                    currentBallNormX, currentBallNormY, hsAnchorMissFrames));
                hsAnchored = false;
                hsStationaryFrames = 0;
                hsAnchorMissFrames = 0;
                if (hsProjStartX >= 0f) { currentBallNormX = hsProjStartX; currentBallNormY = hsProjStartY; }
            }
        }
        if (hsState == HS_STATE_ARMED) {
            if (isBallFound) {
                // >>> IMPACT DETECTED! Ball moved forward past 10mm <<<
                hsState = HS_STATE_TRACKING;
                hsPoints.clear();
                hsConsecutiveLostFrames = 0;

                hsSnippetFrame1 = yBuffer.clone();
                hsSnippetNormX1 = currentBallNormX;
                hsSnippetNormY1 = currentBallNormY;

                // Point 0 at tee, Point 1 moving forward
                hsPoints.add(new HighSpeedPoint(hsStartNormX, hsStartNormY, hsStartNormX * w, hsStartNormY * h, 0f, ballCount, timestampNs - 16_000_000L, true));
                { HighSpeedPoint np = new HighSpeedPoint(normX, normY, normX * w, normY * h, cFwdNorm, ballCount, timestampNs); np.compX = hsCompX; np.compY = hsCompY; hsPoints.add(np); }

                currentBallNormX = normX;
                currentBallNormY = normY;

                log(String.format(Locale.US,
                    "[HIGH-SPEED CV] >>> P1 STROKE IMPACT: start=(%.3f, %.3f), p1=(%.3f, %.3f), fwd=%.1fmm, count=%d <<<",
                    hsStartNormX, hsStartNormY, normX, normY, cFwdM * 1000f, ballCount));
            }
        } else if (hsState == HS_STATE_TRACKING) {
            if (isBallFound) {
                HighSpeedPoint lastPt = hsPoints.get(hsPoints.size() - 1);
                float mdx = (normX - lastPt.normX) - (hsCompX - lastPt.compX);
                float mdy = (normY - lastPt.normY) - (hsCompY - lastPt.compY);
                float stepFwdNorm = mdx * hsFwdNormX + mdy * hsFwdNormY;
                float stepFwdM = stepFwdNorm * metersPerNorm;
                float stepLatNorm = mdx * (-hsFwdNormY) + mdy * hsFwdNormX;
                float stepLatM = Math.abs(stepLatNorm * metersPerNorm);

                // Fix 9: a resting ball "creeps" forward ~4 mm every other frame from head sway / blob jitter
                // (log 8: 0.1 m/s fake tracks that blocked real putts). Require real rolling speed (>= 0.3 m/s).
                float dtStep = (timestampNs - lastPt.timestampNs) / 1_000_000_000.0f;
                float minStepM = Math.max(0.003f, 0.30f * Math.max(0.0f, dtStep));
                if (stepFwdM >= minStepM && stepLatM <= 0.025f) {
                    hsConsecutiveLostFrames = 0;
                    { HighSpeedPoint np = new HighSpeedPoint(normX, normY, normX * w, normY * h, cFwdNorm, ballCount, timestampNs); np.compX = hsCompX; np.compY = hsCompY; hsPoints.add(np); }
                    currentBallNormX = normX;
                    currentBallNormY = normY;

                    if (hsPoints.size() == 3) {
                        hsSnippetFrame2 = yBuffer.clone();
                        hsSnippetNormX2 = normX;
                        hsSnippetNormY2 = normY;
                    }
                    hsSnippetFrame3 = yBuffer.clone();
                    hsSnippetNormX3 = normX;
                    hsSnippetNormY3 = normY;
                    hsSnippetU3 = (hasColorPlanes && uBuf != null) ? uBuf.clone() : null;
                    hsSnippetV3 = (hasColorPlanes && vBuf != null) ? vBuf.clone() : null;

                    log(String.format(Locale.US,
                        "[HIGH-SPEED CV] Pt %d: fwd=%.1fmm (step=%.1fmm), count=%d",
                        hsPoints.size(), cFwdM * 1000f, stepFwdM * 1000f, ballCount));
                } else {
                    hsConsecutiveLostFrames++;
                    log(String.format(Locale.US,
                        "[HIGH-SPEED CV] LOST (step rejected): pts=%d stepFwd=%.1fmm stepLat=%.1fmm count=%d",
                        hsPoints.size(), stepFwdM * 1000f, stepLatM * 1000f, ballCount));
                }
            } else {
                hsConsecutiveLostFrames++;
                log(String.format(Locale.US,
                    "[HIGH-SPEED CV] LOST (no ball): pts=%d peakLum=%d thresh=%d bg=%d ref=%d mode=%d blobCount=%d box=%dx%d",
                    hsPoints.size(), maxPeakLum, brightThresh, bgLum, hsBallRefLum, hsBallDetectionMode, hsDiagCount, hsDiagBw, hsDiagBh));
            }

            boolean isFinished = false;
            float fwdDistM = cFwdM;
            if (hsPoints.size() >= 2) {
                // Virtual Photocell Gate B is at 0.20m (20cm).
                // Complete tracking once the ball has crossed Gate B (+2cm margin = 0.22m),
                // or if the ball was tracked for >=2 frames and then lost for 2 consecutive frames,
                // or after 35 frames (~450-500ms safety limit)
                if (fwdDistM >= 0.65f) { // Fix 13: track to 65 cm for a longer, rolling-phase measuring window
                    isFinished = true;
                } else if (hsConsecutiveLostFrames >= 3) {
                    if (hsPoints.size() - 1 < HS_MIN_REAL_POINTS) {
                        // Fix 3: 1-2 detections then lost = noise / putter, not a putt. Re-anchor and keep waiting.
                        log("[HIGH-SPEED CV] Discarded blip with only " + (hsPoints.size() - 1) + " real points");
                        // not counted as a lost putt: blips are mostly waggles, toe nudges and head swings
                        hsState = HS_STATE_ARMED;
                        hsPoints.clear();
                        hsAnchored = false;
                        hsStationaryFrames = 0;
                        currentBallNormX = hsStartNormX;
                        currentBallNormY = hsStartNormY;
                        return;
                    }
                    isFinished = true;
                } else if (hsPoints.size() >= 60) {
                    isFinished = true;
                }
            } else if (hsConsecutiveLostFrames >= 6) {
                hsLostPuttCount++;
                log("[HIGH-SPEED CV] Lost the ball while tracking (" + (hsPoints.size() - 1) + " real points)");
                hsState = HS_STATE_ARMED;
                hsPoints.clear();
                currentBallNormX = hsStartNormX;
                currentBallNormY = hsStartNormY;
                return;
            }

            if (isFinished) {
                hsState = HS_STATE_FINISHED;
                computeHighSpeedPuttResult(w, h, rowStride, pxStride);
            }
        }
        }

    void computeHighSpeedPuttResult(final int w, final int h, final int rowStride, final int pxStride) {
        if (hsPoints.size() < 2) {
            hsState = HS_STATE_ARMED;
            return;
        }

        hsLastPuttPoints = new ArrayList<>(hsPoints); // Speed v2: raw samples for Godot-side floor reconstruction

        HighSpeedPoint pFirst = hsPoints.get(0);
        HighSpeedPoint pLast = hsPoints.get(hsPoints.size() - 1);

        // Strategy 1: Virtual Photocell Gate ("Chronograph Gate")
        // Gate A at +0.05m (5cm), Gate B at +0.20m (20cm). Gate Distance = 0.15m
        float gateA_m = 0.05f;
        float gateB_m = 0.20f;
        float gateDist_m = gateB_m - gateA_m; // 0.15m

        long tA_ns = -1L;
        long tB_ns = -1L;

        // Sub-frame Photocell Gate Timestamp Extraction via Linear Interpolation
        for (int i = 1; i < hsPoints.size(); i++) {
            HighSpeedPoint prev = hsPoints.get(i - 1);
            HighSpeedPoint curr = hsPoints.get(i);
            float prevDistM = prev.fwdDistNorm * hsMetersPerNormUnit;
            float currDistM = curr.fwdDistNorm * hsMetersPerNormUnit;

            if (tA_ns < 0L && currDistM >= gateA_m) {
                float frac = (currDistM > prevDistM) ? (gateA_m - prevDistM) / (currDistM - prevDistM) : 0f;
                frac = Math.max(0f, Math.min(1f, frac));
                tA_ns = prev.timestampNs + (long) ((curr.timestampNs - prev.timestampNs) * frac);
            }
            if (tB_ns < 0L && currDistM >= gateB_m) {
                float frac = (currDistM > prevDistM) ? (gateB_m - prevDistM) / (currDistM - prevDistM) : 0f;
                frac = Math.max(0f, Math.min(1f, frac));
                tB_ns = prev.timestampNs + (long) ((curr.timestampNs - prev.timestampNs) * frac);
            }
        }

        float dt_sec = 0f;
        float v_avg = 0f;
        float v0 = 0f;

        if (tA_ns > 0L && tB_ns > tA_ns) {
            dt_sec = (tB_ns - tA_ns) / 1_000_000_000.0f;
            if (dt_sec >= 0.03f && dt_sec <= 0.65f) {
                v_avg = gateDist_m / dt_sec;
                // Green friction deceleration a = mu_r * g = (0.56 / 14.5) * 9.81 = 0.37887 m/s^2 (Stimp 14.5 indoor mat)
                float a = 0.37887f;
                v0 = (float) Math.sqrt(Math.max(0f, v_avg * v_avg + 2.0f * a * gateA_m + a * gateDist_m));
            }
        }

        // Fallback calculation for shorter trajectories that reach Gate A but stop before Gate B
        if (v0 <= 0.15f) {
            float dtTotal = (pLast.timestampNs - pFirst.timestampNs) / 1_000_000_000.0f;
            if (dtTotal <= 0.005f) dtTotal = 0.02f;
            float totalDistM = (pLast.fwdDistNorm - pFirst.fwdDistNorm) * hsMetersPerNormUnit;
            if (totalDistM >= 0.02f) {
                v_avg = totalDistM / dtTotal;
                float a = 0.37887f;
                float dStart = pFirst.fwdDistNorm * hsMetersPerNormUnit;
                v0 = (float) Math.sqrt(Math.max(0f, v_avg * v_avg + 2.0f * a * dStart));
                dt_sec = dtTotal;
            }
        }

        // Validate reconstructed launch speed (0.20 m/s to 5.50 m/s range)
        if (v0 < 0.20f || v0 > 5.50f) {
            hsState = HS_STATE_ARMED;
            hsAnchored = false;
            hsStationaryFrames = 0;
            currentBallNormX = hsStartNormX;
            currentBallNormY = hsStartNormY;
            hsPoints.clear();
            return;
        }

        float dx = pLast.normX - pFirst.normX;
        float dy = pLast.normY - pFirst.normY;
        float dot = dx * hsFwdNormX + dy * hsFwdNormY;
        float cross = hsFwdNormX * dy - hsFwdNormY * dx;
        float angleRad = (float) Math.atan2(cross, dot);
        float angleDeg = (float) Math.toDegrees(angleRad);

        synchronized (hsTelemetryResult) {
            hsTelemetryResult[0] = v0;
            hsTelemetryResult[1] = angleDeg;
            hsTelemetryResult[2] = hsPoints.size();
            hsTelemetryResult[3] = dt_sec;
            hsTelemetryResult[4] = pLast.normX;
            hsTelemetryResult[5] = pLast.normY;
        }
        isHsPuttReady = true;

        final float fps = (hsPoints.size() - 1) / Math.max(0.001f, dt_sec);
        log(String.format(Locale.US,
            "[PHOTOCELL GATE] >>> CONFIRMED PUTT: v0=%.2f m/s (v_avg=%.2f m/s, angle=%+.1f deg), gate_dt=%.3fs, %d points (~%.0f FPS) <<<",
            v0, v_avg, angleDeg, dt_sec, hsPoints.size(), fps));

        final List<HighSpeedPoint> ptsCopy = new ArrayList<>(hsPoints);
        final byte[] f1 = (hsSnippetFrame1 != null) ? hsSnippetFrame1.clone() : null;
        final byte[] f2 = (hsSnippetFrame2 != null) ? hsSnippetFrame2.clone() : null;
        final byte[] f3 = (hsSnippetFrame3 != null) ? hsSnippetFrame3.clone() : null;
        final byte[] u3 = (hsSnippetU3 != null) ? hsSnippetU3.clone() : null;
        final byte[] v3 = (hsSnippetV3 != null) ? hsSnippetV3.clone() : null;
        final float sx1 = hsSnippetNormX1, sy1 = hsSnippetNormY1;
        final float sx2 = hsSnippetNormX2, sy2 = hsSnippetNormY2;
        final float sx3 = hsSnippetNormX3, sy3 = hsSnippetNormY3;
        final float finalSpeed = v0;
        final float finalAngle = angleDeg;
        final float finalFps = fps;
        final boolean hasCol = hasColorPlanes;
        final int uStr = uRowStride > 0 ? uRowStride : (w / 2);
        final int uPix = uPixelStride > 0 ? uPixelStride : 1;
        final int vStr = vRowStride > 0 ? vRowStride : (w / 2);
        final int vPix = vPixelStride > 0 ? vPixelStride : 1;

        if (hooks != null) hooks.runAsync(new Runnable() {
            @Override
            public void run() {
                hooks.renderDashboard(w, h, rowStride, pxStride, ptsCopy,
                    f1, sx1, sy1,
                    f2, sx2, sy2,
                    f3, u3, v3, sx3, sy3,
                    hasCol, uStr, uPix, vStr, vPix,
                    finalSpeed, finalAngle, finalFps);
            }
        });
    }
}

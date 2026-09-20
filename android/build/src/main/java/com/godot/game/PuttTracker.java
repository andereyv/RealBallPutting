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

    public boolean isActive() { return hsState == HS_STATE_ARMED || hsState == HS_STATE_TRACKING; }

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
        if (hsState == HS_STATE_TRACKING && hsMatRefLum >= 0) {
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

        // STEP A0 (Fix 5): before anchoring, FIND the resting ball by its brightness peak around the projected
        // spot and (re)sample its appearance there. Godot's projection can be 2-3 cm off, so sampling "the ball"
        // at the projected pixel often sampled the mat instead (log: "Y=22 vs mat=21") and the ball was never found.
        if (hsState == HS_STATE_ARMED && !hsAnchored) {
            int rad = 30;
            int ax0 = Math.max(2, ballPxX - rad), ax1 = Math.min(w - 3, ballPxX + rad);
            int ay0 = Math.max(2, ballPxY - rad), ay1 = Math.min(h - 3, ballPxY + rad);
            // Fix 11: find the ball as a small bright spot on a DARK surround (center-surround contrast), using an
            // integral image. Brightest-pixel / most-bright-pixels picked the wooden floor next to the mat when the
            // ball lay near the mat edge (rec_20260920_152622: "blob too large 500 px", mat=90-140).
            final int RIN = 3, ROUT = 20;
            int ix0 = Math.max(0, ax0 - ROUT - 1), ix1 = Math.min(w - 1, ax1 + ROUT + 1);
            int iy0 = Math.max(0, ay0 - ROUT - 1), iy1 = Math.min(h - 1, ay1 + ROUT + 1);
            int iw = ix1 - ix0 + 2, ih = iy1 - iy0 + 2;
            long[] integ = new long[iw * ih];
            for (int y = 1; y < ih; y++) {
                long rowSum = 0;
                int rowOff = (iy0 + y - 1) * rowStride;
                for (int x = 1; x < iw; x++) {
                    rowSum += yBuffer[rowOff + (ix0 + x - 1) * pxStride] & 0xFF;
                    integ[y * iw + x] = integ[(y - 1) * iw + x] + rowSum;
                }
            }
            float bestScore = -1e9f, bestIn = 0f, bestOut = 0f;
            int pkX = -1, pkY = -1;
            for (int cy = ay0; cy <= ay1; cy += 2) {
                for (int cx = ax0; cx <= ax1; cx += 2) {
                    float in = boxMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, RIN);
                    float out = boxMean(integ, iw, ix0, iy0, ix1, iy1, cx, cy, ROUT);
                    if (out > 95f) continue;                       // not on the dark mat
                    float score = in - out;
                    if (score > bestScore) { bestScore = score; bestIn = in; bestOut = out; pkX = cx; pkY = cy; }
                }
            }
            if (pkX < 0 || bestScore < 25f) {
                if (frameCount % 30 == 0) {
                    log(String.format(Locale.US,
                        "[HIGH-SPEED CV] Anchoring: no ball near projected spot (best contrast %.0f, mat=%d) - need more light/contrast?",
                        bestScore, bgLum));
                }
                hsStationaryFrames = 0;
                return;
            }
            // refine to the local maximum around the candidate, and use the dark surround as the mat level
            bgLum = Math.round(bestOut);
            int peak = Math.round(bestIn);
            int thr = bgLum + Math.max(15, (peak - bgLum) / 2);
            int cnt = 0, sx = 0, sy = 0, sumLum = 0;
            int r2 = 10;
            for (int y = Math.max(2, pkY - r2); y <= Math.min(h - 3, pkY + r2); y++) {
                int rowOff = y * rowStride;
                for (int x = Math.max(2, pkX - r2); x <= Math.min(w - 3, pkX + r2); x++) {
                    int lum = yBuffer[rowOff + x * pxStride] & 0xFF;
                    if (lum >= thr) { cnt++; sx += x; sy += y; sumLum += lum; }
                }
            }
            if (cnt > 380) {
                // too large to be the ball (log 8: shoes/putter head at the image edge, ~500 px, were "anchored")
                if (frameCount % 30 == 0) {
                    log(String.format(Locale.US,
                        "[HIGH-SPEED CV] Anchoring: best blob too large (%d px) - not a ball", cnt));
                }
                hsStationaryFrames = 0;
                return;
            }
            if (cnt < 50) {
                // too small to be the ball (ball at address is ~150-190 px in the logs)
                if (frameCount % 30 == 0) {
                    log(String.format(Locale.US,
                        "[HIGH-SPEED CV] Anchoring: best blob too small (%d px, thr=%d, mat=%d)", cnt, thr, bgLum));
                }
                hsStationaryFrames = 0;
                return;
            }
            float tNormX = ((float) sx / cnt) / (float) w;
            float tNormY = ((float) sy / cnt) / (float) h;
            float fdx = tNormX - currentBallNormX, fdy = tNormY - currentBallNormY;
            float frameMoveM = (float) Math.sqrt(fdx * fdx + fdy * fdy) * metersPerNorm;
            hsStationaryFrames = (frameMoveM < 0.004f) ? hsStationaryFrames + 1 : 0;
            currentBallNormX = tNormX;
            currentBallNormY = tNormY;
            hsStartNormX = tNormX;
            hsStartNormY = tNormY;
            hsBallRefLum = sumLum / cnt;
            hsBallRadiusPx = (float) Math.sqrt(cnt / Math.PI);
            hsMatRefLum = bgLum;
            hsBallDetectionMode = 1; // bright ball on darker mat
            if (hsStationaryFrames >= HS_MIN_STATIONARY_FRAMES) {
                hsAnchored = true;
                log(String.format(Locale.US,
                    "[HIGH-SPEED CV] Ball anchored at rest: (%.3f, %.3f), ballY=%d mat=%d pixels=%d",
                    tNormX, tNormY, hsBallRefLum, bgLum, cnt));
            }
            return;
        }

        // STEP A: If armed, check if ball is still resting stationary on the tee spot
        if (hsState == HS_STATE_ARMED) {
            int teeWinRad = 26;
            int tx0 = Math.max(2, ballPxX - teeWinRad);
            int tx1 = Math.min(w - 3, ballPxX + teeWinRad);
            int ty0 = Math.max(2, ballPxY - teeWinRad);
            int ty1 = Math.min(h - 3, ballPxY + teeWinRad);

            int teeCount = 0, teeSumX = 0, teeSumY = 0;
            int minTx = tx1, maxTx = tx0, minTy = ty1, maxTy = ty0;

            for (int y = ty0; y <= ty1; y++) {
                int rowOff = y * rowStride;
                for (int x = tx0; x <= tx1; x++) {
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

                    if (isBallPix) {
                        teeCount++;
                        teeSumX += x;
                        teeSumY += y;
                        if (x < minTx) minTx = x;
                        if (x > maxTx) maxTx = x;
                        if (y < minTy) minTy = y;
                        if (y > maxTy) maxTy = y;
                    }
                }
            }

            if (teeCount >= 16 && teeCount <= 550) {
                int tbw = maxTx - minTx + 1;
                int tbh = maxTy - minTy + 1;
                float aspect = (float) tbw / Math.max(1, tbh);
                if (tbw >= 6 && tbh >= 6 && tbw <= 36 && tbh <= 36 && aspect >= 0.35f && aspect <= 2.80f) {
                    float tNormX = ((float) teeSumX / teeCount) / (float) w;
                    float tNormY = ((float) teeSumY / teeCount) / (float) h;
                    // Per-frame motion (vs last seen position) and total motion (vs anchored rest position)
                    float fdx = tNormX - currentBallNormX, fdy = tNormY - currentBallNormY;
                    float frameMoveM = (float) Math.sqrt(fdx * fdx + fdy * fdy) * metersPerNorm;
                    float adx = tNormX - hsStartNormX, ady = tNormY - hsStartNormY;
                    float anchorMoveM = (float) Math.sqrt(adx * adx + ady * ady) * metersPerNorm;

                    if (!hsAnchored) {
                        // Snap to the real ball and wait until it has been still for a few frames
                        hsStationaryFrames = (frameMoveM < 0.004f) ? hsStationaryFrames + 1 : 0;
                        currentBallNormX = tNormX;
                        currentBallNormY = tNormY;
                        hsStartNormX = tNormX;
                        hsStartNormY = tNormY;
                        if (hsStationaryFrames >= HS_MIN_STATIONARY_FRAMES) {
                            hsAnchored = true;
                            log(String.format(Locale.US,
                                "[HIGH-SPEED CV] Ball anchored at rest: (%.3f, %.3f) after %d still frames",
                                tNormX, tNormY, hsStationaryFrames));
                        }
                        return;
                    }
                    hsAnchorMissFrames = 0;
                    if (frameMoveM < 0.004f && anchorMoveM < 0.010f) {
                        // Resting ball: follow slow head-induced drift of its image position
                        currentBallNormX = tNormX;
                        currentBallNormY = tNormY;
                        hsStartNormX = tNormX;
                        hsStartNormY = tNormY;
                        return;
                    }
                    if (anchorMoveM < 0.010f) {
                        return; // small wobble (putter touching / noise) - wait
                    }
                }
            }
            if (!hsAnchored) {
                return; // never detect an impact before the resting ball has been found
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

        // STEP C: State Machine Update
        if (hsState == HS_STATE_ARMED && !isBallFound && hsAnchored) {
            if (++hsAnchorMissFrames >= 8) {
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

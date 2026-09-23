#!/usr/bin/env python3
"""Fix 14: plain floors. Patches PuttTracker.java (path in argv[1]) in place."""
import re, sys

p = sys.argv[1]
s = open(p, encoding="utf-8").read()


def sub(old, new, n=1):
    global s
    c = s.count(old)
    if c != n:
        sys.exit("FAIL (%d x): %r" % (c, old[:100]))
    s = s.replace(old, new)


# ---------------------------------------------------------------- helpers
sub("""    public boolean isActive() { return hsState == HS_STATE_ARMED || hsState == HS_STATE_TRACKING; }""",
"""    /** Mean of the square ring between box radius rA (exclusive) and rB (inclusive), clamped like boxMean. */
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

    public boolean isActive() { return hsState == HS_STATE_ARMED || hsState == HS_STATE_TRACKING; }""")

# ---------------------------------------------------------------- state
sub("""    float hsBallRadiusPx = 7f; // measured from the anchored ball's pixel count""",
"""    float hsBallRadiusPx = 7f; // measured from the anchored ball's pixel count
    float hsAnchorScore = 0f;   // Fix 14: centre-vs-ring contrast of the anchored ball
    long hsAnchorMissStartNs = 0L;
    float hsRestNormX = -1f, hsRestNormY = -1f; // Fix 14: anchored rest position, moved only by head compensation
    java.util.List<float[]> hsPrevSpots = null;  // Fix 14: compact spots in the corridor last frame (head-compensated)
    float hsCandNormX = -1f, hsCandNormY = -1f;  // Fix 14: last anchoring candidate (stillness test)
    /** Fix 14: ball contrast below this (grey levels) = "plain floor" mode: compact-spot detection while rolling. */
    static final int LOW_CONTRAST_LEVELS = 60;
    static final float ANCHOR_MIN_SCORE = 14f;
    static final long ANCHOR_LOST_NS = 500_000_000L; // was 8 frames: only 0.13 s at the 60 fps seen on 2026-09-21""")

# ---------------------------------------------------------------- STEP A0 (anchoring)
a0_start = s.index("        // STEP A0 (Fix 5)")
a0_end = s.index("        // STEP A: If armed, check if ball is still resting")
s = s[:a0_start] + """        // STEP A0 (Fix 5, Fix 14): before anchoring, FIND the resting ball around the projected spot. Fix 11 compared
        // a 7x7 centre with a 41x41 box that had to be dark (< 95): fine on the black mat, but on a wooden floor in
        // lamp light that box held planks and a reflection, contrast came out 5-14 and the ball was never found.
        // Now a compact-spot detector (centre vs a tight ring, ring vs the floor further out) - see findBlob.
        if (hsState == HS_STATE_ARMED && !hsAnchored) {
            int rad = 30;
            // search around Godot's projected tee spot (follows the head); the last candidate could have wandered
            // off after a discarded blip and was never found again (rec_20260920_173840 @ 11.4 s)
            int scx = hsProjStartX >= 0f ? Math.round(hsProjStartX * w) : ballPxX;
            int scy = hsProjStartX >= 0f ? Math.round(hsProjStartY * h) : ballPxY;
            BlobHit b = findBlob(yBuffer, w, h, rowStride, pxStride, scx - rad, scy - rad, scx + rad, scy + rad,
                    2, 7f, ANCHOR_MIN_SCORE, 0f, 0f, 0f, 0f, 0f, 0f, 0f, false, -1f, -1f);
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

""" + s[a0_end:]

# ---------------------------------------------------------------- STEP A (resting check while anchored)
a_start = s.index("        // STEP A: If armed, check if ball is still resting")
a_end = s.index("        // STEP B: Focused search along the putting line")
s = s[:a_start] + """        // STEP A (Fix 14): anchored - re-find the resting ball with the same compact-spot detector. The old fixed
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

""" + s[a_end:]

# ---------------------------------------------------------------- floor level for thresholds while armed
sub("""        if (hsState == HS_STATE_TRACKING && hsMatRefLum >= 0) {""",
"""        if ((hsState == HS_STATE_TRACKING || (hsState == HS_STATE_ARMED && hsAnchored)) && hsMatRefLum >= 0) {""")

# ---------------------------------------------------------------- STEP B: plain-floor candidate search
sub("""        hsDiagCount = 0; hsDiagBw = 0; hsDiagBh = 0;""",
"""        hsDiagCount = 0; hsDiagBw = 0; hsDiagBh = 0;
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
        }""")

# the shared state machine (STEP C onward) is needed by both paths: move it into a method the floor path can call.
c_start = s.index("        // STEP C: State Machine Update")
func_end = s.index("    void computeHighSpeedPuttResult(")
body = s[c_start:func_end]
# body ends with the closing brace of processHighSpeedCorridorFrame; split it off
last_brace = body.rstrip().rfind("}")
state_code = body[:last_brace]
s = (s[:c_start]
     + "        stateMachine(isBallFound, normX, normY, cFwdNorm, cFwdM, ballCount, yBuffer, w, h, timestampNs, uBuf, vBuf,\n"
     + "                brightThresh, bgLum, maxPeakLum, rowStride, pxStride);\n"
     + "    }\n\n"
     + "    /** Fix 14: floor path hands its detection to the same state machine as the mat path. */\n"
     + "    private void plainFloorResult(boolean found, float nx, float ny, float fwdN, float fwdM, int count, byte[] yBuffer,\n"
     + "                                  int w, int h, long timestampNs, byte[] uBuf, byte[] vBuf, int brightThresh, int bgLum) {\n"
     + "        hsDiagCount = count;\n"
     + "        stateMachine(found, nx, ny, fwdN, fwdM, count, yBuffer, w, h, timestampNs, uBuf, vBuf, brightThresh, bgLum, -1,\n"
     + "                lastRowStride, lastPxStride);\n"
     + "    }\n\n"
     + "    private int lastRowStride = 0, lastPxStride = 1;\n\n"
     + "    /** STEP C: state machine update (was the tail of processHighSpeedCorridorFrame). */\n"
     + "    private void stateMachine(boolean isBallFound, float normX, float normY, float cFwdNorm, float cFwdM, int ballCount,\n"
     + "                              byte[] yBuffer, int w, int h, long timestampNs, byte[] uBuf, byte[] vBuf,\n"
     + "                              int brightThresh, int bgLum, int maxPeakLum, int rowStride, int pxStride) {\n"
     + "        float metersPerNorm = Math.max(0.10f, hsMetersPerNormUnit);\n"
     + state_code
     + "    }\n\n"
     + s[func_end:])

# remember strides for the floor path
sub("""        if (yBuffer == null || w <= 0 || h <= 0) return;""",
"""        if (yBuffer == null || w <= 0 || h <= 0) return;
        lastRowStride = rowStride; lastPxStride = pxStride;""")

# ---------------------------------------------------------------- anchor lost: time-based
sub("""            if (++hsAnchorMissFrames >= 8) {""",
"""            if (hsAnchorMissFrames++ == 0) hsAnchorMissStartNs = timestampNs;
            if (hsAnchorMissFrames >= 8 && timestampNs - hsAnchorMissStartNs >= ANCHOR_LOST_NS) {""")

# head compensation also moves the rest position
sub("""                        hsCompX += dx; hsCompY += dy;""",
"""                        hsCompX += dx; hsCompY += dy;
                        if (hsRestNormX >= 0f) { hsRestNormX += dx; hsRestNormY += dy; }""")

# while searching, centre on the projection (a wandered candidate at the image edge blocked every later frame)
sub("""        // Current tracked ball center in image pixels
        int ballPxX = (int) (currentBallNormX * w);""",
"""        // Fix 14: while still searching for the resting ball, centre on Godot's projected tee spot. A candidate
        // that wandered to the image edge used to end every frame at the bounds check below, for good
        // (rec_20260920_175353 @ 11.8 s: the putt at 16 s was never armed).
        if (hsState == HS_STATE_ARMED && !hsAnchored && hsProjStartX >= 0f) {
            currentBallNormX = hsProjStartX;
            currentBallNormY = hsProjStartY;
        }
        // Current tracked ball center in image pixels
        int ballPxX = (int) (currentBallNormX * w);""")

open(p, "w", encoding="utf-8").write(s)
print("patched", p)

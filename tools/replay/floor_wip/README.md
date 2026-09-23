# Floor tracking (Fix 14) — applied to the game 2026-09-22

Goal: detect and track the real ball on any floor, not just the black mat.

## What failed on 2026-09-21 (rec_20260921_202308, wood floor, evening lamps)

- The old anchoring needed the ball on a dark surround (41x41 px box mean < 95). On wood the ball is only
  ~25-40 grey levels above the planks, so the resting ball was never found; no putt could be detected.
- A ceiling-lamp reflection lay 5 cm from the ball; the ball sat inside its glow for most of the address.
- The white face of the putter behind the ball is a compact bright spot that scores higher than the ball.
- The putt itself: impact at ~63.71 s, ball rolled at a steady ~1.1 m/s (checked by projecting the ball's image
  positions onto the floor with the head pose).

## What patch_tracker.py changes

- `findBlob` / `findBlobs`: ball = small compact round bright spot (centre box vs a tight ring, ring vs the floor
  further out, roundness test), position = contrast peak with sub-pixel refinement (a centroid of bright pixels was
  pulled 5 cm into the lamp glow).
- Anchoring searches around Godot's projected tee spot, never around a wandered candidate.
- Resting ball: nearest compact spot, may drift at most 8 mm from the head-compensated rest position.
- Anchor is only dropped after 0.5 s unseen (was 8 frames = 0.13 s at the 60 fps seen on 2026-09-21).
- "Plain-floor mode" (ball less than 60 levels above its surround): the ball while rolling = forward-most compact
  spot that is NOT where a spot was last frame (static things ignored), searched up to 25 cm ahead at impact.
- The black-mat path keeps its original pixel logic.

## Status (tools/replay/floor_wip/run.sh)

| | baseline | wip |
| --- | --- | --- |
| Mat putts found (9 in 4 recordings) | 9 (with the old disarm handling) | 9 |
| Fake putts on the mat | 1 | 0 |
| Floor putt (rec_20260921_202308) | missed | missed |

Variants along the way did detect the floor putt at the right moment (63.71 s), but each broke on the next hazard in
this recording: the putter face as anchor, glow patches near the projected tee. Tuning further on this one worst-case
recording would overfit.

## Next

Record 5-10 floor putts in ordinary conditions (daylight, or lamps not reflecting at the ball), keep them in
tools/sessions/regression, and tune against those plus this one. Only ship when the mat set stays 9/9 with no fakes.

## 2026-09-22: applied to PuttTracker.java

rec floor_20260922_202036 (wood floor, evening lamps, camera at ~60 fps): 3 real putts, each ~1.1 m/s when the ball is
tracked frame by frame and projected onto the floor.

| | old tracker (live) | Fix 14 (replay) |
| --- | --- | --- |
| Putt 33.3 s | missed (lost the ball after a head turn, never re-found it) | found, fit 1.14 m/s |
| Putt 105.8 s | measured 1.99 m/s (wrong samples) | found, fit 1.12 m/s |
| Putt 144.6 s | rejected (fit residual 13.5 mm) | found, fit 1.11 m/s |
| Fake at 153 s (looking at the living-room wall) | rejected | not triggered |

Mat set still 9/9 with 0 fakes. The older floor recordings (202308, 214040: lamp glare next to the ball) are still missed.
Blips (1-2 tracked points) no longer count as a lost putt, so they don't show "PUTT NOT MEASURED" (toe nudges, waggles).
patch_tracker.py is kept for reference only; it patches the pre-Fix-14 file.

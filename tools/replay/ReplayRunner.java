import com.godot.game.PuttTracker;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.regex.*;
import java.util.zip.Inflater;

/**
 * Replays a Quest session recording (tools/sessions/.../recordings/rec_*) through the real PuttTracker code
 * (android/build/src/main/java/com/godot/game/PuttTracker.java) and writes every putt it detects.
 *
 * It emulates what Godot does each frame: corridor arm/disarm calls are replayed from the recording, and when the
 * tracker reports a finished putt the result is read and cleared (like _check_and_process_high_speed_putt).
 *
 * Output (in the recording folder):
 *   replay_tracker.log     - every tracker log line with replay time
 *   replay_putts.jsonl     - one line per detected putt: telemetry + samples with absolute capture time (ns)
 */
public class ReplayRunner {
    static final Pattern NUM = Pattern.compile("-?[0-9]+(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?");

    static class Ev { long t; String type; String raw; }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) { System.err.println("usage: ReplayRunner <rec_dir> [--quiet]"); System.exit(1); }
        File dir = new File(args[0]);
        boolean quiet = Arrays.asList(args).contains("--quiet");
        final boolean ignoreDisarm = Arrays.asList(args).contains("--ignore-disarm");

        List<Ev> events = new ArrayList<>();
        try (BufferedReader br = new BufferedReader(new InputStreamReader(new FileInputStream(new File(dir, "events.jsonl")), StandardCharsets.UTF_8))) {
            String line;
            while ((line = br.readLine()) != null) {
                Matcher mt = Pattern.compile("\"t_ns\":(-?\\d+)").matcher(line);
                Matcher mty = Pattern.compile("\"type\":\"(\\w+)\"").matcher(line);
                if (!mt.find() || !mty.find()) continue;
                Ev e = new Ev(); e.t = Long.parseLong(mt.group(1)); e.type = mty.group(1); e.raw = line;
                events.add(e);
            }
        }
        events.sort(Comparator.comparingLong(e -> e.t));
        long t0 = events.isEmpty() ? 0 : events.get(0).t;

        final long[] now = {0};
        final long[] latency = {-1};
        PuttTracker.nanoClock = () -> now[0];
        PuttTracker.bootClockNs = () -> now[0];

        PrintWriter logOut = new PrintWriter(new OutputStreamWriter(new FileOutputStream(new File(dir, "replay_tracker.log")), StandardCharsets.UTF_8));
        PrintWriter putOut = new PrintWriter(new OutputStreamWriter(new FileOutputStream(new File(dir, "replay_putts.jsonl")), StandardCharsets.UTF_8));
        PuttTracker tr = new PuttTracker();
        final long base = t0;
        tr.hooks = new PuttTracker.Hooks() {
            public void log(String msg) {
                String s = String.format(Locale.US, "%8.3fs  %s", (now[0] - base) / 1e9, msg);
                logOut.println(s);
                if (!quiet && (msg.contains("IMPACT") || msg.contains("CONFIRMED") || msg.contains("Discarded") || msg.contains("anchored"))) System.out.println(s);
            }
            public void setExposureLock(boolean locked) { }
            public void event(String json) { }
            public void runAsync(Runnable r) { }  // dashboards are not rendered in replay
            public void renderDashboard(int w, int h, int rowStride, int pxStride, List<PuttTracker.HighSpeedPoint> pts,
                                        byte[] f1, float a1, float b1, byte[] f2, float a2, float b2, byte[] f3, byte[] u3, byte[] v3, float a3, float b3,
                                        boolean hasColor, int us, int up, int vs, int vp, float speed, float angle, float fps) { }
        };

        int evIdx = 0, frames = 0, putts = 0, lowResWhileActive = 0;
        Inflater inf = new Inflater();
        byte[] y = null;
        int colorFrames = 0;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(new File(dir, "frames.bin")), 1 << 20))) {
            while (true) {
                int magic;
                try { magic = in.readInt(); } catch (EOFException eof) { break; }
                if (magic != 0x46524D31 && magic != 0x46524D32) throw new IOException("bad frame magic at frame " + frames);
                boolean color = magic == 0x46524D32; // FRM2: Y (w*h) then U and V planes ((w/2)*(h/2) each)
                long sensorTs = in.readLong(), arrival = in.readLong(), lat = in.readLong();
                int w = in.readInt(), h = in.readInt(), len = in.readInt();
                byte[] comp = new byte[len];
                in.readFully(comp);
                int need = w * h + (color ? 2 * (w / 2) * (h / 2) : 0);
                if (y == null || y.length != need) y = new byte[need];
                inf.reset(); inf.setInput(comp);
                int got = 0;
                while (got < y.length && !inf.finished()) got += inf.inflate(y, got, y.length - got);
                if (color) {
                    // hand the colour planes to the tracker exactly like the live bridge does
                    int cw = w / 2, cs = cw * (h / 2);
                    tr.latestUBuffer = Arrays.copyOfRange(y, w * h, w * h + cs);
                    tr.latestVBuffer = Arrays.copyOfRange(y, w * h + cs, w * h + 2 * cs);
                    tr.uRowStride = cw; tr.vRowStride = cw; tr.uPixelStride = 1; tr.vPixelStride = 1;
                    tr.hasColorPlanes = true;
                    colorFrames++;
                } else {
                    tr.hasColorPlanes = false;
                }

                // Replay recorded Godot->tracker calls that happened before this frame was processed
                while (evIdx < events.size() && events.get(evIdx).t <= arrival) {
                    Ev e = events.get(evIdx++);
                    now[0] = e.t;
                    if (e.type.equals("arm")) {
                        List<Float> v = nums(e.raw.substring(e.raw.indexOf("\"roi\"")));
                        tr.armHighSpeedCorridorInternal(v.get(0), v.get(1), v.get(2), v.get(3), v.get(4), v.get(5), v.get(6), v.get(7), v.get(8), v.get(9));
                    } else if (e.type.equals("disarm")) {
                        // --ignore-disarm: recordings made with an older tracker disarm right after ITS handoff,
                        // which would cut a longer measuring window short in the replay.
                        if (!ignoreDisarm) tr.disarmHighSpeedCorridorInternal();
                    }
                    // recorded "clear" events are ignored: the replay clears its own results below
                }

                now[0] = arrival;
                PuttTracker.latencyOverrideNs = lat;
                tr.frameCount = frames;
                if (tr.isActive()) {
                    if (w >= 600) tr.processHighSpeedCorridorFrame(y, w, h, w, 1, sensorTs);
                    else lowResWhileActive++;   // recorder was still in preview mode (should not happen)
                }
                frames++;

                if (tr.isHsPuttReady) {
                    float[] tele;
                    synchronized (tr.hsTelemetryResult) { tele = tr.hsTelemetryResult.clone(); }
                    float[] smp = tr.getHighSpeedSamples();
                    putts++;
                    StringBuilder sb = new StringBuilder();
                    sb.append(String.format(Locale.US, "{\"putt\":%d,\"t_s\":%.3f,\"now_ns\":%d,\"gate_speed\":%.4f,\"gate_angle\":%.3f,\"gate_points\":%d,\"samples\":[",
                        putts, (arrival - t0) / 1e9, arrival, tele[0], tele[1], (int) tele[2]));
                    int n = (int) smp[0];
                    for (int i = 0; i < n; i++) {
                        float tRel = smp[1 + i * 4], age = smp[2 + i * 4], nx = smp[3 + i * 4], ny = smp[4 + i * 4];
                        long capNs = arrival - (long) (age * 1e9);
                        if (i > 0) sb.append(',');
                        sb.append(String.format(Locale.US, "[%.5f,%d,%.6f,%.6f]", tRel, capNs, nx, ny));
                    }
                    sb.append("]}");
                    putOut.println(sb);
                    String msg = String.format(Locale.US, "%8.3fs  >>> PUTT #%d detected: gate %.2f m/s, %d samples", (arrival - t0) / 1e9, putts, tele[0], n);
                    System.out.println(msg); logOut.println(msg);
                    tr.clearHighSpeedPuttInternal();   // what Godot does after reading the result
                }
            }
        }
        logOut.close(); putOut.close();
        if (lowResWhileActive > 0) System.out.println("WARNING: " + lowResWhileActive + " preview (low-res) frames while the tracker was active were skipped");
        System.out.println(String.format(Locale.US, "Replayed %d frames (%d with colour), %d events -> %d putt(s) detected. Log: %s",
            frames, colorFrames, events.size(), putts, new File(dir, "replay_tracker.log").getPath()));
    }

    static List<Float> nums(String s) {
        List<Float> out = new ArrayList<>();
        Matcher m = NUM.matcher(s);
        while (m.find()) out.add(Float.parseFloat(m.group()));
        return out;
    }
}

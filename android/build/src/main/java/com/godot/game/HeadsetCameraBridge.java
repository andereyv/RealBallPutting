package com.godot.game;

import android.content.Context;
import android.graphics.ImageFormat;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.util.Range;
import android.view.Surface;

import android.util.Size;
import android.hardware.camera2.params.StreamConfigurationMap;

import androidx.annotation.NonNull;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CopyOnWriteArrayList;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Environment;
import java.io.File;
import java.io.FileOutputStream;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class HeadsetCameraBridge {
    private static final String TAG = "HeadsetCameraBridge";
    private static HeadsetCameraBridge instance;

    public enum CameraState { CLOSED, OPENING, RUNNING, CLOSING }
    private volatile CameraState cameraState = CameraState.CLOSED;

    private Context context;
    private CameraManager cameraManager;
    private CameraDevice cameraDevice;
    private CameraCaptureSession captureSession;
    private ImageReader imageReader;

    // Stereo Camera Support (Camera 50 = Left, Camera 51 = Right)
    private CameraDevice cameraDeviceLeft;
    private CameraCaptureSession captureSessionLeft;
    private ImageReader imageReaderLeft;
    private String leftCameraId = "50";

    private CameraDevice cameraDeviceRight;
    private CameraCaptureSession captureSessionRight;
    private ImageReader imageReaderRight;
    private String rightCameraId = "51";
    private boolean isRightCameraRunning = false;

    private CaptureRequest.Builder captureBuilderLeft = null;
    private CaptureRequest.Builder captureBuilderRight = null;
    private volatile boolean isAeLocked = false;

    private HandlerThread backgroundThread;
    private Handler backgroundHandler;
    private HandlerThread inferenceThread;
    private Handler inferenceHandler;

    private final ExecutorService snapshotExecutor = Executors.newSingleThreadExecutor();

    private volatile boolean isRunning = false;
    private volatile byte[] latestYBuffer = null;
    private volatile byte[] latestUBuffer = null;
    private volatile byte[] latestVBuffer = null;
    private volatile boolean hasColorPlanes = false;
    private int frameWidth = 0;
    private int frameHeight = 0;
    private int frameRowStride = 0;
    private int framePixelStride = 1;
    private int uRowStride = 0;
    private int uPixelStride = 1;
    private int vRowStride = 0;
    private int vPixelStride = 1;
    private long frameCount = 0;
    private long inferenceCount = 0;

    // Right Camera YUV Buffers
    private volatile byte[] latestYBufferRight = null;
    private volatile byte[] latestUBufferRight = null;
    private volatile byte[] latestVBufferRight = null;
    private volatile boolean hasColorPlanesRight = false;
    private int frameRowStrideRight = 0;
    private int framePixelStrideRight = 1;
    private int uRowStrideRight = 0;
    private int uPixelStrideRight = 1;
    private int vRowStrideRight = 0;
    private int vPixelStrideRight = 1;
    private long frameCountRight = 0;

    // Dedicated worker buffers for YOLO inference (eliminates thread tearing)
    private byte[] inferenceYBuffer = null;
    private byte[] inferenceUBuffer = null;
    private byte[] inferenceVBuffer = null;
    private byte[] inferenceYBufferRight = null;
    private final Object bufferLock = new Object();

    // Persistent reusable float buffer for ONNX input (eliminates 4.9MB GC allocation per frame)
    private float[] reusablePlanarFloats = null;

    // Pre-computed lookup table for low-light adaptive gamma curve (lifts floor shadow contrast by ~80% with 0ms CPU overhead)
    private static final float[] GAMMA_TABLE_LOW_LIGHT = new float[256];
    static {
        for (int i = 0; i < 256; i++) {
            GAMMA_TABLE_LOW_LIGHT[i] = (float) (Math.pow(i / 255.0, 0.70) * 255.0);
        }
    }

    private volatile float[] latestStereoDetection = new float[]{0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    private volatile long yoloDetectionSeq = 0L;
    private volatile float latestRightNormX = 0f;
    private volatile float latestRightNormY = 0f;
    private volatile boolean latestHasStereo = false;

    // ONNX Runtime YOLOv8
    private OrtEnvironment ortEnv;
    private OrtSession ortSession;
    private boolean isModelLoaded = false;
    private FloatBuffer inputBuffer;
    private static final int MODEL_WIDTH = 640;
    private static final int MODEL_HEIGHT = 640;
    // COCO Class 32 is "sports ball" -> in YOLOv8 (no obj branch), offset is 4 + 32 = 36
    private static final int SPORTS_BALL_CLASS_IDX = 36;
    private static final String[] COCO_SAMPLE_NAMES = new String[]{
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
        "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
        "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
        "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
        "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed",
        "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave", "oven",
        "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    };

    private volatile boolean isInferenceRunning = false;
    private static volatile boolean isYoloPaused = false;

    public static void pauseYoloInference() {
        isYoloPaused = true;
        Log.i(TAG, "[YOLO] Inference PAUSED (0% CPU, 60Hz Classical CV active)");
    }

    public static void resumeYoloInference() {
        isYoloPaused = false;
        Log.i(TAG, "[YOLO] Inference RESUMED (Searching for ball on tee)");
    }

    public static boolean isYoloPaused() {
        return isYoloPaused;
    }

    private volatile float[] latestBallDetection = new float[]{0.0f, 0.0f, 0.0f, 0.0f, 0.0f};

    // Region of Interest (ROI) for Mini Tee Box
    private volatile boolean isRoiEnabled = false;
    private volatile float roiNormLeft = 0.0f;
    private volatile float roiNormTop = 0.0f;
    private volatile float roiNormRight = 1.0f;
    private volatile float roiNormBottom = 1.0f;

    // Fields for calibration bundle export
    private volatile float[] latestCropFloats = null;
    private volatile float latestNormX = 0f;
    private volatile float latestNormY = 0f;
    private volatile float latestNormW = 0f;
    private volatile float latestNormH = 0f;
    private volatile float latestConf = 0f;
    private volatile float latestFullNormX = 0f;
    private volatile float latestFullNormY = 0f;
    private volatile float latestFullNormW = 0f;
    private volatile float latestFullNormH = 0f;
    private volatile Bitmap snippetBmp1 = null;
    private volatile Bitmap snippetBmp2 = null;

    public static void setTeeBoxRoi(float left, float top, float right, float bottom) {
        if (instance != null) {
            if (left < 0.0f || right <= left || bottom <= top) {
                instance.isRoiEnabled = false;
            } else {
                instance.roiNormLeft = Math.max(0.0f, Math.min(1.0f, left));
                instance.roiNormTop = Math.max(0.0f, Math.min(1.0f, top));
                instance.roiNormRight = Math.max(0.0f, Math.min(1.0f, right));
                instance.roiNormBottom = Math.max(0.0f, Math.min(1.0f, bottom));
                instance.isRoiEnabled = true;
            }
        }
    }

    public static void clearTeeBoxRoi() {
        if (instance != null) {
            instance.isRoiEnabled = false;
        }
    }

    public static boolean isTeeBoxRoiActive() {
        return (instance != null && instance.isRoiEnabled);
    }

    public static synchronized HeadsetCameraBridge getInstance(Context ctx) {
        if (instance == null) {
            instance = new HeadsetCameraBridge(ctx);
        }
        return instance;
    }

    public static HeadsetCameraBridge getInstance() {
        return instance;
    }

    public static void init(Context ctx) {
        if (instance == null) {
            instance = new HeadsetCameraBridge(ctx);
        }
    }

    public HeadsetCameraBridge(Context ctx) {
        this.context = ctx.getApplicationContext();
        instance = this;
        initTrackerHooks();
        initYoloModel();
    }

    private void initYoloModel() {
        try {
            Log.i(TAG, "[YOLO] Initializing ONNX Runtime environment...");
            ortEnv = OrtEnvironment.getEnvironment();
            OrtSession.SessionOptions opts = new OrtSession.SessionOptions();
            opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);

            // Pre-allocate input float buffer for 1 x 3 x 320 x 320 NCHW planar floats
            inputBuffer = FloatBuffer.allocate(1 * 3 * MODEL_WIDTH * MODEL_HEIGHT);
            reusablePlanarFloats = new float[1 * 3 * MODEL_WIDTH * MODEL_HEIGHT];

            Log.i(TAG, "[YOLO] Resolving 'yolov8n.onnx' in Android assets...");
            InputStream is = null;
            try {
                is = context.getAssets().open("yolov8n.onnx");
            } catch (Exception e1) {
                try {
                    is = context.getAssets().open("assets/yolov8n.onnx");
                } catch (Exception e2) {
                    String[] rootAssets = context.getAssets().list("");
                    Log.i(TAG, "[YOLO] Root assets list: " + String.join(", ", rootAssets));
                    for (String a : rootAssets) {
                        if (a.contains("yolov8") || a.endsWith(".onnx")) {
                            Log.i(TAG, "[YOLO] Found candidate ONNX asset: " + a);
                            is = context.getAssets().open(a);
                            break;
                        }
                    }
                }
            }

            if (is == null) {
                throw new java.io.FileNotFoundException("Could not find yolov8n.onnx in assets!");
            }

            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[32768];
            int n;
            while ((n = is.read(buf)) != -1) {
                baos.write(buf, 0, n);
            }
            is.close();
            byte[] modelBytes = baos.toByteArray();
            Log.i(TAG, "[YOLO] Successfully read model bytes: " + modelBytes.length + " bytes. Creating ONNX session...");

            ortSession = ortEnv.createSession(modelBytes, opts);
            isModelLoaded = true;
            Log.i(TAG, "[YOLO] SUCCESS: YOLOv8 ONNX model loaded! Ready for sports ball detection.");
        } catch (Exception e) {
            Log.e(TAG, "[YOLO] ERROR initializing ONNX Runtime model: " + e.getMessage(), e);
            isModelLoaded = false;
        }
    }

    public synchronized void startCamera() {
        if (!isModelLoaded || ortSession == null) {
            initYoloModel();
        }

        if (cameraState != CameraState.CLOSED) {
            Log.w(TAG, "Camera cannot start in state: " + cameraState);
            return;
        }
        cameraState = CameraState.OPENING;

        try {
            Log.i(TAG, "Attempting to start headset dual stereo cameras via Camera2 with YUV_420_888...");
            cameraManager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
            if (cameraManager == null) {
                Log.e(TAG, "CameraManager not available.");
                return;
            }

            String[] cameraIds = cameraManager.getCameraIdList();
            Log.i(TAG, "Available Camera IDs: " + String.join(", ", cameraIds));

            if (cameraIds.length == 0) {
                Log.e(TAG, "No cameras reported by CameraManager!");
                return;
            }

            for (String id : cameraIds) {
                try {
                    CameraCharacteristics chars = cameraManager.getCameraCharacteristics(id);
                    Integer facing = chars.get(CameraCharacteristics.LENS_FACING);
                    Log.i(TAG, "Camera ID " + id + ": facing=" + facing);
                } catch (Exception ignored) {}
            }

            // Identify Left (50) and Right (51) color cameras
            leftCameraId = null;
            rightCameraId = null;

            for (String id : cameraIds) {
                if ("50".equals(id)) leftCameraId = id;
                if ("51".equals(id)) rightCameraId = id;
            }

            // Fallback if 50 / 51 not explicitly present: pick back-facing cameras
            if (leftCameraId == null || rightCameraId == null) {
                java.util.List<String> backCams = new java.util.ArrayList<>();
                for (String id : cameraIds) {
                    try {
                        CameraCharacteristics chars = cameraManager.getCameraCharacteristics(id);
                        Integer facing = chars.get(CameraCharacteristics.LENS_FACING);
                        if (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK) {
                            backCams.add(id);
                        }
                    } catch (Exception ignored) {}
                }
                if (leftCameraId == null && backCams.size() > 0) leftCameraId = backCams.get(0);
                if (rightCameraId == null && backCams.size() > 1) rightCameraId = backCams.get(1);
            }

            if (leftCameraId == null) {
                leftCameraId = cameraIds[0];
            }

            Log.i(TAG, "Selected Stereo Cameras: Left=" + leftCameraId + ", Right=" + rightCameraId);

            // Determine optimal supported resolution for YUV_420_888
            frameWidth = 640;
            frameHeight = 480;
            try {
                CameraCharacteristics selChars = cameraManager.getCameraCharacteristics(leftCameraId);
                StreamConfigurationMap map = selChars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                if (map != null) {
                    Size[] yuvSizes = map.getOutputSizes(ImageFormat.YUV_420_888);
                    if (yuvSizes != null && yuvSizes.length > 0) {
                        for (Size s : yuvSizes) {
                            if (s.getWidth() == 640 && s.getHeight() == 480) {
                                frameWidth = 640;
                                frameHeight = 480;
                                break;
                            }
                        }
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "Could not determine output sizes: " + e.getMessage());
            }

            Log.i(TAG, "Configuring ImageReaders at resolution: " + frameWidth + "x" + frameHeight);
            readLensCalibration(leftCameraId);

            backgroundThread = new HandlerThread("CameraBackgroundThread");
            backgroundThread.start();
            backgroundHandler = new Handler(backgroundThread.getLooper());

            inferenceThread = new HandlerThread("YoloInferenceThread");
            inferenceThread.start();
            inferenceHandler = new Handler(inferenceThread.getLooper());

            // 1. Setup Left Camera ImageReader
            imageReaderLeft = ImageReader.newInstance(frameWidth, frameHeight, ImageFormat.YUV_420_888, 3);
            imageReader = imageReaderLeft;
            imageReaderLeft.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
                @Override
                public void onImageAvailable(ImageReader reader) {
                    Image img = null;
                    try {
                        img = reader.acquireLatestImage();
                        if (img == null) {
                            img = reader.acquireNextImage();
                        }
                        if (img != null) {
                            Image.Plane[] planes = img.getPlanes();
                            if (planes != null && planes.length > 0) {
                                Image.Plane yPlane = planes[0];
                                ByteBuffer yBuf = yPlane.getBuffer();
                                int ySize = yBuf.remaining();
                                frameRowStride = yPlane.getRowStride();
                                framePixelStride = yPlane.getPixelStride();

                                if (latestYBuffer == null || latestYBuffer.length != ySize) {
                                    latestYBuffer = new byte[ySize];
                                }
                                yBuf.get(latestYBuffer);

                                if (planes.length >= 3) {
                                    Image.Plane uPlane = planes[1];
                                    Image.Plane vPlane = planes[2];
                                    ByteBuffer uBuf = uPlane.getBuffer();
                                    ByteBuffer vBuf = vPlane.getBuffer();
                                    int uSize = uBuf.remaining();
                                    int vSize = vBuf.remaining();
                                    uRowStride = uPlane.getRowStride();
                                    uPixelStride = uPlane.getPixelStride();
                                    vRowStride = vPlane.getRowStride();
                                    vPixelStride = vPlane.getPixelStride();

                                    if (latestUBuffer == null || latestUBuffer.length != uSize) {
                                        latestUBuffer = new byte[uSize];
                                    }
                                    if (latestVBuffer == null || latestVBuffer.length != vSize) {
                                        latestVBuffer = new byte[vSize];
                                    }
                                    uBuf.get(latestUBuffer);
                                    vBuf.get(latestVBuffer);
                                    hasColorPlanes = true;
                                }

                                frameCount++;
                                if (frameCount % 60 == 0 || frameCount <= 3) {
                                    Log.i(TAG, "Left Cam (#" + leftCameraId + ") frame #" + frameCount + " (" + (hasColorPlanes ? "Color YUV" : "Mono Y") + ")");
                                }

                                // Session recorder (replay on Mac): grayscale frame + sensor timestamp
                                if (sessionRecorder != null) {
                                    // Full resolution while the tracker watches the ball (+1 s), quarter size otherwise
                                    long nowNs = System.nanoTime();
                                    if (tracker.hsState != PuttTracker.HS_STATE_IDLE) recFullResUntilNs = nowNs + 1_000_000_000L;
                                    sessionRecorder.offerFrame(latestYBuffer, frameWidth, frameHeight, frameRowStride, framePixelStride,
                                        img.getTimestamp(), nowNs < recFullResUntilNs);
                                }

                                // High-Speed Differential Putting Corridor Tracker (60-90 Hz, < 0.1 ms)
                                tracker.frameCount = frameCount;
                                tracker.latestUBuffer = latestUBuffer;
                                tracker.latestVBuffer = latestVBuffer;
                                tracker.hasColorPlanes = hasColorPlanes;
                                tracker.uPixelStride = uPixelStride; tracker.vPixelStride = vPixelStride;
                                tracker.uRowStride = uRowStride; tracker.vRowStride = vRowStride;
                                if (tracker.isActive()) {
                                    tracker.processHighSpeedCorridorFrame(latestYBuffer, frameWidth, frameHeight, frameRowStride, framePixelStride, img.getTimestamp());
                                }
                            }

                            // Trigger asynchronous background YOLO inference on dedicated thread
                            if (isModelLoaded && !isYoloPaused && !isInferenceRunning && inferenceHandler != null) {
                                isInferenceRunning = true;
                                synchronized (bufferLock) {
                                    if (latestYBuffer != null) {
                                        int yLen = latestYBuffer.length;
                                        if (inferenceYBuffer == null || inferenceYBuffer.length != yLen) {
                                            inferenceYBuffer = new byte[yLen];
                                        }
                                        System.arraycopy(latestYBuffer, 0, inferenceYBuffer, 0, yLen);
                                    }
                                    if (hasColorPlanes && latestUBuffer != null && latestVBuffer != null) {
                                        int uLen = latestUBuffer.length;
                                        int vLen = latestVBuffer.length;
                                        if (inferenceUBuffer == null || inferenceUBuffer.length != uLen) {
                                            inferenceUBuffer = new byte[uLen];
                                        }
                                        if (inferenceVBuffer == null || inferenceVBuffer.length != vLen) {
                                            inferenceVBuffer = new byte[vLen];
                                        }
                                        System.arraycopy(latestUBuffer, 0, inferenceUBuffer, 0, uLen);
                                        System.arraycopy(latestVBuffer, 0, inferenceVBuffer, 0, vLen);
                                    }
                                    if (latestYBufferRight != null) {
                                        int rYLen = latestYBufferRight.length;
                                        if (inferenceYBufferRight == null || inferenceYBufferRight.length != rYLen) {
                                            inferenceYBufferRight = new byte[rYLen];
                                        }
                                        System.arraycopy(latestYBufferRight, 0, inferenceYBufferRight, 0, rYLen);
                                    }
                                }
                                inferenceHandler.post(new Runnable() {
                                    @Override
                                    public void run() {
                                        try {
                                            runInferenceInternal();
                                        } finally {
                                            isInferenceRunning = false;
                                        }
                                    }
                                });
                            }
                        }
                    } catch (Exception e) {
                        Log.e(TAG, "Error acquiring Left image: " + e.getMessage());
                    } finally {
                        if (img != null) {
                            img.close();
                        }
                    }
                }
            }, backgroundHandler);

            // 2. Setup Right Camera ImageReader (if available)
            if (rightCameraId != null) {
                imageReaderRight = ImageReader.newInstance(frameWidth, frameHeight, ImageFormat.YUV_420_888, 3);
                imageReaderRight.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
                    @Override
                    public void onImageAvailable(ImageReader reader) {
                        Image img = null;
                        try {
                            img = reader.acquireLatestImage();
                            if (img == null) {
                                img = reader.acquireNextImage();
                            }
                            if (img != null) {
                                Image.Plane[] planes = img.getPlanes();
                                if (planes != null && planes.length > 0) {
                                    Image.Plane yPlane = planes[0];
                                    ByteBuffer yBuf = yPlane.getBuffer();
                                    int ySize = yBuf.remaining();
                                    frameRowStrideRight = yPlane.getRowStride();
                                    framePixelStrideRight = yPlane.getPixelStride();

                                    if (latestYBufferRight == null || latestYBufferRight.length != ySize) {
                                        latestYBufferRight = new byte[ySize];
                                    }
                                    yBuf.get(latestYBufferRight);

                                    if (planes.length >= 3) {
                                        Image.Plane uPlane = planes[1];
                                        Image.Plane vPlane = planes[2];
                                        ByteBuffer uBuf = uPlane.getBuffer();
                                        ByteBuffer vBuf = vPlane.getBuffer();
                                        int uSize = uBuf.remaining();
                                        int vSize = vBuf.remaining();
                                        uRowStrideRight = uPlane.getRowStride();
                                        uPixelStrideRight = uPlane.getPixelStride();
                                        vRowStrideRight = vPlane.getRowStride();
                                        vPixelStrideRight = vPlane.getPixelStride();

                                        if (latestUBufferRight == null || latestUBufferRight.length != uSize) {
                                            latestUBufferRight = new byte[uSize];
                                        }
                                        if (latestVBufferRight == null || latestVBufferRight.length != vSize) {
                                            latestVBufferRight = new byte[vSize];
                                        }
                                        uBuf.get(latestUBufferRight);
                                        vBuf.get(latestVBufferRight);
                                        hasColorPlanesRight = true;
                                    }

                                    frameCountRight++;
                                    if (frameCountRight % 60 == 0 || frameCountRight <= 3) {
                                        Log.i(TAG, "Right Cam (#" + rightCameraId + ") frame #" + frameCountRight + " (" + (hasColorPlanesRight ? "Color YUV" : "Mono Y") + ")");
                                    }
                                }
                            }
                        } catch (Exception e) {
                            Log.e(TAG, "Error acquiring Right image: " + e.getMessage());
                        } finally {
                            if (img != null) {
                                img.close();
                            }
                        }
                    }
                }, backgroundHandler);
            }

            // Open Left Camera
            cameraManager.openCamera(leftCameraId, new CameraDevice.StateCallback() {
                @Override
                public void onOpened(@NonNull CameraDevice camera) {
                    if (cameraState != CameraState.OPENING && cameraState != CameraState.RUNNING) {
                        Log.w(TAG, "Left Camera opened while state=" + cameraState + ", closing immediately.");
                        camera.close();
                        return;
                    }
                    Log.i(TAG, "Left Camera " + leftCameraId + " successfully opened!");
                    cameraDeviceLeft = camera;
                    cameraDevice = camera;
                    createCaptureSessionLeft();
                }

                @Override
                public void onDisconnected(@NonNull CameraDevice camera) {
                    Log.w(TAG, "Left Camera " + leftCameraId + " disconnected.");
                    camera.close();
                    cameraDeviceLeft = null;
                    cameraDevice = null;
                    isRunning = false;
                    cameraState = CameraState.CLOSED;
                }

                @Override
                public void onError(@NonNull CameraDevice camera, int error) {
                    Log.e(TAG, "Left Camera " + leftCameraId + " error: " + error);
                    camera.close();
                    cameraDeviceLeft = null;
                    cameraDevice = null;
                    isRunning = false;
                    cameraState = CameraState.CLOSED;
                }
            }, backgroundHandler);

            // Open Right Camera
            if (rightCameraId != null) {
                cameraManager.openCamera(rightCameraId, new CameraDevice.StateCallback() {
                    @Override
                    public void onOpened(@NonNull CameraDevice camera) {
                        if (cameraState != CameraState.OPENING && cameraState != CameraState.RUNNING) {
                            Log.w(TAG, "Right Camera opened while state=" + cameraState + ", closing immediately.");
                            camera.close();
                            return;
                        }
                        Log.i(TAG, "Right Camera " + rightCameraId + " successfully opened!");
                        cameraDeviceRight = camera;
                        isRightCameraRunning = true;
                        createCaptureSessionRight();
                    }

                    @Override
                    public void onDisconnected(@NonNull CameraDevice camera) {
                        Log.w(TAG, "Right Camera " + rightCameraId + " disconnected.");
                        camera.close();
                        cameraDeviceRight = null;
                        isRightCameraRunning = false;
                    }

                    @Override
                    public void onError(@NonNull CameraDevice camera, int error) {
                        Log.e(TAG, "Right Camera " + rightCameraId + " error: " + error);
                        camera.close();
                        cameraDeviceRight = null;
                        isRightCameraRunning = false;
                    }
                }, backgroundHandler);
            }

            isRunning = true;
            startStreamServer(8080);
        } catch (SecurityException se) {
            Log.e(TAG, "SecurityException opening camera: " + se.getMessage(), se);
        } catch (CameraAccessException cae) {
            Log.e(TAG, "CameraAccessException opening camera: " + cae.getMessage(), cae);
        } catch (Exception e) {
            Log.e(TAG, "Exception opening camera: " + e.getMessage(), e);
        }
    }

    private void createCaptureSessionLeft() {
        try {
            if (cameraDeviceLeft == null || imageReaderLeft == null) return;
            Surface readerSurface = imageReaderLeft.getSurface();
            captureBuilderLeft = cameraDeviceLeft.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            final CaptureRequest.Builder captureBuilder = captureBuilderLeft;
            captureBuilder.addTarget(readerSurface);
            captureBuilder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO);
            captureBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF);
            captureBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);

            setOptimalFps(cameraDeviceLeft, captureBuilder);

            cameraDeviceLeft.createCaptureSession(Collections.singletonList(readerSurface), new CameraCaptureSession.StateCallback() {
                @Override
                public void onConfigured(@NonNull CameraCaptureSession session) {
                    if (cameraState != CameraState.OPENING && cameraState != CameraState.RUNNING) {
                        Log.w(TAG, "Left session configured while cameraState=" + cameraState + ", closing.");
                        session.close();
                        return;
                    }
                    cameraState = CameraState.RUNNING;
                    captureSessionLeft = session;
                    captureSession = session;
                    try {
                        captureSessionLeft.setRepeatingRequest(captureBuilder.build(), null, backgroundHandler);
                        Log.i(TAG, "Repeating capture request started on Left camera (" + leftCameraId + ")!");
                    } catch (CameraAccessException e) {
                        Log.e(TAG, "Failed starting Left repeating request: " + e.getMessage());
                    }
                }

                @Override
                public void onConfigureFailed(@NonNull CameraCaptureSession session) {
                    Log.e(TAG, "Left CameraCaptureSession configuration failed.");
                }
            }, backgroundHandler);
        } catch (Exception e) {
            Log.e(TAG, "Exception creating Left capture session: " + e.getMessage(), e);
        }
    }

    private void createCaptureSessionRight() {
        try {
            if (cameraDeviceRight == null || imageReaderRight == null) return;
            Surface readerSurface = imageReaderRight.getSurface();
            captureBuilderRight = cameraDeviceRight.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            final CaptureRequest.Builder captureBuilder = captureBuilderRight;
            captureBuilder.addTarget(readerSurface);
            captureBuilder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO);
            captureBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF);
            captureBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);

            setOptimalFps(cameraDeviceRight, captureBuilder);

            cameraDeviceRight.createCaptureSession(Collections.singletonList(readerSurface), new CameraCaptureSession.StateCallback() {
                @Override
                public void onConfigured(@NonNull CameraCaptureSession session) {
                    if (cameraState != CameraState.OPENING && cameraState != CameraState.RUNNING) {
                        Log.w(TAG, "Right session configured while cameraState=" + cameraState + ", closing.");
                        session.close();
                        return;
                    }
                    captureSessionRight = session;
                    try {
                        captureSessionRight.setRepeatingRequest(captureBuilder.build(), null, backgroundHandler);
                        Log.i(TAG, "Repeating capture request started on Right camera (" + rightCameraId + ")!");
                    } catch (CameraAccessException e) {
                        Log.e(TAG, "Failed starting Right repeating request: " + e.getMessage());
                    }
                }

                @Override
                public void onConfigureFailed(@NonNull CameraCaptureSession session) {
                    Log.e(TAG, "Right CameraCaptureSession configuration failed.");
                }
            }, backgroundHandler);
        } catch (Exception e) {
            Log.e(TAG, "Exception creating Right capture session: " + e.getMessage(), e);
        }
    }

    // =========================================================================
    // SESSION RECORDER: records the raw grayscale camera stream + timestamps + head poses + tracker events,
    // so putting sessions can be replayed through the tracker on the Mac (tools/replay).
    // File layout in <externalFiles>/recordings/rec_<wallclock>/ :
    //   frames.bin  : repeated [magic 'FRM1'(4) | sensorTsNs(8) | arrivalNanoTime(8) | captureLatencyNs(8) | w(4) | h(4) | compLen(4) | deflate(Y w*h)]
    //   events.jsonl: one JSON object per line, each with "t_ns" (System.nanoTime) — head poses, arm/disarm, game events
    //   meta.json   : written by Godot (tee pose, camera params, calibration)
    // =========================================================================
    private static volatile SessionRecorder sessionRecorder = null;
    private long recFullResUntilNs = 0L;

    public static String startSessionRecording(int maxSeconds) {
        if (instance == null) return "";
        stopSessionRecording();
        try {
            File base = (instance.context != null) ? instance.context.getExternalFilesDir(null) : null;
            if (base == null) base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            String stamp = new java.text.SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(new java.util.Date());
            File dir = new File(new File(base, "recordings"), "rec_" + stamp);
            if (!dir.mkdirs() && !dir.isDirectory()) return "";
            sessionRecorder = new SessionRecorder(dir, maxSeconds);
            sessionRecorder.event(String.format(Locale.US,
                "{\"type\":\"start\",\"calib\":%s}", java.util.Arrays.toString(lensCalib)));
            Log.i(TAG, "[REC] Recording started: " + dir.getAbsolutePath());
            return dir.getAbsolutePath();
        } catch (Exception e) {
            Log.e(TAG, "[REC] Could not start recording: " + e.getMessage());
            sessionRecorder = null;
            return "";
        }
    }

    public static void stopSessionRecording() {
        SessionRecorder rec = sessionRecorder;
        sessionRecorder = null;
        if (rec != null) rec.close();
    }

    public static boolean isSessionRecording() {
        SessionRecorder rec = sessionRecorder;
        if (rec != null && rec.isExpired()) {
            stopSessionRecording();
            return false;
        }
        return rec != null;
    }

    /** Head pose from Godot (world position + rotation quaternion), timestamped here on the camera clock side. */
    public static void recordHeadPose(float px, float py, float pz, float qx, float qy, float qz, float qw) {
        SessionRecorder rec = sessionRecorder;
        if (rec != null) {
            rec.event(String.format(Locale.US,
                "{\"type\":\"head\",\"p\":[%.5f,%.5f,%.5f],\"q\":[%.6f,%.6f,%.6f,%.6f]}", px, py, pz, qx, qy, qz, qw));
        }
    }

    /** Free-form game event from Godot (JSON object text without t_ns), e.g. ball locked, putt result, missed putt mark. */
    public static void recordEvent(String json) {
        SessionRecorder rec = sessionRecorder;
        if (rec != null && json != null) rec.event(json);
    }

    private static class SessionRecorder {
        private final File dir;
        private final long startNs = System.nanoTime();
        private final long maxNs;
        private final java.util.concurrent.LinkedBlockingQueue<Object> queue = new java.util.concurrent.LinkedBlockingQueue<>(250);
        private final Thread writer;
        private volatile boolean running = true;
        private volatile int dropped = 0;
        private int frames = 0;
        private static final Object STOP = new Object();

        SessionRecorder(File dir, int maxSeconds) {
            this.dir = dir;
            this.maxNs = Math.max(5, maxSeconds) * 1_000_000_000L;
            writer = new Thread(this::writeLoop, "SessionRecorderWriter");
            writer.setPriority(Thread.MIN_PRIORITY + 1);
            writer.start();
        }

        boolean isExpired() { return System.nanoTime() - startNs > maxNs; }

        void event(String json) {
            if (!running) return;
            String line = "{\"t_ns\":" + System.nanoTime() + "," + json.trim().substring(1);
            if (!queue.offer(line)) dropped++;
        }

        void offerFrame(byte[] y, int w, int h, int rowStride, int pxStride, long sensorTs, boolean fullRes) {
            if (!running || y == null) return;
            if (isExpired()) { running = false; queue.offer(STOP); return; }
            if (!fullRes) {
                // 2x2 box-downsampled preview frame (w/2 x h/2): enough to see what happened, 4x smaller
                int hw = w / 2, hh = h / 2;
                byte[] small = new byte[hw * hh];
                for (int r = 0; r < hh; r++) {
                    int o0 = (2 * r) * rowStride, o1 = (2 * r + 1) * rowStride;
                    for (int c = 0; c < hw; c++) {
                        int x0 = 2 * c * pxStride, x1 = (2 * c + 1) * pxStride;
                        if (o1 + x1 >= y.length) continue;
                        int sum = (y[o0 + x0] & 0xFF) + (y[o0 + x1] & 0xFF) + (y[o1 + x0] & 0xFF) + (y[o1 + x1] & 0xFF);
                        small[r * hw + c] = (byte) (sum >> 2);
                    }
                }
                long[] tm = new long[]{sensorTs, System.nanoTime(), PuttTracker.estimateCaptureLatencyNs(sensorTs), hw, hh};
                if (!queue.offer(new Object[]{tm, small})) dropped++;
                return;
            }
            byte[] packed = new byte[w * h];
            if (pxStride == 1) {
                for (int r = 0; r < h; r++) {
                    int off = r * rowStride;
                    if (off + w > y.length) break;
                    System.arraycopy(y, off, packed, r * w, w);
                }
            } else {
                for (int r = 0; r < h; r++) for (int c = 0; c < w; c++) {
                    int idx = r * rowStride + c * pxStride;
                    if (idx < y.length) packed[r * w + c] = y[idx];
                }
            }
            long[] tmeta = new long[]{sensorTs, System.nanoTime(), PuttTracker.estimateCaptureLatencyNs(sensorTs), w, h};
            if (!queue.offer(new Object[]{tmeta, packed})) dropped++;
        }

        void close() {
            running = false;
            queue.offer(STOP);
            try { writer.join(3000); } catch (InterruptedException ignored) {}
        }

        private void writeLoop() {
            java.util.zip.Deflater deflater = new java.util.zip.Deflater(1);
            byte[] compBuf = new byte[640 * 480 + 1024];
            try (java.io.DataOutputStream fout = new java.io.DataOutputStream(new java.io.BufferedOutputStream(
                     new FileOutputStream(new File(dir, "frames.bin")), 1 << 20));
                 java.io.Writer eout = new java.io.BufferedWriter(new java.io.OutputStreamWriter(
                     new FileOutputStream(new File(dir, "events.jsonl")), "UTF-8"))) {
                while (true) {
                    Object item = queue.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS);
                    if (item == null) { if (!running && queue.isEmpty()) break; continue; }
                    if (item == STOP) { if (queue.isEmpty()) break; else { queue.offer(STOP); continue; } }
                    if (item instanceof String) {
                        eout.write((String) item);
                        eout.write('\n');
                    } else {
                        Object[] fr = (Object[]) item;
                        long[] m = (long[]) fr[0];
                        byte[] px = (byte[]) fr[1];
                        deflater.reset();
                        deflater.setInput(px);
                        deflater.finish();
                        if (compBuf.length < px.length + 1024) compBuf = new byte[px.length + 1024];
                        int len = deflater.deflate(compBuf);
                        fout.writeInt(0x46524D31); // 'FRM1'
                        fout.writeLong(m[0]);
                        fout.writeLong(m[1]);
                        fout.writeLong(m[2]);
                        fout.writeInt((int) m[3]);
                        fout.writeInt((int) m[4]);
                        fout.writeInt(len);
                        fout.write(compBuf, 0, len);
                        frames++;
                    }
                }
                eout.write("{\"t_ns\":" + System.nanoTime() + ",\"type\":\"stop\",\"frames\":" + frames + ",\"dropped\":" + dropped + "}\n");
            } catch (Exception e) {
                Log.e(TAG, "[REC] writer error: " + e.getMessage());
            } finally {
                deflater.end();
                Log.i(TAG, "[REC] Recording stopped: " + frames + " frames, " + dropped + " dropped, dir=" + dir.getAbsolutePath());
            }
        }
    }

    // Speed v2: real lens calibration reported by the camera (Meta Passthrough Camera API), instead of hand-tuned FOV.
    // Layout: [valid, fx, fy, cx, cy, activeW, activeH, streamW, streamH, tx, ty, tz, qx, qy, qz, qw, tsSource]
    private static volatile float[] lensCalib = new float[]{0f};

    public static float[] getCameraCalibration() {
        return lensCalib.clone();
    }

    private void readLensCalibration(String camId) {
        try {
            CameraCharacteristics c = cameraManager.getCameraCharacteristics(camId);
            float[] intr = c.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION);
            float[] trans = c.get(CameraCharacteristics.LENS_POSE_TRANSLATION);
            float[] rot = c.get(CameraCharacteristics.LENS_POSE_ROTATION);
            float[] dist = c.get(CameraCharacteristics.LENS_DISTORTION);
            android.graphics.Rect active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
            android.util.Size pixArr = c.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE);
            Integer tsSrc = c.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE);
            Log.i(TAG, "[CAM CALIB] camera=" + camId
                + " intrinsics=" + java.util.Arrays.toString(intr)
                + " poseT=" + java.util.Arrays.toString(trans)
                + " poseR=" + java.util.Arrays.toString(rot)
                + " distortion=" + java.util.Arrays.toString(dist)
                + " active=" + (active != null ? active.toShortString() : "null")
                + " pixelArray=" + pixArr
                + " stream=" + frameWidth + "x" + frameHeight
                + " tsSource=" + tsSrc);
            if (intr != null && intr.length >= 4 && intr[0] > 0f && intr[1] > 0f && active != null) {
                float[] out = new float[17];
                out[0] = 1f;
                out[1] = intr[0]; out[2] = intr[1]; out[3] = intr[2]; out[4] = intr[3];
                out[5] = active.width(); out[6] = active.height();
                out[7] = frameWidth; out[8] = frameHeight;
                if (trans != null && trans.length >= 3) { out[9] = trans[0]; out[10] = trans[1]; out[11] = trans[2]; }
                if (rot != null && rot.length >= 4) { out[12] = rot[0]; out[13] = rot[1]; out[14] = rot[2]; out[15] = rot[3]; }
                out[16] = (tsSrc != null) ? tsSrc : -1;
                lensCalib = out;
                // The stream keeps the sensor's pixel scale and crops to its aspect ratio (1280x1280 -> 640x480)
                double sc = Math.min((double) frameWidth / active.width(), (double) frameHeight / active.height());
                sc = Math.max(sc, (double) frameWidth / active.width());
                double hfov = Math.toDegrees(2.0 * Math.atan((frameWidth / 2.0) / (intr[0] * sc)));
                double vfov = Math.toDegrees(2.0 * Math.atan((frameHeight / 2.0) / (intr[1] * sc)));
                Log.i(TAG, String.format(Locale.US,
                    "[CAM CALIB] => stream HFOV=%.1f deg, VFOV=%.1f deg, principal point=(%.3f, %.3f) of frame",
                    hfov, vfov, intr[2] / active.width(), intr[3] / active.height()));
            }
        } catch (Exception e) {
            Log.w(TAG, "[CAM CALIB] could not read lens calibration: " + e.getMessage());
        }
    }

    private void setOptimalFps(CameraDevice device, CaptureRequest.Builder captureBuilder) {
        try {
            if (cameraManager == null || device == null) return;
            CameraCharacteristics characteristics = cameraManager.getCameraCharacteristics(device.getId());
            Range<Integer>[] fpsRanges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
            if (fpsRanges != null && fpsRanges.length > 0) {
                Range<Integer> bestRange = fpsRanges[0];
                for (Range<Integer> r : fpsRanges) {
                    // Prioritize highest max FPS, and among those with the same max FPS, prioritize highest min FPS (e.g. [90, 90] over [30, 90])
                    if (r.getUpper() > bestRange.getUpper()) {
                        bestRange = r;
                    } else if (r.getUpper().equals(bestRange.getUpper()) && r.getLower() > bestRange.getLower()) {
                        bestRange = r;
                    }
                }
                captureBuilder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, bestRange);
                Log.i(TAG, "Selected locked high-speed AE FPS range for camera " + device.getId() + ": " + bestRange);
            }
        } catch (Exception e) {
            Log.w(TAG, "Could not set CONTROL_AE_TARGET_FPS_RANGE: " + e.getMessage());
        }
    }

    public static void setExposureLock(final boolean locked) {
        if (instance != null) {
            instance.setExposureLockInternal(locked);
        }
    }

    private void setExposureLockInternal(final boolean locked) {
        if (isAeLocked == locked) return;
        isAeLocked = locked;
        if (backgroundHandler != null) {
            backgroundHandler.post(() -> {
                try {
                    if (captureSessionLeft != null && captureBuilderLeft != null) {
                        captureBuilderLeft.set(CaptureRequest.CONTROL_AE_LOCK, locked);
                        try {
                            captureBuilderLeft.set(CaptureRequest.CONTROL_AWB_LOCK, locked);
                        } catch (Exception ignored) {}
                        captureSessionLeft.setRepeatingRequest(captureBuilderLeft.build(), null, backgroundHandler);
                    }
                    if (captureSessionRight != null && captureBuilderRight != null) {
                        captureBuilderRight.set(CaptureRequest.CONTROL_AE_LOCK, locked);
                        try {
                            captureBuilderRight.set(CaptureRequest.CONTROL_AWB_LOCK, locked);
                        } catch (Exception ignored) {}
                        captureSessionRight.setRepeatingRequest(captureBuilderRight.build(), null, backgroundHandler);
                    }
                    Log.i(TAG, "[CAMERA] AE/AWB lock state updated: " + locked);
                } catch (Exception e) {
                    Log.w(TAG, "Failed updating AE/AWB lock: " + e.getMessage());
                }
            });
        }
    }

    public synchronized void stopCamera() {
        cameraState = CameraState.CLOSING;
        isRunning = false;
        isRightCameraRunning = false;
        isAeLocked = false;
        captureBuilderLeft = null;
        captureBuilderRight = null;
        stopStreamServer();
        try {
            if (captureSessionLeft != null) {
                captureSessionLeft.close();
                captureSessionLeft = null;
            }
            captureSession = null;
            if (captureSessionRight != null) {
                captureSessionRight.close();
                captureSessionRight = null;
            }
            if (cameraDeviceLeft != null) {
                cameraDeviceLeft.close();
                cameraDeviceLeft = null;
            }
            cameraDevice = null;
            if (cameraDeviceRight != null) {
                cameraDeviceRight.close();
                cameraDeviceRight = null;
            }
            if (imageReaderLeft != null) {
                imageReaderLeft.close();
                imageReaderLeft = null;
            }
            imageReader = null;
            if (imageReaderRight != null) {
                imageReaderRight.close();
                imageReaderRight = null;
            }
            if (backgroundThread != null) {
                backgroundThread.quitSafely();
                backgroundThread.join();
                backgroundThread = null;
                backgroundHandler = null;
            }
            if (inferenceThread != null) {
                inferenceThread.quitSafely();
                inferenceThread.join();
                inferenceThread = null;
                inferenceHandler = null;
            }
            Log.i(TAG, "Dual stereo camera hardware stopped. YOLO model retained in memory.");
        } catch (Exception e) {
            Log.e(TAG, "Error stopping cameras: " + e.getMessage(), e);
        } finally {
            cameraState = CameraState.CLOSED;
        }
    }

    public static byte[] getCameraFrame() {
        return (instance != null) ? instance.latestYBuffer : null;
    }

    public static int getCameraWidth() {
        return (instance != null) ? instance.frameWidth : 0;
    }

    public static int getCameraHeight() {
        return (instance != null) ? instance.frameHeight : 0;
    }

    public static long getCameraFrameCount() {
        return (instance != null) ? instance.frameCount : 0;
    }

    public static boolean isYoloActive() {
        return (instance != null && instance.isModelLoaded);
    }

    private void runInferenceInternal() {
        if (!isModelLoaded || ortSession == null || ortEnv == null) {
            return;
        }

        byte[] yData = inferenceYBuffer;
        byte[] uData = inferenceUBuffer;
        byte[] vData = inferenceVBuffer;
        boolean useColor = hasColorPlanes && (uData != null) && (vData != null);

        int w = frameWidth;
        int h = frameHeight;
        int yRowStride = frameRowStride > 0 ? frameRowStride : w;
        int yPxStride = framePixelStride > 0 ? framePixelStride : 1;
        int uRow = uRowStride > 0 ? uRowStride : (w / 2);
        int uPx = uPixelStride > 0 ? uPixelStride : 1;
        int vRow = vRowStride > 0 ? vRowStride : (w / 2);
        int vPx = vPixelStride > 0 ? vPixelStride : 1;

        if (yData == null || w <= 0 || h <= 0) {
            return;
        }

        try {
            long t0 = System.currentTimeMillis();

            // Populate NCHW planar buffer: 1 x 3 x 640 x 640
            inputBuffer.rewind();
            int planeSize = MODEL_WIDTH * MODEL_HEIGHT;
            float[] planarFloats = reusablePlanarFloats;
            if (planarFloats == null || planarFloats.length != 3 * planeSize) {
                planarFloats = new float[3 * planeSize];
                reusablePlanarFloats = planarFloats;
            }

            int cropX0 = 0;
            int cropY0 = 0;
            int cropW = w;
            int cropH = h;

            if (isRoiEnabled) {
                int rx0 = (int) (roiNormLeft * w);
                int ry0 = (int) (roiNormTop * h);
                int rx1 = (int) (roiNormRight * w);
                int ry1 = (int) (roiNormBottom * h);
                int rw = rx1 - rx0;
                int rh = ry1 - ry0;
                if (rw >= 32 && rh >= 32) {
                    // Center-Square Crop to preserve 1:1 aspect ratio
                    int cx = (rx0 + rx1) / 2;
                    int cy = (ry0 + ry1) / 2;
                    int side = Math.max(rw, rh);
                    side = Math.max(side, 96);
                    side = Math.min(side, Math.min(w, h));
                    cropX0 = Math.max(0, Math.min(w - side, cx - side / 2));
                    cropY0 = Math.max(0, Math.min(h - side, cy - side / 2));
                    cropW = side;
                    cropH = side;
                }
            }

            // Quick scan of luminance range inside crop for local contrast stretching and low-light detection
            int minLum = 255;
            int maxLum = 0;
            long cropSumLum = 0;
            int cropNumLum = 0;
            int lumStep = 4;
            for (int sy = cropY0; sy < cropY0 + cropH; sy += lumStep) {
                int rowOffset = sy * yRowStride;
                for (int sx = cropX0; sx < cropX0 + cropW; sx += lumStep) {
                    int off = rowOffset + sx * yPxStride;
                    if (off < yData.length) {
                        int val = yData[off] & 0xFF;
                        if (val < minLum) minLum = val;
                        if (val > maxLum) maxLum = val;
                        cropSumLum += val;
                        cropNumLum++;
                    }
                }
            }
            int avgSceneLum = (cropNumLum > 0) ? (int) (cropSumLum / cropNumLum) : 100;
            boolean doStretch = (maxLum > minLum + 20);
            float lumScale = doStretch ? (255.0f / (float) Math.max(30, maxLum - minLum)) : 1.0f;
            // When floor is dim (< 75/255), lift shadow contrast with smooth gamma curve
            boolean applyLowLightBoost = (avgSceneLum < 75);

            float stepX = (float) cropW / (float) MODEL_WIDTH;
            float stepY = (float) cropH / (float) MODEL_HEIGHT;

            for (int y = 0; y < MODEL_HEIGHT; y++) {
                float fy = cropY0 + y * stepY;
                int y0 = (int) fy;
                int y1 = Math.min(y0 + 1, h - 1);
                float wy = fy - y0;
                int y0Offset = y0 * yRowStride;
                int y1Offset = y1 * yRowStride;
                int rowDst = y * MODEL_WIDTH;

                int uvY = y0 / 2;
                int uRowOffset = uvY * uRow;
                int vRowOffset = uvY * vRow;

                for (int x = 0; x < MODEL_WIDTH; x++) {
                    float fx = cropX0 + x * stepX;
                    int x0 = (int) fx;
                    int x1 = Math.min(x0 + 1, w - 1);
                    float wx = fx - x0;

                    // Bilinear sampling of Y plane
                    int off00 = y0Offset + x0 * yPxStride;
                    int off10 = y0Offset + x1 * yPxStride;
                    int off01 = y1Offset + x0 * yPxStride;
                    int off11 = y1Offset + x1 * yPxStride;

                    float y00 = (off00 < yData.length) ? (yData[off00] & 0xFF) : 0.0f;
                    float y10 = (off10 < yData.length) ? (yData[off10] & 0xFF) : 0.0f;
                    float y01 = (off01 < yData.length) ? (yData[off01] & 0xFF) : 0.0f;
                    float y11 = (off11 < yData.length) ? (yData[off11] & 0xFF) : 0.0f;

                    float yVal = (1.0f - wx) * (1.0f - wy) * y00 +
                                 wx * (1.0f - wy) * y10 +
                                 (1.0f - wx) * wy * y01 +
                                 wx * wy * y11;

                    if (doStretch) {
                        yVal = Math.max(0.0f, Math.min(255.0f, (yVal - minLum) * lumScale));
                    }
                    if (applyLowLightBoost) {
                        int yInt = Math.max(0, Math.min(255, (int) yVal));
                        yVal = GAMMA_TABLE_LOW_LIGHT[yInt];
                    }

                    float r, g, b;
                    if (useColor) {
                        int uvX = x0 / 2;
                        int uOff = uRowOffset + uvX * uPx;
                        int vOff = vRowOffset + uvX * vPx;
                        float uVal = (uOff < uData.length) ? ((uData[uOff] & 0xFF) - 128.0f) : 0.0f;
                        float vVal = (vOff < vData.length) ? ((vData[vOff] & 0xFF) - 128.0f) : 0.0f;
                        r = Math.max(0.0f, Math.min(1.0f, (yVal + 1.402f * vVal) / 255.0f));
                        g = Math.max(0.0f, Math.min(1.0f, (yVal - 0.344136f * uVal - 0.714136f * vVal) / 255.0f));
                        b = Math.max(0.0f, Math.min(1.0f, (yVal + 1.772f * uVal) / 255.0f));
                    } else {
                        r = g = b = yVal / 255.0f;
                    }

                    planarFloats[rowDst + x] = r;
                    planarFloats[planeSize + rowDst + x] = g;
                    planarFloats[2 * planeSize + rowDst + x] = b;
                }
            }

            inputBuffer.put(planarFloats);
            inputBuffer.rewind();

            OnnxTensor inputTensor = OnnxTensor.createTensor(ortEnv, inputBuffer, new long[]{1, 3, MODEL_WIDTH, MODEL_HEIGHT});
            OrtSession.Result result = ortSession.run(Collections.singletonMap("images", inputTensor));
            float[][][] output = (float[][][]) result.get(0).getValue();
            long inferenceMs = System.currentTimeMillis() - t0;
            inferenceCount++;

            // Search output0 [1, 84, numBoxes] for Class 32 ("sports ball", offset 36)
            float bestConf = 0.0f;
            float bestNormX = 0.0f;
            float bestNormY = 0.0f;
            float bestNormW = 0.0f;
            float bestNormH = 0.0f;

            float topAnyClassConf = 0.0f;
            int topAnyClassIdx = -1;

            // Geometry filter: Reject large rugs/plates (>13% full frame) and elongated shoes
            float maxAllowedDim = isRoiEnabled ? 0.40f : 0.13f;
            float minAllowedDim = 0.006f; // ~4 pixels at 640

            int numBoxes = (output.length > 0 && output[0].length > 0 && output[0][0] != null) ? output[0][0].length : 8400;
            for (int i = 0; i < numBoxes; i++) {
                float conf = output[0][SPORTS_BALL_CLASS_IDX][i];
                if (conf >= 0.020f) {
                    float bw = output[0][2][i] / (float) MODEL_WIDTH;
                    float bh = output[0][3][i] / (float) MODEL_HEIGHT;
                    float aspect = bw / Math.max(0.001f, bh);
                    if (aspect >= 0.55f && aspect <= 1.80f &&
                        bw >= minAllowedDim && bw <= maxAllowedDim &&
                        bh >= minAllowedDim && bh <= maxAllowedDim) {
                        if (conf > bestConf) {
                            bestConf = conf;
                            bestNormX = output[0][0][i] / (float) MODEL_WIDTH;
                            bestNormY = output[0][1][i] / (float) MODEL_HEIGHT;
                            bestNormW = bw;
                            bestNormH = bh;
                        }
                    }
                }

                for (int c = 4; c < 84; c++) {
                    float s = output[0][c][i];
                    if (s > topAnyClassConf) {
                        topAnyClassConf = s;
                        topAnyClassIdx = c - 4;
                    }
                }
            }

            inputTensor.close();
            result.close();

            String topName = (topAnyClassIdx >= 0 && topAnyClassIdx < COCO_SAMPLE_NAMES.length) ? COCO_SAMPLE_NAMES[topAnyClassIdx] : ("class_" + topAnyClassIdx);

            long sumLum = 0;
            int sampleStep = 64;
            int numSamples = 0;
            for (int k = 0; k < yData.length; k += sampleStep) {
                sumLum += (yData[k] & 0xFF);
                numSamples++;
            }
            int avgLum = numSamples > 0 ? (int)(sumLum / numSamples) : 0;

            // Map crop-relative coordinates back to full camera frame normalized coordinates:
            float fullNormX = (cropX0 + bestNormX * cropW) / (float) w;
            float fullNormY = (cropY0 + bestNormY * cropH) / (float) h;
            float fullNormW = (bestNormW * cropW) / (float) w;
            float fullNormH = (bestNormH * cropH) / (float) h;

            // Log every 5th inference or if a sports ball is found
            if (inferenceCount % 5 == 0 || bestConf >= 0.05f) {
                Log.i(TAG, String.format(Locale.US, "[YOLO] Infer #%d (%d ms) | %s%s | Lum: %d/255 | Sports ball: %.1f%% at (%.2f, %.2f) | Top: %s (%.1f%%)",
                        inferenceCount, inferenceMs, (useColor ? "Color" : "Mono"), (isRoiEnabled ? " ROI" : ""), avgLum, bestConf * 100.0f, fullNormX, fullNormY, topName, topAnyClassConf * 100.0f));
            }

            latestCropFloats = planarFloats;
            latestNormX = bestNormX;
            latestNormY = bestNormY;
            latestNormW = bestNormW;
            latestNormH = bestNormH;
            latestConf = bestConf;
            latestFullNormX = fullNormX;
            latestFullNormY = fullNormY;
            latestFullNormW = fullNormW;
            latestFullNormH = fullNormH;

            // Detection threshold for sports ball:
            // Allows distance acquisition down to 2.5% confidence for small balls at 1.0m-1.8m.
            // Dual-camera epipolar template (NCC) confirmation on Right camera prevents false positives.
            boolean isHit = (bestConf >= 0.025f);
            float[] rightBall = null;
            if (isHit && isRightCameraRunning) {
                rightBall = findBallInRightCamera(fullNormX, fullNormY, fullNormW, fullNormH);
            }

            boolean hasStereo = (rightBall != null);
            float rightNormX = hasStereo ? rightBall[0] : 0.0f;
            float rightNormY = hasStereo ? rightBall[1] : 0.0f;
            latestRightNormX = rightNormX;
            latestRightNormY = rightNormY;
            latestHasStereo = hasStereo;

            if (isHit) {
                float radiusPx = (fullNormW + fullNormH) * 0.25f * w;
                if (hasStereo) {
                    float disp = fullNormX - rightNormX;
                    Log.i(TAG, String.format(Locale.US, "[STEREO] BALL DETECTED! L=(%.3f, %.3f), R=(%.3f, %.3f), disp=%.4f, conf=%.2f%s",
                            fullNormX, fullNormY, rightNormX, rightNormY, disp, bestConf, (isRoiEnabled ? " [ROI Zoom]" : " [FullFrame]")));
                } else {
                    Log.i(TAG, String.format(Locale.US, "[STEREO] BALL DETECTED (Mono only)! L=(%.3f, %.3f), conf=%.2f%s",
                            fullNormX, fullNormY, bestConf, (isRoiEnabled ? " [ROI Zoom]" : " [FullFrame]")));
                }
                yoloDetectionSeq++;
                latestBallDetection = new float[]{1.0f, fullNormX, fullNormY, radiusPx, bestConf, fullNormW, fullNormH, (float) yoloDetectionSeq};
                latestStereoDetection = new float[]{1.0f, fullNormX, fullNormY, rightNormX, rightNormY, bestConf, hasStereo ? 1.0f : 0.0f, fullNormW, (float) yoloDetectionSeq};
                maybeSaveSnapshot(planarFloats, bestNormX, bestNormY, bestNormW, bestNormH, bestConf);
            } else {
                yoloDetectionSeq++;
                latestBallDetection = new float[]{0.0f, fullNormX, fullNormY, 0.0f, bestConf, 0.0f, 0.0f, (float) yoloDetectionSeq};
                latestStereoDetection = new float[]{0.0f, fullNormX, fullNormY, 0.0f, 0.0f, bestConf, 0.0f, 0.0f, (float) yoloDetectionSeq};
            }

            // Populate pre-stroke ring buffer
            int cropPlaneSize = MODEL_WIDTH * MODEL_HEIGHT;
            int[] prePx = new int[cropPlaneSize];
            for (int i = 0; i < cropPlaneSize; i++) {
                int r = (int) Math.max(0, Math.min(255, planarFloats[i] * 255.0f));
                int g = (int) Math.max(0, Math.min(255, planarFloats[cropPlaneSize + i] * 255.0f));
                int b = (int) Math.max(0, Math.min(255, planarFloats[2 * cropPlaneSize + i] * 255.0f));
                prePx[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }
            synchronized (preStrokeQueue) {
                if (preStrokeQueue.size() >= 3) {
                    preStrokeQueue.pollFirst();
                }
                preStrokeQueue.addLast(new PreStrokeFrame(prePx, bestNormX, bestNormY, bestNormW, bestNormH, bestConf, System.currentTimeMillis()));
            }

            // Continuous Putt Frame Recorder (active from mini-tee lock until ball stops)
            if (isRecordingPutt && puttFrameIndex < 10) {
                final int curIdx = puttFrameIndex++;
                final float[] snapFloats = planarFloats.clone();
                final float sNormX = bestNormX;
                final float sNormY = bestNormY;
                final float sNormW = bestNormW;
                final float sNormH = bestNormH;
                final float sConf = bestConf;
                final long elapsedMs = System.currentTimeMillis() - puttStartTimeMs;
                snapshotExecutor.execute(new Runnable() {
                    @Override
                    public void run() {
                        savePuttFrameInternal(snapFloats, sNormX, sNormY, sNormW, sNormH, sConf, curIdx, elapsedMs);
                    }
                });
            } else if (isRecordingPutt && puttFrameIndex >= 10) {
                isRecordingPutt = false;
                Log.i(TAG, "[PUTT RECORDER] Max 10 frames reached. Auto-stopped.");
            }

            // High-speed sequential stroke frame recorder
            if (strokeFramesToRecord > 0) {
                strokeFramesToRecord--;
                final int curSeq = strokeFrameSequence++;
                final float[] snapFloats = planarFloats.clone();
                final float sNormX = bestNormX;
                final float sNormY = bestNormY;
                final float sNormW = bestNormW;
                final float sNormH = bestNormH;
                final float sConf = bestConf;
                snapshotExecutor.execute(new Runnable() {
                    @Override
                    public void run() {
                        saveStrokeSnapshotInternal(snapFloats, sNormX, sNormY, sNormW, sNormH, sConf, curSeq);
                    }
                });
            }
        } catch (Exception e) {
            Log.e(TAG, "[YOLO] Inference error: " + e.getMessage(), e);
        }
    }

    /**
     * Fast epipolar search on Right Camera (Camera 51) for the golf ball found in Left Camera (Camera 50).
     * Quest 3 Left/Right cameras are horizontally aligned on the visor with 64.4 mm baseline.
     * Uses epipolar horizontal constraint + template NCC matching to prevent false positives from glares or shoes.
     * Returns [rightNormX, rightNormY] or null if not found.
     */
    private float[] findBallInRightCamera(float leftNormX, float leftNormY, float leftNormW, float leftNormH) {
        byte[] yRight = inferenceYBufferRight;
        byte[] yLeft = inferenceYBuffer;
        int w = frameWidth;
        int h = frameHeight;
        if (yRight == null || yLeft == null || w <= 0 || h <= 0) {
            return null;
        }

        // Bounding epipolar search box:
        int minPxX = Math.max(0, (int) ((leftNormX - 0.35f) * w));
        int maxPxX = Math.min(w - 1, (int) ((leftNormX - 0.002f) * w));
        // Vertical tolerance: +/- 8% of height (allows for sensor pitch divergence and lens distortion)
        int minPxY = Math.max(0, (int) ((leftNormY - 0.08f) * h));
        int maxPxY = Math.min(h - 1, (int) ((leftNormY + 0.08f) * h));

        if (maxPxX <= minPxX || maxPxY <= minPxY) {
            return null;
        }

        int rowStrideR = frameRowStrideRight > 0 ? frameRowStrideRight : w;
        int pxStrideR = framePixelStrideRight > 0 ? framePixelStrideRight : 1;
        int rowStrideL = frameRowStride > 0 ? frameRowStride : w;
        int pxStrideL = framePixelStride > 0 ? framePixelStride : 1;

        // Extract template patch from Left camera around ball center
        int lx = (int) (leftNormX * w);
        int ly = (int) (leftNormY * h);
        int tR = Math.max(3, Math.min(6, (int) ((leftNormW + leftNormH) * 0.25f * w)));
        if (lx - tR < 0 || lx + tR >= w || ly - tR < 0 || ly + tR >= h) {
            return null;
        }

        int tSide = 2 * tR + 1;
        int tSize = tSide * tSide;
        int[] leftTemplate = new int[tSize];
        double leftSum = 0;
        int tIdx = 0;
        for (int dy = -tR; dy <= tR; dy++) {
            int lOffset = (ly + dy) * rowStrideL;
            for (int dx = -tR; dx <= tR; dx++) {
                int off = lOffset + (lx + dx) * pxStrideL;
                int val = (off < yLeft.length) ? (yLeft[off] & 0xFF) : 0;
                leftTemplate[tIdx++] = val;
                leftSum += val;
            }
        }
        double leftMean = leftSum / tSize;
        double leftVar = 0;
        for (int v : leftTemplate) {
            double diff = v - leftMean;
            leftVar += diff * diff;
        }
        double leftStd = Math.sqrt(leftVar);

        // Scan Right camera search window for candidate positions
        long sumY = 0;
        int totalPixels = 0;
        int maxY = 0;

        for (int y = minPxY; y <= maxPxY; y++) {
            int rowOffset = y * rowStrideR;
            for (int x = minPxX; x <= maxPxX; x++) {
                int idx = rowOffset + x * pxStrideR;
                if (idx < yRight.length) {
                    int val = yRight[idx] & 0xFF;
                    sumY += val;
                    totalPixels++;
                    if (val > maxY) maxY = val;
                }
            }
        }
        if (totalPixels == 0 || maxY < 35) return null;
        float avgY = (float) sumY / totalPixels;
        if ((maxY - avgY) < 4) return null;

        // Evaluate top candidate peaks with template correlation
        double bestScore = -1.0;
        int bestX = -1;
        int bestY = -1;

        int step = Math.max(1, tR / 2);
        for (int cy = minPxY + tR; cy <= maxPxY - tR; cy += step) {
            int rowOffset = cy * rowStrideR;
            for (int cx = minPxX + tR; cx <= maxPxX - tR; cx += step) {
                int centerIdx = rowOffset + cx * pxStrideR;
                int centerVal = (centerIdx < yRight.length) ? (yRight[centerIdx] & 0xFF) : 0;
                if (centerVal < (avgY + 1)) continue;

                // Compute Normalized Cross-Correlation (NCC)
                double rSum = 0;
                int pIdx = 0;
                int[] rPatch = new int[tSize];
                for (int dy = -tR; dy <= tR; dy++) {
                    int rOff = (cy + dy) * rowStrideR;
                    for (int dx = -tR; dx <= tR; dx++) {
                        int off = rOff + (cx + dx) * pxStrideR;
                        int val = (off < yRight.length) ? (yRight[off] & 0xFF) : 0;
                        rPatch[pIdx++] = val;
                        rSum += val;
                    }
                }
                double rMean = rSum / tSize;
                double rVar = 0;
                double cov = 0;
                for (int i = 0; i < tSize; i++) {
                    double ld = leftTemplate[i] - leftMean;
                    double rd = rPatch[i] - rMean;
                    cov += ld * rd;
                    rVar += rd * rd;
                }
                double rStd = Math.sqrt(rVar);
                double ncc = (leftStd > 1e-4 && rStd > 1e-4) ? (cov / (leftStd * rStd)) : 0.0;

                // Combined score: NCC (shape match) + relative luminance
                double score = ncc * 0.7 + Math.min(1.0, (centerVal - avgY) / 60.0) * 0.3;
                if (ncc > 0.18 && score > bestScore) {
                    bestScore = score;
                    bestX = cx;
                    bestY = cy;
                }
            }
        }

        if (bestX < 0 || bestScore < 0.18) {
            return null;
        }

        return new float[]{(float) bestX / (float) w, (float) bestY / (float) h};
    }

    // Continuous Putt Recorder: Starts when ball registers on mini-tee, ends when ball stops
    private volatile boolean isRecordingPutt = false;
    private volatile int puttFrameIndex = 0;
    private volatile long puttStartTimeMs = 0;

    public static void startPuttRecording() {
        if (instance != null) {
            instance.puttFrameIndex = 0;
            instance.puttStartTimeMs = System.currentTimeMillis();
            instance.isRecordingPutt = true;
            Log.i(TAG, "[PUTT RECORDER] >>> STARTED RECORDING PUTT from mini-tee lock! <<<");

            final byte[] yData = (instance.latestYBuffer != null) ? instance.latestYBuffer.clone() : null;
            final int w = instance.frameWidth;
            final int h = instance.frameHeight;
            final int yRowStride = instance.frameRowStride > 0 ? instance.frameRowStride : w;
            final int yPxStride = instance.framePixelStride > 0 ? instance.framePixelStride : 1;
            final float roiMinX = instance.roiNormLeft;
            final float roiMinY = instance.roiNormTop;
            final float roiMaxX = instance.roiNormRight;
            final float roiMaxY = instance.roiNormBottom;
            final boolean roiOn = instance.isRoiEnabled;
            final float curNormX = instance.latestFullNormX;
            final float curNormY = instance.latestFullNormY;
            final boolean hasBall = (instance.latestStereoDetection[0] > 0.5f);

            instance.snapshotExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        File outDir = (instance.context != null) ? instance.context.getExternalFilesDir(null) : null;
                        if (outDir == null) {
                            outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                        }
                        if (outDir != null && outDir.exists()) {
                            File[] oldFiles = outDir.listFiles((dir, name) -> name.startsWith("putt_frame_") || name.startsWith("stroke_seq_"));
                            if (oldFiles != null) {
                                for (File f : oldFiles) {
                                    f.delete();
                                }
                            }
                        }
                    } catch (Exception e) {
                        Log.w(TAG, "[PUTT RECORDER] Error clearing previous putt frames: " + e.getMessage());
                    }
                    if (yData != null && w > 0 && h > 0) {
                        instance.saveRawStrokeHitInternal(yData, w, h, yRowStride, yPxStride, roiMinX, roiMinY, roiMaxX, roiMaxY, roiOn, curNormX, curNormY, hasBall);
                    }
                }
            });
        }
    }

    public static void stopPuttRecording() {
        if (instance != null && instance.isRecordingPutt) {
            instance.isRecordingPutt = false;
            Log.i(TAG, "[PUTT RECORDER] >>> STOPPED RECORDING PUTT (total frames: " + instance.puttFrameIndex + ") <<<");
        }
    }

    public static boolean isRecordingPutt() {
        return (instance != null && instance.isRecordingPutt);
    }

    private static class PreStrokeFrame {
        final int[] pixels;
        final float normX, normY, normW, normH, conf;
        final long timeMs;

        PreStrokeFrame(int[] px, float x, float y, float w, float h, float c, long t) {
            this.pixels = px;
            this.normX = x;
            this.normY = y;
            this.normW = w;
            this.normH = h;
            this.conf = c;
            this.timeMs = t;
        }
    }

    private final java.util.LinkedList<PreStrokeFrame> preStrokeQueue = new java.util.LinkedList<>();
    private long lastSnapshotTime = 0;
    private volatile int strokeFramesToRecord = 0;
    private volatile int strokeFrameSequence = 0;
    private volatile long strokeStartTimeMs = 0;

    public static void startRecordingStroke(int numFrames) {
        if (instance != null) {
            instance.strokeFrameSequence = 0;
            instance.strokeFramesToRecord = Math.max(1, Math.min(numFrames, 16));
            instance.strokeStartTimeMs = System.currentTimeMillis();
            Log.i(TAG, "[STROKE RECORDER] Arming stroke snapshot sequence for next " + instance.strokeFramesToRecord + " frames.");
            instance.flushPreStrokeSnapshots();
        }
    }

    public static boolean isRecordingStroke() {
        return (instance != null && instance.strokeFramesToRecord > 0);
    }

    private void flushPreStrokeSnapshots() {
        final java.util.List<PreStrokeFrame> preList = new java.util.ArrayList<>();
        synchronized (preStrokeQueue) {
            preList.addAll(preStrokeQueue);
        }

        final byte[] yData = (latestYBuffer != null) ? latestYBuffer.clone() : null;
        final int w = frameWidth;
        final int h = frameHeight;
        final int yRowStride = frameRowStride > 0 ? frameRowStride : w;
        final int yPxStride = framePixelStride > 0 ? framePixelStride : 1;
        final float roiMinX = roiNormLeft;
        final float roiMinY = roiNormTop;
        final float roiMaxX = roiNormRight;
        final float roiMaxY = roiNormBottom;
        final boolean roiOn = isRoiEnabled;
        final float curNormX = latestFullNormX;
        final float curNormY = latestFullNormY;
        final boolean hasBall = (latestStereoDetection[0] > 0.5f);

        snapshotExecutor.execute(new Runnable() {
            @Override
            public void run() {
                // 1. Save Pre-Stroke Frames
                for (int i = 0; i < preList.size(); i++) {
                    PreStrokeFrame frame = preList.get(i);
                    savePreStrokeSnapshotInternal(frame, i, preList.size());
                }

                // 2. Save Raw Wide-Angle Frame at Hit Start
                if (yData != null && w > 0 && h > 0) {
                    saveRawStrokeHitInternal(yData, w, h, yRowStride, yPxStride, roiMinX, roiMinY, roiMaxX, roiMaxY, roiOn, curNormX, curNormY, hasBall);
                }
            }
        });
    }

    private void savePreStrokeSnapshotInternal(PreStrokeFrame frame, int idx, int totalPre) {
        try {
            Bitmap bmp = Bitmap.createBitmap(frame.pixels, MODEL_WIDTH, MODEL_HEIGHT, Bitmap.Config.ARGB_8888);
            Bitmap mutableBmp = bmp.copy(Bitmap.Config.ARGB_8888, true);
            Canvas canvas = new Canvas(mutableBmp);

            if (frame.conf >= 0.12f) {
                Paint boxPaint = new Paint();
                boxPaint.setColor(Color.GREEN);
                boxPaint.setStyle(Paint.Style.STROKE);
                boxPaint.setStrokeWidth(3.0f);

                float cx = frame.normX * MODEL_WIDTH;
                float cy = frame.normY * MODEL_HEIGHT;
                float bw = frame.normW * MODEL_WIDTH;
                float bh = frame.normH * MODEL_HEIGHT;
                canvas.drawRect(cx - bw * 0.5f, cy - bh * 0.5f, cx + bw * 0.5f, cy + bh * 0.5f, boxPaint);

                boxPaint.setColor(Color.CYAN);
                boxPaint.setStrokeWidth(2.0f);
                canvas.drawLine(cx - 8, cy, cx + 8, cy, boxPaint);
                canvas.drawLine(cx, cy - 8, cx, cy + 8, boxPaint);
            }

            Paint textPaint = new Paint();
            textPaint.setColor(Color.YELLOW);
            textPaint.setTextSize(18.0f);
            textPaint.setFakeBoldText(true);
            long dtMs = frame.timeMs - strokeStartTimeMs;
            canvas.drawText(String.format(Locale.US, "PRE #%d (%dms) | Conf: %.0f%% (%.2f, %.2f)", idx, dtMs, frame.conf * 100.0f, frame.normX, frame.normY), 8.0f, 24.0f, textPaint);

            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            if (!outDir.exists()) outDir.mkdirs();

            File outFile = new File(outDir, "stroke_seq_pre_" + idx + ".jpg");
            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                mutableBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
            }
            Log.i(TAG, "[STROKE RECORDER] Saved pre-stroke frame #" + idx + ": " + outFile.getAbsolutePath());
        } catch (Exception e) {
            Log.e(TAG, "[STROKE RECORDER] Failed to save pre-stroke frame #" + idx + ": " + e.getMessage(), e);
        }
    }

    private void saveRawStrokeHitInternal(byte[] yData, int w, int h, int yRowStride, int yPxStride,
                                          float rMinX, float rMinY, float rMaxX, float rMaxY, boolean roiOn,
                                          float normX, float normY, boolean hasBall) {
        try {
            int[] fullPixels = new int[w * h];
            for (int y = 0; y < h; y++) {
                int yRowOffset = y * yRowStride;
                int rowDst = y * w;
                for (int x = 0; x < w; x++) {
                    int yOff = yRowOffset + x * yPxStride;
                    int yVal = (yOff < yData.length) ? (yData[yOff] & 0xFF) : 0;
                    fullPixels[rowDst + x] = 0xFF000000 | (yVal << 16) | (yVal << 8) | yVal;
                }
            }

            Bitmap rawBmp = Bitmap.createBitmap(fullPixels, w, h, Bitmap.Config.ARGB_8888);
            Bitmap mutableRaw = rawBmp.copy(Bitmap.Config.ARGB_8888, true);
            Canvas canvas = new Canvas(mutableRaw);

            Paint p = new Paint();
            if (roiOn) {
                p.setColor(Color.YELLOW);
                p.setStyle(Paint.Style.STROKE);
                p.setStrokeWidth(2.5f);
                canvas.drawRect(rMinX * w, rMinY * h, rMaxX * w, rMaxY * h, p);
            }

            if (hasBall) {
                p.setColor(Color.RED);
                p.setStyle(Paint.Style.STROKE);
                p.setStrokeWidth(3.0f);
                float rx = normX * w;
                float ry = normY * h;
                canvas.drawCircle(rx, ry, 14.0f, p);
                canvas.drawLine(rx - 18, ry, rx + 18, ry, p);
                canvas.drawLine(rx, ry - 18, rx, ry + 18, p);
            }

            Paint textPaint = new Paint();
            textPaint.setColor(Color.YELLOW);
            textPaint.setTextSize(22.0f);
            textPaint.setFakeBoldText(true);
            canvas.drawText(String.format(Locale.US, "HIT START (RAW LEFT) | Ball: (%.2f, %.2f) | ROI: [%.2f, %.2f, %.2f, %.2f]",
                    normX, normY, rMinX, rMinY, rMaxX, rMaxY), 16.0f, 32.0f, textPaint);

            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            if (!outDir.exists()) outDir.mkdirs();

            File outFile = new File(outDir, "stroke_hit_raw_left.jpg");
            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                mutableRaw.compress(Bitmap.CompressFormat.JPEG, 92, fos);
            }
            Log.i(TAG, "[STROKE RECORDER] Saved raw hit frame: " + outFile.getAbsolutePath());
        } catch (Exception e) {
            Log.e(TAG, "[STROKE RECORDER] Failed to save raw hit frame: " + e.getMessage(), e);
        }
    }

    private void savePuttFrameInternal(float[] planarFloats, float normX, float normY, float normW, float normH, float conf, int seqIdx, long elapsedMs) {
        try {
            int planeSize = MODEL_WIDTH * MODEL_HEIGHT;
            int[] pixels = new int[planeSize];
            for (int i = 0; i < planeSize; i++) {
                int r = (int) Math.max(0, Math.min(255, planarFloats[i] * 255.0f));
                int g = (int) Math.max(0, Math.min(255, planarFloats[planeSize + i] * 255.0f));
                int b = (int) Math.max(0, Math.min(255, planarFloats[2 * planeSize + i] * 255.0f));
                pixels[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }

            Bitmap bmp = Bitmap.createBitmap(pixels, MODEL_WIDTH, MODEL_HEIGHT, Bitmap.Config.ARGB_8888);
            Bitmap mutableBmp = bmp.copy(Bitmap.Config.ARGB_8888, true);
            Canvas canvas = new Canvas(mutableBmp);

            if (conf >= 0.10f) {
                Paint boxPaint = new Paint();
                boxPaint.setColor(Color.GREEN);
                boxPaint.setStyle(Paint.Style.STROKE);
                boxPaint.setStrokeWidth(3.0f);

                float cx = normX * MODEL_WIDTH;
                float cy = normY * MODEL_HEIGHT;
                float bw = normW * MODEL_WIDTH;
                float bh = normH * MODEL_HEIGHT;
                canvas.drawRect(cx - bw * 0.5f, cy - bh * 0.5f, cx + bw * 0.5f, cy + bh * 0.5f, boxPaint);

                boxPaint.setColor(Color.CYAN);
                boxPaint.setStrokeWidth(2.0f);
                canvas.drawLine(cx - 8, cy, cx + 8, cy, boxPaint);
                canvas.drawLine(cx, cy - 8, cx, cy + 8, boxPaint);
            }

            Paint textPaint = new Paint();
            textPaint.setColor(Color.YELLOW);
            textPaint.setTextSize(18.0f);
            textPaint.setFakeBoldText(true);
            if (conf >= 0.10f) {
                canvas.drawText(String.format(Locale.US, "Frame #%02d (+%dms) | Ball: %.0f%% (%.2f, %.2f)", seqIdx, elapsedMs, conf * 100.0f, normX, normY), 8.0f, 24.0f, textPaint);
            } else {
                canvas.drawText(String.format(Locale.US, "Frame #%02d (+%dms) | No Ball Detected", seqIdx, elapsedMs), 8.0f, 24.0f, textPaint);
            }

            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            if (!outDir.exists()) outDir.mkdirs();

            File outFile = new File(outDir, String.format(Locale.US, "putt_frame_%02d.jpg", seqIdx));
            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                mutableBmp.compress(Bitmap.CompressFormat.JPEG, 90, fos);
            }
            Log.i(TAG, "[PUTT RECORDER] Saved frame #" + seqIdx + " (" + elapsedMs + "ms): " + outFile.getAbsolutePath());
        } catch (Exception e) {
            Log.e(TAG, "[PUTT RECORDER] Failed to save frame #" + seqIdx + ": " + e.getMessage(), e);
        }
    }

    private void saveStrokeSnapshotInternal(float[] planarFloats, float normX, float normY, float normW, float normH, float conf, int seqIdx) {
        try {
            int planeSize = MODEL_WIDTH * MODEL_HEIGHT;
            int[] pixels = new int[planeSize];
            for (int i = 0; i < planeSize; i++) {
                int r = (int) Math.max(0, Math.min(255, planarFloats[i] * 255.0f));
                int g = (int) Math.max(0, Math.min(255, planarFloats[planeSize + i] * 255.0f));
                int b = (int) Math.max(0, Math.min(255, planarFloats[2 * planeSize + i] * 255.0f));
                pixels[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }

            Bitmap bmp = Bitmap.createBitmap(pixels, MODEL_WIDTH, MODEL_HEIGHT, Bitmap.Config.ARGB_8888);
            Bitmap mutableBmp = bmp.copy(Bitmap.Config.ARGB_8888, true);
            Canvas canvas = new Canvas(mutableBmp);

            if (conf >= 0.12f) {
                Paint boxPaint = new Paint();
                boxPaint.setColor(Color.GREEN);
                boxPaint.setStyle(Paint.Style.STROKE);
                boxPaint.setStrokeWidth(3.0f);

                float cx = normX * MODEL_WIDTH;
                float cy = normY * MODEL_HEIGHT;
                float bw = normW * MODEL_WIDTH;
                float bh = normH * MODEL_HEIGHT;
                canvas.drawRect(cx - bw * 0.5f, cy - bh * 0.5f, cx + bw * 0.5f, cy + bh * 0.5f, boxPaint);

                boxPaint.setColor(Color.CYAN);
                boxPaint.setStrokeWidth(2.0f);
                canvas.drawLine(cx - 8, cy, cx + 8, cy, boxPaint);
                canvas.drawLine(cx, cy - 8, cx, cy + 8, boxPaint);
            }

            Paint textPaint = new Paint();
            textPaint.setColor(Color.YELLOW);
            textPaint.setTextSize(18.0f);
            textPaint.setFakeBoldText(true);
            long dtMs = System.currentTimeMillis() - strokeStartTimeMs;
            canvas.drawText(String.format(Locale.US, "#%d (+%dms) | Conf: %.0f%% (%.2f, %.2f)", seqIdx, dtMs, conf * 100.0f, normX, normY), 8.0f, 24.0f, textPaint);

            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            if (!outDir.exists()) outDir.mkdirs();

            File outFile = new File(outDir, "stroke_seq_" + seqIdx + ".jpg");
            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                mutableBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
            }
            Log.i(TAG, "[STROKE RECORDER] Saved frame #" + seqIdx + ": " + outFile.getAbsolutePath());
        } catch (Exception e) {
            Log.e(TAG, "[STROKE RECORDER] Failed to save frame #" + seqIdx + ": " + e.getMessage(), e);
        }
    }

    private void maybeSaveSnapshot(float[] planarFloats, float normX, float normY, float normW, float normH, float conf) {
        long now = System.currentTimeMillis();
        if (now - lastSnapshotTime < 15000) {
            return; // Throttle snapshots to at most one every 15 seconds
        }
        lastSnapshotTime = now;

        final float[] snapshotFloats = planarFloats.clone();
        final float sNormX = normX;
        final float sNormY = normY;
        final float sNormW = normW;
        final float sNormH = normH;
        final float sConf = conf;

        snapshotExecutor.execute(new Runnable() {
            @Override
            public void run() {
                saveSnapshotInternal(snapshotFloats, sNormX, sNormY, sNormW, sNormH, sConf);
            }
        });
    }

    private void saveSnapshotInternal(float[] planarFloats, float normX, float normY, float normW, float normH, float conf) {
        long now = System.currentTimeMillis();
        try {
            int planeSize = MODEL_WIDTH * MODEL_HEIGHT;
            int[] pixels = new int[planeSize];
            for (int i = 0; i < planeSize; i++) {
                int r = (int) Math.max(0, Math.min(255, planarFloats[i] * 255.0f));
                int g = (int) Math.max(0, Math.min(255, planarFloats[planeSize + i] * 255.0f));
                int b = (int) Math.max(0, Math.min(255, planarFloats[2 * planeSize + i] * 255.0f));
                pixels[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }

            Bitmap bmp = Bitmap.createBitmap(pixels, MODEL_WIDTH, MODEL_HEIGHT, Bitmap.Config.ARGB_8888);
            Bitmap mutableBmp = bmp.copy(Bitmap.Config.ARGB_8888, true);
            Canvas canvas = new Canvas(mutableBmp);

            Paint boxPaint = new Paint();
            boxPaint.setColor(Color.GREEN);
            boxPaint.setStyle(Paint.Style.STROKE);
            boxPaint.setStrokeWidth(3.0f);

            float cx = normX * MODEL_WIDTH;
            float cy = normY * MODEL_HEIGHT;
            float bw = normW * MODEL_WIDTH;
            float bh = normH * MODEL_HEIGHT;
            float left = cx - bw * 0.5f;
            float top = cy - bh * 0.5f;
            float right = cx + bw * 0.5f;
            float bottom = cy + bh * 0.5f;

            canvas.drawRect(left, top, right, bottom, boxPaint);

            // Draw center crosshair
            boxPaint.setColor(Color.CYAN);
            boxPaint.setStrokeWidth(2.0f);
            canvas.drawLine(cx - 8, cy, cx + 8, cy, boxPaint);
            canvas.drawLine(cx, cy - 8, cx, cy + 8, boxPaint);

            // Draw text badge
            Paint textPaint = new Paint();
            textPaint.setColor(Color.GREEN);
            textPaint.setTextSize(16.0f);
            textPaint.setFakeBoldText(true);
            canvas.drawText(String.format(Locale.US, "Ball: %.0f%% (%.2f, %.2f)", conf * 100.0f, normX, normY), 8.0f, 22.0f, textPaint);

            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            if (!outDir.exists()) {
                outDir.mkdirs();
            }
            File outFile = new File(outDir, "yolo_ball_hit.jpg");
            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                mutableBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
            }
            // Also save rolling history (up to 5 snapshots)
            int snapIdx = (int) ((now / 1500) % 5);
            File rollingFile = new File(outDir, "yolo_ball_hit_" + snapIdx + ".jpg");
            try (FileOutputStream fos = new FileOutputStream(rollingFile)) {
                mutableBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
            }
            Log.i(TAG, "[YOLO] SNAPSHOT SAVED ASYNC: " + outFile.getAbsolutePath());
        } catch (Exception e) {
            Log.e(TAG, "[YOLO] Failed to save snapshot async: " + e.getMessage(), e);
        }
    }

    // 3-Point Forward Corridor Snippet System
    private static class CorridorPoint {
        final int pointIdx;
        final float normX, normY;
        final float speedMps, angleDeg;
        final long timestamp;
        CorridorPoint(int pointIdx, float normX, float normY, float speedMps, float angleDeg, long timestamp) {
            this.pointIdx = pointIdx;
            this.normX = normX;
            this.normY = normY;
            this.speedMps = speedMps;
            this.angleDeg = angleDeg;
            this.timestamp = timestamp;
        }
    }
    private final java.util.List<CorridorPoint> corridorHistory = new java.util.concurrent.CopyOnWriteArrayList<>();

    public static boolean saveCorridorSnippet(int pointIdx, float normX, float normY, float speedMps, float angleDeg) {
        if (instance == null) return false;
        return instance.saveCorridorSnippetInternal(pointIdx, normX, normY, speedMps, angleDeg);
    }

    private boolean saveCorridorSnippetInternal(final int pointIdx, final float normX, final float normY, final float speedMps, final float angleDeg) {
        final byte[] yData = latestYBuffer;
        final byte[] uData = latestUBuffer;
        final byte[] vData = latestVBuffer;
        final int w = frameWidth;
        final int h = frameHeight;
        final boolean hasColor = hasColorPlanes;
        final int yStride = frameRowStride > 0 ? frameRowStride : w;
        final int yPx = framePixelStride > 0 ? framePixelStride : 1;
        final int uStride = uRowStride > 0 ? uRowStride : (w / 2);
        final int uPx = uPixelStride > 0 ? uPixelStride : 1;
        final int vStride = vRowStride > 0 ? vRowStride : (w / 2);
        final int vPx = vPixelStride > 0 ? vPixelStride : 1;

        if (pointIdx == 1) {
            corridorHistory.clear();
        }
        corridorHistory.add(new CorridorPoint(pointIdx, normX, normY, speedMps, angleDeg, System.currentTimeMillis()));

        snapshotExecutor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
                    if (outDir == null) {
                        outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                    }
                    if (!outDir.exists()) outDir.mkdirs();

                    if (yData == null || w <= 0 || h <= 0) return;

                    int[] fullPixels = new int[w * h];
                    for (int y = 0; y < h; y++) {
                        int yRowOffset = y * yStride;
                        int uvY = y / 2;
                        int uRowOffset = uvY * uStride;
                        int vRowOffset = uvY * vStride;
                        int rowDst = y * w;
                        for (int x = 0; x < w; x++) {
                            int yOff = yRowOffset + x * yPx;
                            float yVal = (yOff < yData.length) ? (yData[yOff] & 0xFF) : 0f;
                            int r, g, b;
                            if (hasColor && uData != null && vData != null) {
                                int uvX = x / 2;
                                int uOff = uRowOffset + uvX * uPx;
                                int vOff = vRowOffset + uvX * vPx;
                                float uVal = (uOff < uData.length) ? ((uData[uOff] & 0xFF) - 128f) : 0f;
                                float vVal = (vOff < vData.length) ? ((vData[vOff] & 0xFF) - 128f) : 0f;
                                r = (int) Math.max(0, Math.min(255, yVal + 1.402f * vVal));
                                g = (int) Math.max(0, Math.min(255, yVal - 0.344136f * uVal - 0.714136f * vVal));
                                b = (int) Math.max(0, Math.min(255, yVal + 1.772f * uVal));
                            } else {
                                int gray = (int) yVal;
                                r = gray; g = gray; b = gray;
                            }
                            fullPixels[rowDst + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
                        }
                    }

                    Bitmap fullBmp = Bitmap.createBitmap(fullPixels, w, h, Bitmap.Config.ARGB_8888);
                    Bitmap mutableBmp = fullBmp.copy(Bitmap.Config.ARGB_8888, true);
                    Canvas canvas = new Canvas(mutableBmp);

                    Paint p = new Paint();
                    p.setAntiAlias(true);

                    float prevX = -1, prevY = -1;
                    for (CorridorPoint cp : corridorHistory) {
                        float px = cp.normX * w;
                        float py = cp.normY * h;

                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(3f);
                        if (cp.pointIdx == 1) p.setColor(Color.YELLOW);
                        else if (cp.pointIdx == 2) p.setColor(Color.CYAN);
                        else p.setColor(Color.GREEN);

                        canvas.drawCircle(px, py, 14f, p);
                        canvas.drawLine(px - 10, py, px + 10, py, p);
                        canvas.drawLine(px, py - 10, px, py + 10, p);

                        if (prevX >= 0) {
                            p.setColor(Color.WHITE);
                            p.setStrokeWidth(2.5f);
                            canvas.drawLine(prevX, prevY, px, py, p);
                        }
                        prevX = px;
                        prevY = py;

                        Paint textP = new Paint();
                        textP.setColor(Color.WHITE);
                        textP.setTextSize(18f);
                        textP.setFakeBoldText(true);
                        canvas.drawText("P" + cp.pointIdx, px + 18, py + 6, textP);
                    }

                    // Header badge
                    Paint badgeP = new Paint();
                    badgeP.setColor(Color.argb(190, 0, 0, 0));
                    badgeP.setStyle(Paint.Style.FILL);
                    canvas.drawRect(8, 8, 440, 56, badgeP);

                    Paint badgeTextP = new Paint();
                    badgeTextP.setColor(pointIdx == 3 ? Color.GREEN : Color.CYAN);
                    badgeTextP.setTextSize(17f);
                    badgeTextP.setFakeBoldText(true);
                    String header = String.format(Locale.US, "Point %d/3 | (%.2f, %.2f)", pointIdx, normX, normY);
                    if (pointIdx == 3) {
                        header = String.format(Locale.US, "CONFIRMED PUTT: %.2f m/s (%+.1f°)", speedMps, angleDeg);
                    }
                    canvas.drawText(header, 16, 38, badgeTextP);

                    // 1. Save full annotated frame
                    File pointFile = new File(outDir, "corridor_point_" + pointIdx + ".jpg");
                    try (FileOutputStream fos = new FileOutputStream(pointFile)) {
                        mutableBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                    }

                    // 2. Also save tight zoomed crop around the point (160x160)
                    int cropSize = 160;
                    int cx = (int) (normX * w);
                    int cy = (int) (normY * h);
                    int cropL = Math.max(0, Math.min(w - cropSize, cx - cropSize / 2));
                    int cropT = Math.max(0, Math.min(h - cropSize, cy - cropSize / 2));
                    Bitmap cropBmp = Bitmap.createBitmap(mutableBmp, cropL, cropT, cropSize, cropSize);
                    File snippetFile = new File(outDir, "corridor_snippet_" + pointIdx + ".jpg");
                    try (FileOutputStream fos = new FileOutputStream(snippetFile)) {
                        cropBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                    }

                    Log.i(TAG, "[CORRIDOR] Snippet saved: " + snippetFile.getName() + " and full: " + pointFile.getName());

                    if (pointIdx == 1) {
                        snippetBmp1 = cropBmp.copy(Bitmap.Config.ARGB_8888, false);
                    } else if (pointIdx == 2) {
                        snippetBmp2 = cropBmp.copy(Bitmap.Config.ARGB_8888, false);
                    } else if (pointIdx == 3) {
                        // Option A: Multi-View Dashboard Card
                        int footerH = 166;
                        Bitmap boardBmp = Bitmap.createBitmap(w, h + footerH, Bitmap.Config.ARGB_8888);
                        Canvas boardCanvas = new Canvas(boardBmp);
                        boardCanvas.drawBitmap(mutableBmp, 0, 0, null);

                        // Dark sleek footer background
                        Paint bgP = new Paint();
                        bgP.setColor(Color.argb(240, 15, 20, 28));
                        boardCanvas.drawRect(0, h, w, h + footerH, bgP);

                        // Divider line
                        Paint divP = new Paint();
                        divP.setColor(Color.argb(200, 0, 210, 255));
                        divP.setStrokeWidth(3f);
                        boardCanvas.drawLine(0, h, w, h, divP);

                        // Draw Snippet 1, 2, 3 side-by-side
                        int snipW = 196;
                        int snipH = 146;
                        int snipY = h + 10;
                        Paint borderP = new Paint();
                        borderP.setStyle(Paint.Style.STROKE);
                        borderP.setStrokeWidth(3f);

                        Paint lblP = new Paint();
                        lblP.setTextSize(14f);
                        lblP.setFakeBoldText(true);

                        // 1. Snippet 1 (Gate Entry / Yellow)
                        int x1 = 12;
                        if (snippetBmp1 != null) {
                            Rect dst1 = new Rect(x1, snipY, x1 + snipW, snipY + snipH);
                            boardCanvas.drawBitmap(snippetBmp1, null, dst1, null);
                        }
                        borderP.setColor(Color.YELLOW);
                        boardCanvas.drawRect(x1, snipY, x1 + snipW, snipY + snipH, borderP);
                        lblP.setColor(Color.YELLOW);
                        boardCanvas.drawText("P1: GATE ENTRY", x1 + 8, snipY + 20, lblP);

                        // 2. Snippet 2 (Mid Corridor / Cyan)
                        int x2 = 222;
                        if (snippetBmp2 != null) {
                            Rect dst2 = new Rect(x2, snipY, x2 + snipW, snipY + snipH);
                            boardCanvas.drawBitmap(snippetBmp2, null, dst2, null);
                        }
                        borderP.setColor(Color.CYAN);
                        boardCanvas.drawRect(x2, snipY, x2 + snipW, snipY + snipH, borderP);
                        lblP.setColor(Color.CYAN);
                        boardCanvas.drawText("P2: MID CORRIDOR", x2 + 8, snipY + 20, lblP);

                        // 3. Snippet 3 (Exit Point / Green)
                        int x3 = 432;
                        Rect dst3 = new Rect(x3, snipY, x3 + snipW, snipY + snipH);
                        boardCanvas.drawBitmap(cropBmp, null, dst3, null);
                        borderP.setColor(Color.GREEN);
                        boardCanvas.drawRect(x3, snipY, x3 + snipW, snipY + snipH, borderP);
                        lblP.setColor(Color.GREEN);
                        boardCanvas.drawText("P3: CONFIRMED EXIT", x3 + 8, snipY + 20, lblP);

                        File compFile = new File(outDir, "corridor_composite.jpg");
                        try (FileOutputStream fos = new FileOutputStream(compFile)) {
                            boardBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                        }
                    }
                } catch (Exception e) {
                    Log.e(TAG, "[CORRIDOR] Error saving snippet: " + e.getMessage(), e);
                }
            }
        });
        return true;
    }

    // =========================================================================
    // HIGH-SPEED PUTTING CORRIDOR TRACKER -> see PuttTracker.java (shared with the Mac replay tool)
    // =========================================================================
    final PuttTracker tracker = new PuttTracker();

    private void initTrackerHooks() {
        PuttTracker.bootClockNs = android.os.SystemClock::elapsedRealtimeNanos;
        tracker.hooks = new PuttTracker.Hooks() {
            @Override public void log(String msg) { Log.i(TAG, msg); }
            @Override public void setExposureLock(boolean locked) { setExposureLockInternal(locked); }
            @Override public void event(String json) { SessionRecorder rec = sessionRecorder; if (rec != null) rec.event(json); }
            @Override public void runAsync(Runnable r) { snapshotExecutor.execute(r); }
            @Override public void renderDashboard(int w, int h, int rowStride, int pxStride, List<PuttTracker.HighSpeedPoint> pts,
                                                  byte[] frame1, float sx1, float sy1, byte[] frame2, float sx2, float sy2,
                                                  byte[] frame3, byte[] u3, byte[] v3, float sx3, float sy3,
                                                  boolean hasColor, int uStride, int uPx, int vStride, int vPx,
                                                  float speedMps, float angleDeg, float fps) {
                renderAndSaveHighSpeedDashboard(w, h, rowStride, pxStride, pts, frame1, sx1, sy1, frame2, sx2, sy2,
                    frame3, u3, v3, sx3, sy3, hasColor, uStride, uPx, vStride, vPx, speedMps, angleDeg, fps);
            }
        };
    }

    public static float[] getHighSpeedSamples() {
        if (instance == null) return new float[]{0f};
        return instance.tracker.getHighSpeedSamples();
    }

    public static void armHighSpeedCorridor(float minX, float minY, float maxX, float maxY,
                                            float startNormX, float startNormY,
                                            float fwdNormX, float fwdNormY,
                                            float metersPerNormUnit, float corridorLengthNorm) {
        if (instance != null) {
            instance.tracker.armHighSpeedCorridorInternal(minX, minY, maxX, maxY, startNormX, startNormY, fwdNormX, fwdNormY, metersPerNormUnit, corridorLengthNorm);
        }
    }

    public static void disarmHighSpeedCorridor() {
        if (instance != null) instance.tracker.disarmHighSpeedCorridorInternal();
    }

    public static boolean isHighSpeedPuttReady() {
        return (instance != null && instance.tracker.isHsPuttReady);
    }

    public static float[] getHighSpeedPuttTelemetry() {
        if (instance == null) return new float[]{0f, 0f, 0f, 0f, 0f, 0f};
        synchronized (instance.tracker.hsTelemetryResult) {
            return instance.tracker.hsTelemetryResult.clone();
        }
    }

    public static void clearHighSpeedPutt() {
        if (instance != null) instance.tracker.clearHighSpeedPuttInternal();
    }

    private void renderAndSaveHighSpeedDashboard(int w, int h, int rowStride, int pxStride,
                                                 List<PuttTracker.HighSpeedPoint> pts,
                                                 byte[] frame1, float sx1, float sy1,
                                                 byte[] frame2, float sx2, float sy2,
                                                 byte[] frame3, byte[] u3, byte[] v3, float sx3, float sy3,
                                                 boolean hasColor, int uStride, int uPx, int vStride, int vPx,
                                                 float speedMps, float angleDeg, float fps) {
        try {
            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            if (!outDir.exists()) outDir.mkdirs();

            // 1. Render full composite base bitmap from frame 3 (fallback to frame 2 or frame 1)
            byte[] baseFrame = (frame3 != null) ? frame3 : ((frame2 != null) ? frame2 : frame1);
            if (baseFrame == null) return;
            Bitmap fullBmp = yuvToBitmap(baseFrame, u3, v3, w, h, rowStride, pxStride, uStride, uPx, vStride, vPx, hasColor);
            if (fullBmp == null) return;
            Bitmap mutableBmp = fullBmp.copy(Bitmap.Config.ARGB_8888, true);
            Canvas canvas = new Canvas(mutableBmp);

            Paint p = new Paint();
            p.setAntiAlias(true);
            float prevX = -1, prevY = -1;

            for (int i = 0; i < pts.size(); i++) {
                PuttTracker.HighSpeedPoint pt = pts.get(i);
                float px = pt.normX * w;
                float py = pt.normY * h;

                if (i == 0) {
                    p.setColor(Color.YELLOW);
                    p.setStyle(Paint.Style.STROKE);
                    p.setStrokeWidth(3.5f);
                    canvas.drawCircle(px, py, 14f, p);
                    canvas.drawLine(px - 10, py, px + 10, py, p);
                    canvas.drawLine(px, py - 10, px, py + 10, p);
                } else if (i == pts.size() - 1) {
                    p.setColor(Color.GREEN);
                    p.setStyle(Paint.Style.STROKE);
                    p.setStrokeWidth(3.5f);
                    canvas.drawCircle(px, py, 14f, p);
                    canvas.drawLine(px - 10, py, px + 10, py, p);
                    canvas.drawLine(px, py - 10, px, py + 10, p);
                } else {
                    p.setColor(Color.CYAN);
                    p.setStyle(Paint.Style.FILL);
                    canvas.drawCircle(px, py, 6f, p);
                }

                if (prevX >= 0) {
                    p.setColor(Color.WHITE);
                    p.setStyle(Paint.Style.STROKE);
                    p.setStrokeWidth(2.5f);
                    canvas.drawLine(prevX, prevY, px, py, p);
                }
                prevX = px;
                prevY = py;

                if (i == 0 || i == pts.size() - 1) {
                    Paint textP = new Paint();
                    textP.setColor(Color.WHITE);
                    textP.setTextSize(18f);
                    textP.setFakeBoldText(true);
                    String lbl = (i == 0) ? "P1" : ("P" + pts.size());
                    canvas.drawText(lbl, px + 18, py + 6, textP);
                }
            }

            // Header badge
            Paint badgeP = new Paint();
            badgeP.setColor(Color.argb(210, 10, 15, 22));
            badgeP.setStyle(Paint.Style.FILL);
            canvas.drawRect(8, 8, 500, 56, badgeP);

            Paint badgeTextP = new Paint();
            badgeTextP.setColor(Color.GREEN);
            badgeTextP.setTextSize(18f);
            badgeTextP.setFakeBoldText(true);
            String header = String.format(Locale.US, "CONFIRMED PUTT: %.2f m/s (%+.1f°) | %d pts @ %.0f FPS",
                speedMps, angleDeg, pts.size(), fps);
            canvas.drawText(header, 16, 38, badgeTextP);

            // Option A: Multi-View Dashboard Card
            int footerH = 166;
            Bitmap boardBmp = Bitmap.createBitmap(w, h + footerH, Bitmap.Config.ARGB_8888);
            Canvas boardCanvas = new Canvas(boardBmp);
            boardCanvas.drawBitmap(mutableBmp, 0, 0, null);

            // Dark sleek footer background
            Paint bgP = new Paint();
            bgP.setColor(Color.argb(245, 12, 16, 24));
            boardCanvas.drawRect(0, h, w, h + footerH, bgP);

            // Cyan divider line
            Paint divP = new Paint();
            divP.setColor(Color.argb(220, 0, 210, 255));
            divP.setStrokeWidth(3f);
            boardCanvas.drawLine(0, h, w, h, divP);

            int snipW = 196;
            int snipH = 146;
            int snipY = h + 10;
            Paint borderP = new Paint();
            borderP.setStyle(Paint.Style.STROKE);
            borderP.setStrokeWidth(3f);

            Paint lblP = new Paint();
            lblP.setTextSize(14f);
            lblP.setFakeBoldText(true);

            int cropSize = 160;
            Bitmap snipBmp1 = extractZoomCrop(frame1, sx1, sy1, cropSize, w, h, rowStride, pxStride);
            Bitmap snipBmp2 = extractZoomCrop(frame2, sx2, sy2, cropSize, w, h, rowStride, pxStride);
            Bitmap snipBmp3 = extractZoomCrop(frame3, sx3, sy3, cropSize, w, h, rowStride, pxStride);

            // 1. Snippet 1 (Gate Entry / Yellow)
            int x1 = 12;
            if (snipBmp1 != null) {
                boardCanvas.drawBitmap(snipBmp1, null, new Rect(x1, snipY, x1 + snipW, snipY + snipH), null);
            }
            borderP.setColor(Color.YELLOW);
            boardCanvas.drawRect(x1, snipY, x1 + snipW, snipY + snipH, borderP);
            lblP.setColor(Color.YELLOW);
            boardCanvas.drawText("P1: GATE ENTRY", x1 + 8, snipY + 20, lblP);

            // 2. Snippet 2 (Mid Corridor / Cyan)
            int x2 = 222;
            if (snipBmp2 != null) {
                boardCanvas.drawBitmap(snipBmp2, null, new Rect(x2, snipY, x2 + snipW, snipY + snipH), null);
            }
            borderP.setColor(Color.CYAN);
            boardCanvas.drawRect(x2, snipY, x2 + snipW, snipY + snipH, borderP);
            lblP.setColor(Color.CYAN);
            boardCanvas.drawText("P2: MID CORRIDOR", x2 + 8, snipY + 20, lblP);

            // 3. Snippet 3 (Exit Point / Green)
            int x3 = 432;
            if (snipBmp3 != null) {
                boardCanvas.drawBitmap(snipBmp3, null, new Rect(x3, snipY, x3 + snipW, snipY + snipH), null);
            }
            borderP.setColor(Color.GREEN);
            boardCanvas.drawRect(x3, snipY, x3 + snipW, snipY + snipH, borderP);
            lblP.setColor(Color.GREEN);
            boardCanvas.drawText("P3: CONFIRMED EXIT", x3 + 8, snipY + 20, lblP);

            File compFile = new File(outDir, "corridor_composite.jpg");
            try (FileOutputStream fos = new FileOutputStream(compFile)) {
                boardBmp.compress(Bitmap.CompressFormat.JPEG, 92, fos);
            }
            Log.i(TAG, "[HIGH-SPEED CV] Option A Dashboard saved: " + compFile.getAbsolutePath());

            // Also save individual points and snippets for offline inspection
            if (snipBmp1 != null) {
                try (FileOutputStream fos = new FileOutputStream(new File(outDir, "corridor_snippet_1.jpg"))) {
                    snipBmp1.compress(Bitmap.CompressFormat.JPEG, 90, fos);
                }
            }
            if (snipBmp2 != null) {
                try (FileOutputStream fos = new FileOutputStream(new File(outDir, "corridor_snippet_2.jpg"))) {
                    snipBmp2.compress(Bitmap.CompressFormat.JPEG, 90, fos);
                }
            }
            if (snipBmp3 != null) {
                try (FileOutputStream fos = new FileOutputStream(new File(outDir, "corridor_snippet_3.jpg"))) {
                    snipBmp3.compress(Bitmap.CompressFormat.JPEG, 90, fos);
                }
            }
            try (FileOutputStream fos = new FileOutputStream(new File(outDir, "corridor_point_3.jpg"))) {
                mutableBmp.compress(Bitmap.CompressFormat.JPEG, 90, fos);
            }
        } catch (Exception e) {
            Log.e(TAG, "[HIGH-SPEED CV] Error rendering dashboard: " + e.getMessage(), e);
        }
    }

    private Bitmap extractZoomCrop(byte[] yBuffer, float normX, float normY, int cropSize, int w, int h, int rowStride, int pxStride) {
        if (yBuffer == null || w <= 0 || h <= 0) return null;
        int cx = (int) (normX * w);
        int cy = (int) (normY * h);
        int cropL = Math.max(0, Math.min(w - cropSize, cx - cropSize / 2));
        int cropT = Math.max(0, Math.min(h - cropSize, cy - cropSize / 2));

        int[] pixels = new int[cropSize * cropSize];
        for (int y = 0; y < cropSize; y++) {
            int srcY = cropT + y;
            int rowOff = srcY * rowStride;
            int dstOff = y * cropSize;
            for (int x = 0; x < cropSize; x++) {
                int srcX = cropL + x;
                int off = rowOff + srcX * pxStride;
                int gray = (off < yBuffer.length) ? (yBuffer[off] & 0xFF) : 0;
                pixels[dstOff + x] = 0xFF000000 | (gray << 16) | (gray << 8) | gray;
            }
        }
        return Bitmap.createBitmap(pixels, cropSize, cropSize, Bitmap.Config.ARGB_8888);
    }

    private Bitmap yuvToBitmap(byte[] yData, byte[] uData, byte[] vData, int w, int h,
                               int yStride, int yPx, int uStride, int uPx, int vStride, int vPx, boolean hasColor) {
        if (yData == null || w <= 0 || h <= 0) return null;
        int[] fullPixels = new int[w * h];
        for (int y = 0; y < h; y++) {
            int yRowOffset = y * yStride;
            int uvY = y / 2;
            int uRowOffset = uvY * uStride;
            int vRowOffset = uvY * vStride;
            int rowDst = y * w;
            for (int x = 0; x < w; x++) {
                int yOff = yRowOffset + x * yPx;
                float yVal = (yOff < yData.length) ? (yData[yOff] & 0xFF) : 0f;
                int r, g, b;
                if (hasColor && uData != null && vData != null) {
                    int uvX = x / 2;
                    int uOff = uRowOffset + uvX * uPx;
                    int vOff = vRowOffset + uvX * vPx;
                    float uVal = (uOff < uData.length) ? ((uData[uOff] & 0xFF) - 128f) : 0f;
                    float vVal = (vOff < vData.length) ? ((vData[vOff] & 0xFF) - 128f) : 0f;
                    r = (int) Math.max(0, Math.min(255, yVal + 1.402f * vVal));
                    g = (int) Math.max(0, Math.min(255, yVal - 0.344136f * uVal - 0.714136f * vVal));
                    b = (int) Math.max(0, Math.min(255, yVal + 1.772f * uVal));
                } else {
                    int gray = (int) yVal;
                    r = gray; g = gray; b = gray;
                }
                fullPixels[rowDst + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }
        }
        return Bitmap.createBitmap(fullPixels, w, h, Bitmap.Config.ARGB_8888);
    }

    public static boolean saveCalibrationBundle(String bundleId) {
        if (instance == null) return false;
        return instance.saveCalibrationBundleInternal(bundleId);
    }

    private boolean saveCalibrationBundleInternal(String bundleId) {
        try {
            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            if (!outDir.exists()) outDir.mkdirs();

            // 1. Save Full Raw 640x480 RGB Frame
            byte[] yData = latestYBuffer;
            byte[] uData = latestUBuffer;
            byte[] vData = latestVBuffer;
            int w = frameWidth;
            int h = frameHeight;
            if (yData != null && w > 0 && h > 0) {
                int yRowStride = frameRowStride > 0 ? frameRowStride : w;
                int yPxStride = framePixelStride > 0 ? framePixelStride : 1;
                int uRow = uRowStride > 0 ? uRowStride : (w / 2);
                int uPx = uPixelStride > 0 ? uPixelStride : 1;
                int vRow = vRowStride > 0 ? vRowStride : (w / 2);
                int vPx = vPixelStride > 0 ? vPixelStride : 1;
                boolean useColor = hasColorPlanes && (uData != null) && (vData != null);

                int[] fullPixels = new int[w * h];
                for (int y = 0; y < h; y++) {
                    int yRowOffset = y * yRowStride;
                    int uvY = y / 2;
                    int uRowOffset = uvY * uRow;
                    int vRowOffset = uvY * vRow;
                    int rowDst = y * w;

                    for (int x = 0; x < w; x++) {
                        int yOff = yRowOffset + x * yPxStride;
                        float yVal = (yOff < yData.length) ? (yData[yOff] & 0xFF) : 0f;
                        int r, g, b;
                        if (useColor) {
                            int uvX = x / 2;
                            int uOff = uRowOffset + uvX * uPx;
                            int vOff = vRowOffset + uvX * vPx;
                            float uVal = (uOff < uData.length) ? ((uData[uOff] & 0xFF) - 128f) : 0f;
                            float vVal = (vOff < vData.length) ? ((vData[vOff] & 0xFF) - 128f) : 0f;
                            r = (int) Math.max(0, Math.min(255, yVal + 1.402f * vVal));
                            g = (int) Math.max(0, Math.min(255, yVal - 0.344136f * uVal - 0.714136f * vVal));
                            b = (int) Math.max(0, Math.min(255, yVal + 1.772f * uVal));
                        } else {
                            r = g = b = (int) yVal;
                        }
                        fullPixels[rowDst + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
                    }
                }

                Bitmap rawBmp = Bitmap.createBitmap(fullPixels, w, h, Bitmap.Config.ARGB_8888);
                Bitmap mutableRaw = rawBmp.copy(Bitmap.Config.ARGB_8888, true);
                if (latestStereoDetection[0] > 0.5f) {
                    Canvas rawCanvas = new Canvas(mutableRaw);
                    Paint p = new Paint();
                    p.setColor(Color.RED);
                    p.setStyle(Paint.Style.STROKE);
                    p.setStrokeWidth(3f);
                    float rx = latestFullNormX * w;
                    float ry = latestFullNormY * h;
                    rawCanvas.drawCircle(rx, ry, 14f, p);
                    rawCanvas.drawLine(rx - 18, ry, rx + 18, ry, p);
                    rawCanvas.drawLine(rx, ry - 18, rx, ry + 18, p);
                }

                File rawFile = new File(outDir, "bundle_" + bundleId + "_raw.jpg");
                try (FileOutputStream fos = new FileOutputStream(rawFile)) {
                    mutableRaw.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                }
                File leftRawFile = new File(outDir, "bundle_" + bundleId + "_left_raw.jpg");
                try (FileOutputStream fos = new FileOutputStream(leftRawFile)) {
                    mutableRaw.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                }
                Log.i(TAG, "[BUNDLE] Saved Left raw image: " + leftRawFile.getAbsolutePath());
            }

            // 2. Save Full Right Raw RGB Frame (if available)
            byte[] yRight = latestYBufferRight;
            byte[] uRight = latestUBufferRight;
            byte[] vRight = latestVBufferRight;
            if (yRight != null && w > 0 && h > 0) {
                int yRowStride = frameRowStrideRight > 0 ? frameRowStrideRight : w;
                int yPxStride = framePixelStrideRight > 0 ? framePixelStrideRight : 1;
                int uRow = uRowStrideRight > 0 ? uRowStrideRight : (w / 2);
                int uPx = uPixelStrideRight > 0 ? uPixelStrideRight : 1;
                int vRow = vRowStrideRight > 0 ? vRowStrideRight : (w / 2);
                int vPx = vPixelStrideRight > 0 ? vPixelStrideRight : 1;
                boolean useColor = hasColorPlanesRight && (uRight != null) && (vRight != null);

                int[] rightPixels = new int[w * h];
                for (int y = 0; y < h; y++) {
                    int yRowOffset = y * yRowStride;
                    int uvY = y / 2;
                    int uRowOffset = uvY * uRow;
                    int vRowOffset = uvY * vRow;
                    int rowDst = y * w;

                    for (int x = 0; x < w; x++) {
                        int yOff = yRowOffset + x * yPxStride;
                        float yVal = (yOff < yRight.length) ? (yRight[yOff] & 0xFF) : 0f;
                        int r, g, b;
                        if (useColor) {
                            int uvX = x / 2;
                            int uOff = uRowOffset + uvX * uPx;
                            int vOff = vRowOffset + uvX * vPx;
                            float uVal = (uOff < uRight.length) ? ((uRight[uOff] & 0xFF) - 128f) : 0f;
                            float vVal = (vOff < vRight.length) ? ((vRight[vOff] & 0xFF) - 128f) : 0f;
                            r = (int) Math.max(0, Math.min(255, yVal + 1.402f * vVal));
                            g = (int) Math.max(0, Math.min(255, yVal - 0.344136f * uVal - 0.714136f * vVal));
                            b = (int) Math.max(0, Math.min(255, yVal + 1.772f * uVal));
                        } else {
                            r = g = b = (int) yVal;
                        }
                        rightPixels[rowDst + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
                    }
                }

                Bitmap rightBmp = Bitmap.createBitmap(rightPixels, w, h, Bitmap.Config.ARGB_8888);
                Bitmap mutableRight = rightBmp.copy(Bitmap.Config.ARGB_8888, true);
                if (latestHasStereo) {
                    Canvas rightCanvas = new Canvas(mutableRight);
                    Paint p = new Paint();
                    p.setColor(Color.CYAN);
                    p.setStyle(Paint.Style.STROKE);
                    p.setStrokeWidth(3f);
                    float rx = latestRightNormX * w;
                    float ry = latestRightNormY * h;
                    rightCanvas.drawCircle(rx, ry, 14f, p);
                    rightCanvas.drawLine(rx - 18, ry, rx + 18, ry, p);
                    rightCanvas.drawLine(rx, ry - 18, rx, ry + 18, p);
                }

                File rightFile = new File(outDir, "bundle_" + bundleId + "_right_raw.jpg");
                try (FileOutputStream fos = new FileOutputStream(rightFile)) {
                    mutableRight.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                }
                Log.i(TAG, "[BUNDLE] Saved Right raw image: " + rightFile.getAbsolutePath());
            }

            // 3. Save Crop Image if available
            float[] pFloats = latestCropFloats;
            if (pFloats != null) {
                int planeSize = MODEL_WIDTH * MODEL_HEIGHT;
                int[] cropPixels = new int[planeSize];
                for (int i = 0; i < planeSize; i++) {
                    int r = (int) Math.max(0, Math.min(255, pFloats[i] * 255.0f));
                    int g = (int) Math.max(0, Math.min(255, pFloats[planeSize + i] * 255.0f));
                    int b = (int) Math.max(0, Math.min(255, pFloats[2 * planeSize + i] * 255.0f));
                    cropPixels[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
                }
                Bitmap cropBmp = Bitmap.createBitmap(cropPixels, MODEL_WIDTH, MODEL_HEIGHT, Bitmap.Config.ARGB_8888);
                Bitmap mutableCrop = cropBmp.copy(Bitmap.Config.ARGB_8888, true);
                Canvas cCanvas = new Canvas(mutableCrop);
                Paint boxPaint = new Paint();
                boxPaint.setColor(Color.GREEN);
                boxPaint.setStyle(Paint.Style.STROKE);
                boxPaint.setStrokeWidth(3.0f);
                float cx = latestNormX * MODEL_WIDTH;
                float cy = latestNormY * MODEL_HEIGHT;
                float bw = latestNormW * MODEL_WIDTH;
                float bh = latestNormH * MODEL_HEIGHT;
                cCanvas.drawRect(cx - bw * 0.5f, cy - bh * 0.5f, cx + bw * 0.5f, cy + bh * 0.5f, boxPaint);
                Paint textPaint = new Paint();
                textPaint.setColor(Color.GREEN);
                textPaint.setTextSize(18f);
                textPaint.setFakeBoldText(true);
                cCanvas.drawText(String.format(Locale.US, "Ball: %.1f%%", latestConf * 100f), 10f, 25f, textPaint);

                File cropFile = new File(outDir, "bundle_" + bundleId + "_crop.jpg");
                try (FileOutputStream fos = new FileOutputStream(cropFile)) {
                    mutableCrop.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                }
                Log.i(TAG, "[BUNDLE] Saved crop image: " + cropFile.getAbsolutePath());
            }

            return true;
        } catch (Exception e) {
            Log.e(TAG, "[BUNDLE] Failed to save bundle: " + e.getMessage(), e);
            return false;
        }
    }

    public static String getStorageDir() {
        if (instance != null && instance.context != null) {
            File d = instance.context.getExternalFilesDir(null);
            if (d != null) return d.getAbsolutePath();
        }
        return "/storage/emulated/0/Android/data/com.godot.game/files";
    }

    public static boolean saveTextFile(String filename, String content) {
        try {
            File outDir = (instance != null && instance.context != null) ? instance.context.getExternalFilesDir(null) : new File("/storage/emulated/0/Android/data/com.godot.game/files");
            if (outDir != null && !outDir.exists()) outDir.mkdirs();
            File f = new File(outDir, filename);
            try (FileOutputStream fos = new FileOutputStream(f)) {
                fos.write(content.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            Log.i(TAG, "[BUNDLE] Successfully saved text file: " + f.getAbsolutePath());
            return true;
        } catch (Exception e) {
            Log.e(TAG, "[BUNDLE] Failed to save text file " + filename + ": " + e.getMessage());
            return false;
        }
    }

    public static boolean saveImageFile(String filename, byte[] bytes) {
        try {
            File outDir = (instance != null && instance.context != null) ? instance.context.getExternalFilesDir(null) : new File("/storage/emulated/0/Android/data/com.godot.game/files");
            if (outDir != null && !outDir.exists()) outDir.mkdirs();
            File f = new File(outDir, filename);
            try (FileOutputStream fos = new FileOutputStream(f)) {
                fos.write(bytes);
            }
            Log.i(TAG, "[BUNDLE] Successfully saved image file: " + f.getAbsolutePath() + " (" + bytes.length + " bytes)");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "[BUNDLE] Failed to save image file " + filename + ": " + e.getMessage());
            return false;
        }
    }

    /**
     * Returns the latest YOLO detection result instantly (non-blocking).
     * [found (1.0/0.0), left_norm_x, left_norm_y, right_norm_x, right_norm_y, confidence, has_stereo (1.0/0.0), norm_w]
     */
    public static float[] detectBall() {
        if (instance == null) {
            return new float[]{0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        }
        if (!instance.isModelLoaded) {
            return new float[]{0.0f, 0.0f, 0.0f, 0.0f, 0.0f, -1.0f, 0.0f, 0.0f};
        }
        return instance.latestStereoDetection;
    }

    /**
     * Returns the latest stereo detection result instantly (non-blocking).
     * [found (1.0/0.0), left_norm_x, left_norm_y, right_norm_x, right_norm_y, confidence, has_stereo (1.0/0.0), norm_w]
     */
    public static float[] detectBallStereo() {
        if (instance == null) {
            return new float[]{0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        }
        if (!instance.isModelLoaded) {
            return new float[]{0.0f, 0.0f, 0.0f, 0.0f, 0.0f, -1.0f, 0.0f, 0.0f, 0.0f};
        }
        return instance.latestStereoDetection;
    }

    public static long getYoloDetectionSeq() {
        return (instance != null) ? instance.yoloDetectionSeq : 0L;
    }

    // =========================================================================
    // MJPEG & HTTP STREAMING SERVER (Port 8080)
    // =========================================================================
    private ServerSocket streamServerSocket = null;
    private Thread streamAcceptorThread = null;
    private Thread streamWorkerThread = null;
    private volatile boolean isStreamServerRunning = false;
    private final CopyOnWriteArrayList<StreamClient> streamClients = new CopyOnWriteArrayList<>();

    // Head Pose Telemetry for Stream HUD
    private static volatile float headPosX = 0f;
    private static volatile float headPosY = 0f;
    private static volatile float headPosZ = 0f;
    private static volatile float headPitch = 0f;
    private static volatile float headYaw = 0f;
    private static volatile float headRoll = 0f;

    public static void updateHeadPose(float px, float py, float pz, float pitch, float yaw, float roll) {
        headPosX = px; headPosY = py; headPosZ = pz;
        headPitch = pitch; headYaw = yaw; headRoll = roll;
    }

    private static class StreamClient {
        final Socket socket;
        final OutputStream os;
        final String mode; // "stereo", "left", "right"
        long lastActiveTime;

        StreamClient(Socket s, OutputStream o, String m) {
            this.socket = s;
            this.os = o;
            this.mode = m;
            this.lastActiveTime = System.currentTimeMillis();
        }
    }

    public synchronized void startStreamServer(final int port) {
        if (isStreamServerRunning) return;
        isStreamServerRunning = true;

        streamAcceptorThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    streamServerSocket = new ServerSocket();
                    streamServerSocket.setReuseAddress(true);
                    streamServerSocket.bind(new InetSocketAddress(port));
                    Log.i(TAG, "[STREAM] MJPEG Server listening on port " + port);

                    while (isStreamServerRunning && !streamServerSocket.isClosed()) {
                        final Socket clientSocket = streamServerSocket.accept();
                        clientSocket.setTcpNoDelay(true);
                        clientSocket.setSoTimeout(3000);

                        new Thread(new Runnable() {
                            @Override
                            public void run() {
                                handleHttpClient(clientSocket);
                            }
                        }, "StreamClientHandler").start();
                    }
                } catch (Exception e) {
                    if (isStreamServerRunning) {
                        Log.e(TAG, "[STREAM] Acceptor error: " + e.getMessage());
                    }
                }
            }
        }, "MjpegStreamAcceptor");
        streamAcceptorThread.setDaemon(true);
        streamAcceptorThread.start();

        streamWorkerThread = new Thread(new Runnable() {
            @Override
            public void run() {
                broadcastStreamLoop();
            }
        }, "MjpegStreamWorker");
        streamWorkerThread.setDaemon(true);
        streamWorkerThread.start();
    }

    public synchronized void stopStreamServer() {
        isStreamServerRunning = false;
        try {
            if (streamServerSocket != null) {
                streamServerSocket.close();
                streamServerSocket = null;
            }
        } catch (Exception ignored) {}

        for (StreamClient client : streamClients) {
            try {
                client.socket.close();
            } catch (Exception ignored) {}
        }
        streamClients.clear();

        if (streamAcceptorThread != null) {
            streamAcceptorThread.interrupt();
            streamAcceptorThread = null;
        }
        if (streamWorkerThread != null) {
            streamWorkerThread.interrupt();
            streamWorkerThread = null;
        }
        Log.i(TAG, "[STREAM] MJPEG Server stopped.");
    }

    private void handleHttpClient(Socket socket) {
        try {
            BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream()));
            String line = reader.readLine();
            if (line == null) {
                socket.close();
                return;
            }

            String[] parts = line.split(" ");
            if (parts.length < 2) {
                socket.close();
                return;
            }

            String method = parts[0];
            String path = parts[1];

            while ((line = reader.readLine()) != null && !line.isEmpty()) {}

            OutputStream os = socket.getOutputStream();

            if (path.equals("/") || path.equals("/index.html")) {
                sendHtmlDashboard(os);
                socket.close();
            } else if (path.equals("/status")) {
                sendStatusJson(os);
                socket.close();
            } else if (path.startsWith("/stereo") || path.startsWith("/left") || path.startsWith("/right")) {
                String mode = "stereo";
                if (path.startsWith("/left")) mode = "left";
                else if (path.startsWith("/right")) mode = "right";

                String header = "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n" +
                        "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
                        "Pragma: no-cache\r\n" +
                        "Expires: 0\r\n" +
                        "Access-Control-Allow-Origin: *\r\n" +
                        "Connection: close\r\n\r\n";
                os.write(header.getBytes("UTF-8"));
                os.flush();

                streamClients.add(new StreamClient(socket, os, mode));
                Log.i(TAG, "[STREAM] New subscriber (" + mode + "). Total: " + streamClients.size());
            } else if (path.startsWith("/snapshot")) {
                boolean ok = saveStereoSnapshotInternal("manual", "snap_" + System.currentTimeMillis());
                String resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\n\r\n{\"success\":" + ok + "}";
                os.write(resp.getBytes("UTF-8"));
                os.flush();
                socket.close();
            } else {
                String resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
                os.write(resp.getBytes("UTF-8"));
                os.flush();
                socket.close();
            }
        } catch (Exception e) {
            try { socket.close(); } catch (Exception ignored) {}
        }
    }

    private void sendStatusJson(OutputStream os) throws Exception {
        float leftX = latestFullNormX;
        float leftY = latestFullNormY;
        float rightX = latestRightNormX;
        float rightY = latestRightNormY;
        float conf = latestStereoDetection[0] > 0 ? latestStereoDetection[5] : 0f;
        float disp = latestHasStereo ? (leftX - rightX) : 0f;
        float hsSpeed = tracker.hsTelemetryResult[0];
        int hsSamples = (int) tracker.hsTelemetryResult[2];
        boolean hsArmed = (tracker.hsState != PuttTracker.HS_STATE_IDLE);

        String json = String.format(Locale.US,
                "{\"fps\":%d,\"clients\":%d,\"left\":{\"x\":%.3f,\"y\":%.3f,\"conf\":%.2f}," +
                "\"right\":{\"x\":%.3f,\"y\":%.3f},\"disparity\":%.4f," +
                "\"hs_cv\":{\"armed\":%b,\"speed\":%.2f,\"samples\":%d}," +
                "\"head\":{\"x\":%.3f,\"y\":%.3f,\"z\":%.3f,\"pitch\":%.1f,\"yaw\":%.1f,\"roll\":%.1f}}\r\n",
                frameCount > 0 ? 60 : 0, streamClients.size(),
                leftX, leftY, conf, rightX, rightY, disp,
                hsArmed, hsSpeed, hsSamples,
                headPosX, headPosY, headPosZ, headPitch, headYaw, headRoll);

        String resp = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Content-Length: " + json.getBytes("UTF-8").length + "\r\n\r\n" + json;
        os.write(resp.getBytes("UTF-8"));
        os.flush();
    }

    private void sendHtmlDashboard(OutputStream os) throws Exception {
        String html = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>RealBallPutting Quest 3 Stream</title>" +
                "<meta name='viewport' content='width=device-width, initial-scale=1'>" +
                "<style>" +
                "body{background:#121214;color:#eee;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,sans-serif;margin:0;padding:16px;display:flex;flex-direction:column;align-items:center;}" +
                "h1{margin:0 0 12px;font-size:22px;color:#4ade80;}" +
                ".stream-container{position:relative;background:#000;border-radius:10px;overflow:hidden;box-shadow:0 8px 24px rgba(0,0,0,0.6);margin-bottom:16px;max-width:1280px;width:100%;}" +
                "img#liveStream{width:100%;height:auto;display:block;}" +
                ".btn-group{display:flex;gap:10px;margin-bottom:16px;}" +
                "button{background:#27272a;color:#eee;border:1px solid #3f3f46;padding:8px 16px;border-radius:6px;cursor:pointer;font-weight:600;transition:0.15s;}" +
                "button:hover{background:#3f3f46;}" +
                "button.active{background:#22c55e;color:#000;border-color:#22c55e;}" +
                ".dashboard{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;width:100%;max-width:1280px;}" +
                ".card{background:#18181b;border:1px solid #27272a;border-radius:8px;padding:12px;}" +
                ".card-title{font-size:11px;color:#a1a1aa;text-transform:uppercase;letter-spacing:0.05em;margin-bottom:6px;}" +
                ".card-val{font-size:18px;font-weight:700;font-family:monospace;color:#38bdf8;}" +
                "</style></head><body>" +
                "<h1>RealBallPutting - Quest 3 Dual Camera Stream</h1>" +
                "<div class='btn-group'>" +
                "<button id='btnStereo' class='active' onclick=\"switchMode('stereo')\">Stereo View (1280x480)</button>" +
                "<button id='btnLeft' onclick=\"switchMode('left')\">Left Camera</button>" +
                "<button id='btnRight' onclick=\"switchMode('right')\">Right Camera</button>" +
                "<button onclick=\"triggerSnap()\" style='background:#0284c7;color:#fff;border-color:#0284c7;'>Take Snapshot</button>" +
                "</div>" +
                "<div class='stream-container'><img id='liveStream' src='/stereo' /></div>" +
                "<div class='dashboard'>" +
                "<div class='card'><div class='card-title'>Ball Tracking</div><div class='card-val' id='cardBall'>Searching</div></div>" +
                "<div class='card'><div class='card-title'>Stereo Disparity</div><div class='card-val' id='cardDisp'>0.0000</div></div>" +
                "<div class='card'><div class='card-title'>High-Speed CV</div><div class='card-val' id='cardHs'>Disarmed</div></div>" +
                "<div class='card'><div class='card-title'>Head Pose</div><div class='card-val' id='cardHead'>P:0 Y:0 R:0</div></div>" +
                "</div>" +
                "<script>" +
                "function switchMode(m){" +
                "document.getElementById('liveStream').src = '/' + m + '?t=' + Date.now();" +
                "document.querySelectorAll('.btn-group button').forEach(b=>b.classList.remove('active'));" +
                "if(m==='stereo')document.getElementById('btnStereo').classList.add('active');" +
                "else if(m==='left')document.getElementById('btnLeft').classList.add('active');" +
                "else if(m==='right')document.getElementById('btnRight').classList.add('active');" +
                "}" +
                "function triggerSnap(){fetch('/snapshot').then(r=>r.json()).then(d=>alert('Snapshot saved: '+d.success));}" +
                "setInterval(async()=>{" +
                "try{" +
                "let r = await fetch('/status');" +
                "let d = await r.json();" +
                "document.getElementById('cardBall').innerHTML = d.left.conf>0.2 ? ('Ball: '+(d.left.conf*100).toFixed(0)+'% ('+d.left.x.toFixed(2)+', '+d.left.y.toFixed(2)+')') : 'No Ball';" +
                "document.getElementById('cardDisp').innerHTML = d.disparity.toFixed(4) + (d.disparity>0?' (Active)':' (None)');" +
                "document.getElementById('cardHs').innerHTML = d.hs_cv.armed ? ('ARMED | Last: '+d.hs_cv.speed.toFixed(2)+' m/s ('+d.hs_cv.samples+' pts)') : 'Disarmed';" +
                "document.getElementById('cardHead').innerHTML = 'P:'+d.head.pitch.toFixed(1)+'° Y:'+d.head.yaw.toFixed(1)+'° R:'+d.head.roll.toFixed(1)+'°';" +
                "}catch(e){}" +
                "},250);" +
                "</script></body></html>";

        String resp = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/html; charset=UTF-8\r\n" +
                "Content-Length: " + html.getBytes("UTF-8").length + "\r\n\r\n" + html;
        os.write(resp.getBytes("UTF-8"));
        os.flush();
    }

    private void broadcastStreamLoop() {
        final int w = 640;
        final int h = 480;
        final int[] leftPixels = new int[w * h];
        final int[] rightPixels = new int[w * h];
        final int[] stereoPixels = new int[2 * w * h];

        Bitmap leftBmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Bitmap rightBmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Bitmap stereoBmp = Bitmap.createBitmap(2 * w, h, Bitmap.Config.ARGB_8888);

        Paint ballPaint = new Paint();
        ballPaint.setColor(Color.GREEN);
        ballPaint.setStyle(Paint.Style.STROKE);
        ballPaint.setStrokeWidth(3f);

        Paint rightPaint = new Paint();
        rightPaint.setColor(Color.CYAN);
        rightPaint.setStyle(Paint.Style.STROKE);
        rightPaint.setStrokeWidth(3f);

        Paint roiPaint = new Paint();
        roiPaint.setColor(Color.YELLOW);
        roiPaint.setStyle(Paint.Style.STROKE);
        roiPaint.setStrokeWidth(2f);

        Paint textPaint = new Paint();
        textPaint.setColor(Color.WHITE);
        textPaint.setTextSize(18f);
        textPaint.setFakeBoldText(true);
        textPaint.setShadowLayer(3f, 1f, 1f, Color.BLACK);

        while (isStreamServerRunning) {
            try {
                if (streamClients.isEmpty()) {
                    Thread.sleep(100);
                    continue;
                }

                long frameStart = System.currentTimeMillis();

                // 1. Render Left YUV to RGB
                final byte[] yL = latestYBuffer;
                final byte[] uL = latestUBuffer;
                final byte[] vL = latestVBuffer;
                boolean hasLeft = convertYuvToRgb(yL, uL, vL,
                        w, h, frameRowStride, framePixelStride, uRowStride, uPixelStride, vRowStride, vPixelStride,
                        hasColorPlanes, leftPixels);

                // 2. Render Right YUV to RGB
                final byte[] yR = latestYBufferRight;
                final byte[] uR = latestUBufferRight;
                final byte[] vR = latestVBufferRight;
                boolean hasRight = convertYuvToRgb(yR, uR, vR,
                        w, h, frameRowStrideRight, framePixelStrideRight, uRowStrideRight, uPixelStrideRight, vRowStrideRight, vPixelStrideRight,
                        hasColorPlanesRight, rightPixels);

                if (!hasLeft && !hasRight) {
                    Thread.sleep(30);
                    continue;
                }

                boolean needStereo = false, needLeft = false, needRight = false;
                for (StreamClient c : streamClients) {
                    if ("stereo".equals(c.mode)) needStereo = true;
                    else if ("left".equals(c.mode)) needLeft = true;
                    else if ("right".equals(c.mode)) needRight = true;
                }

                byte[] stereoJpeg = null;
                byte[] leftJpeg = null;
                byte[] rightJpeg = null;

                float lx = latestFullNormX * w;
                float ly = latestFullNormY * h;
                float conf = latestStereoDetection[0] > 0 ? latestStereoDetection[5] : 0f;
                float rx = latestRightNormX * w;
                float ry = latestRightNormY * h;

                if (needStereo) {
                    for (int y = 0; y < h; y++) {
                        int srcRow = y * w;
                        int dstRow = y * (2 * w);
                        System.arraycopy(leftPixels, srcRow, stereoPixels, dstRow, w);
                        System.arraycopy(rightPixels, srcRow, stereoPixels, dstRow + w, w);
                    }
                    stereoBmp.setPixels(stereoPixels, 0, 2 * w, 0, 0, 2 * w, h);
                    Canvas canvas = new Canvas(stereoBmp);

                    if (conf >= 0.15f) {
                        canvas.drawCircle(lx, ly, 16f, ballPaint);
                        canvas.drawLine(lx - 22, ly, lx + 22, ly, ballPaint);
                        canvas.drawLine(lx, ly - 22, lx, ly + 22, ballPaint);
                    }
                    if (isRoiEnabled) {
                        canvas.drawRect(roiNormLeft * w, roiNormTop * h, roiNormRight * w, roiNormBottom * h, roiPaint);
                    }
                    canvas.drawText(String.format(Locale.US, "LEFT EYE | Ball: %.0f%% (%.2f, %.2f)", conf * 100f, latestFullNormX, latestFullNormY), 12f, 28f, textPaint);

                    if (latestHasStereo) {
                        float rScreenX = rx + w;
                        canvas.drawCircle(rScreenX, ry, 16f, rightPaint);
                        canvas.drawLine(rScreenX - 22, ry, rScreenX + 22, ry, rightPaint);
                        canvas.drawLine(rScreenX, ry - 22, rScreenX, ry + 22, rightPaint);
                        canvas.drawLine(w, ly, 2 * w, ly, roiPaint);
                    }
                    canvas.drawText(String.format(Locale.US, "RIGHT EYE | Disparity: %.4f", latestHasStereo ? (latestFullNormX - latestRightNormX) : 0f), w + 12f, 28f, textPaint);

                    ByteArrayOutputStream baos = new ByteArrayOutputStream();
                    stereoBmp.compress(Bitmap.CompressFormat.JPEG, 75, baos);
                    stereoJpeg = baos.toByteArray();
                }

                if (needLeft) {
                    leftBmp.setPixels(leftPixels, 0, w, 0, 0, w, h);
                    Canvas canvas = new Canvas(leftBmp);
                    if (conf >= 0.15f) {
                        canvas.drawCircle(lx, ly, 16f, ballPaint);
                    }
                    canvas.drawText(String.format(Locale.US, "LEFT EYE | %.0f%%", conf * 100f), 12f, 28f, textPaint);
                    ByteArrayOutputStream baos = new ByteArrayOutputStream();
                    leftBmp.compress(Bitmap.CompressFormat.JPEG, 75, baos);
                    leftJpeg = baos.toByteArray();
                }

                if (needRight) {
                    rightBmp.setPixels(rightPixels, 0, w, 0, 0, w, h);
                    Canvas canvas = new Canvas(rightBmp);
                    if (latestHasStereo) {
                        canvas.drawCircle(rx, ry, 16f, rightPaint);
                    }
                    canvas.drawText("RIGHT EYE", 12f, 28f, textPaint);
                    ByteArrayOutputStream baos = new ByteArrayOutputStream();
                    rightBmp.compress(Bitmap.CompressFormat.JPEG, 75, baos);
                    rightJpeg = baos.toByteArray();
                }

                List<StreamClient> toRemove = new ArrayList<>();
                for (StreamClient client : streamClients) {
                    byte[] data = "stereo".equals(client.mode) ? stereoJpeg :
                                 ("left".equals(client.mode) ? leftJpeg : rightJpeg);
                    if (data == null) continue;

                    try {
                        String frameHeader = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + data.length + "\r\n\r\n";
                        client.os.write(frameHeader.getBytes("UTF-8"));
                        client.os.write(data);
                        client.os.write("\r\n".getBytes("UTF-8"));
                        client.os.flush();
                        client.lastActiveTime = System.currentTimeMillis();
                    } catch (Exception e) {
                        toRemove.add(client);
                    }
                }

                for (StreamClient dead : toRemove) {
                    try { dead.socket.close(); } catch (Exception ignored) {}
                    streamClients.remove(dead);
                    Log.i(TAG, "[STREAM] Client disconnected. Remaining: " + streamClients.size());
                }

                long elapsed = System.currentTimeMillis() - frameStart;
                long sleepMs = Math.max(5, 40 - elapsed);
                Thread.sleep(sleepMs);
            } catch (InterruptedException ie) {
                break;
            } catch (Exception e) {
                Log.e(TAG, "[STREAM] Broadcast loop error: " + e.getMessage());
            }
        }
    }

    private boolean convertYuvToRgb(byte[] yData, byte[] uData, byte[] vData,
                                    int w, int h, int yRow, int yPx, int uRow, int uPx, int vRow, int vPx,
                                    boolean useColor, int[] outPixels) {
        if (yData == null || w <= 0 || h <= 0) return false;
        int yRowStride = yRow > 0 ? yRow : w;
        int yPxStride = yPx > 0 ? yPx : 1;
        int uRowStride = uRow > 0 ? uRow : (w / 2);
        int uPxStride = uPx > 0 ? uPx : 1;
        int vRowStride = vRow > 0 ? vRow : (w / 2);
        int vPxStride = vPx > 0 ? vPx : 1;
        boolean color = useColor && (uData != null) && (vData != null);

        for (int y = 0; y < h; y++) {
            int yRowOffset = y * yRowStride;
            int uvY = y / 2;
            int uRowOffset = uvY * uRowStride;
            int vRowOffset = uvY * vRowStride;
            int rowDst = y * w;

            for (int x = 0; x < w; x++) {
                int yOff = yRowOffset + x * yPxStride;
                float yVal = (yOff < yData.length) ? (yData[yOff] & 0xFF) : 0f;
                int r, g, b;
                if (color) {
                    int uvX = x / 2;
                    int uOff = uRowOffset + uvX * uPxStride;
                    int vOff = vRowOffset + uvX * vPxStride;
                    float uVal = (uOff < uData.length) ? ((uData[uOff] & 0xFF) - 128f) : 0f;
                    float vVal = (vOff < vData.length) ? ((vData[vOff] & 0xFF) - 128f) : 0f;
                    r = (int) Math.max(0, Math.min(255, yVal + 1.402f * vVal));
                    g = (int) Math.max(0, Math.min(255, yVal - 0.344136f * uVal - 0.714136f * vVal));
                    b = (int) Math.max(0, Math.min(255, yVal + 1.772f * uVal));
                } else {
                    r = g = b = (int) yVal;
                }
                outPixels[rowDst + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
            }
        }
        return true;
    }

    public static boolean saveStereoSnapshot(String sessionName, String frameTag) {
        if (instance != null) {
            return instance.saveStereoSnapshotInternal(sessionName, frameTag);
        }
        return false;
    }

    public boolean saveStereoSnapshotInternal(final String sessionName, final String frameTag) {
        try {
            File outDir = (context != null) ? context.getExternalFilesDir(null) : null;
            if (outDir == null) {
                outDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            }
            final File sessionDir = new File(outDir, "sessions/" + sessionName);
            if (!sessionDir.exists()) sessionDir.mkdirs();

            final byte[] rawYL = latestYBuffer;
            final byte[] rawUL = latestUBuffer;
            final byte[] rawVL = latestVBuffer;
            final byte[] rawYR = latestYBufferRight;
            final byte[] rawUR = latestUBufferRight;
            final byte[] rawVR = latestVBufferRight;
            final byte[] yL = (rawYL != null) ? rawYL.clone() : null;
            final byte[] uL = (rawUL != null) ? rawUL.clone() : null;
            final byte[] vL = (rawVL != null) ? rawVL.clone() : null;
            final byte[] yR = (rawYR != null) ? rawYR.clone() : null;
            final byte[] uR = (rawUR != null) ? rawUR.clone() : null;
            final byte[] vR = (rawVR != null) ? rawVR.clone() : null;

            final int w = frameWidth > 0 ? frameWidth : 640;
            final int h = frameHeight > 0 ? frameHeight : 480;
            final int yRowL = frameRowStride, yPxL = framePixelStride, uRowL = uRowStride, uPxL = uPixelStride, vRowL = vRowStride, vPxL = vPixelStride;
            final int yRowR = frameRowStrideRight, yPxR = framePixelStrideRight, uRowR = uRowStrideRight, uPxR = uPixelStrideRight, vRowR = vRowStrideRight, vPxR = vPixelStrideRight;
            final boolean colL = hasColorPlanes, colR = hasColorPlanesRight;

            snapshotExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        int[] pxL = new int[w * h];
                        if (convertYuvToRgb(yL, uL, vL, w, h, yRowL, yPxL, uRowL, uPxL, vRowL, vPxL, colL, pxL)) {
                            Bitmap bmpL = Bitmap.createBitmap(pxL, w, h, Bitmap.Config.ARGB_8888);
                            File fL = new File(sessionDir, frameTag + "_left.jpg");
                            try (FileOutputStream fos = new FileOutputStream(fL)) {
                                bmpL.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                            }
                        }

                        int[] pxR = new int[w * h];
                        if (convertYuvToRgb(yR, uR, vR, w, h, yRowR, yPxR, uRowR, uPxR, vRowR, vPxR, colR, pxR)) {
                            Bitmap bmpR = Bitmap.createBitmap(pxR, w, h, Bitmap.Config.ARGB_8888);
                            File fR = new File(sessionDir, frameTag + "_right.jpg");
                            try (FileOutputStream fos = new FileOutputStream(fR)) {
                                bmpR.compress(Bitmap.CompressFormat.JPEG, 92, fos);
                            }
                        }
                        Log.i(TAG, "[SNAPSHOT] Saved stereo pair for session " + sessionName + " (" + frameTag + ")");
                    } catch (Exception e) {
                        Log.e(TAG, "[SNAPSHOT] Failed to save stereo pair: " + e.getMessage(), e);
                    }
                }
            });
            return true;
        } catch (Exception e) {
            Log.e(TAG, "[SNAPSHOT] Error scheduling snapshot: " + e.getMessage(), e);
            return false;
        }
    }
}


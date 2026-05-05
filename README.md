# Dense Pose Lab

Flutter + Python starter implementation for real-time human pose detection with camera input, a WebSocket pose backend, and 2D plus 3D-like pose overlays.

## Architecture

The current implementation uses MediaPipe Pose as the real-time baseline:

1. Flutter opens the device camera with the `camera` plugin.
2. The app periodically captures JPEG frames while the preview stays live.
3. Frames are sent as base64 JSON messages to `ws://<host>:8001/ws/pose`.
4. FastAPI decodes each frame with OpenCV and runs MediaPipe Pose.
5. The backend returns normalized body landmarks: `x`, `y`, `z`, `visibility`, and landmark names.
6. Flutter paints the skeleton over the camera preview and optionally renders a depth-shifted duplicate for a 3D-like visualization.

MediaPipe Pose is the default because it is practical for real-time mobile streaming. DensePose is better for dense body surface UV maps and multi-person body correspondence, but it is heavier and usually belongs in a dedicated GPU Detectron2 service.

## Project Layout

- `lib/main.dart`: Flutter camera UI, WebSocket client, and skeleton renderer.
- `backend/app/main.py`: FastAPI backend with `/health`, `/models`, and `/ws/pose`.
- `backend/requirements.txt`: Python dependencies.
- `android/app/src/main/AndroidManifest.xml`: Camera, internet, and local cleartext development permissions.
- `ios/Runner/Info.plist`: Camera and local network permission descriptions.

## Backend Setup

From the repository root:

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8001
```

Check the backend:

```powershell
curl http://127.0.0.1:8001/health
```

## Flutter Setup

Install Flutter dependencies:

```powershell
flutter pub get
```

Run on an Android emulator:

```powershell
flutter run
```

The app defaults to `ws://10.0.2.2:8001/ws/pose` on Android emulators and `ws://127.0.0.1:8001/ws/pose` elsewhere.

For a physical phone, replace the WebSocket URL in the app with your computer's LAN IP address:

```text
ws://YOUR_COMPUTER_IP:8001/ws/pose
```

Make sure the phone and backend machine are on the same network and your firewall allows port `8001`.

## WebSocket Payloads

Flutter sends:

```json
{
  "type": "frame",
  "image": "<base64-jpeg>",
  "rotation": 90,
  "timestamp": "2026-05-05T12:00:00Z"
}
```

Backend returns:

```json
{
  "type": "pose",
  "model": "mediapipe_pose",
  "fps": 6.2,
  "people": [
    {
      "id": 0,
      "landmarks": [
        {
          "index": 0,
          "name": "nose",
          "x": 0.5,
          "y": 0.2,
          "z": -0.1,
          "visibility": 0.99
        }
      ]
    }
  ]
}
```

## Model Options

MediaPipe Pose:

- Good first choice for real-time webcam/mobile pose.
- Returns 33 landmarks with approximate relative depth.
- Single-person in this starter backend.

DensePose:

- Best when you need dense body surface coordinates, not just joints.
- Use Detectron2 DensePose in a separate GPU-enabled Python service.
- Return either UV maps, body-part masks, or sampled mesh points through the same WebSocket/API contract.

Multi-person:

- Replace the backend estimator with MediaPipe Tasks Pose Landmarker or a detector-first pipeline.
- Keep the frontend unchanged if the backend returns multiple `people` entries.

RF/WiFi sensing:

- Treat it as another backend input stream.
- Fuse RF-derived coarse pose or occupancy with camera landmarks by timestamp before returning the `people` payload.

## Performance Notes

- The starter app sends snapshots at about 6 FPS to stay simple and reliable.
- For higher FPS, replace `takePicture()` with `startImageStream()` and send compressed YUV/RGB frames or run an on-device TFLite model.
- Use a GPU backend for DensePose or high-resolution multi-person workloads.
- Lower camera resolution and send only every Nth frame if latency rises.

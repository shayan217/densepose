# Dense Pose Lab

Dense Pose Lab is a Flutter + Python project for real-time human pose detection. The Flutter app opens the camera, sends frames to a local FastAPI backend over WebSocket, and draws a body/avatar overlay on top of the detected person.

The current backend uses MediaPipe Pose. It returns 33 normalized landmarks for one person, which the Flutter app uses to position the avatar over the camera preview.

## Project Structure

```text
dense_pose/
  lib/main.dart                         Flutter app and camera overlay UI
  backend/app/main.py                   FastAPI pose backend
  backend/requirements.txt              Python backend dependencies
  android/app/src/main/AndroidManifest.xml
  ios/Runner/Info.plist
  pubspec.yaml
```

## What You Need To Install

Install these before running the project:

1. Flutter SDK
   - Download from: https://docs.flutter.dev/get-started/install
   - After installing, make sure `flutter` is available in your terminal.

2. Android Studio
   - Download from: https://developer.android.com/studio
   - Install the Android SDK, Android SDK Platform Tools, and at least one Android emulator.
   - Also install the Flutter and Dart plugins if you plan to use Android Studio.

3. Python
   - Recommended: Python 3.10, 3.11, or 3.12.
   - Download from: https://www.python.org/downloads/
   - On Windows, enable `Add python.exe to PATH` during installation.

4. Git
   - Download from: https://git-scm.com/downloads

5. Optional for iOS/macOS
   - Xcode is required for iPhone simulator or iOS device builds.
   - CocoaPods may be needed for iOS dependencies:

```bash
sudo gem install cocoapods
```

## Check Your Installations

From a terminal, run:

```bash
flutter doctor
python --version
git --version
```

On Windows, if `python` does not work, try:

```powershell
py --version
```

Fix any major `flutter doctor` issues before continuing, especially Android toolchain or device/emulator problems.

## Clone The Project

```bash
git clone <your-repository-url>
cd dense_pose
```

If you received the project as a zip file, extract it and open a terminal inside the extracted `dense_pose` folder.

## Backend Setup

The backend must be running before the Flutter app can detect poses.

### 1. Open The Backend Folder

```bash
cd backend
```

### 2. Create A Python Virtual Environment

Windows PowerShell:

```powershell
python -m venv .venv
```

If your system uses the Python launcher:

```powershell
py -m venv .venv
```

macOS/Linux:

```bash
python3 -m venv .venv
```

### 3. Activate The Virtual Environment

Windows PowerShell:

```powershell
.\.venv\Scripts\Activate.ps1
```

If PowerShell blocks activation scripts, run this once in the same PowerShell window:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\Activate.ps1
```

Windows Command Prompt:

```bat
.venv\Scripts\activate.bat
```

macOS/Linux:

```bash
source .venv/bin/activate
```

After activation, your terminal prompt should show `(.venv)`.

### 4. Install Backend Dependencies

Make sure you are still inside the `backend` folder and the virtual environment is active.

```bash
python -m pip install --upgrade pip
pip install -r requirements.txt
```

This installs FastAPI, Uvicorn, MediaPipe, OpenCV, and NumPy.

### 5. Run The FastAPI Backend

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8001
```

Keep this terminal open. You should see output showing that Uvicorn is running on port `8001`.

### 6. Test The Backend

Open a second terminal and run:

```bash
curl http://127.0.0.1:8001/health
```

Expected response:

```json
{"status":"ok","model":"mediapipe_pose"}
```

You can also open this URL in a browser:

```text
http://127.0.0.1:8001/health
```

## Flutter App Setup

Open a new terminal at the project root, not inside `backend`.

If you are still in the backend folder, run:

```bash
cd ..
```

### 1. Install Flutter Dependencies

```bash
flutter pub get
```

### 2. Start An Emulator Or Connect A Device

List available devices:

```bash
flutter devices
```

Start an Android emulator from Android Studio:

1. Open Android Studio.
2. Go to Device Manager.
3. Start an existing virtual device or create a new one.
4. Run `flutter devices` again and confirm the emulator appears.

For a real Android device:

1. Enable Developer Options.
2. Enable USB Debugging.
3. Connect the device with USB.
4. Accept the debugging prompt on the phone.
5. Run `flutter devices`.

### 3. Run The Flutter App

```bash
flutter run
```

If more than one device is connected, choose one:

```bash
flutter run -d <device-id>
```

Example:

```bash
flutter run -d emulator-5554
```

## WebSocket URL Configuration

The Flutter app connects to the backend using a WebSocket URL shown in the top text field.

The app currently defaults to:

```text
Android emulator: ws://10.0.2.2:8001/ws/pose
Other platforms:  ws://127.0.0.1:8001/ws/pose
```

Use the correct URL for your device:

| Where the Flutter app runs | WebSocket URL |
| --- | --- |
| Android emulator | `ws://10.0.2.2:8001/ws/pose` |
| Windows/macOS/Linux desktop app | `ws://127.0.0.1:8001/ws/pose` |
| iOS simulator | `ws://127.0.0.1:8001/ws/pose` |
| Real Android/iPhone on same Wi-Fi | `ws://YOUR_COMPUTER_IP:8001/ws/pose` |

For a real phone, replace `YOUR_COMPUTER_IP` with your computer's local network IP address.

Find your IP on Windows:

```powershell
ipconfig
```

Look for the `IPv4 Address`, usually something like:

```text
192.168.1.25
```

Then use:

```text
ws://192.168.1.25:8001/ws/pose
```

Find your IP on macOS/Linux:

```bash
ifconfig
```

or:

```bash
ip addr
```

The backend must be started with `--host 0.0.0.0` for real devices to connect from the network.

## Camera And Network Permissions

Android permissions are already declared in:

```text
android/app/src/main/AndroidManifest.xml
```

The app includes:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.INTERNET" />
```

Android also has local cleartext HTTP/WebSocket traffic enabled for development:

```xml
android:usesCleartextTraffic="true"
```

iOS permission text is already declared in:

```text
ios/Runner/Info.plist
```

The app includes camera and local network usage descriptions.

When the app opens for the first time, allow camera access. Without camera permission, the app cannot capture frames for pose detection.

## Normal Development Workflow

Use two terminals.

Terminal 1, backend:

```bash
cd backend
source .venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8001
```

On Windows PowerShell, activation is:

```powershell
cd backend
.\.venv\Scripts\Activate.ps1
uvicorn app.main:app --host 0.0.0.0 --port 8001
```

Terminal 2, Flutter app:

```bash
flutter pub get
flutter run
```

In the app:

1. Confirm the WebSocket URL is correct.
2. Tap `Start`.
3. Point the camera at a person.
4. The app should show the detected person count, backend FPS, and avatar overlay.

## Troubleshooting

### `flutter doctor` shows Android toolchain issues

Open Android Studio and install the missing SDK components. Then run:

```bash
flutter doctor --android-licenses
flutter doctor
```

Accept the licenses when prompted.

### `python` is not recognized

On Windows, try:

```powershell
py --version
py -m venv .venv
```

If that works, use `py` instead of `python` for virtual environment creation.

### PowerShell blocks virtual environment activation

Run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\Activate.ps1
```

This only changes the policy for the current PowerShell process.

### `pip install -r requirements.txt` fails

First upgrade pip:

```bash
python -m pip install --upgrade pip
```

Then retry:

```bash
pip install -r requirements.txt
```

If MediaPipe fails to install, check your Python version. Python 3.10, 3.11, or 3.12 is recommended for this project.

### Backend starts, but the app says connection failed

Check these items:

1. The backend terminal is still running.
2. The backend command used `--host 0.0.0.0 --port 8001`.
3. The WebSocket URL in the app matches your device type.
4. Your firewall allows inbound connections on port `8001`.
5. For a real phone, the phone and computer are on the same Wi-Fi network.

Test the backend from your computer:

```bash
curl http://127.0.0.1:8001/health
```

For a real phone, test from another device on the same network by opening:

```text
http://YOUR_COMPUTER_IP:8001/health
```

### Android emulator cannot connect to `127.0.0.1`

Use this URL for Android emulator:

```text
ws://10.0.2.2:8001/ws/pose
```

`127.0.0.1` inside the emulator means the emulator itself, not your computer.

### Real phone cannot connect to backend

Use your computer's LAN IP:

```text
ws://YOUR_COMPUTER_IP:8001/ws/pose
```

Also check:

1. Phone and computer are on the same network.
2. VPN is disabled if it blocks local networking.
3. Windows Defender Firewall or another firewall allows Python/Uvicorn on port `8001`.
4. The backend was started with `--host 0.0.0.0`.

### Camera preview is black or camera permission was denied

Stop the app and grant camera permission from device settings.

Android:

```text
Settings > Apps > dense_pose > Permissions > Camera > Allow
```

iOS:

```text
Settings > Privacy & Security > Camera > Dense Pose > Allow
```

Then restart the app:

```bash
flutter run
```

### No pose is detected

Try these fixes:

1. Make sure the backend terminal is receiving frames.
2. Improve lighting.
3. Move farther back so the full upper body is visible.
4. Keep only one person clearly in frame, because this starter backend uses single-person MediaPipe Pose.
5. Check that the app status changes from `No pose detected` to `Detected 1 person`.

### Android emulator connects but never detects a person

`ws://10.0.2.2:8001/ws/pose` is the correct backend URL for an Android emulator. If the app connects and the frame count/FPS changes, but the status remains `No pose detected`, the problem is usually the emulator camera input.

Many Android emulators use a virtual scene or an empty camera feed by default. MediaPipe will not detect a person unless the emulator camera is actually showing a person.

Fix it in Android Studio:

1. Open Android Studio.
2. Open Device Manager.
3. Stop the emulator.
4. Click the edit pencil for the virtual device.
5. Open `Show Advanced Settings`.
6. Find the `Camera` section.
7. Set `Front` or `Back` camera to `Webcam0` if you want to use your computer webcam.
8. Save the device.
9. Cold boot the emulator.
10. Run the Flutter app again.

Then point your computer webcam at a person and tap `Start` in the app.

Use the app status strip to identify the failure type:

| Status/result | Meaning |
| --- | --- |
| `Connection failed` | Backend URL, backend process, or firewall problem |
| `Streaming frames` but frame count stays `0` | App connected but is not receiving backend responses |
| Frame count increases, FPS increases, but `No pose detected` | Backend is working, but the camera image does not contain a detectable person |
| `Detected 1 person` | Backend and camera feed are working |

### App is slow or FPS is low

This starter app sends camera snapshots to the backend every few frames. Performance depends on camera resolution, CPU speed, Wi-Fi quality, and backend load.

Try:

1. Close other heavy apps.
2. Use USB or a local emulator instead of Wi-Fi.
3. Run the backend on a faster computer.
4. Lower camera resolution in `lib/main.dart` by changing `ResolutionPreset.medium` to `ResolutionPreset.low`.

## Cleaning Generated Files Before Pushing

Generated folders such as `.dart_tool/`, `build/`, `backend/.venv/`, and `__pycache__/` should not be pushed to GitHub. They are now listed in `.gitignore`.

If any generated files were already tracked before `.gitignore` was fixed, remove them from Git tracking without deleting your local copies:

```bash
git rm -r --cached .dart_tool build backend/.venv backend/app/__pycache__
git rm --cached .flutter-plugins-dependencies
```

Then check:

```bash
git status
```

Commit the cleanup:

```bash
git add .gitignore README.md
git commit -m "Update gitignore and setup documentation"
```

## API Summary

Health check:

```text
GET /health
```

Models:

```text
GET /models
```

Pose WebSocket:

```text
WS /ws/pose
```

Flutter sends base64 JPEG frames. The backend returns pose landmarks like:

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

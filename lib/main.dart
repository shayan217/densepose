import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras;
  try {
    cameras = await availableCameras();
  } catch (_) {
    cameras = <CameraDescription>[];
  }

  runApp(PoseApp(cameras: cameras));
}

class PoseApp extends StatelessWidget {
  const PoseApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dense Pose Lab',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff1f7a7a),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff111416),
        useMaterial3: true,
      ),
      home: PoseHome(cameras: cameras),
    );
  }
}

class PoseHome extends StatefulWidget {
  const PoseHome({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<PoseHome> createState() => _PoseHomeState();
}

class _PoseHomeState extends State<PoseHome> with WidgetsBindingObserver {
  final TextEditingController _serverController = TextEditingController(
    text: 'ws://192.168.10.148:8001/ws/pose',
  );

  CameraController? _cameraController;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _captureTimer;
  List<PosePerson> _people = const [];
  String _status = 'Camera idle';
  bool _isConnecting = false;
  bool _isCapturing = false;
  bool _showDepth = true;
  int _cameraIndex = 0;
  int _framesSent = 0;
  int _framesReceived = 0;
  double _backendFps = 0;

  bool get _isConnected => _channel != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStreaming(updateUi: false);
    _cameraController?.dispose();
    _serverController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      setState(() => _status = 'No camera found on this device');
      return;
    }

    await _cameraController?.dispose();
    final selected = widget.cameras[_cameraIndex % widget.cameras.length];
    _log(
      'Initializing camera index=$_cameraIndex '
      'name=${selected.name} lens=${selected.lensDirection.name} '
      'orientation=${selected.sensorOrientation}',
    );
    final controller = CameraController(
      selected,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    setState(() {
      _cameraController = controller;
      _status = 'Starting camera...';
    });

    try {
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      _log(
        'Camera ready preview=${controller.value.previewSize} '
        'aspect=${controller.value.aspectRatio.toStringAsFixed(3)}',
      );
      if (mounted) {
        setState(() => _status = 'Camera ready');
      }
    } on CameraException catch (error) {
      _log('Camera error: ${error.code} ${error.description}');
      if (mounted) {
        setState(() => _status = 'Camera error: ${error.description}');
      }
    }
  }

  Future<void> _toggleConnection() async {
    if (_isConnected) {
      await _stopStreaming();
      return;
    }

    setState(() {
      _isConnecting = true;
      _status = 'Connecting to backend...';
    });

    try {
      final serverUrl = _serverController.text.trim();
      _log('Connecting WebSocket: $serverUrl');
      if (serverUrl.isEmpty) {
        throw Exception('Server URL خالی ہے۔ براہ کرم URL درج کریں');
      }
      final channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      await channel.ready.timeout(const Duration(seconds: 10));
      _log('WebSocket connected');
      _channel = channel;
      _socketSubscription = channel.stream.listen(
        _handlePoseMessage,
        onError: (Object error) {
          _log('WebSocket error: $error');
          if (mounted) {
            setState(() => _status = 'WebSocket error: $error');
          }
          _stopStreaming();
        },
        onDone: () {
          _log('WebSocket closed by backend/device');
          if (mounted) {
            setState(() => _status = 'Backend disconnected');
          }
          _stopStreaming();
        },
      );
      _startStreaming();
      setState(() => _status = 'Streaming frames');
    } on TimeoutException catch (error) {
      _log('Connection timeout - Backend accessible نہیں ہے: $error');
      setState(
        () => _status = 'Timeout - Backend سے رابطہ نہیں ہوا۔ IP/Port چیک کریں',
      );
    } catch (error) {
      _log('Connection failed: $error');
      setState(() => _status = 'Connection failed: $error');
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  void _startStreaming() {
    _captureTimer?.cancel();
    _log('Starting camera frame streaming');
    _captureTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sendFrame(),
    );
  }

  Future<void> _stopStreaming({bool updateUi = true}) async {
    _log('Stopping stream');
    _captureTimer?.cancel();
    _captureTimer = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _channel?.sink.close();
    _channel = null;

    if (mounted && updateUi) {
      setState(() {
        _people = const [];
        _backendFps = 0;
        _framesSent = 0;
        _status = 'Disconnected';
      });
    }
  }

  Future<void> _sendFrame() async {
    final controller = _cameraController;
    final channel = _channel;
    if (controller == null ||
        channel == null ||
        _isCapturing ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture) {
      return;
    }

    _isCapturing = true;
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _framesSent += 1;
      channel.sink.add(
        jsonEncode({
          'type': 'frame',
          'image': base64Encode(bytes),
          'rotation': _cameraRotationDegrees(controller.description),
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      if (mounted) {
        setState(() {});
      }
      if (_framesSent == 1 || _framesSent % 5 == 0) {
        _log(
          'Sent frame #$_framesSent '
          'bytes=${bytes.length} '
          'rotation=${_cameraRotationDegrees(controller.description)}',
        );
      }
    } catch (error) {
      _log('Frame capture/send failed: $error');
      if (mounted) {
        setState(() => _status = 'Frame capture failed: $error');
      }
    } finally {
      _isCapturing = false;
    }
  }

  int _cameraRotationDegrees(CameraDescription description) {
    return description.sensorOrientation;
  }

  void _handlePoseMessage(dynamic message) {
    if (!mounted) {
      return;
    }

    final decoded = jsonDecode(message as String) as Map<String, dynamic>;
    if (decoded['type'] == 'error') {
      _log("Backend error payload: ${decoded['message']}");
      setState(
        () => _status = decoded['message'] as String? ?? 'Backend error',
      );
      return;
    }

    final peopleJson = (decoded['people'] as List<dynamic>? ?? const []);
    final nextPeople = peopleJson
        .map((person) => PosePerson.fromJson(person as Map<String, dynamic>))
        .toList(growable: false);

    setState(() {
      _people = nextPeople;
      _framesReceived += 1;
      _backendFps = (decoded['fps'] as num?)?.toDouble() ?? _backendFps;
      _status = nextPeople.isEmpty
          ? 'No pose detected'
          : 'Detected ${nextPeople.length} person${nextPeople.length == 1 ? '' : 's'}';
    });
    if (_framesReceived == 1 || _framesReceived % 5 == 0) {
      _log(
        'Received pose #$_framesReceived '
        'people=${nextPeople.length} '
        'backendFps=${_backendFps.toStringAsFixed(1)}',
      );
    }
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2) {
      return;
    }
    final wasConnected = _isConnected;
    if (wasConnected) {
      await _stopStreaming();
    }
    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    _log('Switching camera to index=$_cameraIndex');
    await _initializeCamera();
    if (wasConnected) {
      await _toggleConnection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              serverController: _serverController,
              connected: _isConnected,
              connecting: _isConnecting,
              showDepth: _showDepth,
              onConnect: _toggleConnection,
              onSwitchCamera: _switchCamera,
              onToggleDepth: () => setState(() => _showDepth = !_showDepth),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ColoredBox(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (controller != null &&
                            controller.value.isInitialized)
                          Center(child: CameraPreview(controller))
                        else
                          const Center(child: CircularProgressIndicator()),
                        CustomPaint(
                          painter: PosePainter(
                            people: _people,
                            showDepth: _showDepth,
                          ),
                        ),
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 12,
                          child: _StatusStrip(
                            status: _status,
                            sent: _framesSent,
                            frames: _framesReceived,
                            fps: _backendFps,
                            people: _people.length,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _log(String message) {
    debugPrint('[DensePose] $message');
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.serverController,
    required this.connected,
    required this.connecting,
    required this.showDepth,
    required this.onConnect,
    required this.onSwitchCamera,
    required this.onToggleDepth,
  });

  final TextEditingController serverController;
  final bool connected;
  final bool connecting;
  final bool showDepth;
  final VoidCallback onConnect;
  final VoidCallback onSwitchCamera;
  final VoidCallback onToggleDepth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          const Icon(Icons.accessibility_new, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: serverController,
              enabled: !connected,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Pose backend WebSocket',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Switch camera',
            child: IconButton.filledTonal(
              onPressed: onSwitchCamera,
              icon: const Icon(Icons.cameraswitch),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: showDepth ? 'Hide avatar shadow' : 'Show avatar shadow',
            child: IconButton.filledTonal(
              onPressed: onToggleDepth,
              icon: Icon(showDepth ? Icons.layers : Icons.layers_outlined),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: connecting ? null : onConnect,
            icon: Icon(connected ? Icons.stop : Icons.play_arrow),
            label: Text(connected ? 'Stop' : 'Start'),
          ),
        ],
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.status,
    required this.sent,
    required this.frames,
    required this.fps,
    required this.people,
  });

  final String status;
  final int sent;
  final int frames;
  final double fps;
  final int people;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(173),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                status,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text('people $people'),
            const SizedBox(width: 10),
            Text('sent $sent'),
            const SizedBox(width: 10),
            Text('fps ${fps.toStringAsFixed(1)}'),
            const SizedBox(width: 10),
            Text('recv $frames'),
          ],
        ),
      ),
    );
  }
}

class PosePerson {
  const PosePerson({required this.id, required this.landmarks});

  factory PosePerson.fromJson(Map<String, dynamic> json) {
    return PosePerson(
      id: json['id'] as int? ?? 0,
      landmarks: (json['landmarks'] as List<dynamic>? ?? const [])
          .map(
            (landmark) =>
                PoseLandmark.fromJson(landmark as Map<String, dynamic>),
          )
          .toList(growable: false),
    );
  }

  final int id;
  final List<PoseLandmark> landmarks;
}

class PoseLandmark {
  const PoseLandmark({
    required this.name,
    required this.x,
    required this.y,
    required this.z,
    required this.visibility,
  });

  factory PoseLandmark.fromJson(Map<String, dynamic> json) {
    return PoseLandmark(
      name: json['name'] as String? ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
      z: (json['z'] as num?)?.toDouble() ?? 0,
      visibility: (json['visibility'] as num?)?.toDouble() ?? 0,
    );
  }

  final String name;
  final double x;
  final double y;
  final double z;
  final double visibility;
}

class PosePainter extends CustomPainter {
  PosePainter({required this.people, required this.showDepth});

  final List<PosePerson> people;
  final bool showDepth;

  @override
  void paint(Canvas canvas, Size size) {
    for (final person in people) {
      final points = person.landmarks
          .map((landmark) => _project(landmark, size, depth: false))
          .toList(growable: false);
      _drawAvatar(canvas, person, points, size);
    }
  }

  void _drawAvatar(
    Canvas canvas,
    PosePerson person,
    List<Offset> points,
    Size size,
  ) {
    final leftShoulder = _point(person, points, 11);
    final rightShoulder = _point(person, points, 12);
    final leftHip = _point(person, points, 23);
    final rightHip = _point(person, points, 24);

    if (leftShoulder == null ||
        rightShoulder == null ||
        leftHip == null ||
        rightHip == null) {
      return;
    }

    final shoulderWidth = (leftShoulder - rightShoulder).distance;
    final hipWidth = (leftHip - rightHip).distance;
    final bodyScale = (shoulderWidth + hipWidth)
        .clamp(24.0, size.width * 0.5)
        .toDouble();
    final limbWidth = (bodyScale * 0.18).clamp(10.0, 34.0).toDouble();
    final armWidth = (bodyScale * 0.14).clamp(8.0, 28.0).toDouble();
    final handRadius = (bodyScale * 0.13).clamp(6.0, 22.0).toDouble();
    final footRadius = (bodyScale * 0.16).clamp(8.0, 26.0).toDouble();

    final skinPaint = Paint()
      ..color = const Color(0xffe4ae82).withAlpha(232)
      ..style = PaintingStyle.fill;
    final skinShadePaint = Paint()
      ..color = const Color(0xffb86f4a).withAlpha(118)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final shirtPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0xff0f8f8d).withAlpha(236),
          const Color(0xff0a4f69).withAlpha(236),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromPoints(leftShoulder, rightHip))
      ..style = PaintingStyle.fill;
    final shortsPaint = Paint()
      ..color = const Color(0xff242936).withAlpha(236)
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = Colors.black.withAlpha(70)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (bodyScale * 0.035).clamp(2.0, 6.0).toDouble()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final shadowPaint = Paint()
      ..color = Colors.black.withAlpha(showDepth ? 78 : 44)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

    if (showDepth) {
      final bounds = _personBounds(person, points);
      if (bounds != null) {
        canvas.drawOval(
          Rect.fromCenter(
            center: bounds.center.translate(0, bounds.height * 0.08),
            width: bounds.width * 1.05,
            height: bounds.height * 0.88,
          ),
          shadowPaint,
        );
      }
    }

    final leftElbow = _point(person, points, 13);
    final rightElbow = _point(person, points, 14);
    final leftWrist = _point(person, points, 15);
    final rightWrist = _point(person, points, 16);
    final leftKnee = _point(person, points, 25);
    final rightKnee = _point(person, points, 26);
    final leftAnkle = _point(person, points, 27);
    final rightAnkle = _point(person, points, 28);
    final leftFoot = _point(person, points, 31) ?? _point(person, points, 29);
    final rightFoot = _point(person, points, 32) ?? _point(person, points, 30);

    _drawLimb(
      canvas,
      [
        leftShoulder,
        if (leftElbow != null) leftElbow,
        if (leftWrist != null) leftWrist,
      ],
      armWidth,
      skinPaint,
      outlinePaint,
    );
    _drawLimb(
      canvas,
      [
        rightShoulder,
        if (rightElbow != null) rightElbow,
        if (rightWrist != null) rightWrist,
      ],
      armWidth,
      skinPaint,
      outlinePaint,
    );

    final leftLegStart = Offset.lerp(leftHip, rightHip, 0.12)!;
    final rightLegStart = Offset.lerp(rightHip, leftHip, 0.12)!;
    _drawLimb(
      canvas,
      [
        leftLegStart,
        if (leftKnee != null) leftKnee,
        if (leftAnkle != null) leftAnkle,
      ],
      limbWidth,
      skinPaint,
      outlinePaint,
    );
    _drawLimb(
      canvas,
      [
        rightLegStart,
        if (rightKnee != null) rightKnee,
        if (rightAnkle != null) rightAnkle,
      ],
      limbWidth,
      skinPaint,
      outlinePaint,
    );

    final waistLeft = Offset.lerp(leftHip, leftShoulder, 0.08)!;
    final waistRight = Offset.lerp(rightHip, rightShoulder, 0.08)!;
    final torsoPath = Path()
      ..moveTo(leftShoulder.dx, leftShoulder.dy)
      ..quadraticBezierTo(
        (leftShoulder.dx + rightShoulder.dx) / 2,
        (leftShoulder.dy + rightShoulder.dy) / 2 - bodyScale * 0.08,
        rightShoulder.dx,
        rightShoulder.dy,
      )
      ..lineTo(waistRight.dx, waistRight.dy)
      ..quadraticBezierTo(
        (leftHip.dx + rightHip.dx) / 2,
        (leftHip.dy + rightHip.dy) / 2 + bodyScale * 0.08,
        waistLeft.dx,
        waistLeft.dy,
      )
      ..close();
    canvas.drawPath(torsoPath, shirtPaint);
    canvas.drawPath(torsoPath, outlinePaint);

    final shortsPath = Path()
      ..moveTo(waistLeft.dx, waistLeft.dy)
      ..lineTo(waistRight.dx, waistRight.dy)
      ..lineTo(
        rightLegStart.dx + limbWidth * 0.45,
        rightLegStart.dy + limbWidth,
      )
      ..lineTo((leftHip.dx + rightHip.dx) / 2, (leftHip.dy + rightHip.dy) / 2)
      ..lineTo(leftLegStart.dx - limbWidth * 0.45, leftLegStart.dy + limbWidth)
      ..close();
    canvas.drawPath(shortsPath, shortsPaint);
    canvas.drawPath(shortsPath, outlinePaint);

    if (leftWrist != null) {
      canvas.drawCircle(leftWrist, handRadius, skinPaint);
      canvas.drawCircle(leftWrist, handRadius, outlinePaint);
    }
    if (rightWrist != null) {
      canvas.drawCircle(rightWrist, handRadius, skinPaint);
      canvas.drawCircle(rightWrist, handRadius, outlinePaint);
    }
    if (leftAnkle != null) {
      _drawFoot(
        canvas,
        leftAnkle,
        leftFoot,
        footRadius,
        shortsPaint,
        outlinePaint,
      );
    }
    if (rightAnkle != null) {
      _drawFoot(
        canvas,
        rightAnkle,
        rightFoot,
        footRadius,
        shortsPaint,
        outlinePaint,
      );
    }

    final neckTop = _headAnchor(person, points, leftShoulder, rightShoulder);
    final neckBase = Offset.lerp(leftShoulder, rightShoulder, 0.5)!;
    _drawLimb(
      canvas,
      [neckBase, neckTop],
      (bodyScale * 0.16).clamp(8.0, 24.0).toDouble(),
      skinPaint,
      outlinePaint,
    );
    _drawHead(
      canvas,
      person,
      points,
      neckTop,
      bodyScale,
      skinPaint,
      outlinePaint,
    );

    skinShadePaint.strokeWidth = (bodyScale * 0.025).clamp(1.5, 4.0).toDouble();
    _drawSubtleContour(canvas, leftShoulder, leftHip, skinShadePaint);
    _drawSubtleContour(canvas, rightShoulder, rightHip, skinShadePaint);
  }

  void _drawLimb(
    Canvas canvas,
    List<Offset> anchors,
    double width,
    Paint fillPaint,
    Paint outlinePaint,
  ) {
    if (anchors.length < 2) {
      return;
    }

    final outline = Paint()
      ..color = outlinePaint.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width + outlinePaint.strokeWidth * 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = fillPaint.color
      ..shader = fillPaint.shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()..moveTo(anchors.first.dx, anchors.first.dy);
    if (anchors.length == 2) {
      path.lineTo(anchors.last.dx, anchors.last.dy);
    } else {
      path.quadraticBezierTo(
        anchors[1].dx,
        anchors[1].dy,
        anchors.last.dx,
        anchors.last.dy,
      );
    }

    canvas.drawPath(path, outline);
    canvas.drawPath(path, fill);
  }

  void _drawFoot(
    Canvas canvas,
    Offset ankle,
    Offset? toe,
    double radius,
    Paint fillPaint,
    Paint outlinePaint,
  ) {
    final target = toe ?? ankle.translate(0, radius * 0.65);
    final center = Offset.lerp(ankle, target, 0.6)!;
    final angle = (target - ankle).direction;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: radius * 2.25,
      height: radius * 1.05,
    );
    canvas.drawOval(rect, fillPaint);
    canvas.drawOval(rect, outlinePaint);
    canvas.restore();
  }

  void _drawHead(
    Canvas canvas,
    PosePerson person,
    List<Offset> points,
    Offset neckTop,
    double bodyScale,
    Paint skinPaint,
    Paint outlinePaint,
  ) {
    final nose = _point(person, points, 0);
    final leftEar = _point(person, points, 7);
    final rightEar = _point(person, points, 8);
    final headCenter = nose == null
        ? neckTop.translate(0, -bodyScale * 0.35)
        : nose;
    final headWidth = leftEar != null && rightEar != null
        ? (leftEar - rightEar).distance
              .clamp(bodyScale * 0.28, bodyScale * 0.62)
              .toDouble()
        : bodyScale * 0.42;
    final headHeight = headWidth * 1.28;
    final headRect = Rect.fromCenter(
      center: Offset(headCenter.dx, headCenter.dy - headHeight * 0.06),
      width: headWidth,
      height: headHeight,
    );
    final hairRect = Rect.fromLTWH(
      headRect.left,
      headRect.top - headHeight * 0.03,
      headRect.width,
      headRect.height * 0.48,
    );
    final hairPaint = Paint()
      ..color = const Color(0xff2c1c16).withAlpha(224)
      ..style = PaintingStyle.stroke
      ..strokeWidth = headHeight * 0.18
      ..strokeCap = StrokeCap.round;
    final faceDetailPaint = Paint()
      ..color = Colors.black.withAlpha(95)
      ..strokeWidth = (bodyScale * 0.018).clamp(1.0, 3.0).toDouble()
      ..strokeCap = StrokeCap.round;

    canvas.drawOval(headRect, skinPaint);
    canvas.drawOval(headRect, outlinePaint);
    canvas.drawArc(hairRect, 3.14, 3.14, false, hairPaint);

    final leftEye = _point(person, points, 2);
    final rightEye = _point(person, points, 5);
    if (leftEye != null && rightEye != null) {
      final eyeRadius = (bodyScale * 0.022).clamp(1.5, 4.0).toDouble();
      canvas.drawCircle(leftEye, eyeRadius, faceDetailPaint);
      canvas.drawCircle(rightEye, eyeRadius, faceDetailPaint);
    }
    canvas.drawLine(
      headRect.center.translate(-headWidth * 0.16, headHeight * 0.18),
      headRect.center.translate(headWidth * 0.16, headHeight * 0.18),
      faceDetailPaint,
    );
  }

  void _drawSubtleContour(Canvas canvas, Offset from, Offset to, Paint paint) {
    canvas.drawLine(
      Offset.lerp(from, to, 0.22)!,
      Offset.lerp(from, to, 0.78)!,
      paint,
    );
  }

  Offset _headAnchor(
    PosePerson person,
    List<Offset> points,
    Offset leftShoulder,
    Offset rightShoulder,
  ) {
    final nose = _point(person, points, 0);
    final shoulderCenter = Offset.lerp(leftShoulder, rightShoulder, 0.5)!;
    if (nose == null) {
      return shoulderCenter.translate(
        0,
        -(leftShoulder - rightShoulder).distance * 0.35,
      );
    }
    return Offset.lerp(shoulderCenter, nose, 0.42)!;
  }

  Offset _project(PoseLandmark landmark, Size size, {required bool depth}) {
    final x = landmark.x * size.width;
    final y = landmark.y * size.height;
    if (!depth) {
      return Offset(x, y);
    }

    final depthOffset =
        landmark.z.clamp(-0.5, 0.5).toDouble() * size.shortestSide * 0.18;
    return Offset(x - depthOffset, y + depthOffset);
  }

  Offset? _point(PosePerson person, List<Offset> points, int index) {
    if (person.landmarks.length <= index ||
        points.length <= index ||
        person.landmarks[index].visibility <= 0.35) {
      return null;
    }
    return points[index];
  }

  Rect? _personBounds(PosePerson person, List<Offset> points) {
    final visiblePoints = <Offset>[
      for (
        var index = 0;
        index < person.landmarks.length && index < points.length;
        index += 1
      )
        if (person.landmarks[index].visibility > 0.35) points[index],
    ];
    if (visiblePoints.isEmpty) {
      return null;
    }

    var left = visiblePoints.first.dx;
    var top = visiblePoints.first.dy;
    var right = visiblePoints.first.dx;
    var bottom = visiblePoints.first.dy;
    for (final point in visiblePoints.skip(1)) {
      left = point.dx < left ? point.dx : left;
      top = point.dy < top ? point.dy : top;
      right = point.dx > right ? point.dx : right;
      bottom = point.dy > bottom ? point.dy : bottom;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.people != people || oldDelegate.showDepth != showDepth;
  }
}

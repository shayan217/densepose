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
    text: defaultTargetPlatform == TargetPlatform.android
        ? 'ws://192.168.10.237:8001/ws/pose'
        : 'ws://192.168.10.237:8001/ws/pose',
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
    final controller = CameraController(
      selected,
      ResolutionPreset.medium,
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
      if (mounted) {
        setState(() => _status = 'Camera ready');
      }
    } on CameraException catch (error) {
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
      final channel = WebSocketChannel.connect(
        Uri.parse(_serverController.text.trim()),
      );
      await channel.ready.timeout(const Duration(seconds: 4));
      _channel = channel;
      _socketSubscription = channel.stream.listen(
        _handlePoseMessage,
        onError: (Object error) {
          if (mounted) {
            setState(() => _status = 'WebSocket error: $error');
          }
          _stopStreaming();
        },
        onDone: () {
          if (mounted) {
            setState(() => _status = 'Backend disconnected');
          }
          _stopStreaming();
        },
      );
      _startStreaming();
      setState(() => _status = 'Streaming frames');
    } catch (error) {
      setState(() => _status = 'Connection failed: $error');
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  void _startStreaming() {
    _captureTimer?.cancel();
    _captureTimer = Timer.periodic(
      const Duration(milliseconds: 160),
      (_) => _sendFrame(),
    );
  }

  Future<void> _stopStreaming({bool updateUi = true}) async {
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
      channel.sink.add(
        jsonEncode({
          'type': 'frame',
          'image': base64Encode(bytes),
          'rotation': _cameraRotationDegrees(controller.description),
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (error) {
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
            message: showDepth
                ? 'Hide depth projection'
                : 'Show depth projection',
            child: IconButton.filledTonal(
              onPressed: onToggleDepth,
              icon: Icon(showDepth ? Icons.view_in_ar : Icons.polyline),
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
    required this.frames,
    required this.fps,
    required this.people,
  });

  final String status;
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
            const SizedBox(width: 16),
            Text('fps ${fps.toStringAsFixed(1)}'),
            const SizedBox(width: 16),
            Text('frames $frames'),
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

  static const connections = <(int, int)>[
    (11, 12),
    (11, 13),
    (13, 15),
    (12, 14),
    (14, 16),
    (11, 23),
    (12, 24),
    (23, 24),
    (23, 25),
    (25, 27),
    (24, 26),
    (26, 28),
    (27, 31),
    (28, 32),
    (0, 11),
    (0, 12),
  ];

  final List<PosePerson> people;
  final bool showDepth;

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = const Color(0xff43d9ad)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final depthPaint = Paint()
      ..color = const Color(0xffffcf5a).withAlpha(107)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final jointPaint = Paint()..color = const Color(0xffffffff);

    for (final person in people) {
      final points = person.landmarks
          .map((landmark) => _project(landmark, size, depth: false))
          .toList(growable: false);
      final depthPoints = person.landmarks
          .map((landmark) => _project(landmark, size, depth: true))
          .toList(growable: false);

      if (showDepth) {
        for (final (a, b) in connections) {
          if (_isVisible(person, a) && _isVisible(person, b)) {
            canvas.drawLine(depthPoints[a], depthPoints[b], depthPaint);
          }
        }
      }

      for (final (a, b) in connections) {
        if (_isVisible(person, a) && _isVisible(person, b)) {
          canvas.drawLine(points[a], points[b], linePaint);
        }
      }

      for (var index = 0; index < person.landmarks.length; index += 1) {
        if (_isVisible(person, index)) {
          final radius = (6 - person.landmarks[index].z * 2).clamp(3, 7);
          canvas.drawCircle(points[index], radius.toDouble(), jointPaint);
        }
      }
    }
  }

  Offset _project(PoseLandmark landmark, Size size, {required bool depth}) {
    final x = landmark.x * size.width;
    final y = landmark.y * size.height;
    if (!depth) {
      return Offset(x, y);
    }

    final depthOffset = landmark.z.clamp(-0.5, 0.5) * size.shortestSide * 0.18;
    return Offset(x - depthOffset, y + depthOffset);
  }

  bool _isVisible(PosePerson person, int index) {
    return person.landmarks.length > index &&
        person.landmarks[index].visibility > 0.45;
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.people != people || oldDelegate.showDepth != showDepth;
  }
}

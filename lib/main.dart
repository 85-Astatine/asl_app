import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';



void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Dashboard',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // --- Model state ---
  Interpreter? _interpreter;
  bool _modelLoaded = false;
  String _prediction = '--';

  //// speack to text
  late stt.SpeechToText _speech;
  bool _speechEnabled = false;
  String _sst_text = '';

  ////// text to speach
  late FlutterTts _flutterTts;
  String _tts_text = '';
  bool _autoSpeak = false;
  String _lastSpoken = '';



  // --- BLE parameters ---
  final _deviceId    = 'EC:70:C8:52:75:F0';
  final _serviceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  final _txCharUuid  = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
  late BluetoothDevice _device;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // --- Parsed sensor values ---
  String _uptime       = '--:--:--';
  double _accX = 0, _accY = 0, _accZ = 0;
  List<int> _flex = [0, 0, 0, 0, 0];
  double _vbat = 0;
  String _chg   = 'idle';

  @override
  void initState() {
    super.initState();
    _initialize();  // load model → then BLE
    _initSpeech();
    _flutterTts = FlutterTts();

  }

  void _initSpeech() async {
    _speech = stt.SpeechToText();
    _speechEnabled = await _speech.initialize(
      onStatus: (_) => setState((){}),
      onError: (_)  => setState((){}),
    );
    setState((){});
  }
  void _listen() async {
    if (!_speechEnabled) return;
    if (_speech.isListening) {
      await _speech.stop();
    } else {
      _sst_text = '';
      await _speech.listen(
        onResult: (result) {
          setState(() {
            _sst_text = result.recognizedWords;
            _tts_text = _sst_text; /////should be changed later
            // after updating _sst_text and _tts_text speak teh
            if (_autoSpeak && _tts_text.isNotEmpty && _tts_text != _lastSpoken) {
              _speak();
              _lastSpoken = _tts_text;
            }

          });

        },
      );
    }
    setState((){});
  }

  Future<void> _speak() async {
    if (_tts_text.isNotEmpty) {
      await _flutterTts.speak(_tts_text);
    }
  }


  Future<void> _initialize() async {
    // 1) Load & allocate TFLite model
    try {
      _interpreter = await Interpreter.fromAsset('model/sensor_model.tflite');
      _interpreter!.allocateTensors();
      print('✅ TFLite model loaded and tensors allocated');
      setState(() => _modelLoaded = true);
    } catch (e) {
      print('❌ Failed to load model: $e');
      return; // skip BLE if model load fails
    }

    // 2) Start BLE only after model is ready
    _device = BluetoothDevice.fromId(_deviceId);
    _listenConnection();
    await _connectAndListen();
  }

  void _listenConnection() {
    _connSub = _device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        print('BLE disconnected — reconnecting');
        _connectAndListen();
      }
    });
  }

  Future<void> _connectAndListen() async {
    // wait for Bluetooth to be on
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first;

    print('🔗 Connecting to BLE device...');
    await _device.connect(autoConnect: false);

    print('🔍 Discovering services...');
    final svcs = await _device.discoverServices();
    final nus = svcs.firstWhere((s) => s.serviceUuid == _serviceUuid);
    final tx  = nus.characteristics.firstWhere((c) => c.characteristicUuid == _txCharUuid);
    await tx.setNotifyValue(true);

    _dataSub?.cancel();
    _dataSub = tx.onValueReceived.listen((bytes) {
      final line = utf8.decode(bytes).trim();
      _parseLine(line);
    });
  }

  void _parseLine(String line) {
    print('RAW LINE ▶ $line');

    // parse uptime
    final t = RegExp(r"\[(\d{2}:\d{2}:\d{2}:\d{3})\]").firstMatch(line);
    if (t != null) _uptime = t.group(1)!;

    // parse accelerometer
    final a = RegExp(r"X:(-?\d+\.\d+)\s+Y:(-?\d+\.\d+)\s+Z:(-?\d+\.\d+)")
        .firstMatch(line);
    if (a != null) {
      _accX = double.parse(a.group(1)!);
      _accY = double.parse(a.group(2)!);
      _accZ = double.parse(a.group(3)!);
    }

    // parse flex sensors
    final f = RegExp(r"F0:(\d+)\s+F1:(\d+)\s+F2:(\d+)\s+F3:(\d+)\s+F4:(\d+)")
        .firstMatch(line);
    if (f != null) {
      _flex = List.generate(5, (i) => int.parse(f.group(i+1)!));
    }

    // parse battery
    final v = RegExp(r"VBAT:(\d+\.\d+)V").firstMatch(line);
    if (v != null) _vbat = double.parse(v.group(1)!);

    // parse charge status
    final c = RegExp(r"CHG:(\w+)").firstMatch(line);
    if (c != null) _chg = c.group(1)!;

    // run inference if model is loaded
    if (_modelLoaded) {
      try {
        _runInference();
      } catch (e) {
        print('⚠️ Inference error: $e');
      }
    }

    // update UI
    setState(() {});
  }

  void _runInference() {
    final interp = _interpreter!;
    // build input [F0…F4, X, Y, Z]
    final input = Float32List(8);
    for (var i = 0; i < 5; i++) input[i] = _flex[i].toDouble();
    input[5] = _accX;
    input[6] = _accY;
    input[7] = _accZ;

    // prepare output (3 classes)
    final output = Float32List(3);
    interp.run(input.buffer, output.buffer);
    print('OUTPUT RAW ▶ ${output.toList()}');

    // pick the max index
    var maxI = 0;
    for (var i = 1; i < output.length; i++) {
      if (output[i] > output[maxI]) maxI = i;
    }

    const labels = ['A', 'B', 'C'];
    _prediction = labels[maxI];
  }

@override
  void dispose() {
    _dataSub?.cancel();
    _connSub?.cancel();
    _device.disconnect();
    super.dispose();
  }

  Widget _buildAccelTile(String axis, double val, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(axis, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          Text(val.toStringAsFixed(2), style: TextStyle(fontSize: 18)),
        ],
      ),
    );
  }

  Widget _buildFlexTile(int i, int v, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text('F$i', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          Text('$v'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Dashboard')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Battery on top
            Card(
              elevation: 4,
              color: Colors.green.shade50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: Icon(
                  _chg == 'charging' ? Icons.battery_charging_full : Icons.battery_std,
                  color: Colors.green,
                ),
                title: const Text('Battery'),
                subtitle: Text('${(_vbat * 20).toInt()}%'),
                trailing: Text('${_vbat.toStringAsFixed(2)} V'),
              ),
            ),

            const SizedBox(height: 12),

            // Uptime next
            Card(
              elevation: 3,
              color: Colors.blue.shade50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: const Icon(Icons.timer, color: Colors.blue),
                title: const Text('Uptime'),
                trailing: Text(_uptime, style: const TextStyle(fontSize: 16)),
              ),
            ),

            const SizedBox(height: 12),

            // Accelerometer
            Card(
              elevation: 3,
              color: Colors.orange.shade50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    _buildAccelTile('X', _accX, Colors.red),
                    _buildAccelTile('Y', _accY, Colors.green),
                    _buildAccelTile('Z', _accZ, Colors.blue),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Flex sensors
            Card(
              elevation: 3,
              color: Colors.purple.shade50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: List.generate(
                    5,
                        (i) => _buildFlexTile(
                      i,
                      _flex[i],
                      Colors.purple[(i + 2) * 100]!,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),
            Card(
              elevation: 3,
              color: Colors.grey.shade50,           // neutral background
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(Icons.analytics, color: Colors.grey),
                title: const Text('Prediction'),
                trailing: Text(
                  _prediction,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ),



            const SizedBox(height: 12),
            // 1) TTS card with auto‑play toggle
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [



                    // <-- MANUAL PLAY BUTTON
                    IconButton(
                      icon: const Icon(Icons.play_arrow, color: Colors.blue),
                      onPressed: _speak,
                    ),

                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _tts_text.isEmpty ? 'Nothing to speak' : _tts_text,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // <-- AUTO‑PLAY TOGGLE
                    Switch(
                      value: _autoSpeak,
                      onChanged: (v) => setState(() {
                        _autoSpeak = v;
                        // reset last spoken so it will play fresh next time
                        _lastSpoken = '';
                      }),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 48), //extraspace

            const SizedBox(height: 12),
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _speech.isListening ? Icons.mic : Icons.mic_none,
                        color: _speech.isListening ? Colors.red : Colors.grey,
                      ),
                      onPressed: _listen,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _sst_text.isEmpty
                            ? 'Tap mic and speak...'
                            : _sst_text,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),


          ],
        ),
      ),
    );
  }
}

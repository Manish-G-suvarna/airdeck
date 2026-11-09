import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

// ------------------------------------------------------------------ protocol
const int tcpPort = 47800;
const int discoveryPort = 47801;
const int sampleRate = 16000;

const int tAuth = 1, tMove = 2, tButton = 3, tClick = 4, tScroll = 5;
const int tText = 6, tKey = 7, tAudio = 8, tTalkStart = 9, tTalkEnd = 10;
const int tPing = 12;
const int rAuthOk = 0x81, rAuthFail = 0x82, rAudio = 0x88;
const int rTalkStart = 0x89, rTalkEnd = 0x8A;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const AirDeckApp());
}

// ------------------------------------------------------- background service
// A foreground service keeps the app process (and its socket to the PC)
// alive while AirDeck is in the background or the screen is off.
@pragma('vm:entry-point')
void bgServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_BgHandler());
}

class _BgHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'disconnect') FlutterForegroundTask.sendDataToMain('disconnect');
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

class BgService {
  static bool _inited = false;
  static void Function()? onDisconnectPressed;

  static void _onData(Object data) {
    if (data == 'disconnect') onDisconnectPressed?.call();
  }

  static Future<void> start(String host) async {
    try {
      if (!_inited) {
        _inited = true;
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'airdeck_connection',
            channelName: 'AirDeck connection',
            channelDescription: 'Shown while AirDeck is connected to your PC',
            onlyAlertOnce: true,
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
          ),
          iosNotificationOptions: const IOSNotificationOptions(),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.nothing(),
            autoRunOnBoot: false,
            allowWakeLock: true,
            allowWifiLock: true,
          ),
        );
        FlutterForegroundTask.addTaskDataCallback(_onData);
      }
      if (await FlutterForegroundTask.checkNotificationPermission() !=
          NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      const buttons = [NotificationButton(id: 'disconnect', text: 'Disconnect')];
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'AirDeck connected',
          notificationText: 'Controlling $host · tap to open',
          notificationButtons: buttons,
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 4780,
          serviceTypes: [ForegroundServiceTypes.dataSync],
          notificationTitle: 'AirDeck connected',
          notificationText: 'Controlling $host · tap to open',
          notificationButtons: buttons,
          callback: bgServiceCallback,
        );
      }
    } catch (_) {
      // the app still works in the foreground without the service
    }
  }

  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}

class AirDeckApp extends StatelessWidget {
  const AirDeckApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF5B8CFF), brightness: Brightness.dark);
    return MaterialApp(
      title: 'AirDeck',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: const ConnectScreen(),
    );
  }
}

// ---------------------------------------------------------------- connection
class PcFound {
  final String ip;
  final String host;
  PcFound(this.ip, this.host);
}

class Connection {
  final Socket _sock;
  String host;
  final String address;
  final _buf = BytesBuilder(copy: false);
  Timer? _ping;
  void Function() onClosed = () {};
  void Function(bool talking) onPcTalk = (_) {};
  bool _closed = false;
  bool _pcmReady = false;
  Completer<String>? _auth;

  Connection._(this._sock, this.host) : address = host;

  /// Connects and authenticates. Throws a readable message on failure.
  static Future<Connection> open(String ip, String pin,
      {required void Function() onClosed,
      required void Function(bool) onPcTalk}) async {
    final sock = await Socket.connect(ip, tcpPort,
        timeout: const Duration(seconds: 4));
    sock.setOption(SocketOption.tcpNoDelay, true);
    final conn = Connection._(sock, ip)
      ..onClosed = onClosed
      ..onPcTalk = onPcTalk
      .._auth = Completer<String>();
    sock.listen(conn._feed, onError: (e) {
      conn._failAuth('Connection failed: $e');
      conn._handleClose();
    }, onDone: () {
      conn._failAuth('PC closed the connection');
      conn._handleClose();
    });
    sock.add(_frame(tAuth,
        utf8.encode(jsonEncode({'pin': pin.trim(), 'name': 'AirDeck phone'}))));
    try {
      conn.host = await conn._auth!.future.timeout(const Duration(seconds: 5));
    } catch (e) {
      conn._closed = true;
      sock.destroy();
      throw e is TimeoutException ? 'PC did not answer' : e;
    }
    conn._ping =
        Timer.periodic(const Duration(seconds: 5), (_) => conn.send(tPing));
    return conn;
  }

  void _failAuth(String msg) {
    final a = _auth;
    if (a != null && !a.isCompleted) a.completeError(msg);
  }

  static Uint8List _frame(int type, List<int> payload) {
    final out = Uint8List(5 + payload.length);
    out[0] = type;
    ByteData.sublistView(out, 1, 5).setUint32(0, payload.length);
    out.setRange(5, out.length, payload);
    return out;
  }

  void send(int type, [List<int> payload = const []]) {
    if (_closed) return;
    try {
      _sock.add(_frame(type, payload));
    } catch (_) {
      _handleClose();
    }
  }

  void _feed(List<int> data) {
    if (data.isEmpty) return;
    _buf.add(data);
    var b = _buf.toBytes();
    var off = 0;
    while (b.length - off >= 5) {
      final type = b[off];
      final len = ByteData.sublistView(b, off + 1, off + 5).getUint32(0);
      if (b.length - off < 5 + len) break;
      _onFrame(type, Uint8List.sublistView(b, off + 5, off + 5 + len));
      off += 5 + len;
    }
    _buf.clear();
    if (off < b.length) _buf.add(b.sublist(off));
  }

  Future<void> _onFrame(int type, Uint8List p) async {
    final a = _auth;
    if (a != null && !a.isCompleted) {
      if (type == rAuthOk) {
        String h = host;
        try {
          h = jsonDecode(utf8.decode(p))['host'] ?? h;
        } catch (_) {}
        a.complete(h);
      } else {
        a.completeError('Wrong connection code');
      }
      return;
    }
    if (type == rTalkStart) {
      if (!_pcmReady) {
        await FlutterPcmSound.setLogLevel(LogLevel.none);
        await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
        FlutterPcmSound.setFeedCallback((_) {});
        _pcmReady = true;
      }
      onPcTalk(true);
    } else if (type == rAudio && _pcmReady) {
      final copy = Uint8List.fromList(p);
      await FlutterPcmSound.feed(
          PcmArrayInt16(bytes: copy.buffer.asByteData()));
    } else if (type == rTalkEnd) {
      onPcTalk(false);
    }
  }

  void _handleClose() {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    onClosed();
  }

  void close() {
    _closed = true;
    _ping?.cancel();
    _sock.destroy();
  }

  // ----- convenience senders
  static Uint8List _i16pair(int a, int b) {
    final d = ByteData(4)
      ..setInt16(0, a.clamp(-32768, 32767))
      ..setInt16(2, b.clamp(-32768, 32767));
    return d.buffer.asUint8List();
  }

  void move(int dx, int dy) {
    if (dx != 0 || dy != 0) send(tMove, _i16pair(dx, dy));
  }

  void scroll(int v, int h) {
    if (v != 0 || h != 0) send(tScroll, _i16pair(v, h));
  }

  void click(int button) => send(tClick, [button]);
  void button(int button, bool down) => send(tButton, [button, down ? 1 : 0]);
  void text(String s) => send(tText, utf8.encode(s));
  void key(String combo) => send(tKey, utf8.encode(combo));
}

Future<List<PcFound>> discover() async {
  final found = <String, PcFound>{};
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;
    final targets = <String>{'255.255.255.255'};
    for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4)) {
      for (final a in iface.addresses) {
        final p = a.address.split('.');
        if (p.length == 4 && !a.isLoopback) {
          targets.add('${p[0]}.${p[1]}.${p[2]}.255');
        }
      }
    }
    sock.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final dg = sock!.receive();
      if (dg == null) return;
      final msg = utf8.decode(dg.data, allowMalformed: true);
      if (!msg.startsWith('AIRDECK!')) return;
      String host = dg.address.address;
      try {
        host = jsonDecode(msg.substring(8))['host'] ?? host;
      } catch (_) {}
      found[dg.address.address] = PcFound(dg.address.address, host);
    });
    for (var i = 0; i < 3; i++) {
      for (final t in targets) {
        try {
          sock.send(utf8.encode('AIRDECK?'), InternetAddress(t), discoveryPort);
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
  } finally {
    sock?.close();
  }
  return found.values.toList();
}

// ------------------------------------------------------------ connect screen
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _ip = TextEditingController();
  final _pin = TextEditingController();
  List<String> _savedIps = [];
  String? _savedHost;
  List<PcFound> _found = [];
  bool _searching = false;
  bool _busy = false;
  bool _cancel = false;
  bool _manual = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _savedIps = p.getStringList('ips') ??
        [if ((p.getString('ip') ?? '').isNotEmpty) p.getString('ip')!];
    _savedHost = p.getString('host');
    _pin.text = p.getString('pin') ?? '';
    if (_savedIps.isNotEmpty) _ip.text = _savedIps.first;
    if (!mounted) return;
    setState(() {});
    if (_savedIps.isNotEmpty && _pin.text.isNotEmpty) {
      _autoConnect();
    } else {
      _search();
    }
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final r = await discover();
    if (!mounted) return;
    setState(() {
      _found = r;
      _searching = false;
      if (_ip.text.isEmpty && r.isNotEmpty) _ip.text = r.first.ip;
    });
  }

  /// Tries the remembered PC addresses, then any PC found on the network.
  /// With [keepTrying], retries for 30 s (used after a dropped connection).
  Future<void> _autoConnect({bool keepTrying = false, List<String>? ips}) async {
    if (_busy) return;
    final pin = _pin.text.trim();
    if (pin.isEmpty) {
      setState(() => _error = 'Scan the QR code on the PC, or enter its code');
      return;
    }
    setState(() {
      _busy = true;
      _cancel = false;
      _error = null;
      _status = keepTrying
          ? 'Connection lost. Reconnecting…'
          : 'Connecting to ${_savedHost ?? 'your PC'}…';
    });
    final deadline =
        DateTime.now().add(Duration(seconds: keepTrying ? 30 : 0));
    String? lastError;
    do {
      final tried = <String>{};
      Future<Connection?> attempt(String ip) async {
        if (_cancel || !tried.add(ip)) return null;
        try {
          return await _open(ip, pin);
        } catch (e) {
          lastError = e is String ? e : 'Could not reach $ip';
          if (lastError == 'Wrong connection code') _cancel = true;
          return null;
        }
      }

      for (final ip in ips ?? _savedIps) {
        final c = await attempt(ip);
        if (c != null) return _enter(c);
      }
      if (_cancel) break;
      final found = await discover();
      if (mounted) setState(() => _found = found);
      for (final pc in found) {
        final c = await attempt(pc.ip);
        if (c != null) return _enter(c);
      }
      if (_cancel) break;
      if (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 2));
      }
    } while (!_cancel && DateTime.now().isBefore(deadline));
    BgService.stop();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = null;
      _error = _cancel && lastError != 'Wrong connection code'
          ? null
          : (lastError == 'Wrong connection code'
              ? 'Wrong connection code. Scan the QR code on the PC again.'
              : 'Could not find your PC. Make sure AirDeck is running on it and both are on the same Wi-Fi/hotspot.');
    });
  }

  final _talk = ValueNotifier<bool>(false);
  ValueNotifier<bool> _closed = ValueNotifier<bool>(false);

  Future<Connection> _open(String ip, String pin) {
    _closed = ValueNotifier<bool>(false);
    final closed = _closed;
    return Connection.open(ip, pin,
        onClosed: () => closed.value = true,
        onPcTalk: (v) => _talk.value = v);
  }

  Future<void> _enter(Connection conn) async {
    final closed = _closed;
    final ip = conn.address;
    final p = await SharedPreferences.getInstance();
    _savedIps = [ip, ..._savedIps.where((e) => e != ip)];
    _savedHost = conn.host;
    await p.setStringList('ips', _savedIps);
    await p.setString('pin', _pin.text.trim());
    await p.setString('host', conn.host);
    if (!mounted) {
      conn.close();
      return;
    }
    setState(() {
      _busy = false;
      _status = null;
      _ip.text = ip;
    });
    await BgService.start(conn.host);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            ControlScreen(conn: conn, pcTalking: _talk, closed: closed)));
    final dropped = closed.value;
    conn.close();
    _talk.value = false;
    if (dropped && mounted) {
      _autoConnect(keepTrying: true); // service stays up while reconnecting
    } else {
      BgService.stop();
    }
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (raw == null || !mounted) return;
    final uri = Uri.tryParse(raw);
    final code = uri?.queryParameters['code'] ?? '';
    final ips = (uri?.queryParameters['ip'] ?? '')
        .split(',')
        .where((e) => e.isNotEmpty)
        .toList();
    if (code.isEmpty || ips.isEmpty) {
      setState(() => _error = 'That QR code is not an AirDeck code');
      return;
    }
    _pin.text = code;
    _ip.text = ips.first;
    _savedHost = uri!.queryParameters['host'];
    _autoConnect(ips: ips);
  }

  void _connectManual() {
    final ip = _ip.text.trim();
    if (ip.isEmpty || _pin.text.trim().isEmpty) {
      setState(() => _error = 'Enter the PC address and connection code');
      return;
    }
    _autoConnect(ips: [ip]);
  }

  void _tapFound(PcFound pc) {
    _ip.text = pc.ip;
    _savedHost = pc.host;
    if (_pin.text.trim().isNotEmpty) {
      _autoConnect(ips: [pc.ip]);
    } else {
      setState(() {
        _manual = true;
        _error = 'Enter the code shown on ${pc.host}, or scan its QR code';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AirDeck')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_status != null)
            Card(
              color: cs.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5)),
                  const SizedBox(width: 16),
                  Expanded(
                      child: Text(_status!,
                          style: TextStyle(color: cs.onPrimaryContainer))),
                  TextButton(
                      onPressed: () => setState(() => _cancel = true),
                      child: const Text('Cancel')),
                ]),
              ),
            ),
          const SizedBox(height: 8),
          Icon(Icons.qr_code_scanner, size: 64, color: cs.primary),
          const SizedBox(height: 8),
          Text('Connect to your PC',
              textAlign: TextAlign.center, style: tt.headlineSmall),
          const SizedBox(height: 6),
          Text(
              'Open AirDeck on the PC and scan the QR code it shows. '
              'You only need to do this once.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error)),
            ),
          const SizedBox(height: 24),
          Row(children: [
            Text('Computers on this network', style: tt.titleSmall),
            const Spacer(),
            _searching
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    onPressed: _busy ? null : _search,
                    icon: const Icon(Icons.refresh)),
          ]),
          if (_found.isEmpty && !_searching)
            Text('None found yet.',
                style: TextStyle(color: cs.onSurfaceVariant)),
          for (final pc in _found)
            Card(
              child: ListTile(
                leading: const Icon(Icons.computer),
                title: Text(pc.host),
                subtitle: Text(pc.ip),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _tapFound(pc),
              ),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _manual = !_manual),
            child: Text(_manual ? 'Hide manual entry' : 'Enter address manually'),
          ),
          if (_manual) ...[
            TextField(
              controller: _ip,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'PC address (IP)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                  labelText: 'Connection code (shown on the PC)',
                  border: OutlineInputBorder()),
              onSubmitted: (_) => _connectManual(),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _connectManual,
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              child: const Text('Connect'),
            ),
          ],
        ],
      ),
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the QR code on your PC')),
      body: Stack(children: [
        MobileScanner(onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && v.startsWith('airdeck://')) {
              _done = true;
              HapticFeedback.mediumImpact();
              Navigator.of(context).pop(v);
              return;
            }
          }
        }),
        Center(
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------ control screen
class ControlScreen extends StatefulWidget {
  final Connection conn;
  final ValueNotifier<bool> pcTalking;
  final ValueNotifier<bool> closed;
  const ControlScreen(
      {super.key,
      required this.conn,
      required this.pcTalking,
      required this.closed});
  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen>
    with WidgetsBindingObserver {
  Connection get conn => widget.conn;

  // settings
  double _touchSpeed = 1.6;
  double _gyroSpeed = 22;
  bool _invertScroll = true;

  // gyro air mouse
  bool _gyroOn = false;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gfx = 0, _gfy = 0;

  // touchpad state
  final Map<int, Offset> _pointers = {};
  Offset _lastCentroid = Offset.zero;
  double _fx = 0, _fy = 0, _scrollAcc = 0, _hScrollAcc = 0;
  DateTime _downAt = DateTime.now();
  double _travel = 0;
  int _maxPointers = 0;

  // push to talk
  // hold to talk = speech to text, typed on the PC
  final SpeechToText _stt = SpeechToText();
  bool _sttReady = false;
  bool _talking = false;
  String _heard = '';
  String? _finalText;
  Completer<void>? _finalDone;
  List<LocaleName> _locales = [];
  String? _localeId;
  bool _enterAfter = false;

  // keyboard
  final _kb = TextEditingController(text: ' ');
  final _kbFocus = FocusNode();
  bool _kbOpen = false;

  @override
  void initState() {
    super.initState();
    widget.closed.addListener(_onClosed);
    WidgetsBinding.instance.addObserver(this);
    BgService.onDisconnectPressed = () {
      if (mounted) Navigator.of(context).maybePop();
    };
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _touchSpeed = p.getDouble('touchSpeed') ?? _touchSpeed;
        _gyroSpeed = p.getDouble('gyroSpeed') ?? _gyroSpeed;
        _invertScroll = p.getBool('invertScroll') ?? true;
        _localeId = p.getString('speechLocale');
        _enterAfter = p.getBool('enterAfter') ?? false;
      });
    });
  }

  void _onClosed() {
    if (!widget.closed.value || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected from PC')));
    Navigator.of(context).maybePop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Stay connected in the background, but stop the air mouse so the
    // cursor doesn't wander while the phone is in a pocket.
    if (state != AppLifecycleState.resumed) {
      if (_gyroOn) _toggleGyro();
      if (_talking) _talkStop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BgService.onDisconnectPressed = null;
    widget.closed.removeListener(_onClosed);
    _gyroSub?.cancel();
    _stt.cancel();
    _kb.dispose();
    _kbFocus.dispose();
    super.dispose();
  }

  // ---------------- touchpad
  Offset _centroid() {
    var s = Offset.zero;
    for (final p in _pointers.values) {
      s += p;
    }
    return s / _pointers.length.toDouble();
  }

  void _down(PointerDownEvent e) {
    if (_pointers.isEmpty) {
      _downAt = DateTime.now();
      _travel = 0;
      _maxPointers = 0;
    }
    _pointers[e.pointer] = e.localPosition;
    _maxPointers = math.max(_maxPointers, _pointers.length);
    _lastCentroid = _centroid();
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final c = _centroid();
    final d = c - _lastCentroid;
    _lastCentroid = c;
    _travel += d.distance;
    if (_pointers.length == 1) {
      final accel = 1 + math.min(d.distance / 10, 2.0);
      _fx += d.dx * _touchSpeed * accel;
      _fy += d.dy * _touchSpeed * accel;
      final ix = _fx.truncate(), iy = _fy.truncate();
      _fx -= ix;
      _fy -= iy;
      conn.move(ix, iy);
    } else if (_pointers.length == 2) {
      // natural: content follows the fingers (like a phone)
      final sign = _invertScroll ? 1 : -1;
      _scrollAcc += d.dy * sign / 18;
      _hScrollAcc += -d.dx * sign / 18;
      final v = _scrollAcc.truncate(), h = _hScrollAcc.truncate();
      _scrollAcc -= v;
      _hScrollAcc -= h;
      conn.scroll(v, h);
    }
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.isEmpty) {
      final quick =
          DateTime.now().difference(_downAt) < const Duration(milliseconds: 250);
      if (quick && _travel < 12) {
        conn.click(_maxPointers >= 2 ? 1 : 0);
        HapticFeedback.selectionClick();
      }
    } else {
      _lastCentroid = _centroid();
    }
  }

  // ---------------- gyroscope
  void _toggleGyro() {
    setState(() => _gyroOn = !_gyroOn);
    _gyroSub?.cancel();
    _gyroSub = null;
    if (!_gyroOn) return;
    _gfx = _gfy = 0;
    // Hold the phone like a TV remote (top edge pointing at the screen).
    // Turning left/right rotates around the Z axis, tilting up/down around X.
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen((g) {
      double yaw = g.z, pitch = g.x;
      const dead = 0.03; // rad/s – ignores hand tremor
      yaw = yaw.abs() < dead ? 0 : yaw - dead * yaw.sign;
      pitch = pitch.abs() < dead ? 0 : pitch - dead * pitch.sign;
      _gfx += -yaw * _gyroSpeed;
      _gfy += -pitch * _gyroSpeed;
      final ix = _gfx.truncate(), iy = _gfy.truncate();
      _gfx -= ix;
      _gfy -= iy;
      conn.move(ix, iy);
    });
  }

  // ---------------- hold to talk: speech to text
  Future<bool> _ensureStt() async {
    if (_sttReady) return true;
    _sttReady = await _stt.initialize(onError: (e) {
      if (!mounted || e.errorMsg == 'error_speech_timeout') return;
      if (e.errorMsg == 'error_no_match') {
        _finalDone?.complete();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Speech recognition: ${e.errorMsg}')));
    });
    if (_sttReady) {
      _locales = await _stt.locales();
      _localeId ??= (await _stt.systemLocale())?.localeId;
    }
    return _sttReady;
  }

  Future<void> _talkStart() async {
    if (_talking) return;
    setState(() {
      _talking = true;
      _heard = '';
    });
    if (!await _ensureStt()) {
      setState(() => _talking = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Speech recognition is not available. Allow the microphone permission and try again.')));
      }
      return;
    }
    if (!_talking) return; // released while initializing
    HapticFeedback.mediumImpact();
    _finalText = null;
    _finalDone = Completer<void>();
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) {
        if (!mounted) return;
        setState(() => _heard = r.recognizedWords);
        if (r.finalResult) {
          _finalText = r.recognizedWords;
          if (!(_finalDone?.isCompleted ?? true)) _finalDone!.complete();
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        localeId: _localeId,
        listenFor: const Duration(minutes: 1),
        pauseFor: const Duration(seconds: 10),
      ),
    );
  }

  Future<void> _talkStop() async {
    if (!_talking) return;
    setState(() => _talking = false);
    if (!_sttReady) return;
    await _stt.stop();
    // wait briefly for the recognizer to deliver its final text
    try {
      await _finalDone?.future.timeout(const Duration(seconds: 3));
    } catch (_) {}
    final text = (_finalText ?? _heard).trim();
    if (text.isEmpty) {
      if (mounted) setState(() => _heard = '');
      return;
    }
    if (_enterAfter) {
      conn.text(text);
      conn.key('enter');
    } else {
      conn.text('$text ');
    }
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _heard = 'Typed: $text');
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_talking && _heard == 'Typed: $text') {
        setState(() => _heard = '');
      }
    });
  }

  // ---------------- keyboard
  void _kbChanged(String v) {
    // The field always holds a single sentinel space; anything after it is
    // new text, and deleting the sentinel means Backspace.
    if (v.isEmpty) {
      conn.key('backspace');
    } else if (v.length > 1) {
      conn.text(v.substring(1));
    }
    _kb.value = const TextEditingValue(
        text: ' ', selection: TextSelection.collapsed(offset: 1));
  }

  void _toggleKeyboard() {
    setState(() => _kbOpen = !_kbOpen);
    if (_kbOpen) {
      _kbFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    } else {
      _kbFocus.unfocus();
    }
  }

  // ---------------- settings
  void _openSettings() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        void save() async {
          final p = await SharedPreferences.getInstance();
          await p.setDouble('touchSpeed', _touchSpeed);
          await p.setDouble('gyroSpeed', _gyroSpeed);
          await p.setBool('invertScroll', _invertScroll);
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                title: const Text('Touchpad speed'),
                subtitle: Slider(
                    min: 0.5,
                    max: 4,
                    value: _touchSpeed,
                    onChanged: (v) {
                      set(() => _touchSpeed = v);
                      setState(() {});
                    },
                    onChangeEnd: (_) => save())),
            ListTile(
                title: const Text('Air mouse (gyroscope) speed'),
                subtitle: Slider(
                    min: 5,
                    max: 60,
                    value: _gyroSpeed,
                    onChanged: (v) {
                      set(() => _gyroSpeed = v);
                      setState(() {});
                    },
                    onChangeEnd: (_) => save())),
            SwitchListTile(
                title: const Text('Press Enter after voice typing'),
                subtitle: const Text('Useful for search boxes and chats'),
                value: _enterAfter,
                onChanged: (v) async {
                  set(() => _enterAfter = v);
                  setState(() {});
                  (await SharedPreferences.getInstance())
                      .setBool('enterAfter', v);
                }),
            if (_locales.isNotEmpty)
              ListTile(
                title: const Text('Voice typing language'),
                trailing: DropdownButton<String>(
                  value: _locales.any((l) => l.localeId == _localeId)
                      ? _localeId
                      : null,
                  hint: const Text('Phone default'),
                  items: [
                    for (final l in (_locales.toList()
                      ..sort((a, b) => a.name.compareTo(b.name))))
                      DropdownMenuItem(
                          value: l.localeId,
                          child: Text(l.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) async {
                    set(() => _localeId = v);
                    setState(() {});
                    if (v != null) {
                      (await SharedPreferences.getInstance())
                          .setString('speechLocale', v);
                    }
                  },
                ),
              ),
            SwitchListTile(
                title: const Text('Natural scrolling (like a phone)'),
                value: _invertScroll,
                onChanged: (v) {
                  set(() => _invertScroll = v);
                  setState(() {});
                  save();
                }),
          ]),
        );
      }),
    );
  }

  Widget _keyChip(String label, String combo) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ActionChip(
            label: Text(label),
            onPressed: () {
              HapticFeedback.selectionClick();
              conn.key(combo);
            }),
      );

  Widget _mouseButton(String label, int b) => Expanded(
        child: Listener(
          onPointerDown: (_) {
            HapticFeedback.selectionClick();
            conn.button(b, true);
          },
          onPointerUp: (_) => conn.button(b, false),
          onPointerCancel: (_) => conn.button(b, false),
          child: Container(
            height: 64,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(label),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(conn.host),
        actions: [
          IconButton(
              tooltip: 'Keyboard',
              onPressed: _toggleKeyboard,
              icon: Icon(_kbOpen ? Icons.keyboard_hide : Icons.keyboard)),
          IconButton(
              tooltip: 'Settings',
              onPressed: _openSettings,
              icon: const Icon(Icons.tune)),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          ValueListenableBuilder<bool>(
            valueListenable: widget.pcTalking,
            builder: (_, v, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: v ? 36 : 0,
              width: double.infinity,
              color: cs.tertiaryContainer,
              alignment: Alignment.center,
              child: v
                  ? Text('🔊  PC is talking',
                      style: TextStyle(color: cs.onTertiaryContainer))
                  : null,
            ),
          ),
          // hidden text field that drives the phone keyboard
          SizedBox(
            height: 1,
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: _kb,
                focusNode: _kbFocus,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.text,
                onChanged: _kbChanged,
                onSubmitted: (_) {
                  conn.key('enter');
                  _kbFocus.requestFocus();
                },
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                _keyChip('Esc', 'esc'),
                _keyChip('Tab', 'tab'),
                _keyChip('Enter', 'enter'),
                _keyChip('⌫', 'backspace'),
                _keyChip('←', 'left'),
                _keyChip('↑', 'up'),
                _keyChip('↓', 'down'),
                _keyChip('→', 'right'),
                _keyChip('Copy', 'ctrl+c'),
                _keyChip('Paste', 'ctrl+v'),
                _keyChip('Undo', 'ctrl+z'),
                _keyChip('Alt+Tab', 'alt+tab'),
                _keyChip('Super', 'super'),
                _keyChip('⏯', 'playpause'),
                _keyChip('Vol −', 'volumedown'),
                _keyChip('Vol +', 'volumeup'),
                _keyChip('Mute', 'mute'),
              ],
            ),
          ),
          Expanded(
            child: Listener(
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: _gyroOn ? cs.primary : cs.outlineVariant,
                      width: _gyroOn ? 2 : 1),
                ),
                alignment: Alignment.center,
                child: Text(
                  _gyroOn
                      ? 'Air mouse ON\nPoint the phone at the screen and move it'
                      : 'Touchpad\nTap = click · 2-finger tap = right click\n2-finger drag = scroll',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ),
          ),
          if (_talking || _heard.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.secondaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                _heard.isEmpty ? 'Listening… speak now' : _heard,
                style: TextStyle(color: cs.onSecondaryContainer, fontSize: 16),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              _mouseButton('Left', 0),
              _mouseButton('Middle', 2),
              _mouseButton('Right', 1),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _toggleGyro,
                  icon: Icon(_gyroOn ? Icons.screen_rotation : Icons.sensors),
                  label: Text(_gyroOn ? 'Air mouse: ON' : 'Air mouse'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(72),
                    backgroundColor: _gyroOn ? cs.primary : null,
                    foregroundColor: _gyroOn ? cs.onPrimary : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Listener(
                  onPointerDown: (_) => _talkStart(),
                  onPointerUp: (_) => _talkStop(),
                  onPointerCancel: (_) => _talkStop(),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    height: 72,
                    decoration: BoxDecoration(
                      color: _talking ? cs.error : cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(36),
                    ),
                    alignment: Alignment.center,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_talking ? Icons.mic : Icons.mic_none,
                          color: _talking
                              ? cs.onError
                              : cs.onSecondaryContainer),
                      const SizedBox(width: 8),
                      Text(_talking ? 'Listening…' : 'Hold to type by voice',
                          style: TextStyle(
                              color: _talking
                                  ? cs.onError
                                  : cs.onSecondaryContainer,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

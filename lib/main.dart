import 'dart:async';
import 'dart:io' show Platform, File; // for desktop detection and local key file
import 'dart:isolate';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'openai_service.dart';
import 'prompt_styles.dart';
import 'memory_store.dart';
import 'email_service.dart';

// Compile-time defines passed via --dart-define (defaults keep types non-null)
const String _openAiKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
const String _pvKey     = String.fromEnvironment('PICOVOICE_ACCESS_KEY', defaultValue: '');
const String _modelId   = String.fromEnvironment('OPENAI_MODEL', defaultValue: 'gpt-4o-mini');
// Optional default recipient for emailing last reply
const String _defaultEmailTo = String.fromEnvironment('DEFAULT_EMAIL_TO', defaultValue: '');
// Optional email sending
// SMTP (recommended, no vendor lock-in)
const String _smtpHost = String.fromEnvironment('SMTP_HOST', defaultValue: '');
const int _smtpPort = int.fromEnvironment('SMTP_PORT', defaultValue: 587);
const String _smtpUser = String.fromEnvironment('SMTP_USER', defaultValue: '');
const String _smtpPass = String.fromEnvironment('SMTP_PASS', defaultValue: '');
const String _smtpEncryption = String.fromEnvironment('SMTP_ENCRYPTION', defaultValue: 'starttls'); // ssl|starttls|none
// SendGrid (optional fallback)
const String _sendgridKey = String.fromEnvironment('SENDGRID_API_KEY', defaultValue: '');
const String _emailSender = String.fromEnvironment('EMAIL_SENDER', defaultValue: '');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TeddyApp());
}

class _SimpleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {}
  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {}
  @override
  Future<void> onButtonPressed(String id) async {}
  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {}
  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {}
}

class TeddyApp extends StatelessWidget {
  const TeddyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Teddy Talks',
      theme: ThemeData.dark(useMaterial3: true),
      home: const TeddyHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class TeddyHome extends StatefulWidget {
  const TeddyHome({super.key});
  @override
  State<TeddyHome> createState() => _TeddyHomeState();
}

class _TeddyHomeState extends State<TeddyHome> {
  // IO
  final FlutterTts tts = FlutterTts();
  final stt.SpeechToText sttEngine = stt.SpeechToText();
  PorcupineManager? _ppnMgr;

  // App state
  bool isAwake = false;
  bool stayAwake = true;
  bool isPaused = false;
  String ageMode = "General";
  String status = "Sleeping";
  String lastHeard = "";
  String lastReply = "";
  final List<String> log = [];
  MemoryStore? _memory;
  String? _emailTo; // default recipient, stored in prefs

  // Voice controls
  List<Map<String, String>> _voices = [];
  String? _selectedVoiceName;
  String? _selectedVoiceLocale;
  double _rate = 0.88; // a bit slower
  double _pitch = 0.92; // slightly deeper

  // Timing metrics
  DateTime? _tWake;
  DateTime? _tListenStart;
  DateTime? _tListenEnd;
  DateTime? _tLlmStart;
  DateTime? _tLlmEnd;
  DateTime? _tTtsStart;
  DateTime? _tTtsEnd;

  // Desktop/test helpers
  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  final TextEditingController _typedController = TextEditingController();

  late OpenAIService openai;
  EmailService? _emailService;

  bool _sttReady = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _initForegroundTask();
    }
    _bootstrap();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'teddy_talks_bg',
        channelName: 'Teddy background',
        channelDescription: 'Keeps wake word active in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        isOnceEvent: false,
        allowWakeLock: true,
        autoRunOnBoot: false,
      ),
    );
  }

  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'Teddy is listening',
      notificationText: 'Say "Hey Teddy" to wake',
      callback: _fgServiceCallback,
    );
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
  }

  @pragma('vm:entry-point')
  static void _fgServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_SimpleTaskHandler());
  }

  Future<void> _bootstrap() async {
  // Load saved preferences
  final prefs = await SharedPreferences.getInstance();
  ageMode = prefs.getString('ageMode') ?? ageMode;
  // Load memory
  _memory = await MemoryStore.load(prefs);
  _selectedVoiceName = prefs.getString('ttsVoiceName');
  _selectedVoiceLocale = prefs.getString('ttsVoiceLocale');
  _rate = prefs.getDouble('ttsRate') ?? _rate;
  _pitch = prefs.getDouble('ttsPitch') ?? _pitch;
  _emailTo = prefs.getString('emailTo');
  setState(() {});
    String _normalizeKey(String raw) {
      var k = raw.trim().replaceAll('"', '').replaceAll('\ufeff', '').replaceAll('ï»¿', '');
      if (k.isEmpty) return '';
      // If a placeholder or unresolved variable sneaks in, ignore
      if (k.contains('%')) return '';
      // If the user wrote OPENAI_API_KEY=... keep only the value (prefer from first 'sk-')
      final idxSk = k.indexOf('sk-');
      if (k.contains('OPENAI_API_KEY') || k.contains('=')) {
        if (idxSk >= 0) {
          k = k.substring(idxSk);
        } else {
          // No recognizable key inside
          return '';
        }
      }
      return k;
    }

    // Resolve key/model from dart-define, env, or local file
    var key = _normalizeKey(_openAiKey);
    if (key.isEmpty) {
      key = _normalizeKey(Platform.environment['OPENAI_API_KEY'] ?? '');
    }
    if (key.isEmpty) {
      try {
        final f = File('openai_key.txt');
        if (await f.exists()) {
          key = _normalizeKey(await f.readAsString());
        }
      } catch (_) {}
    }
    final rawDefine = _modelId.trim().replaceAll('"', '');
    final bool placeholder = rawDefine.contains('%');
    String resolvedModel = rawDefine;
    String source = 'define';
    if (resolvedModel.isEmpty || placeholder) {
      final envModel = (Platform.environment['OPENAI_MODEL'] ?? '').trim();
      if (envModel.isNotEmpty && !envModel.contains('%')) {
        resolvedModel = envModel;
        source = 'env';
      }
    }
    // Whitelist common valid models; fallback to gpt-4o-mini if unknown
    final allowed = <String>{
      'gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini', 'gpt-4.1', 'gpt-4o-mini-2024-07-18'
    };
    if (resolvedModel.isEmpty || resolvedModel.contains('%') || !allowed.contains(resolvedModel)) {
      if (resolvedModel.isEmpty) {
        source = 'default';
      } else if (!allowed.contains(resolvedModel)) {
        source = 'fallback(unknown-model)';
      } else {
        source = 'fallback(placeholder)';
      }
      resolvedModel = 'gpt-4o-mini';
    }
    openai = OpenAIService(apiKey: key, model: resolvedModel);
    // Email service (optional)
    if ((_emailTo == null || _emailTo!.isEmpty) && _defaultEmailTo.isNotEmpty) {
      _emailTo = _defaultEmailTo;
      await prefs.setString('emailTo', _emailTo!);
      _pushLog("Email: default recipient set to $_emailTo");
    }

    if (_smtpHost.isNotEmpty && _smtpUser.isNotEmpty && _smtpPass.isNotEmpty) {
      _emailService = EmailService(
        smtpHost: _smtpHost,
        smtpPort: _smtpPort,
        smtpUser: _smtpUser,
        smtpPass: _smtpPass,
        smtpEncryption: _smtpEncryption,
      );
      _pushLog("Email: SMTP configured for $_smtpUser");
    } else if (_sendgridKey.isNotEmpty && _emailSender.isNotEmpty) {
      _emailService = EmailService(sendgridKey: _sendgridKey, sendgridSender: _emailSender);
      _pushLog("Email: SendGrid configured (sender set)");
    } else {
      _pushLog("Email: No SMTP/SendGrid configured; will use mail client if available.");
    }

    // Show key/model status early for diagnostics (do not print the key)
    final maskedLen = key.length;
    _pushLog(maskedLen == 0 ? "OpenAI key: MISSING" : "OpenAI key: detected ($maskedLen chars)");
    _pushLog("OPENAI_MODEL define: ${rawDefine.isEmpty ? '(empty)' : rawDefine}");
    if (placeholder) _pushLog("OPENAI_MODEL looked like a placeholder");
    final envModelLog = Platform.environment['OPENAI_MODEL'];
    if (envModelLog != null && envModelLog.isNotEmpty) {
      _pushLog("OPENAI_MODEL env: $envModelLog");
    }
    _pushLog("OpenAI model: $resolvedModel (source: $source)");
    // Permissions (mobile only)
    if (_isMobile) {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        _pushLog("Microphone permission not granted.");
      }
    } else {
      _pushLog("Desktop/test mode: mic permission not required.");
    }

    // TTS config
    await tts.setLanguage("en-GB");
    // Prefer Google TTS on Android to get the widest voice set (incl. male voices)
    if (_isMobile && Platform.isAndroid) {
      try {
        final engines = await tts.getEngines as List?; // may be null on some platforms
        final google = engines?.map((e) => e.toString()).firstWhere(
              (e) => e.contains('com.google.android.tts'),
              orElse: () => '',
            ) ?? '';
        if (google.isNotEmpty) {
          await tts.setEngine('com.google.android.tts');
        }
      } catch (_) {}
    }
    await _applyTtsSettings();
    await _loadVoices(preferMale: true); // default to a male EN-GB voice when present

    // STT init: only attempt on mobile; on desktop we fall back to typing
    if (_isMobile) {
      try {
        _sttReady = await sttEngine.initialize(
          onError: (e) => _pushLog("STT error: ${e.errorMsg}"),
          onStatus: (s) => _pushLog("STT status: $s"),
        );
        if (!_sttReady) {
          _pushLog("Speech recognizer not available.");
        }
      } catch (e) {
        _sttReady = false;
        _pushLog("STT init failed: $e");
      }
    } else {
      _sttReady = false;
      _pushLog("STT disabled on desktop. Use the typing box.");
    }

    // Start Porcupine
    // On desktop we may not have Porcupine; show manual controls instead
    if (_isMobile && _pvKey.isNotEmpty) {
      await _startWakeWord();
    } else {
      _pushLog("Desktop/test mode: Use 'Test Wake' or Talk/Type controls below.");
    }
  }

  Future<void> _startWakeWord() async {
    try {
      // porcupine_flutter 3.x uses the Manager helpers to construct from keyword paths
      _ppnMgr = await PorcupineManager.fromKeywordPaths(
        _pvKey,
        ["assets/wake/hey_teddy.ppn"],
        _onWakeWord,
        sensitivities: [0.6],
      );
      await _ppnMgr!.start();
      _pushLog("Wake word armed. Say 'Hey Teddy'.");
    } catch (e) {
      _pushLog("Failed to start wake word: $e");
    }
  }

  void _onWakeWord(int index) async {
  _tWake = DateTime.now();
    if (!isAwake) {
      isAwake = true;
      status = "Awake";
      setState(() {});
      await _startForegroundService();
      if (!isPaused) {
        await _speak("Hello, I’m listening.");
      }
    }
    if (!_listening) {
  // brief cooldown to avoid self-hearing the greeting
  await Future.delayed(const Duration(milliseconds: 700));
  _listenOnce();
    }
  }

  Future<void> _listenOnce() async {
    if (!_sttReady) return;
    _listening = true;
    lastHeard = "";
    setState(() {});
    _tListenStart = DateTime.now();

    await sttEngine.listen(
      onResult: (r) {
        if (r.finalResult) {
          lastHeard = r.recognizedWords.trim();
        }
      },
      localeId: "en_GB",
      listenFor: const Duration(seconds: 7),
      pauseFor: const Duration(milliseconds: 800),
      partialResults: false,
      listenMode: stt.ListenMode.dictation,
    );

    // Wait until STT stops by itself or timeout
    final completer = Completer<void>();
    Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (!sttEngine.isListening) {
        t.cancel();
        completer.complete();
      }
    });
    await completer.future;
    _listening = false;
  _tListenEnd = DateTime.now();

  if (lastHeard.isEmpty) {
      if (isAwake && stayAwake) _listenOnce();
      return;
    }

    _pushLog("User: $lastHeard");

    // Handle local voice commands (hands-free controls) before calling LLM
    if (await _maybeHandleCommand(lastHeard)) {
  // If a command produced speech, allow a short delay before listening again
  await Future.delayed(const Duration(milliseconds: 500));
  if (stayAwake && isAwake) _listenOnce();
      return;
    }

    final lower = lastHeard.toLowerCase();
    if (lower == 'hey teddy' || lower.contains('wake teddy') || lower.contains('wake up teddy')) {
      if (!isAwake) {
        isAwake = true;
        status = 'Awake';
        setState(() {});
      }
      await _startForegroundService();
      await _speak('Yes?');
      return;
    }
    if (lower.contains("sleep teddy") || lower.contains("sleep k-2") || lower == "sleep") {
      await _forceSleep();
      return;
    }

    // Natural topic reset phrase
    if (lower.startsWith("new topic") || lower.startsWith("let's change topic") || lower.startsWith("switch topic")) {
      final prefs = await SharedPreferences.getInstance();
      _memory?.resetTopic();
      await _memory?.save(prefs);
      await _speak("Alright, fresh slate. What's next?");
      if (stayAwake && isAwake) _listenOnce();
      return;
    }

    // Compose and call GPT
  final sys = _composeSystemPrompt();
    final style = PromptStyles.prefixForMode(ageMode);
    String reply;
    try {
      _tLlmStart = DateTime.now();
  reply = await openai.chat(
        systemPrompt: sys,
        stylePrefix: style,
        userText: lastHeard,
      );
  reply = _shapeReply(reply);
  // Strip generic helper closers the model sometimes adds
      const closers = [
        'how can i assist you today?',
        'how may i assist you today?',
        'how can i help you today?',
        'how may i help you today?',
        'how can i assist you?',
        'how may i assist you?',
        'how can i help you?',
        'how may i help you?'
      ];
      final rl = reply.toLowerCase();
      for (final c in closers) {
        if (rl.endsWith(c)) {
          reply = reply.substring(0, rl.lastIndexOf(c)).trimRight();
          if (reply.endsWith('.') || reply.endsWith('!') || reply.endsWith('?')) {
            // keep punctuation
          } else {
            reply = reply.trimRight();
          }
          break;
        }
      }
      _tLlmEnd = DateTime.now();
    } catch (e) {
      _pushLog("OpenAI error: $e");
      reply = "I’m having a wobble. Check my internet or key.";
    }

    lastReply = reply;
  _pushLog("K-2 S-O: $reply");
  // Update memory
  _memory?.maybeCaptureFact(lastHeard);
  _memory?.maybeCaptureFromAssistant(reply);
  _memory?.addExchange(lastHeard, reply);
  final prefs2 = await SharedPreferences.getInstance();
  await _memory?.save(prefs2);

    // If we have 10 exchanges in this topic, ask for a one-sentence summary and store it
    if (_memory?.needsSummary() == true) {
      try {
        final s = await openai.chat(
          systemPrompt: "Summarize the conversation below in one concise sentence focusing on the topic and user's goal.",
          stylePrefix: "",
          userText: (_memory?.recentBlock() ?? ''),
        );
        _memory?.appendSummary(s);
        await _memory?.save(prefs2);
  _pushLog("Topic summarized: $s");
      } catch (_) {}
    }
    await _speak(reply);
  // short cooldown to reduce self-hearing when housed with a speaker
  await Future.delayed(const Duration(milliseconds: 600));
  if (stayAwake && isAwake) _listenOnce();
  }

  Future<void> _speak(String text) async {
    await tts.stop();
  _tTtsStart = DateTime.now();
  // Phonetic aliasing for device TTS pronunciation quirks
  // Map the name first so later math verbalization doesn't turn '-' into 'minus'
  var spoken = text;
  final k2so = RegExp(r'k[\-\s]?2[\s\-]?s[\-\s]?o', caseSensitive: false);
  spoken = spoken.replaceAllMapped(k2so, (_) => 'Kay Two Ess Oh');
  spoken = _verbalizeForTts(spoken);
  await tts.speak(spoken);
  // We can't precisely know when TTS finishes on all platforms; mark end after call returns
  _tTtsEnd = DateTime.now();
  }

  // Convert symbol-heavy or LaTeX-like math into listener-friendly speech.
  String _verbalizeForTts(String input) {
    var s = input;
    // Remove LaTeX delimiters and inline markers
    s = s.replaceAll(RegExp(r"\$\$?"), '');
    s = s.replaceAll(RegExp(r"\\\(|\\\)"), '');
    s = s.replaceAll(RegExp(r"\\\[|\\\]"), '');

    // Common math words
    s = s.replaceAll(RegExp(r"\\times|\*"), ' times ');
    s = s.replaceAll(RegExp(r"\\div"), ' divided by ');
  s = s.replaceAllMapped(RegExp(r"\\sqrt\{([^}]+)\}"), (m) => ' the square root of ${m.group(1)} ');
  s = s.replaceAllMapped(RegExp(r"\\frac\{([^}]+)\}\{([^}]+)\}"), (m) => ' ${m.group(1)} over ${m.group(2)} ');

    // Powers like a^2, x^3 -> a squared, x cubed; generic -> to the n-th power
    s = s.replaceAllMapped(RegExp(r"\b([a-zA-Z])\^2\b"), (m) => '${m[1]} squared');
    s = s.replaceAllMapped(RegExp(r"\b([a-zA-Z])\^3\b"), (m) => '${m[1]} cubed');
    s = s.replaceAllMapped(RegExp(r"\b([a-zA-Z])\^([0-9]+)\b"), (m) => '${m[1]} to the ${m[2]} power');

  // Replace operators with words
    s = s.replaceAll(RegExp(r"\+"), ' plus ');
  // Hyphen to minus only in simple math contexts (between symbols/numbers), not in ordinary words
  s = s.replaceAllMapped(RegExp(r"(?<=\b[0-9A-Za-z])\s*-\s*(?=[0-9A-Za-z]\b)"), (_) => ' minus ');
    s = s.replaceAll(RegExp(r"/"), ' over ');
    s = s.replaceAll(RegExp(r"="), ' equals ');

    // Remove backslashes and stray underscores spoken literally
    s = s.replaceAll('\\\\', ' ');
    s = s.replaceAll('_', ' ');

    // Collapse excessive whitespace
    s = s.replaceAll(RegExp(r"\s+"), ' ').trim();
    return s;
  }

  void _pushLog(String s) {
    log.insert(0, s);
    setState(() {});
  }

  @override
  void dispose() {
    _ppnMgr?.stop();
    sttEngine.stop();
    tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Teddy Talks"),
        actions: [
          IconButton(
            tooltip: 'Voice settings',
            icon: const Icon(Icons.settings_voice_outlined),
            onPressed: _openVoiceSettingsSheet,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Chip(
                  label: Text(status),
          backgroundColor: isPaused
            ? Colors.amber
            : (isAwake ? Colors.green : Colors.grey),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: ageMode,
                  items: const [
                    DropdownMenuItem(value: "Kids", child: Text("Kids")),
                    DropdownMenuItem(value: "Teens", child: Text("Teens")),
                    DropdownMenuItem(value: "Adults", child: Text("Adults")),
                    DropdownMenuItem(value: "General", child: Text("General")),
                  ],
                  onChanged: (v) async {
                    setState(() => ageMode = v ?? "General");
                    final p = await SharedPreferences.getInstance();
                    await p.setString('ageMode', ageMode);
                  },
                ),
                const Spacer(),
                Row(
                  children: [
                    const Text("Stay awake"),
                    Switch(
                      value: stayAwake,
                      onChanged: (v) async { await _toggleStayAwake(v); },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Latency readout
            if (_tListenStart != null) Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _latencyLabel(),
                style: const TextStyle(fontFeatures: []),
              ),
            ),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: Text("Last heard: $lastHeard")),
            Align(alignment: Alignment.centerLeft, child: Text("Last reply: $lastReply")),
            const Divider(),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: log.length,
                itemBuilder: (_, i) => Text(log[log.length - 1 - i]),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton(
                  onPressed: () {
                    if (!isAwake) _onWakeWord(0); // manual test
                  },
                  child: const Text("Test Wake"),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async { await _forceSleep(); },
                  child: const Text("Force Sleep"),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await _memory?.clear(prefs);
                    _pushLog("Memory cleared.");
                  },
                  child: const Text("Reset Memory"),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    _memory?.resetTopic();
                    final prefs = await SharedPreferences.getInstance();
                    await _memory?.save(prefs);
                    _pushLog("New topic started (kept long-term facts).");
                  },
                  child: const Text("New Topic"),
                ),
                const SizedBox(width: 8),
                if (_sttReady)
                  ElevatedButton(
                    onPressed: _listening ? null : _listenOnce,
                    child: Text(_listening ? "Listening…" : "Talk"),
                  ),
              ],
            )
            ,
            const SizedBox(height: 8),
            // Typing fallback when STT is not available (desktop)
            if (!_sttReady)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _typedController,
                      decoration: const InputDecoration(
                        labelText: 'Type to test (desktop mode)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final text = _typedController.text.trim();
                      if (text.isEmpty) return;
                      _typedController.clear();
                      isAwake = true;
                      status = "Awake";
                      lastHeard = text;
                      setState(() {});
                      await _processTyped(text);
                    },
                    child: const Text('Send'),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            // Voice chooser & TTS tuning
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selectedVoiceName,
                    hint: const Text('Select voice'),
                    items: _voices
                        .map((v) => DropdownMenuItem<String>(
                              value: v['name'],
                              child: Text("${v['name']} (${v['locale']})"),
                            ))
                        .toList(),
                    onChanged: (name) async {
                      final v = _voices.firstWhere(
                        (e) => e['name'] == name,
                        orElse: () => {}
                      );
                      setState(() {
                        _selectedVoiceName = v['name'];
                        _selectedVoiceLocale = v['locale'];
                      });
                      await _applyTtsSettings();
                      final p = await SharedPreferences.getInstance();
                      await p.setString('ttsVoiceName', _selectedVoiceName ?? '');
                      await p.setString('ttsVoiceLocale', _selectedVoiceLocale ?? '');
                    },
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const Text('Rate'),
                Expanded(
                  child: Slider(
                    value: _rate,
                    onChanged: (v) async {
                      setState(() => _rate = v);
                      await _applyTtsSettings();
                      final p = await SharedPreferences.getInstance();
                      await p.setDouble('ttsRate', _rate);
                    },
                    min: 0.5,
                    max: 1.2,
                  ),
                ),
                const SizedBox(width: 12),
                const Text('Pitch'),
                Expanded(
                  child: Slider(
                    value: _pitch,
                    onChanged: (v) async {
                      setState(() => _pitch = v);
                      await _applyTtsSettings();
                      final p = await SharedPreferences.getInstance();
                      await p.setDouble('ttsPitch', _pitch);
                    },
                    min: 0.6,
                    max: 1.4,
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  // Bottom sheet for voice selection and TTS tuning (Android-friendly UI)
  Future<void> _openVoiceSettingsSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        String? localVoice = _selectedVoiceName;
        double localRate = _rate;
        double localPitch = _pitch;
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> persist() async {
              final p = await SharedPreferences.getInstance();
              await p.setString('ttsVoiceName', _selectedVoiceName ?? '');
              await p.setString('ttsVoiceLocale', _selectedVoiceLocale ?? '');
              await p.setDouble('ttsRate', _rate);
              await p.setDouble('ttsPitch', _pitch);
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 12,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Voice settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      )
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: localVoice,
                    hint: const Text('Select voice'),
                    items: _voices
                        .map((v) => DropdownMenuItem<String>(
                              value: v['name'],
                              child: Text("${v['name']} (${v['locale']})"),
                            ))
                        .toList(),
                    onChanged: (name) async {
                      final v = _voices.firstWhere((e) => e['name'] == name, orElse: () => {});
                      setModalState(() => localVoice = v['name']);
                      setState(() {
                        _selectedVoiceName = v['name'];
                        _selectedVoiceLocale = v['locale'];
                      });
                      await _applyTtsSettings();
                      await persist();
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: () async {
                          await _loadVoices(preferMale: true);
                          setModalState(() => localVoice = _selectedVoiceName);
                          await _applyTtsSettings();
                          await persist();
                          await _speak('Male voice selected.');
                        },
                        child: const Text('Male'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () async {
                          await _loadVoices(preferMale: false);
                          setModalState(() => localVoice = _selectedVoiceName);
                          await _applyTtsSettings();
                          await persist();
                          await _speak('Female voice selected.');
                        },
                        child: const Text('Female'),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () async { await _speak('Ready when you are.'); },
                        icon: const Icon(Icons.volume_up_outlined),
                        label: const Text('Preview'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Rate'),
                      Expanded(
                        child: Slider(
                          value: localRate,
                          onChanged: (v) async {
                            setModalState(() => localRate = v);
                            setState(() => _rate = v);
                            await _applyTtsSettings();
                            await persist();
                          },
                          min: 0.5,
                          max: 1.2,
                        ),
                      ),
                      SizedBox(width: 8, child: Text(localRate.toStringAsFixed(2), textAlign: TextAlign.right)),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('Pitch'),
                      Expanded(
                        child: Slider(
                          value: localPitch,
                          onChanged: (v) async {
                            setModalState(() => localPitch = v);
                            setState(() => _pitch = v);
                            await _applyTtsSettings();
                            await persist();
                          },
                          min: 0.6,
                          max: 1.4,
                        ),
                      ),
                      SizedBox(width: 8, child: Text(localPitch.toStringAsFixed(2), textAlign: TextAlign.right)),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _latencyLabel() {
    String b(String k, Duration? d) => d == null ? "$k: -" : "$k: ${d.inMilliseconds} ms";
    final listen = (_tListenStart != null && _tListenEnd != null) ? _tListenEnd!.difference(_tListenStart!) : null;
    final llm = (_tLlmStart != null && _tLlmEnd != null) ? _tLlmEnd!.difference(_tLlmStart!) : null;
    final ttsDur = (_tTtsStart != null && _tTtsEnd != null) ? _tTtsEnd!.difference(_tTtsStart!) : null;
    return [
      b('Listen', listen),
      b('LLM', llm),
      b('TTS', ttsDur),
    ].join('  |  ');
  }

  Future<void> _forceSleep() async {
  isAwake = false;
  isPaused = false;
    status = "Sleeping";
    setState(() {});
    await _stopForegroundService();
    await _speak("Going to sleep.");
  }

  Future<void> _toggleStayAwake(bool value) async {
    stayAwake = value;
    setState(() {});
    if (stayAwake) {
      await _startForegroundService();
    } else {
      await _stopForegroundService();
    }
  }

  Future<void> _loadVoices({bool preferMale = false}) async {
    try {
      final raw = await tts.getVoices; // dynamic per platform
      List<dynamic> list;
      if (raw is List) {
        list = raw;
      } else if (raw is Map && raw['voices'] is List) {
        list = List<dynamic>.from(raw['voices']);
      } else {
        list = const [];
      }

      // Normalize to {name, locale}
      _voices = list
          .map<Map<String, String>>((v) {
            if (v is Map) {
              final name = (v['name'] ?? '').toString();
              final locale = (v['locale'] ?? '').toString();
              final gender = (v['gender'] ?? '').toString();
              final engine = (v['engine'] ?? '').toString();
              return {'name': name, 'locale': locale, 'gender': gender, 'engine': engine};
            }
            return {'name': v.toString(), 'locale': ''};
          })
          .where((m) => (m['name'] ?? '').isNotEmpty)
          .toList();

      // Prefer saved voice if still available; otherwise pick EN-GB if possible
      Map<String, String>? preferred = {};
      if (_selectedVoiceName != null) {
        preferred = _voices.firstWhere(
          (v) => v['name'] == _selectedVoiceName,
          orElse: () => {},
        );
      }
      // Helper to check gender hints in voice metadata/name
      bool _isMale(Map<String, String> v) {
        final g = (v['gender'] ?? '').toLowerCase();
        final n = (v['name'] ?? '').toLowerCase();
        return g == 'male' || n.contains('#male') || RegExp(r'\bmale\b').hasMatch(n);
      }
      if (preferred.isEmpty) {
        // Prefer EN-GB male if asked, else EN-GB any
        if (preferMale) {
          preferred = _voices.firstWhere(
            (v) => (v['locale'] ?? '').toLowerCase().startsWith('en_gb') && _isMale(v),
            orElse: () => {},
          );
        }
        if (preferred.isEmpty) {
          preferred = _voices.firstWhere(
            (v) => (v['locale'] ?? '').toLowerCase().startsWith('en_gb'),
            orElse: () => {},
          );
        }
        // Fallbacks: any EN male, else any male, else first voice
        if (preferred.isEmpty && preferMale) {
          preferred = _voices.firstWhere(
            (v) => (v['locale'] ?? '').toLowerCase().startsWith('en') && _isMale(v),
            orElse: () => {},
          );
        }
        if (preferred.isEmpty && preferMale) {
          preferred = _voices.firstWhere(
            (v) => _isMale(v),
            orElse: () => {},
          );
        }
        if (preferred.isEmpty) {
          preferred = _voices.isNotEmpty ? _voices.first : {};
        }
      }
      if (preferred.isNotEmpty) {
        _selectedVoiceName = preferred['name'];
        _selectedVoiceLocale = preferred['locale'];
      }
      setState(() {});
      await _applyTtsSettings();
    } catch (e) {
      _pushLog('Could not load TTS voices: $e');
    }
  }

  Future<void> _applyTtsSettings() async {
    try {
      await tts.setSpeechRate(_rate);
      await tts.setPitch(_pitch);
  // Ensure TTS engine volume is maxed (does not change device system volume)
  await tts.setVolume(1.0);
  try { await tts.awaitSpeakCompletion(true); } catch (_) {}
      if (_selectedVoiceName != null && _selectedVoiceLocale != null) {
        await tts.setVoice({'name': _selectedVoiceName!, 'locale': _selectedVoiceLocale!});
      }
    } catch (e) {
      _pushLog('TTS setting error: $e');
    }
  }

  Future<void> _processTyped(String text) async {
    _pushLog("User: $text");
    // Let typing also use the command handler for quick tests on desktop
    if (await _maybeHandleCommand(text)) {
      setState((){});
      return;
    }
  final sys = _composeSystemPrompt();
    final style = PromptStyles.prefixForMode(ageMode);
    String reply;
    try {
      _tLlmStart = DateTime.now();
      reply = await openai.chat(
        systemPrompt: sys,
        stylePrefix: style,
        userText: text,
      );
      _tLlmEnd = DateTime.now();
  reply = _shapeReply(reply);
    } catch (e) {
      _pushLog("OpenAI error: $e");
      reply = "I’m having a wobble. Check my internet or key.";
    }
    lastReply = reply;
    setState(() {});
    // Update memory
    _memory?.maybeCaptureFact(text);
  _memory?.maybeCaptureFromAssistant(reply);
    _memory?.addExchange(text, reply);
    final prefs2 = await SharedPreferences.getInstance();
    await _memory?.save(prefs2);
    await _speak(reply);
  }

  bool _wantsElaboration(String prompt) {
    final p = prompt.toLowerCase();
    return p.contains('explain') || p.contains('elaborate') || p.contains('break down') || p.contains('walk me through');
  }

  bool _wantsContinue(String prompt) {
    final p = prompt.toLowerCase();
    return p == 'continue' || p.startsWith('continue ') || p.contains('go on') || p.contains('tell me more');
  }

  // Post-processor to keep replies concise, stoic, and filler-free.
  String _shapeReply(String raw) {
    if (raw.isEmpty) return raw;
    var reply = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Remove common filler, softeners, casual idioms, and tag questions at the end.
  final stripPatterns = <RegExp>[
      RegExp(r'\bif you ask me\b\.?$', caseSensitive: false),
      RegExp(r"\bisn't it\??$", caseSensitive: false),
      RegExp(r"\bright\??$", caseSensitive: false),
      RegExp(r"\bokay\??$", caseSensitive: false),
      RegExp(r"\bkind of\b", caseSensitive: false),
      RegExp(r"\bsort of\b", caseSensitive: false),
    ];
    for (final re in stripPatterns) {
      reply = reply.replaceAll(re, '').trim();
    }

    // Conditionally remove pronunciation guidance unless the user asked for it
    final askedPronounce = RegExp(r"\b(pronounc|how to say|say it|pronunciation)\b", caseSensitive: false)
        .hasMatch(lastHeard);
    if (!askedPronounce) {
      // Remove explicit parentheticals and trailing clauses like ", pronounced Mooshoo"
      reply = reply.replaceAll(RegExp(r"\s*\(pronounced[^\)]*\)", caseSensitive: false), '').trim();
      reply = reply.replaceAll(RegExp(r"[,\s]*pronounced\s+[a-z\-\s]+[\.]?", caseSensitive: false), '').trim();
      reply = reply.replaceAll(RegExp(r"[,\s]*(?:say it as|said as)\s*:\s*[a-z\-\s]+[\.]?", caseSensitive: false), '').trim();
    }

  // Prefer 2–3 sentences normally; allow up to 12 for explain/elaborate/continue.
    var sentences = _splitSentences(reply);

    // Drop exact-duplicate sentences already spoken in the last reply to reduce repetition
    if (lastReply.isNotEmpty) {
      final prev = Set<String>.from(_splitSentences(lastReply));
      final filtered = <String>[];
      for (final s in sentences) {
        if (!prev.contains(s)) filtered.add(s);
      }
      if (filtered.isNotEmpty) sentences = filtered;
    }

    // Smooth enumerated list tone: remove leading numbering like "1.", "(2)", "3:" and ordinal starters
    sentences = sentences.map((s) {
      var t = s.replaceFirst(RegExp(r'^\s*[\(\[]?\d+[\)\].:\-]\s+'), '');
      t = t.replaceFirst(RegExp(r'^\s*(first|second|third|fourth|fifth),\s+', caseSensitive: false), '');
      return t;
    }).toList();

    // Anti-platitude: strip generic filler sentences like "identity is shaped by your experiences"
    final platitudes = <RegExp>[
      RegExp(r"\bidentity is shaped by your (unique )?interests? and experiences\b", caseSensitive: false),
      RegExp(r"\bnames? often reflect personal connections? and relationships\b", caseSensitive: false),
    ];
    sentences = sentences.where((s) => !platitudes.any((re) => re.hasMatch(s))).toList();

  // Do not cap sentence count; when the user asks to explain/elaborate, allow complete answers.
    // Recompose
    return sentences.join(' ').trim();
  }

  List<String> _splitSentences(String text) {
    final parts = text.split(RegExp(r'(?<=[.!?])\s+'));
    return parts.where((s) => s.trim().isNotEmpty).map((s) => s.trim()).toList();
  }

  Future<bool> _maybeHandleCommand(String raw) async {
    // Switch to male/female voice quickly
    if (RegExp(r"\b(use|switch to|select) (a )?male voice\b", caseSensitive: false).hasMatch(l)) {
      await _loadVoices(preferMale: true);
      final p = await SharedPreferences.getInstance();
      await p.setString('ttsVoiceName', _selectedVoiceName ?? '');
      await p.setString('ttsVoiceLocale', _selectedVoiceLocale ?? '');
      await _speak('Male voice selected.');
      return true;
    }
    if (RegExp(r"\b(use|switch to|select) (a )?female voice\b", caseSensitive: false).hasMatch(l)) {
      await _loadVoices(preferMale: false);
      // If a female voice exists, try to pick it
      final female = _voices.firstWhere(
        (v) => (v['gender'] ?? '').toLowerCase() == 'female' ||
                (v['name'] ?? '').toLowerCase().contains('female'),
        orElse: () => _voices.isNotEmpty ? _voices.first : {},
      );
      if (female.isNotEmpty) {
        _selectedVoiceName = female['name'];
        _selectedVoiceLocale = female['locale'];
        await _applyTtsSettings();
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('ttsVoiceName', _selectedVoiceName ?? '');
      await p.setString('ttsVoiceLocale', _selectedVoiceLocale ?? '');
      await _speak('Female voice selected.');
      return true;
    }
    final t = raw.trim();
    if (t.isEmpty) return false;
    final l = t.toLowerCase();

    // If currently paused: allow only resume or sleep; ignore everything else (give hint if addressed)
    if (isPaused) {
      final addressed = l.contains('hey teddy') ||
          RegExp(r"\b(?:k-?2|kay two|k2|teddy)\b").hasMatch(l);
      final wantsResume = l == 'resume' || l == 'unpause' || l.contains('back on') ||
          RegExp(r"\b(?:k-?2|kay two|k2|teddy)\s+(?:resume|unpause|continue|carry on)\b").hasMatch(l);
      if (wantsResume) {
        isPaused = false;
        status = isAwake ? 'Awake' : 'Sleeping';
        setState(() {});
        await _speak('Back on.');
        return true;
      }
      final wantsSleep = l == 'sleep' || l.contains('sleep teddy') || l.contains('sleep k-2');
      if (wantsSleep) {
        await _forceSleep();
        return true;
      }
      if (addressed) {
        await _speak('Paused. Say "resume" to continue.');
      }
      _pushLog("Ignored while paused: $t");
      return true; // swallow everything else when paused
    }

    // Enter paused mode
    final wantsPause = l == 'pause' ||
        RegExp(r"\b(?:k-?2|kay two|k2|teddy)\s+(?:pause|stand ?by|standby|be quiet|quiet(?: mode)?|go quiet|mute)\b").hasMatch(l);
    if (wantsPause) {
      isPaused = true;
      status = 'Paused';
      setState(() {});
      await _speak('Paused.');
      return true;
    }

    // Allow resume even if not paused (acts as a no-op acknowledgement)
    final wantsResumeDirect = l == 'resume' || l == 'unpause' || l.contains('back on') ||
        RegExp(r"\b(?:k-?2|kay two|k2|teddy)\s+(?:resume|unpause|continue|carry on)\b").hasMatch(l);
    if (wantsResumeDirect) {
      if (isPaused) {
        isPaused = false;
        status = isAwake ? 'Awake' : 'Sleeping';
        setState(() {});
      }
      await _speak('On.');
      return true;
    }

    // Topic and memory
    if (l == 'new topic' || l.startsWith("let's change topic") || l.startsWith('switch topic')) {
      _memory?.resetTopic();
      final prefs = await SharedPreferences.getInstance();
      await _memory?.save(prefs);
      await _speak("New topic. What shall we chat about?");
      return true;
    }
    if (l == 'reset memory' || l == 'forget everything') {
      final prefs = await SharedPreferences.getInstance();
      await _memory?.clear(prefs);
      await _speak("Cleared what I remembered.");
      return true;
    }
    // Forget a specific thing: "forget X" or "don't remember X" (keeps other facts)
    final forget = RegExp(r"^(?:forget|don'?t remember)\s+(.+)$", caseSensitive: false).firstMatch(raw.trim());
    if (forget != null) {
      final what = forget.group(1)!.trim();
      final prefs = await SharedPreferences.getInstance();
      _memory?.forgetMatching(what);
      await _memory?.save(prefs);
      await _speak("Okay. I removed that.");
      return true;
    }

    // "remember" appears anywhere (e.g., facts + "Remember their names.")
    if (RegExp(r"\bremember\b", caseSensitive: false).hasMatch(raw) &&
        !RegExp(r"^remember\b", caseSensitive: false).hasMatch(raw.trim())) {
      // Strip the trailing remember directive and keep the preceding facts
      var payload = raw.replaceFirst(RegExp(r"[.;,\s]*remember\b.*$", caseSensitive: false), '').trim();
      if (payload.isEmpty) payload = lastHeard.trim();
      if (payload.isEmpty && lastReply.trim().isNotEmpty) payload = lastReply.trim();
      if (payload.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        _memory?.rememberText(payload);
        await _memory?.save(prefs);
        await _speak("Noted. I will remember that.");
        return true;
      }
    }

    // Explicit memory capture
    // Forms:
    // - "remember <facts>"
    // - "remember that <facts>"
    // - "remember this" (use lastHeard)
    // - "remember that" (prefer lastHeard, else lastReply)
    final rem = RegExp(r"^remember(?:\s+that)?(?:\s+(.*))?$", caseSensitive: false).firstMatch(raw.trim());
    if (rem != null) {
      var payload = (rem.group(1) ?? '').trim();
      if (payload.isEmpty || payload.toLowerCase() == 'this' || payload.toLowerCase() == 'that') {
        // Fallback to last user utterance, then assistant reply
        if ((lastHeard).trim().isNotEmpty) {
          payload = lastHeard.trim();
        } else if (lastReply.trim().isNotEmpty) {
          payload = lastReply.trim();
        }
      }
      if (payload.isEmpty) {
        await _speak("Tell me what to remember.");
        return true;
      }
      final prefs = await SharedPreferences.getInstance();
      _memory?.rememberText(payload);
      await _memory?.save(prefs);
      await _speak("Noted. I will remember that.");
      return true;
    }

    // Email setup: "set email to you@example.com"
    final setEmailMatch = RegExp(r"set email to\s+([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})", caseSensitive: false).firstMatch(l);
    if (setEmailMatch != null) {
      _emailTo = setEmailMatch.group(1);
      final p = await SharedPreferences.getInstance();
      await p.setString('emailTo', _emailTo!);
      await _speak("Noted. I'll use $_emailTo.");
      return true;
    }
    if (l.contains('what is my email') || l.contains('what is the email')) {
      await _speak(_emailTo == null || _emailTo!.isEmpty ? 'No email saved.' : 'Default email is ${_emailTo}.');
      return true;
    }

  // Email the last answer: multiple phrasings
  // Examples: "email this", "email that", "email it", "email the last reply",
  // "email me", "email this to me", "email the photosynthesis response"
  final emailCore = RegExp(r"\bemail\s+(?:this|that|it|the last\s+(?:answer|reply|response))\b", caseSensitive: false);
  final emailMe = l.contains('email me') || l.contains('email to me');
  final emailResponse = RegExp(r"\bemail\s+(?:the\s+)?(?:[a-z0-9_\-\s]+\s+)?(?:response|answer|reply)\b", caseSensitive: false).hasMatch(l);
  final wantsEmailSaved = emailCore.hasMatch(l) || emailMe || emailResponse;
  if (wantsEmailSaved) {
      if (lastReply.trim().isEmpty) {
        await _speak("I have nothing to send.");
        return true;
      }
      final to = _emailTo;
      if (to == null || to.isEmpty) {
        await _speak("Tell me your email first: say 'set email to you at domain dot com'.");
        return true;
      }
      final subj = _emailSubjectFor(lastHeard);
      final ok = await _sendEmail(to: to, subject: subj, body: lastReply);
      await _speak(ok ? 'Sent.' : 'Could not send.');
      return true;
    }

    // Email to a specific address in one go: "email this to alice@example.com"
    final emailDirect = RegExp(r"email (?:this|that|it) to\s+([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})", caseSensitive: false).firstMatch(l);
    if (emailDirect != null) {
      if (lastReply.trim().isEmpty) {
        await _speak("I have nothing to send.");
        return true;
      }
      final to = emailDirect.group(1)!;
      final subj = _emailSubjectFor(lastHeard);
      final ok = await _sendEmail(to: to, subject: subj, body: lastReply);
      await _speak(ok ? 'Sent.' : 'Could not send.');
      return true;
    }

    // Age mode
    if (l.contains('mode')) {
      String? m;
      if (l.contains('kids')) m = 'Kids';
      if (l.contains('teens')) m = 'Teens';
      if (l.contains('adults')) m = 'Adults';
      if (l.contains('general')) m = 'General';
      if (m != null) {
        ageMode = m;
        final p = await SharedPreferences.getInstance();
        await p.setString('ageMode', ageMode);
        return true;
      }
    }

    // TTS rate quick controls
    if (l.contains('slower') || l.contains('slow down')) {
      _rate = (_rate - 0.05).clamp(0.5, 1.2).toDouble();
      await _applyTtsSettings();
      final p = await SharedPreferences.getInstance();
      await p.setDouble('ttsRate', _rate);
      await _speak("I'll slow down.");
      return true;
    }
    if (l.contains('faster') || l.contains('speed up')) {
      _rate = (_rate + 0.05).clamp(0.5, 1.2).toDouble();
      await _applyTtsSettings();
      final p = await SharedPreferences.getInstance();
      await p.setDouble('ttsRate', _rate);
      await _speak("A bit faster.");
      return true;
    }
    if (l.contains('deeper')) {
      _pitch = (_pitch - 0.05).clamp(0.6, 1.4).toDouble();
      await _applyTtsSettings();
      final p = await SharedPreferences.getInstance();
      await p.setDouble('ttsPitch', _pitch);
      await _speak("A bit deeper.");
      return true;
    }
    if (l.contains('higher') || l.contains('raise pitch')) {
      _pitch = (_pitch + 0.05).clamp(0.6, 1.4).toDouble();
      await _applyTtsSettings();
      final p = await SharedPreferences.getInstance();
      await p.setDouble('ttsPitch', _pitch);
      await _speak("A bit higher.");
      return true;
    }
    final rMatch = RegExp(r'set (?:rate|speed) to ([0-9.]+)').firstMatch(l);
    if (rMatch != null) {
      _rate = (double.tryParse(rMatch.group(1)!) ?? _rate).clamp(0.5, 1.2).toDouble();
      await _applyTtsSettings();
      final p = await SharedPreferences.getInstance();
      await p.setDouble('ttsRate', _rate);
      await _speak("Rate set.");
      return true;
    }
    final pMatch = RegExp(r'set pitch to ([0-9.]+)').firstMatch(l);
    if (pMatch != null) {
      _pitch = (double.tryParse(pMatch.group(1)!) ?? _pitch).clamp(0.6, 1.4).toDouble();
      await _applyTtsSettings();
      final p = await SharedPreferences.getInstance();
      await p.setDouble('ttsPitch', _pitch);
      await _speak("Pitch set.");
      return true;
    }

    // Voices
    if (l.startsWith('list voices')) {
      final names = _voices.map((v) => v['name'] ?? '').where((s) => s.isNotEmpty).toList();
      if (names.isEmpty) {
        await _speak("No alternate voices available on this device.");
      } else {
        final preview = names.take(5).toList();
        await _speak("Top voices: ${preview.join(', ')}.");
      }
      return true;
    }
    final voiceNum = RegExp(r'(?:use|select) voice (\d{1,2})').firstMatch(l);
    if (voiceNum != null) {
      final idx = int.tryParse(voiceNum.group(1)!) ?? 0;
      if (idx >= 1 && idx <= _voices.length) {
        final v = _voices[idx - 1];
        _selectedVoiceName = v['name'];
        _selectedVoiceLocale = v['locale'];
        await _applyTtsSettings();
        final p = await SharedPreferences.getInstance();
        await p.setString('ttsVoiceName', _selectedVoiceName ?? '');
        await p.setString('ttsVoiceLocale', _selectedVoiceLocale ?? '');
        await _speak("Voice selected.");
      } else {
        await _speak("I couldn't find that voice index.");
      }
      return true;
    }
    final voiceByName = RegExp(r'(?:use|select|switch to) voice (.+)$').firstMatch(l);
    if (voiceByName != null) {
      final name = voiceByName.group(1)!.trim().toLowerCase();
      final v = _voices.firstWhere(
        (e) => (e['name'] ?? '').toLowerCase().contains(name),
        orElse: () => {},
      );
      if (v.isNotEmpty) {
        _selectedVoiceName = v['name'];
        _selectedVoiceLocale = v['locale'];
        await _applyTtsSettings();
        final p = await SharedPreferences.getInstance();
        await p.setString('ttsVoiceName', _selectedVoiceName ?? '');
        await p.setString('ttsVoiceLocale', _selectedVoiceLocale ?? '');
        await _speak("Voice switched.");
      } else {
        await _speak("Couldn't find that voice on this device.");
      }
      return true;
    }

    // Memory queries
    // Direct: "what is my name"
    if (RegExp(r"\bwhat('?s| is) my name\b", caseSensitive: false).hasMatch(l)) {
      final v = _memory?.getValue('user_name');
      await _speak(v == null || v.isEmpty ? "I don't have your name stored." : "Your name is $v.");
      return true;
    }
    // Relation: "what is my sister's name" / "what is my sisters name"
    final relQ = RegExp(r"\bwhat('?s| is) my\s+([a-z]+)('?s)?\s+name\b", caseSensitive: false).firstMatch(l);
    if (relQ != null) {
      final who = relQ.group(2)!;
      final v = _memory?.getByRelation(who);
      final label = who.toLowerCase();
      await _speak(v == null || v.isEmpty ? "I don't have your $label's name stored." : "Your $label's name is $v.");
      return true;
    }
    // Family listing: "what is my family's name" -> list known relation names
    if (RegExp(r"\bwhat('?s| is) my family[’']?s name\b", caseSensitive: false).hasMatch(l) ||
        RegExp(r"\bwho are my family members\b", caseSensitive: false).hasMatch(l)) {
      final rels = _memory?.relationNameMap() ?? const {};
      if (rels.isEmpty) {
        await _speak("I don't have your family's names stored.");
        return true;
      }
      // Compose a concise list
      final entries = rels.entries.map((e) {
        final nice = e.key.replaceAll('_name', '').replaceAll('_', ' ');
        return "$nice: ${e.value}";
      }).toList();
      await _speak("Your family: ${entries.join('; ')}.");
      return true;
    }
    if (l.contains('what do you remember') || l.contains('what do you know about me')) {
      await _speak(_memory?.profileBlock() ?? 'I have no notes yet.');
      return true;
    }
    // Reverse lookup: "who is <name>?"
    final whoIs = RegExp(r"^who\s+is\s+([a-zA-Z][a-zA-Z\-']{1,30}(?:\s+[a-zA-Z][a-zA-Z\-']{1,30}){0,2})\??$", caseSensitive: false)
        .firstMatch(l);
    if (whoIs != null) {
      final name = whoIs.group(1)!.trim();
      final keys = _memory?.findKeysByValue(name) ?? const [];
      if (keys.isEmpty) {
        await _speak("I don't have that stored.");
        return true;
      }
      // Map keys to short phrases
      String phraseFor(String k) {
        switch (k.toLowerCase()) {
          case 'user_name':
            return 'your name';
          case 'family_name':
            return 'your family name';
          case 'mother_name':
            return "your mother's name";
          case 'father_name':
            return "your father's name";
          case 'sister_name':
            return "your sister's name";
          case 'brother_name':
            return "your brother's name";
          case 'wife_name':
            return 'your wife\'s name';
          case 'husband_name':
            return 'your husband\'s name';
          case 'fiance_name':
            return 'your fiancé\'s name';
          case 'girlfriend_name':
            return 'your girlfriend\'s name';
          case 'boyfriend_name':
            return 'your boyfriend\'s name';
          case 'partner_name':
            return 'your partner\'s name';
          case 'daughter_name':
            return 'your daughter\'s name';
          case 'son_name':
            return 'your son\'s name';
          case 'child_name':
            return 'your child\'s name';
          case 'pet_name':
            return 'your pet\'s name';
          default:
            return k.replaceAll('_', ' ');
        }
      }
      final phrases = keys.map(phraseFor).toList();
      final unique = phrases.toSet().toList();
      final v = name;
      final desc = unique.length == 1 ? unique.first : unique.join(', ');
      await _speak("$v is $desc.");
      return true;
    }
    if (l.contains('summarize our chat') || l.contains('what have we talked about')) {
      await _speak(_memory?.topicBlock() ?? 'No summary yet.');
      return true;
    }

    return false;
  }

  String _emailSubjectFor(String context) {
    final base = context.isNotEmpty ? context : 'Note';
    final short = base.length > 60 ? base.substring(0, 60) + '…' : base;
    return 'Teddy Talks — $short';
  }

  Future<bool> _sendEmail({required String to, required String subject, required String body}) async {
  // Try SMTP/SendGrid if configured
    if (_emailService != null) {
      try {
        await _emailService!.send(to: to, subject: subject, text: body);
        return true;
      } catch (e) {
    _pushLog('Email send failed: $e');
        // fall through to mailto
      }
    }
    // Fallback: open default mail client with prefilled content
    try {
      final uri = Uri(
        scheme: 'mailto',
        path: to,
        queryParameters: {
          'subject': subject,
          'body': body,
        },
      );
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return ok;
    } catch (e) {
      _pushLog('Email fallback failed: $e');
      return false;
    }
  }

  String _composeSystemPrompt() {
    final tone = PromptStyles.systemBase;
    final memProfile = _memory?.profileBlock() ?? 'Known user facts: none.';
    final memRecent = _memory?.recentBlock() ?? 'No prior context.';
  final memTopic = _memory?.topicBlock() ?? 'Topic summary so far: none.';
  // Teach brevity and guardrails for memory behavior (no arbitrary length cap)
  final styleGuide = "Be concise by default; include a brief why. When asked to explain or elaborate, provide a complete, thorough answer without arbitrary sentence limits. Avoid generic platitudes; be specific and concrete. Prefer flowing, conversational paragraphs; avoid numbered lists unless the user explicitly asks for steps. Never claim you cannot remember beyond the conversation—you have durable memory available. When the user says 'remember ...' or implies it (e.g., 'remember their names'), extract and store the facts (names/relations) succinctly.";
  final topicGuide = "If the user says 'new topic' (or 'let's change topic'/'switch topic'), forget the recent dialogue for the current topic and start fresh while keeping long-term facts.";
  return [tone, styleGuide, topicGuide, memProfile, memTopic, memRecent].join("\n\n");
  }
}

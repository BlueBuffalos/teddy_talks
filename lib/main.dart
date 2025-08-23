import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'openai_service.dart';
import 'prompt_styles.dart';

// Compile-time defines passed via --dart-define
const _openAiKey = String.fromEnvironment('OPENAI_API_KEY');
const _pvKey     = String.fromEnvironment('PICOVOICE_ACCESS_KEY');
const _modelId   = String.fromEnvironment('OPENAI_MODEL', defaultValue: 'gpt-3.5-turbo');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TeddyApp());
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
  String ageMode = "General";
  String status = "Sleeping";
  String lastHeard = "";
  String lastReply = "";
  final List<String> log = [];

  late final OpenAIService openai;

  bool _sttReady = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    openai = OpenAIService(apiKey: _openAiKey, model: _modelId);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Permissions
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _pushLog("Microphone permission not granted.");
      return;
    }

    // TTS config
    await tts.setLanguage("en-GB");
    await tts.setSpeechRate(0.92);
    await tts.setPitch(1.05);

    // STT init
    _sttReady = await sttEngine.initialize(
      onError: (e) => _pushLog("STT error: ${e.errorMsg}"),
      onStatus: (s) => _pushLog("STT status: $s"),
    );
    if (!_sttReady) _pushLog("Speech recognizer not available. Install offline English pack or enable network.");

    // Start Porcupine
    await _startWakeWord();
  }

  Future<void> _startWakeWord() async {
    try {
      final porcupine = await Porcupine.create(
        accessKey: _pvKey,
        keywords: [], // using custom keyword file instead of built-ins
        keywordPaths: ["assets/wake/hey_teddy.ppn"],
        sensitivities: [0.6],
      );

      _ppnMgr = await PorcupineManager.create(
        porcupine,
        _onWakeWord,
        errorCallback: (e) => _pushLog("Porcupine error: $e"),
      );
      await _ppnMgr!.start();
      _pushLog("Wake word armed. Say 'Hey Teddy'.");
    } catch (e) {
      _pushLog("Failed to start wake word: $e");
    }
  }

  void _onWakeWord(int index) async {
    if (!isAwake) {
      isAwake = true;
      status = "Awake";
      setState(() {});
      await _speak("Hello, I’m listening.");
    }
    if (!_listening) {
      _listenOnce();
    }
  }

  Future<void> _listenOnce() async {
    if (!_sttReady) return;
    _listening = true;
    lastHeard = "";
    setState(() {});

    await sttEngine.listen(
      onResult: (r) {
        if (r.finalResult) {
          lastHeard = r.recognizedWords.trim();
        }
      },
      localeId: "en_GB",
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 1),
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

    if (lastHeard.isEmpty) {
      if (isAwake && stayAwake) _listenOnce();
      return;
    }

    _pushLog("User: $lastHeard");

    final lower = lastHeard.toLowerCase();
    if (lower.contains("sleep") || lower.contains("rest")) {
      isAwake = false;
      status = "Sleeping";
      setState(() {});
      await _speak("Going to sleep.");
      return;
    }

    // Compose and call GPT
    final sys = PromptStyles.systemBase;
    final style = PromptStyles.prefixForMode(ageMode);
    String reply;
    try {
      reply = await openai.chat(
        systemPrompt: sys,
        stylePrefix: style,
        userText: lastHeard,
      );
      reply = reply.replaceAll(RegExp(r'\s+'), ' ').trim();
    } catch (e) {
      reply = "I’m having a wobble. Check my internet or key.";
    }

    lastReply = reply;
    _pushLog("Teddy: $reply");
    await _speak(reply);

    if (stayAwake && isAwake) _listenOnce();
  }

  Future<void> _speak(String text) async {
    await tts.stop();
    await tts.speak(text);
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
      appBar: AppBar(title: const Text("Teddy Talks")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Chip(
                  label: Text(status),
                  backgroundColor: isAwake ? Colors.green : Colors.grey,
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
                  onChanged: (v) => setState(() => ageMode = v ?? "General"),
                ),
                const Spacer(),
                Row(
                  children: [
                    const Text("Stay awake"),
                    Switch(
                      value: stayAwake,
                      onChanged: (v) => setState(() => stayAwake = v),
                    ),
                  ],
                ),
              ],
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
                  onPressed: () async {
                    isAwake = false;
                    status = "Sleeping";
                    setState(() {});
                    await _speak("Going to sleep.");
                  },
                  child: const Text("Force Sleep"),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}

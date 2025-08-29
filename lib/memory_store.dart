import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class MemoryStore {
  static const _kProfile = 'mem_profile_v2';
  static const _kRecent = 'mem_recent_v2';
  static const _kTopicSummary = 'mem_topic_summary_v2';
  static const _maxRecent = 10; // keep last 10 turns

  String profile; // concise facts about the user
  final List<Map<String, String>> recent; // [{u: user, t: teddy}]
  String topicSummary; // rolling summary of current topic

  MemoryStore({required this.profile, required this.recent, required this.topicSummary});

  static Future<MemoryStore> load(SharedPreferences prefs) async {
    // Try persistent file first
    final fileData = await _loadFromFile();
    String prof = fileData['profile'] ?? '';
    String topic = fileData['topicSummary'] ?? '';
    String? recentStr = fileData['recent'];

    // Fallback to SharedPreferences if file not present
    if (fileData.isEmpty) {
      prof = prefs.getString(_kProfile) ?? '';
      topic = prefs.getString(_kTopicSummary) ?? '';
      recentStr = prefs.getString(_kRecent);
    }
    List<Map<String, String>> recent = [];
    if (recentStr != null && recentStr.isNotEmpty) {
      try {
        final l = jsonDecode(recentStr) as List;
        recent = l
            .map((e) => {
                  'u': (e['u'] ?? '').toString(),
                  't': (e['t'] ?? '').toString(),
                })
            .toList();
      } catch (_) {}
    }
  final store = MemoryStore(profile: prof, recent: recent, topicSummary: topic);
  store._migrateLegacyFacts();
  // Sync back to file so future loads are file-first
  await store._saveToFile();
  return store;
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(_kProfile, profile);
    await prefs.setString(_kRecent, jsonEncode(recent));
    await prefs.setString(_kTopicSummary, topicSummary);
  await _saveToFile();
  }

  Future<void> clear(SharedPreferences prefs) async {
    profile = '';
    topicSummary = '';
    recent.clear();
    await save(prefs);
  }

  void addExchange(String user, String teddy) {
    if (user.trim().isEmpty && teddy.trim().isEmpty) return;
    recent.add({'u': user.trim(), 't': teddy.trim()});
    if (recent.length > _maxRecent) {
      recent.removeAt(0);
    }
  }

  bool needsSummary() => recent.length >= _maxRecent;

  void appendSummary(String s) {
    if (s.trim().isEmpty) return;
    topicSummary = topicSummary.isEmpty ? s.trim() : "$topicSummary\n$s";
  }

  void resetTopic() {
    recent.clear();
    topicSummary = '';
  }

  // Explicit memory capture: accept raw sentences and try to convert to durable facts.
  void rememberText(String raw) {
    if (raw.trim().isEmpty) return;
    final additions = <String>[];

    // Split on common separators while keeping names intact
    final parts = raw
        .split(RegExp(r"[\.;\n]|\band\b", caseSensitive: false))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    for (final p in parts) {
      final l = p.toLowerCase();

  // Keyed relations: supports straight and curly apostrophes: ' or ’
  final relA = RegExp(r"my\s+([a-z]+)[’']?s\s+name\s+is\s+([A-Za-z][A-Za-z\-']{1,30})", caseSensitive: false)
          .firstMatch(p);
      if (relA != null) {
        final who = relA.group(1)!;
        final proper = _properCase(relA.group(2)!.trim());
        final key = _relationKey(who);
        additions.add("$key=$proper");
        continue;
      }

      // Variants: "my sister is Daniela" / "my sister named|called Daniela" / "my sister name is Daniela" (missing apostrophe)
  final relB = RegExp(r"my\s+([A-Za-z]+)\s+(?:is|named|called|name\s+is)\s+([A-Za-z][A-Za-z\-']{1,30})", caseSensitive: false)
          .firstMatch(p);
      if (relB != null) {
        final who = relB.group(1)!;
        final proper = _properCase(relB.group(2)!.trim());
        final key = _relationKey(who);
        additions.add("$key=$proper");
        continue;
      }

      // User own name
  final name = RegExp(r"\bmy name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,2})\b", caseSensitive: false).firstMatch(p)?.group(1);
      if (name != null) {
        additions.add("user_name=${_properCase(name)}");
        continue;
      }

      // Family/surname variants
  final fam1 = RegExp(r"\bmy family[’']?s name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})\b", caseSensitive: false)
          .firstMatch(p);
      if (fam1 != null) {
        additions.add("family_name=${_properCaseWords(fam1.group(1)!.trim())}");
        continue;
      }
      final fam2 = RegExp(r"\bmy family name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})\b", caseSensitive: false)
          .firstMatch(p);
      if (fam2 != null) {
        additions.add("family_name=${_properCaseWords(fam2.group(1)!.trim())}");
        continue;
      }
      final fam3 = RegExp(r"\bour family name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})\b", caseSensitive: false)
          .firstMatch(p);
      if (fam3 != null) {
        additions.add("family_name=${_properCaseWords(fam3.group(1)!.trim())}");
        continue;
      }
      final surname = RegExp(r"\bmy (?:surname|last name) is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})\b", caseSensitive: false)
          .firstMatch(p);
      if (surname != null) {
        additions.add("family_name=${_properCaseWords(surname.group(1)!.trim())}");
        continue;
      }

      // Fallback: store note
      additions.add("note:${p}");
    }

    if (additions.isEmpty) return;
    for (final f in additions) {
      final i = f.indexOf('=');
      if (i > 0) {
        final k = f.substring(0, i).trim();
        final v = f.substring(i + 1).trim();
        _upsert(k, v);
      } else {
        _appendIfMissing(f);
      }
    }
  }

  String _relationKey(String who) {
    switch (who.toLowerCase()) {
      case 'mom':
      case 'mother':
        return 'mother_name';
      case 'dad':
      case 'father':
        return 'father_name';
      case 'sister':
        return 'sister_name';
      case 'brother':
        return 'brother_name';
      case 'girlfriend':
        return 'girlfriend_name';
      case 'boyfriend':
        return 'boyfriend_name';
      case 'partner':
        return 'partner_name';
      case 'fiancee':
      case 'fiancé':
      case 'fiance':
        return 'fiance_name';
      case 'wife':
        return 'wife_name';
      case 'husband':
        return 'husband_name';
      case 'daughter':
        return 'daughter_name';
      case 'son':
        return 'son_name';
      case 'child':
      case 'kid':
      case 'kids':
        return 'child_name';
    }
    return '${who}_name';
  }

  // Heuristics to capture simple facts without extra model calls
  void maybeCaptureFact(String utterance) {
    final u = utterance.toLowerCase();
    final facts = <String>[];
  // Family name / surname
  final famM = RegExp(r"\bmy family'?s name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})\b", caseSensitive: false)
    .firstMatch(utterance);
  final famM2 = RegExp(r"\b(?:my|our) family name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})\b", caseSensitive: false)
    .firstMatch(utterance);
  final famM3 = RegExp(r"\bmy (?:surname|last name) is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})\b", caseSensitive: false)
    .firstMatch(utterance);
  final famVal = famM?.group(1) ?? famM2?.group(1) ?? famM3?.group(1);
  if (famVal != null) facts.add("family_name=${famVal.trim()}");


    // Capture "my name is X" allowing trailing punctuation/phrases
    final nameMatch = RegExp(r"\bmy name is\s+([A-Za-z][A-Za-z\-']{1,30})", caseSensitive: false)
        .firstMatch(utterance);
    if (nameMatch != null) {
      final rawName = nameMatch.group(1)!.trim();
      facts.add("user_name=${_properCase(rawName)}");
    }

    final age = RegExp(r"\bi(?: am|'m)\s+(\d{1,2})\s+years?\s+old\b").firstMatch(u)?.group(1);
    if (age != null) facts.add("age=$age");

  final cityMatch = RegExp(r"\b(?:i live in|i'm from)\s+([A-Za-z\-\s]{2,40})\b", caseSensitive: false)
    .firstMatch(utterance);
  if (cityMatch != null) facts.add("city=${cityMatch.group(1)!.trim()}");

    final pet = RegExp(r"\bi have a\s+(dog|cat|pet)\s+(?:named\s+)?([a-zA-Z][a-zA-Z\-']{1,30})?\b").firstMatch(utterance);
    if (pet != null) {
      final kind = (pet.group(1) ?? '').toLowerCase();
      final pname = pet.group(2);
      if (pname != null && pname.trim().isNotEmpty) {
        _upsert('pet_name', _properCase(pname.trim()));
      }
      if (kind == 'dog' || kind == 'cat' || kind == 'pet') {
        _upsert('pet_kind', kind);
      }
    }

  final likeMatch = RegExp(r"\bi (?:really\s+)?like\s+([^,.!]+)", caseSensitive: false)
    .firstMatch(utterance);
  if (likeMatch != null) facts.add("likes=${likeMatch.group(1)!.trim()}");

  final roleMatch = RegExp(r"\bi (?:am|'m) a[n]?\s+([A-Za-z\-\s]{2,30})\b", caseSensitive: false)
    .firstMatch(utterance);
  if (roleMatch != null) facts.add("role=${roleMatch.group(1)!.trim()}");

    if (facts.isNotEmpty) {
      for (final f in facts) {
        final kv = f.split('=');
        if (kv.length == 2) {
          _upsert(kv[0], kv[1]);
        } else {
          _appendIfMissing(f);
        }
      }
    }
  }

  // Capture facts the assistant asserted (e.g., names it answered with)
  void maybeCaptureFromAssistant(String reply) {
    final r = reply.toLowerCase();
    final facts = <String>[];

    // Dog/cat name patterns like: "Your dog's name is Mushu (pronounced Mooshoo)."
  final petName = RegExp(r"your (?:dog|cat|pet)[’']?s name is\s+([a-zA-Z][a-zA-Z\-']{1,30})").firstMatch(r)?.group(1);
    if (petName != null) {
      // Only capture if we don't already have a pet_name
      if (!_hasKey('pet_name')) {
        facts.add("pet_name=${_properCase(petName)}");
      }
    }

    // If assistant echoes user name
  final youAre = RegExp(r"\byour name is\s+([A-Za-z][A-Za-z\-']{1,30})\b", caseSensitive: false)
    .firstMatch(reply)
    ?.group(1);
  if (youAre != null) facts.add("user_name=${_properCase(youAre)}");

    // Relation names echoed by assistant: "Your sister's name is Daniela."
  final rel = RegExp(r"your\s+([a-z]+)[’']?s\s+name\s+is\s+([A-Za-z][A-Za-z\-']{1,30})", caseSensitive: false)
        .firstMatch(reply);
    if (rel != null) {
      final who = rel.group(1)!;
      final nm = _properCase(rel.group(2)!.trim());
      facts.add("${_relationKey(who)}=$nm");
    }

  // Family name echoed by assistant
  final fam = RegExp(r"your family'?s name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})", caseSensitive: false)
    .firstMatch(reply);
  final fam2 = RegExp(r"your family name is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})", caseSensitive: false)
    .firstMatch(reply);
  final fam3 = RegExp(r"your (?:surname|last name) is\s+([A-Za-z][A-Za-z\-']{1,30}(?:\s+[A-Za-z][A-Za-z\-']{1,30}){0,3})", caseSensitive: false)
    .firstMatch(reply);
  final famVal = fam?.group(1) ?? fam2?.group(1) ?? fam3?.group(1);
  if (famVal != null) facts.add("family_name=${_properCaseWords(famVal.trim())}");

    if (facts.isEmpty) return;
    for (final f in facts) {
      final kv = f.split('=');
      if (kv.length == 2) {
        _upsert(kv[0], kv[1]);
      } else {
        _appendIfMissing(f);
      }
    }
  }

  // Public getters
  String? getValue(String key) {
    if (profile.isEmpty) return null;
    final items = profile.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
    for (final it in items) {
      final i = it.indexOf('=');
      if (i > 0) {
        final k = it.substring(0, i).trim();
        if (k.toLowerCase() == key.toLowerCase()) {
          return it.substring(i + 1).trim();
        }
      }
    }
    return null;
  }

  String? getByRelation(String who) {
    final key = _relationKey(who);
    return getValue(key);
  }

  // Reverse lookup: find keys whose value equals the provided name (case-insensitive)
  List<String> findKeysByValue(String value) {
    final needle = value.trim().toLowerCase();
    if (needle.isEmpty || profile.isEmpty) return const [];
    final out = <String>[];
    final items = profile.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
    for (final it in items) {
      final i = it.indexOf('=');
      if (i > 0) {
        final k = it.substring(0, i).trim();
        final v = it.substring(i + 1).trim();
        if (v.toLowerCase() == needle) {
          out.add(k);
        }
      }
    }
    return out;
  }

  // Return all stored relation names (mother_name, sister_name, etc.)
  Map<String, String> relationNameMap() {
    final out = <String, String>{};
    if (profile.isEmpty) return out;
    final allow = <String>{
      'mother_name', 'father_name', 'sister_name', 'brother_name',
      'wife_name', 'husband_name', 'fiance_name', 'girlfriend_name', 'boyfriend_name', 'partner_name',
      'daughter_name', 'son_name', 'child_name',
      // grandparents (optional common)
      'grandmother_name', 'grandfather_name', 'grandma_name', 'grandpa_name'
    };
    final items = profile.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
    for (final it in items) {
      final i = it.indexOf('=');
      if (i > 0) {
        final k = it.substring(0, i).trim();
        final v = it.substring(i + 1).trim();
        if (allow.contains(k.toLowerCase())) {
          out[k] = v;
        }
      }
    }
    return out;
  }

  String profileBlock() {
    return profile.isEmpty
        ? "Known user facts: none."
        : "Known user facts: $profile.";
  }

  String recentBlock() {
    if (recent.isEmpty) return "No prior context.";
    final lines = recent
        .map((e) => "User: ${e['u']}\nTeddy: ${e['t']}")
        .join("\n");
    return "Recent dialogue (most recent last):\n$lines";
  }

  String topicBlock() {
    return topicSummary.isEmpty
        ? "Topic summary so far: none."
        : "Topic summary so far:\n$topicSummary";
  }

  // Remove facts matching a phrase (case-insensitive). Keeps other facts.
  void forgetMatching(String phrase) {
    final q = phrase.trim().toLowerCase();
    if (q.isEmpty || profile.isEmpty) return;
    final items = profile.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final kept = items.where((it) => !it.toLowerCase().contains(q)).toList();
    profile = kept.join('; ');
  }

  // ===== File persistence helpers =====
  static Future<Map<String, String>> _loadFromFile() async {
    try {
      final file = await _memoryFile();
      if (file == null || !await file.exists()) return {};
      final content = await file.readAsString();
      final m = jsonDecode(content) as Map<String, dynamic>;
      return {
        'profile': (m['profile'] ?? '').toString(),
        'recent': jsonEncode(m['recent'] ?? const []),
        'topicSummary': (m['topicSummary'] ?? '').toString(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveToFile() async {
    try {
      final file = await _memoryFile();
      if (file == null) return;
      final m = {
        'profile': profile,
        'recent': recent,
        'topicSummary': topicSummary,
      };
      await file.writeAsString(jsonEncode(m));
    } catch (_) {
      // ignore file errors; prefs already saved
    }
  }

  static Future<File?> _memoryFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}memory.json');
      return f;
    } catch (_) {
      return null;
    }
  }

  // ===== Fact helpers =====
  bool _hasKey(String key) {
    final parts = profile.split(';').map((s) => s.trim());
    for (final p in parts) {
      final i = p.indexOf('=');
      if (i > 0 && p.substring(0, i).trim().toLowerCase() == key.toLowerCase()) return true;
    }
    return false;
  }

  void _appendIfMissing(String token) {
    if (token.trim().isEmpty) return;
    if (profile.isEmpty) {
      profile = token.trim();
      return;
    }
    if (!profile.toLowerCase().contains(token.trim().toLowerCase())) {
      profile = "$profile; ${token.trim()}";
    }
  }

  void _upsert(String key, String value) {
    final k = key.trim();
    final v = value.trim();
    if (k.isEmpty || v.isEmpty) return;
    // normalize legacy keys that conflict
    final synonyms = <String>{k};
    if (k == 'pet_name') synonyms.addAll({'pet', 'dog_name', 'cat_name'});
    if (k == 'mother_name') synonyms.addAll({'mom_name'});
    if (k == 'father_name') synonyms.addAll({'dad_name'});

    final items = profile.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final kept = <String>[];
    for (final it in items) {
      final i = it.indexOf('=');
      if (i > 0) {
        final keyPart = it.substring(0, i).trim().toLowerCase();
        if (synonyms.contains(keyPart)) continue; // drop old value for this key family
      }
      // migrate legacy pet=dog:Name -> pet_kind=dog; pet_name=Name
      if (it.toLowerCase().startsWith('pet=')) continue;
      kept.add(it);
    }
    kept.add("$k=$v");
    profile = kept.join('; ');
  }

  void _migrateLegacyFacts() {
    if (profile.isEmpty) return;
    final items = profile.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    String petKind = '';
    String petName = '';
    final kept = <String>[];
    for (final it in items) {
      final m = RegExp(r"^pet=([a-zA-Z]+):([A-Za-z\-']+)$", caseSensitive: false).firstMatch(it);
      if (m != null) {
        petKind = (m.group(1) ?? '').toLowerCase();
        petName = _properCase(m.group(2) ?? '');
        continue; // skip legacy token
      }
      kept.add(it);
    }
    if (petKind.isNotEmpty) kept.add('pet_kind=$petKind');
    if (petName.isNotEmpty && !_hasKey('pet_name')) kept.add('pet_name=$petName');
    profile = kept.join('; ');
  }

  String _properCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + (s.length > 1 ? s.substring(1) : '');
  }

  String _properCaseWords(String s) {
    if (s.trim().isEmpty) return s;
    return s
        .split(RegExp(r"\s+"))
        .map((w) => _properCase(w))
        .join(' ');
  }
}

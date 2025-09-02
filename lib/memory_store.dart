import 'package:shared_preferences/shared_preferences.dart';

class MemoryStore {
  final List<Map<String, String>> _exchanges = [];
  final Map<String, String> _facts = {};
  final List<String> _summaries = [];
  String _currentTopic = '';
  
  static Future<MemoryStore> load(SharedPreferences prefs) async {
    final store = MemoryStore();
    
    // Load persisted data from SharedPreferences
    final exchangesJson = prefs.getStringList('memory_exchanges') ?? [];
    for (final json in exchangesJson) {
      final parts = json.split('|||');
      if (parts.length == 2) {
        store._exchanges.add({
          'user': parts[0],
          'assistant': parts[1],
        });
      }
    }
    
    final factsKeys = prefs.getStringList('memory_facts_keys') ?? [];
    final factsValues = prefs.getStringList('memory_facts_values') ?? [];
    for (int i = 0; i < factsKeys.length && i < factsValues.length; i++) {
      store._facts[factsKeys[i]] = factsValues[i];
    }
    
    store._summaries.addAll(prefs.getStringList('memory_summaries') ?? []);
    store._currentTopic = prefs.getString('memory_current_topic') ?? '';
    
    return store;
  }
  
  Future<void> save(SharedPreferences prefs) async {
    // Save exchanges
    final exchangesJson = _exchanges.map((e) => '${e['user']}|||${e['assistant']}').toList();
    await prefs.setStringList('memory_exchanges', exchangesJson);
    
    // Save facts
    await prefs.setStringList('memory_facts_keys', _facts.keys.toList());
    await prefs.setStringList('memory_facts_values', _facts.values.toList());
    
    // Save summaries and topic
    await prefs.setStringList('memory_summaries', _summaries);
    await prefs.setString('memory_current_topic', _currentTopic);
  }
  
  Future<void> clear(SharedPreferences prefs) async {
    _exchanges.clear();
    _facts.clear();
    _summaries.clear();
    _currentTopic = '';
    
    await prefs.remove('memory_exchanges');
    await prefs.remove('memory_facts_keys');
    await prefs.remove('memory_facts_values');
    await prefs.remove('memory_summaries');
    await prefs.remove('memory_current_topic');
  }
  
  void resetTopic() {
    _currentTopic = '';
    _exchanges.clear();
    _summaries.clear();
  }
  
  void addExchange(String userText, String assistantReply) {
    _exchanges.add({
      'user': userText,
      'assistant': assistantReply,
    });
    
    // Keep only recent exchanges to prevent memory bloat
    if (_exchanges.length > 20) {
      _exchanges.removeAt(0);
    }
  }
  
  void maybeCaptureFact(String text) {
    // Simple fact extraction - look for patterns like "my name is X"
    final nameMatch = RegExp(r'(?:my name is|i am|i\'m|call me)\s+(\w+)', caseSensitive: false).firstMatch(text);
    if (nameMatch != null) {
      final name = nameMatch.group(1);
      if (name != null) {
        _facts['user_name'] = name;
      }
    }
    
    // Look for other personal information patterns
    final ageMatch = RegExp(r'i am (\d+)(?:\s+years?\s+old)?', caseSensitive: false).firstMatch(text);
    if (ageMatch != null) {
      final age = ageMatch.group(1);
      if (age != null) {
        _facts['user_age'] = age;
      }
    }
  }
  
  void maybeCaptureFromAssistant(String reply) {
    // Could extract information the assistant learned about the user
    // For now, this is a placeholder
  }
  
  bool needsSummary() {
    // Return true if we have 10 or more exchanges without a recent summary
    return _exchanges.length >= 10;
  }
  
  String recentBlock() {
    if (_exchanges.isEmpty) return '';
    
    final recent = _exchanges.take(10).map((e) => 
      'User: ${e['user']}\nAssistant: ${e['assistant']}'
    ).join('\n');
    
    return recent;
  }
  
  void appendSummary(String summary) {
    _summaries.add(summary);
    // Keep only recent summaries
    if (_summaries.length > 5) {
      _summaries.removeAt(0);
    }
  }
  
  void forgetMatching(String pattern) {
    _facts.removeWhere((key, value) => 
      key.toLowerCase().contains(pattern.toLowerCase()) || 
      value.toLowerCase().contains(pattern.toLowerCase())
    );
  }
  
  void rememberText(String text) {
    // Store arbitrary text as a fact with timestamp
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    _facts['note_$timestamp'] = text;
  }
  
  String? getValue(String key) {
    return _facts[key];
  }
  
  List<String> getByRelation(String relation) {
    // Return values that might be related to the given relation
    final results = <String>[];
    _facts.forEach((key, value) {
      if (key.toLowerCase().contains(relation.toLowerCase()) || 
          value.toLowerCase().contains(relation.toLowerCase())) {
        results.add(value);
      }
    });
    return results;
  }
  
  Map<String, String> relationNameMap() {
    // Return a map of relationship names to values
    final relations = <String, String>{};
    _facts.forEach((key, value) {
      if (key.contains('_')) {
        final relation = key.split('_')[0];
        relations[relation] = value;
      }
    });
    return relations;
  }
  
  String profileBlock() {
    if (_facts.isEmpty) return 'Known user facts: none.';
    
    final profile = _facts.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    return 'Known user facts:\n$profile';
  }
  
  List<String> findKeysByValue(String value) {
    final keys = <String>[];
    _facts.forEach((key, val) {
      if (val.toLowerCase().contains(value.toLowerCase())) {
        keys.add(key);
      }
    });
    return keys;
  }
  
  String topicBlock() {
    if (_summaries.isEmpty) return 'Topic summary so far: none.';
    return 'Topic summary so far:\n${_summaries.join('\n')}';
  }
}
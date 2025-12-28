import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';

class StorageService {
  static const _tokenKey = 'github_token';
  static const _reposKey = 'repositories';
  static const _historyKey = 'operation_history';
  static const _settingsKey = 'settings';
  
  late SharedPreferences _prefs;
  
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }
  
  // ========== Token ==========
  
  String? getToken() => _prefs.getString(_tokenKey);
  
  Future<void> setToken(String token) async {
    await _prefs.setString(_tokenKey, token);
  }
  
  Future<void> clearToken() async {
    await _prefs.remove(_tokenKey);
  }
  
  // ========== 仓库 ==========
  
  List<Repository> getRepositories() {
    final json = _prefs.getString(_reposKey);
    if (json == null) return [];
    final list = jsonDecode(json) as List;
    return list.map((e) => Repository.fromJson(e)).toList();
  }
  
  Future<void> saveRepositories(List<Repository> repos) async {
    final json = jsonEncode(repos.map((e) => e.toJson()).toList());
    await _prefs.setString(_reposKey, json);
  }
  
  Future<void> addRepository(Repository repo) async {
    final repos = getRepositories();
    // 如果是第一个，设为默认
    if (repos.isEmpty) {
      repos.add(Repository(
        owner: repo.owner,
        name: repo.name,
        branch: repo.branch,
        isDefault: true,
      ));
    } else {
      repos.add(repo);
    }
    await saveRepositories(repos);
  }
  
  Future<void> removeRepository(String fullName) async {
    final repos = getRepositories();
    repos.removeWhere((r) => r.fullName == fullName);
    await saveRepositories(repos);
  }
  
  Future<void> setDefaultRepository(String fullName) async {
    final repos = getRepositories();
    for (var i = 0; i < repos.length; i++) {
      repos[i] = Repository(
        owner: repos[i].owner,
        name: repos[i].name,
        branch: repos[i].branch,
        isDefault: repos[i].fullName == fullName,
      );
    }
    await saveRepositories(repos);
  }
  
  Repository? getDefaultRepository() {
    final repos = getRepositories();
    try {
      return repos.firstWhere((r) => r.isDefault);
    } catch (_) {
      return repos.isNotEmpty ? repos.first : null;
    }
  }
  
  // ========== 历史记录 ==========
  
  List<OperationHistory> getHistory() {
    final json = _prefs.getString(_historyKey);
    if (json == null) return [];
    final list = jsonDecode(json) as List;
    return list.map((e) => OperationHistory.fromJson(e)).toList();
  }
  
  Future<void> addHistory(OperationHistory history) async {
    final list = getHistory();
    list.insert(0, history);
    // 只保留最近50条
    if (list.length > 50) {
      list.removeRange(50, list.length);
    }
    final json = jsonEncode(list.map((e) => e.toJson()).toList());
    await _prefs.setString(_historyKey, json);
  }
  
  Future<void> clearHistory() async {
    await _prefs.remove(_historyKey);
  }
  
  // ========== 设置 ==========
  
  Map<String, dynamic> getSettings() {
    final json = _prefs.getString(_settingsKey);
    if (json == null) {
      return {
        'fontSize': 14,
        'showLineNumbers': true,
        'darkMode': false,
      };
    }
    return jsonDecode(json);
  }
  
  Future<void> saveSettings(Map<String, dynamic> settings) async {
    await _prefs.setString(_settingsKey, jsonEncode(settings));
  }
}

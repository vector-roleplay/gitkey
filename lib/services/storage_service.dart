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
    try {
      final json = _prefs.getString(_historyKey);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List;
      return list.map((e) => OperationHistory.fromJson(e)).toList();
    } catch (e) {
      // 解析失败时返回空列表，避免崩溃
      return [];
    }
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
}// ========== 本地工作区 ==========
  
  static const _workspaceKey = 'workspace_files';
  static const _workspaceModeKey = 'workspace_mode';
  
  /// 获取工作区模式开关状态
  bool getWorkspaceMode() {
    return _prefs.getBool(_workspaceModeKey) ?? false;
  }
  
  /// 设置工作区模式开关
  Future<void> setWorkspaceMode(bool enabled) async {
    await _prefs.setBool(_workspaceModeKey, enabled);
  }
  
  /// 获取所有工作区文件
  List<WorkspaceFile> getWorkspaceFiles() {
    try {
      final json = _prefs.getString(_workspaceKey);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List;
      return list.map((e) => WorkspaceFile.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }
  
  /// 保存工作区文件列表
  Future<void> _saveWorkspaceFiles(List<WorkspaceFile> files) async {
    final json = jsonEncode(files.map((e) => e.toJson()).toList());
    await _prefs.setString(_workspaceKey, json);
  }
  
  /// 添加或更新工作区文件
  Future<void> addOrUpdateWorkspaceFile(WorkspaceFile file) async {
    final files = getWorkspaceFiles();
    final index = files.indexWhere((f) => f.path == file.path);
    if (index >= 0) {
      files[index] = file;
    } else {
      files.add(file);
    }
    await _saveWorkspaceFiles(files);
  }
  
  /// 批量添加工作区文件
  Future<void> addWorkspaceFiles(List<WorkspaceFile> newFiles) async {
    final files = getWorkspaceFiles();
    for (final newFile in newFiles) {
      final index = files.indexWhere((f) => f.path == newFile.path);
      if (index >= 0) {
        files[index] = newFile;
      } else {
        files.add(newFile);
      }
    }
    await _saveWorkspaceFiles(files);
  }
  
  /// 获取单个工作区文件
  WorkspaceFile? getWorkspaceFile(String path) {
    final files = getWorkspaceFiles();
    try {
      return files.firstWhere((f) => f.path == path);
    } catch (_) {
      return null;
    }
  }
  
  /// 删除工作区文件
  Future<void> removeWorkspaceFile(String path) async {
    final files = getWorkspaceFiles();
    files.removeWhere((f) => f.path == path);
    await _saveWorkspaceFiles(files);
  }
  
  /// 清空工作区
  Future<void> clearWorkspace() async {
    await _prefs.remove(_workspaceKey);
  }


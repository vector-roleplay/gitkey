import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'services/storage_service.dart';
import 'services/github_service.dart';
import 'services/parser_service.dart';
import 'screens/home_screen.dart';
import 'screens/parser_screen.dart';
import 'screens/editor_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/history_screen.dart';
import 'screens/build_screen.dart';

import 'models.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final storageService = StorageService();
  await storageService.init();
  
  final githubService = GitHubService();
  final token = storageService.getToken();
  if (token != null) {
    githubService.setToken(token);
  }
  
  // 加载工作区模式状态
  final workspaceMode = storageService.getWorkspaceMode();
  
  runApp(

    MultiProvider(
      providers: [
        Provider.value(value: storageService),
        Provider.value(value: githubService),
        Provider(create: (_) => ParserService()),
        Provider(create: (_) => CodeMerger()),
        Provider(create: (_) => DiffGenerator()),
        ChangeNotifierProvider(create: (_) => AppState()..setWorkspaceMode(workspaceMode)),
      ],
      child: const MyApp(),
    ),
  );
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Code Sync',
      debugShowCheckedModeBanner: false,
      
      // 本地化配置
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'CN'),
      
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/parser': (context) => const ParserScreen(),
        '/settings': (context) => const SettingsScreen(),
        '/history': (context) => const HistoryScreen(),
        '/build': (context) => const BuildScreen(),
      },
      onGenerateRoute:
 (settings) {
        if (settings.name == '/editor') {
          final filePath = settings.arguments as String;
          return MaterialPageRoute(
            builder: (context) => EditorScreen(filePath: filePath),
          );
        }
        return null;
      },
    );
  }
}

/// 全局状态管理
class AppState extends ChangeNotifier {
  Repository? _selectedRepo;
  final Map<String, FileChange> _fileChanges = {};
  bool _useWorkspaceMode = false;  // 是否使用本地工作区模式
  bool _targetIsWorkspace = false; // 推送目标是否为工作区
  
  // ========== 构建状态（全局保持，避免页面切换时闪烁） ==========
  int? _buildRunId;
  String? _buildStatus;          // queued, in_progress, completed
  String? _buildConclusion;      // success, failure, cancelled
  DateTime? _buildStartTime;     // 用于计时（与官网同步）
  String? _buildRepoFullName;    // 正在构建的仓库
  bool _isDownloading = false;
  double _downloadProgress = 0;
  String? _downloadedApkPath;
  Duration _clockOffset = Duration.zero;  // 本地时钟与服务器时钟的偏差
  
  int? get buildRunId => _buildRunId;
  String? get buildStatus => _buildStatus;
  String? get buildConclusion => _buildConclusion;
  DateTime? get buildStartTime => _buildStartTime;
  String? get buildRepoFullName => _buildRepoFullName;
  Duration get clockOffset => _clockOffset;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get downloadedApkPath => _downloadedApkPath;

  
  bool get hasBuildInProgress => _buildStatus == 'queued' || _buildStatus == 'in_progress';
  bool get isBuildSuccess => _buildStatus == 'completed' && _buildConclusion == 'success';
  bool get isBuildFailed => _buildStatus == 'completed' && _buildConclusion != 'success';
  
  void updateBuildState({
    int? runId,
    String? status,
    String? conclusion,
    DateTime? startTime,
    String? repoFullName,
  }) {
    _buildRunId = runId ?? _buildRunId;
    _buildStatus = status ?? _buildStatus;
    _buildConclusion = conclusion;
    _buildStartTime = startTime ?? _buildStartTime;
    _buildRepoFullName = repoFullName ?? _buildRepoFullName;
    notifyListeners();
  }
  
  /// 更新时钟偏差（用于与服务器时间同步）
  void updateClockOffset(DateTime serverTime) {
    _clockOffset = serverTime.difference(DateTime.now());
    // 不需要 notifyListeners，因为这只是校准值
  }
  
  /// 获取校准后的当前时间（与服务器同步）
  DateTime get calibratedNow => DateTime.now().add(_clockOffset);

  
  void updateDownloadState({bool? isDownloading, double? progress, String? apkPath}) {
    _isDownloading = isDownloading ?? _isDownloading;
    _downloadProgress = progress ?? _downloadProgress;
    _downloadedApkPath = apkPath ?? _downloadedApkPath;
    notifyListeners();
  }
  
  void clearBuildState() {
    _buildRunId = null;
    _buildStatus = null;
    _buildConclusion = null;
    _buildStartTime = null;
    _buildRepoFullName = null;
    _isDownloading = false;
    _downloadProgress = 0;
    _downloadedApkPath = null;
    _clockOffset = Duration.zero;
    notifyListeners();
  }

  
  Repository? get selectedRepo => _selectedRepo;
  bool get useWorkspaceMode => _useWorkspaceMode;
  bool get targetIsWorkspace => _targetIsWorkspace;


  List<FileChange> get fileChanges => _fileChanges.values.toList();
  int get selectedCount => _fileChanges.values.where((f) => f.isSelected).length;
  
  void setSelectedRepo(Repository? repo) {
    _selectedRepo = repo;
    notifyListeners();
  }void setWorkspaceMode(bool enabled) {
    _useWorkspaceMode = enabled;
    notifyListeners();
  }
  
  void setTargetIsWorkspace(bool isWorkspace) {
    _targetIsWorkspace = isWorkspace;
    notifyListeners();
  }

  
  void addFileChanges(List<FileChange> changes) {
    for (final change in changes) {
      _fileChanges[change.filePath] = change;
    }
    notifyListeners();
  }
  
  void updateFileChange(String filePath, FileChange change) {
    _fileChanges[filePath] = change;
    notifyListeners();
  }
  
  FileChange? getFileChange(String filePath) {
    return _fileChanges[filePath];
  }
  
  void toggleFileSelection(String filePath, bool selected) {
    final change = _fileChanges[filePath];
    if (change != null) {
      _fileChanges[filePath] = change.copyWith(isSelected: selected);
      notifyListeners();
    }
  }
  
  void selectAll() {
    for (final key in _fileChanges.keys) {
      _fileChanges[key] = _fileChanges[key]!.copyWith(isSelected: true);
    }
    notifyListeners();
  }
  
  void deselectAll() {
    for (final key in _fileChanges.keys) {
      _fileChanges[key] = _fileChanges[key]!.copyWith(isSelected: false);
    }
    notifyListeners();
  }
  
  void removeFileChange(String filePath) {
    _fileChanges.remove(filePath);
    notifyListeners();
  }
  
  void clearAll() {
    _fileChanges.clear();
    notifyListeners();
  }
  
  List<FileChange> getSelectedChanges() {
    return _fileChanges.values.where((f) => f.isSelected).toList();
  }
}
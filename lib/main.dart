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
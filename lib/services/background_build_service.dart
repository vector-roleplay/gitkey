import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 后台构建监控服务
class BackgroundBuildService {
  static final BackgroundBuildService instance = BackgroundBuildService._internal();
  BackgroundBuildService._internal();

  static const String _notificationChannelId = 'build_channel';
  static const String _notificationChannelName = '构建通知';
  static const int _buildNotificationId = 1001;
  static const int _downloadNotificationId = 1002;
  static const int _chronometerNotificationId = 1003;  // 计时器通知ID

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;

  /// 初始化通知
  Future<void> init() async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    
    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // 创建通知渠道
    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _notificationChannelId,
        _notificationChannelName,
        description: 'APK 构建进度通知',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );

    _isInitialized = true;
  }

  void _onNotificationTap(NotificationResponse response) {
    // 点击通知时的处理
  }

  /// 初始化前台任务
  void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _notificationChannelId,
        channelName: _notificationChannelName,
        channelDescription: 'APK 构建监控服务',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000), // 5秒轮询构建状态
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// 显示带 Chronometer 的计时通知（系统级自动计时）
  Future<void> showChronometerNotification({
    required DateTime startTime,
    required String title,
    String? body,
  }) async {
    await init();

    final androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: 'APK 构建进度通知',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      usesChronometer: true,  // 关键：启用系统计时器
      when: startTime.millisecondsSinceEpoch,  // 计时起始时间
      chronometerCountDown: false,  // 正向计时
      playSound: false,
      enableVibration: false,
      category: AndroidNotificationCategory.progress,
      visibility: NotificationVisibility.public,
    );

    await _notifications.show(
      _chronometerNotificationId,
      title,
      body ?? '构建进行中...',
      NotificationDetails(android: androidDetails),
    );
  }

  /// 更新计时通知的文本（保持计时器运行）
  Future<void> updateChronometerNotification({
    required DateTime startTime,
    required String title,
    String? body,
  }) async {
    await showChronometerNotification(
      startTime: startTime,
      title: title,
      body: body,
    );
  }

  /// 取消计时通知
  Future<void> cancelChronometerNotification() async {
    await _notifications.cancel(_chronometerNotificationId);
  }

  /// 开始后台监控构建
  Future<ServiceRequestResult> startBackgroundMonitor({
    required String token,
    required String owner,
    required String repo,
    required String workflowId,
    required int runId,
    required DateTime startTime,
  }) async {
    await init();
    initForegroundTask();

    // 保存构建信息到 SharedPreferences，供后台任务读取
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bg_build_token', token);
    await prefs.setString('bg_build_owner', owner);
    await prefs.setString('bg_build_repo', repo);
    await prefs.setString('bg_build_workflow', workflowId);
    await prefs.setInt('bg_build_run_id', runId);
    await prefs.setString('bg_build_start_time', startTime.toIso8601String());
    await prefs.setBool('bg_build_active', true);

    // 显示带 Chronometer 的计时通知（系统自动计时，无需手动更新）
    await showChronometerNotification(
      startTime: startTime,
      title: '🔨 正在构建 APK',
      body: '构建进行中...',
    );

    // 启动前台服务（用于保活和轮询构建状态）
    return FlutterForegroundTask.startService(
      notificationTitle: '构建监控运行中',
      notificationText: '正在后台监控构建状态',
      callback: startCallback,
    );
  }

  /// 停止后台监控
  Future<ServiceRequestResult> stopBackgroundMonitor() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bg_build_active', false);
    
    // 取消计时通知
    await cancelChronometerNotification();
    await _notifications.cancel(_buildNotificationId);
    
    return FlutterForegroundTask.stopService();
  }

  /// 检查是否正在后台运行
  Future<bool> isRunning() async {
    return FlutterForegroundTask.isRunningService;
  }

  /// 显示构建完成通知
  Future<void> showCompletionNotification({
    required bool success,
    String? message,
  }) async {
    await init();
    
    // 先取消计时通知
    await cancelChronometerNotification();

    final androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: 'APK 构建进度通知',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
    );

    await _notifications.show(
      _buildNotificationId,
      success ? '✅ 构建成功' : '❌ 构建失败',
      message ?? (success ? '点击安装 APK' : '请检查构建日志'),
      NotificationDetails(android: androidDetails),
    );
  }

  /// 显示下载进度通知
  Future<void> showDownloadProgress({
    required int progress,
    required int total,
  }) async {
    await init();
    
    // 先取消计时通知
    await cancelChronometerNotification();

    final percent = total > 0 ? (progress * 100 ~/ total) : 0;

    final androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: 'APK 下载进度',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      playSound: false,
      enableVibration: false,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
    );

    await _notifications.show(
      _downloadNotificationId,
      '📥 正在下载 APK',
      '$percent%',
      NotificationDetails(android: androidDetails),
    );
  }

  /// 取消下载通知
  Future<void> cancelDownloadNotification() async {
    await _notifications.cancel(_downloadNotificationId);
  }
}

/// 前台任务回调（必须是顶级函数）
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BuildTaskHandler());
}

/// 后台任务处理器
class BuildTaskHandler extends TaskHandler {
  DateTime? _startTime;
  int? _runId;
  String? _token;
  String? _owner;
  String? _repo;
  String? _workflowId;
  bool _isDownloading = false;
  
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _initNotifications();
    await _initFromPrefs();
  }
  
  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _notifications.initialize(initSettings);
  }

  Future<void> _initFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('bg_build_token');
    _owner = prefs.getString('bg_build_owner');
    _repo = prefs.getString('bg_build_repo');
    _workflowId = prefs.getString('bg_build_workflow');
    _runId = prefs.getInt('bg_build_run_id');
    final startTimeStr = prefs.getString('bg_build_start_time');
    if (startTimeStr != null) {
      _startTime = DateTime.tryParse(startTimeStr);
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _doRepeatEvent();
  }
  
  @override
  void onReceiveData(Object data) {
    // 接收主线程数据（暂不使用）
  }

  Future<void> _doRepeatEvent() async {
    final prefs = await SharedPreferences.getInstance();
    final isActive = prefs.getBool('bg_build_active') ?? false;
    
    if (!isActive || _isDownloading) return;

    // 只检查构建状态，不更新计时（计时由系统 Chronometer 自动处理）
    await _checkBuildStatus(prefs);
  }

  Future<void> _checkBuildStatus(SharedPreferences prefs) async {
    if (_token == null || _owner == null || _repo == null || _workflowId == null) {
      return;
    }

    try {
      final url = 'https://api.github.com/repos/$_owner/$_repo/actions/workflows/$_workflowId/runs?per_page=1';
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'Authorization': 'token $_token',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final runs = data['workflow_runs'] as List;
        
        if (runs.isNotEmpty) {
          final run = runs.first;
          final status = run['status'] as String;
          final conclusion = run['conclusion'] as String?;
          final runId = run['id'] as int;

          // 更新 runId
          if (_runId == null || runId >= _runId!) {
            _runId = runId;
            await prefs.setInt('bg_build_run_id', runId);
          }

          // 更新开始时间
          if (_startTime == null && run['run_started_at'] != null) {
            _startTime = DateTime.tryParse(run['run_started_at']);
            if (_startTime != null) {
              await prefs.setString('bg_build_start_time', _startTime!.toIso8601String());
              // 更新 Chronometer 通知的开始时间
              await _showChronometerNotification(_startTime!);
            }
          }

          if (status == 'completed') {
            if (conclusion == 'success') {
              await _downloadAndInstall(prefs);
            } else {
              await _showFailureNotification(conclusion);
              await prefs.setBool('bg_build_active', false);
              await Future.delayed(const Duration(seconds: 3));
              FlutterForegroundTask.stopService();
            }
          }
        }
      }
    } catch (e) {
      // 网络错误，继续重试
    }
  }

  /// 显示 Chronometer 通知
  Future<void> _showChronometerNotification(DateTime startTime) async {
    final androidDetails = AndroidNotificationDetails(
      'build_channel',
      '构建通知',
      channelDescription: 'APK 构建进度通知',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      usesChronometer: true,
      when: startTime.millisecondsSinceEpoch,
      chronometerCountDown: false,
      playSound: false,
      enableVibration: false,
    );

    await _notifications.show(
      1003,
      '🔨 正在构建 APK',
      '构建进行中...',
      NotificationDetails(android: androidDetails),
    );
  }

  /// 显示失败通知
  Future<void> _showFailureNotification(String? conclusion) async {
    // 取消计时通知
    await _notifications.cancel(1003);
    
    final androidDetails = AndroidNotificationDetails(
      'build_channel',
      '构建通知',
      channelDescription: 'APK 构建进度通知',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
    );

    await _notifications.show(
      1001,
      '❌ 构建失败',
      '结论: $conclusion',
      NotificationDetails(android: androidDetails),
    );
  }

  Future<void> _downloadAndInstall(SharedPreferences prefs) async {
    if (_isDownloading) return;
    _isDownloading = true;

    // 取消计时通知，显示下载通知
    await _notifications.cancel(1003);
    
    await _showDownloadNotification('获取下载链接...');

    try {
      // 1. 获取 artifacts
      final artifactsUrl = 'https://api.github.com/repos/$_owner/$_repo/actions/runs/$_runId/artifacts';
      final artifactsResponse = await http.get(
        Uri.parse(artifactsUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'Authorization': 'token $_token',
        },
      ).timeout(const Duration(seconds: 15));

      if (artifactsResponse.statusCode != 200) {
        throw Exception('获取 artifacts 失败');
      }

      final artifactsData = jsonDecode(artifactsResponse.body);
      final artifacts = artifactsData['artifacts'] as List;
      
      if (artifacts.isEmpty) {
        throw Exception('没有找到构建产物');
      }

      final artifactId = artifacts.first['id'] as int;

      // 2. 获取下载重定向 URL
      await _showDownloadNotification('下载中...');

      final downloadApiUrl = 'https://api.github.com/repos/$_owner/$_repo/actions/artifacts/$artifactId/zip';
      final redirectRequest = http.Request('GET', Uri.parse(downloadApiUrl));
      redirectRequest.headers.addAll({
        'Accept': 'application/vnd.github.v3+json',
        'Authorization': 'token $_token',
      });
      redirectRequest.followRedirects = false;

      final redirectResponse = await redirectRequest.send().timeout(const Duration(seconds: 30));
      
      String? realDownloadUrl;
      if (redirectResponse.statusCode == 302) {
        realDownloadUrl = redirectResponse.headers['location'];
      }

      if (realDownloadUrl == null) {
        throw Exception('获取下载链接失败');
      }

      // 3. 流式下载文件
      final tempDir = await getTemporaryDirectory();
      final zipPath = '${tempDir.path}/artifact_${DateTime.now().millisecondsSinceEpoch}.zip';
      final zipFile = File(zipPath);

      final downloadRequest = http.Request('GET', Uri.parse(realDownloadUrl));
      final downloadResponse = await downloadRequest.send().timeout(const Duration(seconds: 30));

      if (downloadResponse.statusCode != 200) {
        throw Exception('下载失败: ${downloadResponse.statusCode}');
      }

      final sink = zipFile.openWrite();
      try {
        await for (final chunk in downloadResponse.stream) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      await _showDownloadNotification('解压中...');

      // 4. 解压
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      String? apkPath;
      for (final file in archive) {
        if (file.isFile && file.name.endsWith('.apk')) {
          final outFile = File('${tempDir.path}/${file.name}');
          await outFile.writeAsBytes(file.content as List<int>);
          apkPath = outFile.path;
          break;
        }
      }

      await zipFile.delete();

      if (apkPath == null) {
        throw Exception('未找到 APK 文件');
      }

      // 5. 保存 APK 路径供前台读取
      await prefs.setString('bg_build_apk_path', apkPath);
      await prefs.setBool('bg_build_completed', true);
      await prefs.setBool('bg_build_active', false);

      await _showSuccessNotification();

      // 6. 自动打开安装程序
      await OpenFilex.open(apkPath);

      await Future.delayed(const Duration(seconds: 2));
      FlutterForegroundTask.stopService();

    } catch (e) {
      await _showErrorNotification(e.toString());
      await prefs.setBool('bg_build_active', false);
      _isDownloading = false;
      
      await Future.delayed(const Duration(seconds: 3));
      FlutterForegroundTask.stopService();
    }
  }

  Future<void> _showDownloadNotification(String text) async {
    final androidDetails = AndroidNotificationDetails(
      'build_channel',
      '构建通知',
      channelDescription: 'APK 构建进度通知',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      playSound: false,
      enableVibration: false,
    );

    await _notifications.show(
      1002,
      '📥 正在下载 APK',
      text,
      NotificationDetails(android: androidDetails),
    );
  }

  Future<void> _showSuccessNotification() async {
    await _notifications.cancel(1002);
    
    final androidDetails = AndroidNotificationDetails(
      'build_channel',
      '构建通知',
      channelDescription: 'APK 构建进度通知',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
    );

    await _notifications.show(
      1001,
      '✅ 下载完成',
      '点击安装 APK',
      NotificationDetails(android: androidDetails),
    );
  }

  Future<void> _showErrorNotification(String error) async {
    await _notifications.cancel(1002);
    
    final androidDetails = AndroidNotificationDetails(
      'build_channel',
      '构建通知',
      channelDescription: 'APK 构建进度通知',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
    );

    await _notifications.show(
      1001,
      '❌ 下载失败',
      error,
      NotificationDetails(android: androidDetails),
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // 确保取消所有通知
    await _notifications.cancel(1003);
  }

  @override
  void onNotificationButtonPressed(String id) {
    // 通知按钮点击
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    // 通知被清除
  }
}

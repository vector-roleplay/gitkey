import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 后台构建服务 - 仅用于保活进程和显示通知
class BackgroundBuildService {
  static final BackgroundBuildService instance = BackgroundBuildService._internal();
  BackgroundBuildService._internal();

  static const String _notificationChannelId = 'build_channel';
  static const String _notificationChannelName = '构建通知';

  bool _isInitialized = false;

  /// 初始化前台任务配置
  Future<void> init() async {
    if (_isInitialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _notificationChannelId,
        channelName: _notificationChannelName,
        channelDescription: 'APK 构建状态通知',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
        showWhen: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(), // 不需要后台回调
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
  }

  /// 启动前台服务（仅保活进程）
  Future<bool> startService({
    required String title,
    String? text,
  }) async {
    await init();

    final result = await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: text ?? '后台运行中',
      callback: _emptyCallback,
    );

    return result is ServiceRequestSuccess;
  }

  /// 更新通知内容
  Future<void> updateNotification({
    required String title,
    String? text,
  }) async {
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text ?? '',
    );
  }

  /// 停止前台服务
  Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
  }

  /// 检查是否正在运行
  Future<bool> get isRunning async {
    return await FlutterForegroundTask.isRunningService;
  }
}

/// 空回调（前台服务需要，但我们不使用）
@pragma('vm:entry-point')
void _emptyCallback() {
  FlutterForegroundTask.setTaskHandler(_EmptyTaskHandler());
}

/// 空任务处理器
class _EmptyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}



import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 中转站文件数据
class TransferFile {
  final String path;
  final String content;
  final DateTime uploadedAt;

  TransferFile({
    required this.path,
    required this.content,
    DateTime? uploadedAt,
  }) : uploadedAt = uploadedAt ?? DateTime.now();

  String get fileName => path.split('/').last;

  Map<String, dynamic> toJson() => {
    'path': path,
    'content': content,
    'uploadedAt': uploadedAt.toIso8601String(),
  };

  factory TransferFile.fromJson(Map<String, dynamic> json) => TransferFile(
    path: json['path'] as String,
    content: json['content'] as String,
    uploadedAt: DateTime.parse(json['uploadedAt'] as String),
  );
}

/// 权限检查结果
class PermissionResult {
  final bool granted;
  final bool permanentlyDenied;
  final String? message;

  PermissionResult({
    required this.granted,
    this.permanentlyDenied = false,
    this.message,
  });
}

/// 中转站服务 - 用于两个应用之间共享文件
class TransferService {
  static final TransferService instance = TransferService._internal();
  TransferService._internal();

  /// 检查并请求存储权限
  Future<PermissionResult> checkAndRequestPermission() async {
    if (!Platform.isAndroid) {
      return PermissionResult(granted: true);
    }

    // Android 11+ (API 30+) 需要 MANAGE_EXTERNAL_STORAGE
    if (await _isAndroid11OrHigher()) {
      final status = await Permission.manageExternalStorage.status;
      
      if (status.isGranted) {
        return PermissionResult(granted: true);
      }
      
      if (status.isPermanentlyDenied || status.isDenied) {
        // 需要引导用户去设置页面开启
        return PermissionResult(
          granted: false,
          permanentlyDenied: true,
          message: '需要"所有文件访问权限"才能使用中转站功能',
        );
      }
      
      // 请求权限
      final result = await Permission.manageExternalStorage.request();
      return PermissionResult(
        granted: result.isGranted,
        permanentlyDenied: result.isPermanentlyDenied,
        message: result.isGranted ? null : '权限被拒绝',
      );
    } else {
      // Android 10 及以下使用传统存储权限
      final status = await Permission.storage.status;
      
      if (status.isGranted) {
        return PermissionResult(granted: true);
      }
      
      final result = await Permission.storage.request();
      return PermissionResult(
        granted: result.isGranted,
        permanentlyDenied: result.isPermanentlyDenied,
        message: result.isGranted ? null : '存储权限被拒绝',
      );
    }
  }

  /// 检查是否为 Android 11+
  Future<bool> _isAndroid11OrHigher() async {
    // 简单判断：检查 MANAGE_EXTERNAL_STORAGE 是否可用
    try {
      await Permission.manageExternalStorage.status;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 打开应用设置页面
  Future<bool> openSettings() async {
    return await openAppSettings();
  }

  /// 获取中转站目录路径
  Future<String> get _transferDirPath async {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/AiCodeTransfer';
    } else {
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/AiCodeTransfer';
    }
  }

  /// 获取中转站文件路径
  Future<String> get _transferFilePath async {
    final dir = await _transferDirPath;
    return '$dir/transfer.json';
  }

  /// 确保中转站目录存在
  Future<bool> _ensureDirectoryExists() async {
    try {
      final dirPath = await _transferDirPath;
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return true;
    } catch (e) {
      print('创建目录失败: $e');
      return false;
    }
  }

  /// 读取中转站中的所有文件
  Future<List<TransferFile>> getFiles() async {
    try {
      final filePath = await _transferFilePath;
      final file = File(filePath);
      
      if (!await file.exists()) {
        return [];
      }

      final content = await file.readAsString();
      if (content.isEmpty) {
        return [];
      }

      final data = jsonDecode(content) as Map<String, dynamic>;
      final files = data['files'] as List? ?? [];
      
      return files.map((f) => TransferFile.fromJson(f)).toList();
    } catch (e) {
      print('读取中转站失败: $e');
      return [];
    }
  }

  /// 上传文件到中转站（追加模式）
  Future<({bool success, String? error})> uploadFiles(List<TransferFile> newFiles) async {
    try {
      // 先检查权限
      final permission = await checkAndRequestPermission();
      if (!permission.granted) {
        return (
          success: false, 
          error: permission.message ?? '存储权限被拒绝',
        );
      }

      // 确保目录存在
      final dirCreated = await _ensureDirectoryExists();
      if (!dirCreated) {
        return (success: false, error: '无法创建中转站目录');
      }
      
      // 读取现有文件
      final existingFiles = await getFiles();
      
      // 合并文件（新文件覆盖同路径的旧文件）
      final fileMap = <String, TransferFile>{};
      for (final f in existingFiles) {
        fileMap[f.path] = f;
      }
      for (final f in newFiles) {
        fileMap[f.path] = f;
      }
      
      // 写入文件
      final filePath = await _transferFilePath;
      final file = File(filePath);
      
      final data = {
        'files': fileMap.values.map((f) => f.toJson()).toList(),
        'lastUpdated': DateTime.now().toIso8601String(),
      };
      
      await file.writeAsString(jsonEncode(data), flush: true);
      return (success: true, error: null);
    } catch (e) {
      print('上传到中转站失败: $e');
      return (success: false, error: e.toString());
    }
  }

  /// 上传单个文件
  Future<({bool success, String? error})> uploadFile(TransferFile file) async {
    return uploadFiles([file]);
  }

  /// 从中转站删除指定文件
  Future<bool> removeFile(String path) async {
    try {
      final files = await getFiles();
      files.removeWhere((f) => f.path == path);
      
      final filePath = await _transferFilePath;
      final file = File(filePath);
      
      final data = {
        'files': files.map((f) => f.toJson()).toList(),
        'lastUpdated': DateTime.now().toIso8601String(),
      };
      
      await file.writeAsString(jsonEncode(data), flush: true);
      return true;
    } catch (e) {
      print('从中转站删除失败: $e');
      return false;
    }
  }

  /// 清空中转站
  Future<bool> clear() async {
    try {
      final filePath = await _transferFilePath;
      final file = File(filePath);
      
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      print('清空中转站失败: $e');
      return false;
    }
  }

  /// 获取中转站文件数量
  Future<int> getFileCount() async {
    final files = await getFiles();
    return files.length;
  }
}

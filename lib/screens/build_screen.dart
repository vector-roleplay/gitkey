import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:open_filex/open_filex.dart';
import '../services/github_service.dart';
import '../services/storage_service.dart';
import '../models.dart';
import '../main.dart';

class BuildScreen extends StatefulWidget {
  const BuildScreen({super.key});

  @override
  State<BuildScreen> createState() => _BuildScreenState();
}

class _BuildScreenState extends State<BuildScreen> {
  List<Repository> _repos = [];
  Repository? _selectedRepo;
  String _buildType = 'release';
  
  // 状态
  bool _isTriggering = false;
  String? _errorMessage;
  
  Timer? _pollTimer;
  Timer? _tickTimer;
  String _elapsedTime = '';

  @override
  void initState() {
    super.initState();
    _loadRepos();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBuildState();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  void _loadRepos() {
    final storage = context.read<StorageService>();
    setState(() {
      _repos = storage.getRepositories();
      _selectedRepo = storage.getDefaultRepository();
    });
  }

  /// 初始化构建状态（从全局状态恢复，或检查现有构建）
  Future<void> _initBuildState() async {
    final appState = context.read<AppState>();
    
    // 如果全局状态中有构建信息，直接恢复
    if (appState.hasBuildInProgress || appState.isBuildSuccess) {
      // 恢复计时
      if (appState.buildStartTime != null) {
        _startTicking();
      }
      // 如果正在构建中，恢复轮询
      if (appState.hasBuildInProgress) {
        _startPolling();
      }
      return;
    }
    
    // 否则检查是否有正在进行的构建
    if (_selectedRepo != null) {
      await _checkExistingBuild();
    }
  }

  /// 检查是否有正在进行的构建
  Future<void> _checkExistingBuild() async {
    if (_selectedRepo == null) return;
    
    final github = context.read<GitHubService>();
    final appState = context.read<AppState>();
    
    final result = await github.getLatestWorkflowRun(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: 'android.yml',
    );

    if (result.run != null && result.run!.isRunning) {
      // 有正在进行的构建，更新全局状态
      appState.updateBuildState(
        runId: result.run!.id,
        status: result.run!.status,
        conclusion: result.run!.conclusion,
        startTime: result.run!.startTime,
        repoFullName: _selectedRepo!.fullName,
      );
      _startTicking();
      _startPolling();
    }
  }

  /// 格式化已用时间
  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    if (minutes > 0) {
      return '$minutes分${seconds}秒';
    } else {
      return '$seconds秒';
    }
  }

  /// 更新已用时间显示
  void _updateElapsedTime() {
    final appState = context.read<AppState>();
    final startTime = appState.buildStartTime;
    if (startTime != null) {
      final elapsed = DateTime.now().difference(startTime);
      if (mounted) {
        setState(() {
          _elapsedTime = _formatDuration(elapsed);
        });
      }
    }
  }

  /// 开始计时
  void _startTicking() {
    _tickTimer?.cancel();
    _updateElapsedTime();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateElapsedTime();
    });
  }

  /// 停止计时
  void _stopTicking() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  /// 触发构建
  Future<void> _triggerBuild() async {
    if (_selectedRepo == null) {
      setState(() => _errorMessage = '请先选择仓库');
      return;
    }

    final appState = context.read<AppState>();
    
    setState(() {
      _isTriggering = true;
      _errorMessage = null;
    });
    
    // 清除之前的构建状态
    appState.clearBuildState();

    final github = context.read<GitHubService>();
    final result = await github.triggerWorkflow(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: 'android.yml',
      ref: _selectedRepo!.branch,
      inputs: {'build_type': _buildType},
    );

    if (result.success) {
      setState(() {
        _isTriggering = false;
      });
      
      // 更新全局状态
      appState.updateBuildState(
        status: 'queued',
        repoFullName: _selectedRepo!.fullName,
      );
      
      // 等待一下再开始轮询
      await Future.delayed(const Duration(seconds: 3));
      _startPolling();
    } else {
      setState(() {
        _isTriggering = false;
        _errorMessage = result.error;
      });
    }
  }

  /// 开始轮询构建状态
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      await _checkBuildStatus();
    });
    // 立即检查一次
    _checkBuildStatus();
  }

  /// 停止轮询
  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 检查构建状态
  Future<void> _checkBuildStatus() async {
    final github = context.read<GitHubService>();
    final appState = context.read<AppState>();
    
    if (_selectedRepo == null) return;
    
    final result = await github.getLatestWorkflowRun(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: 'android.yml',
    );

    if (result.run != null) {
      // 更新全局状态
      appState.updateBuildState(
        runId: result.run!.id,
        status: result.run!.status,
        conclusion: result.run!.conclusion,
        startTime: result.run!.startTime,
      );
      
      // 如果刚开始执行（从 queued 变为 in_progress），开始计时
      if (result.run!.isInProgress && appState.buildStartTime == null) {
        appState.updateBuildState(startTime: result.run!.startTime);
      }
      
      // 如果有开始时间且计时器没启动，启动计时器
      if (appState.buildStartTime != null && _tickTimer == null) {
        _startTicking();
      }

      if (result.run!.isCompleted) {
        _stopPolling();
        _stopTicking();
        
        if (result.run!.isSuccess) {
          // 构建成功，自动开始下载
          _autoDownloadAndInstall();
        } else {
          setState(() {
            _errorMessage = '构建失败: ${result.run!.conclusion}';
          });
        }
      }
    } else if (result.error != null) {
      setState(() => _errorMessage = result.error);
    }
  }

  /// 自动下载并安装 APK
  Future<void> _autoDownloadAndInstall() async {
    final appState = context.read<AppState>();
    
    if (appState.buildRunId == null || _selectedRepo == null) return;
    
    appState.updateDownloadState(isDownloading: true, progress: 0);

    final github = context.read<GitHubService>();

    // 1. 获取 artifacts
    final artifactsResult = await github.getArtifacts(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      runId: appState.buildRunId!,
    );

    if (artifactsResult.error != null || artifactsResult.artifacts.isEmpty) {
      appState.updateDownloadState(isDownloading: false);
      setState(() {
        _errorMessage = artifactsResult.error ?? '没有找到构建产物';
      });
      return;
    }

    final artifact = artifactsResult.artifacts.first;

    // 2. 下载 artifact
    final downloadResult = await github.downloadArtifact(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      artifactId: artifact.id,
    );

    if (downloadResult.error != null || downloadResult.bytes == null) {
      appState.updateDownloadState(isDownloading: false);
      setState(() {
        _errorMessage = downloadResult.error ?? '下载失败';
      });
      return;
    }

    appState.updateDownloadState(progress: 0.5);

    // 3. 保存并解压
    try {
      final tempDir = await getTemporaryDirectory();
      final zipFile = File('${tempDir.path}/artifact.zip');
      await zipFile.writeAsBytes(downloadResult.bytes!);

      // 解压
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

      // 清理 zip
      await zipFile.delete();

      if (apkPath == null) {
        appState.updateDownloadState(isDownloading: false);
        setState(() {
          _errorMessage = '未找到 APK 文件';
        });
        return;
      }

      appState.updateDownloadState(
        isDownloading: false,
        progress: 1.0,
        apkPath: apkPath,
      );

      // 4. 自动打开安装程序
      await OpenFilex.open(apkPath);
      
    } catch (e) {
      appState.updateDownloadState(isDownloading: false);
      setState(() {
        _errorMessage = '处理失败: $e';
      });
    }
  }

  /// 手动安装已下载的 APK
  Future<void> _installApk() async {
    final appState = context.read<AppState>();
    final apkPath = appState.downloadedApkPath;
    
    if (apkPath != null) {
      await OpenFilex.open(apkPath);
    }
  }

  /// 获取状态文本
  String _getStatusText(AppState appState) {
    if (_isTriggering) return '正在触发构建...';
    
    if (appState.isDownloading) {
      if (appState.downloadProgress < 0.5) {
        return '📥 正在下载...';
      } else {
        return '📦 正在解压...';
      }
    }
    
    if (appState.downloadedApkPath != null) {
      return '✅ 下载完成，准备安装';
    }
    
    switch (appState.buildStatus) {
      case 'queued':
        return '⏳ 排队中...';
      case 'in_progress':
        return '🔨 正在构建...';
      case 'completed':
        if (appState.isBuildSuccess) {
          return '✅ 构建成功！';
        } else {
          return '❌ 构建失败';
        }
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final hasActiveTask = appState.hasBuildInProgress || appState.isDownloading;
    final statusText = _getStatusText(appState);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('构建 APK'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 仓库选择
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('选择仓库', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _selectedRepo?.fullName,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.folder),
                    ),
                    items: _repos.map((r) => DropdownMenuItem(
                      value: r.fullName,
                      child: Text(r.fullName),
                    )).toList(),
                    onChanged: hasActiveTask ? null : (value) {
                      if (value != null) {
                        setState(() {
                          _selectedRepo = _repos.firstWhere((r) => r.fullName == value);
                        });
                        _checkExistingBuild();
                      }
                    },
                    hint: const Text('请选择仓库'),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 12),
          
          // 构建类型
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('构建类型', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'release', label: Text('Release'), icon: Icon(Icons.rocket_launch)),
                      ButtonSegment(value: 'debug', label: Text('Debug'), icon: Icon(Icons.bug_report)),
                    ],
                    selected: {_buildType},
                    onSelectionChanged: hasActiveTask ? null : (value) {
                      setState(() => _buildType = value.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _buildType == 'release' ? '体积小、运行快，适合日常使用' : '体积大、可调试，适合开发测试',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 12),
          
          // 触发构建按钮
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: _isTriggering || hasActiveTask ? null : _triggerBuild,
              icon: _isTriggering
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(_isTriggering ? '触发中...' : (hasActiveTask ? '构建中...' : '开始构建')),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // 状态显示
          if (statusText.isNotEmpty || _errorMessage != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (hasActiveTask || appState.isDownloading)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (hasActiveTask || appState.isDownloading) const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                statusText,
                                style: const TextStyle(fontSize: 16),
                              ),
                              // 显示已用时间（只在构建中显示，且只在实际开始后显示）
                              if (appState.buildStatus == 'in_progress' && _elapsedTime.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '已用时: $_elapsedTime',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ),
                              // 排队中显示提示
                              if (appState.buildStatus == 'queued')
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '等待 GitHub Actions 分配运行器...',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[500],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (hasActiveTask)
                          TextButton(
                            onPressed: () {
                              _stopPolling();
                              _stopTicking();
                              context.read<AppState>().clearBuildState();
                              setState(() {
                                _elapsedTime = '';
                              });
                            },
                            child: const Text('取消'),
                          ),
                      ],
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error, color: Colors.red, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (appState.isDownloading) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: appState.downloadProgress),
                    ],
                  ],
                ),
              ),
            ),
          
          // 安装按钮（下载完成后显示）
          if (appState.downloadedApkPath != null && !appState.isDownloading) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _installApk,
                icon: const Icon(Icons.install_mobile),
                label: const Text('安装 APK'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                ),
              ),
            ),
          ],
          
          // 重新构建按钮（构建完成后显示）
          if (appState.buildStatus == 'completed' && !appState.isDownloading) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: () {
                  context.read<AppState>().clearBuildState();
                  setState(() {
                    _errorMessage = null;
                    _elapsedTime = '';
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重新构建'),
              ),
            ),
          ],
          
          const SizedBox(height: 24),
          
          // 说明
          Card(
            color: Colors.blue.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info, color: Colors.blue[700], size: 20),
                      const SizedBox(width: 8),
                      Text('说明', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue[700])),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('1. 构建大约需要 3-5 分钟（有缓存时）'),
                  const Text('2. 首次构建可能需要 8-10 分钟'),
                  const Text('3. 计时与 GitHub 官网同步'),
                  const Text('4. 构建完成后会自动下载并弹出安装'),
                  const Text('5. 可以离开此页面，状态会保持'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/github_service.dart';
import '../services/storage_service.dart';
import '../services/background_build_service.dart';
import '../models.dart';
import '../main.dart';

class BuildScreen extends StatefulWidget {
  const BuildScreen({super.key});

  @override
  State<BuildScreen> createState() => _BuildScreenState();
}

class _BuildScreenState extends State<BuildScreen> with WidgetsBindingObserver {
  List<Repository> _repos = [];
  Repository? _selectedRepo;
  String _buildType = 'release';
  
  // Workflow 相关
  List<WorkflowInfo> _workflows = [];
  WorkflowInfo? _selectedWorkflow;
  bool _isLoadingWorkflows = false;
  
  // 状态
  bool _isTriggering = false;
  String? _errorMessage;
  
  Timer? _pollTimer;
  Timer? _tickTimer;
  String _elapsedTime = '';
  
  // 后台服务
  final _bgService = BackgroundBuildService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadRepos();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBuildState();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    final appState = context.read<AppState>();
    
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // 应用进入后台
      if (appState.hasBuildInProgress) {
        _startBackgroundService();
      }
    } else if (state == AppLifecycleState.resumed) {
      // 应用回到前台
      _stopBackgroundService();
      _checkBackgroundResult();
      
      // 如果还在构建中，重新启动前台轮询
      if (appState.hasBuildInProgress) {
        _startPolling();
        _startTicking();
      }
    }
  }

  /// 启动后台服务
  Future<void> _startBackgroundService() async {
    final appState = context.read<AppState>();
    final storage = context.read<StorageService>();
    final token = storage.getToken();
    
    if (token == null || _selectedRepo == null || _selectedWorkflow == null) return;
    if (appState.buildRunId == null) return;

    // 停止前台轮询
    _pollTimer?.cancel();
    _tickTimer?.cancel();

    await _bgService.startBackgroundMonitor(
      token: token,
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: _selectedWorkflow!.fileName,
      runId: appState.buildRunId!,
      startTime: appState.buildStartTime ?? DateTime.now(),
    );
  }

  /// 停止后台服务
  Future<void> _stopBackgroundService() async {
    await _bgService.stopBackgroundMonitor();
  }

  /// 检查后台任务结果
  Future<void> _checkBackgroundResult() async {
    final prefs = await SharedPreferences.getInstance();
    final completed = prefs.getBool('bg_build_completed') ?? false;
    
    if (completed) {
      final apkPath = prefs.getString('bg_build_apk_path');
      final appState = context.read<AppState>();
      
      if (apkPath != null) {
        appState.updateDownloadState(
          isDownloading: false,
          progress: 1.0,
          apkPath: apkPath,
        );
        appState.updateBuildState(
          status: 'completed',
          conclusion: 'success',
        );
      }
      
      // 清理标记
      await prefs.remove('bg_build_completed');
      await prefs.remove('bg_build_apk_path');
    }
  }

  void _loadRepos() {
    final storage = context.read<StorageService>();
    setState(() {
      _repos = storage.getRepositories();
      _selectedRepo = storage.getDefaultRepository();
    });
    
    if (_selectedRepo != null) {
      _loadWorkflows(_selectedRepo!);
    }
  }

  Future<void> _loadWorkflows(Repository repo) async {
    setState(() {
      _isLoadingWorkflows = true;
      _workflows = [];
      _selectedWorkflow = null;
      _errorMessage = null;
    });

    final github = context.read<GitHubService>();
    final result = await github.getWorkflows(
      owner: repo.owner,
      repo: repo.name,
    );

    if (result.error != null) {
      setState(() {
        _isLoadingWorkflows = false;
        _errorMessage = '获取 workflows 失败: ${result.error}';
      });
      return;
    }

    if (result.workflows.isEmpty) {
      setState(() {
        _isLoadingWorkflows = false;
        _errorMessage = '该仓库没有配置 GitHub Actions workflow';
      });
      return;
    }

    WorkflowInfo? selected;
    if (result.workflows.length == 1) {
      selected = result.workflows.first;
    } else {
      final keywords = ['android', 'build', 'apk', 'flutter'];
      for (final keyword in keywords) {
        selected = result.workflows.firstWhere(
          (w) => w.name.toLowerCase().contains(keyword) || 
                 w.fileName.toLowerCase().contains(keyword),
          orElse: () => result.workflows.first,
        );
        if (selected.name.toLowerCase().contains(keyword) ||
            selected.fileName.toLowerCase().contains(keyword)) {
          break;
        }
      }
      selected ??= result.workflows.first;
    }

    setState(() {
      _isLoadingWorkflows = false;
      _workflows = result.workflows;
      _selectedWorkflow = selected;
    });
  }

  Future<void> _initBuildState() async {
    final appState = context.read<AppState>();
    
    // 先检查后台任务结果
    await _checkBackgroundResult();
    
    if (appState.hasBuildInProgress || appState.isBuildSuccess) {
      if (appState.buildStartTime != null) {
        _startTicking();
      }
      if (appState.hasBuildInProgress) {
        _startPolling();
      }
      return;
    }
    
    if (_selectedRepo != null && _selectedWorkflow != null) {
      await _checkExistingBuild();
    }
  }

  Future<void> _checkExistingBuild() async {
    if (_selectedRepo == null || _selectedWorkflow == null) return;
    
    final github = context.read<GitHubService>();
    final appState = context.read<AppState>();
    
    final result = await github.getLatestWorkflowRun(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: _selectedWorkflow!.fileName,
    );

    if (result.serverTime != null) {
      appState.updateClockOffset(result.serverTime!);
    }

    if (result.run != null && result.run!.isRunning) {
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

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    if (minutes > 0) {
      return '$minutes分${seconds}秒';
    } else {
      return '$seconds秒';
    }
  }

  void _updateElapsedTime() {
    final appState = context.read<AppState>();
    final startTime = appState.buildStartTime;
    if (startTime != null) {
      final calibratedNow = appState.calibratedNow;
      final elapsed = calibratedNow.difference(startTime);
      final safeElapsed = elapsed.isNegative ? Duration.zero : elapsed;
      if (mounted) {
        setState(() {
          _elapsedTime = _formatDuration(safeElapsed);
        });
      }
    }
  }

  void _startTicking() {
    _tickTimer?.cancel();
    _updateElapsedTime();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateElapsedTime();
    });
  }

  void _stopTicking() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  Future<void> _triggerBuild() async {
    if (_selectedRepo == null) {
      setState(() => _errorMessage = '请先选择仓库');
      return;
    }

    if (_selectedWorkflow == null) {
      setState(() => _errorMessage = '未找到可用的 workflow');
      return;
    }

    final appState = context.read<AppState>();
    
    setState(() {
      _isTriggering = true;
      _errorMessage = null;
    });
    
    appState.clearBuildState();

    final github = context.read<GitHubService>();
    
    Map<String, String>? inputs;
    if (_selectedWorkflow!.name.toLowerCase().contains('android') ||
        _selectedWorkflow!.fileName.toLowerCase().contains('android')) {
      inputs = {'build_type': _buildType};
    }
    
    final result = await github.triggerWorkflow(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: _selectedWorkflow!.fileName,
      ref: _selectedRepo!.branch,
      inputs: inputs,
    );

    if (result.success) {
      setState(() {
        _isTriggering = false;
      });
      
      appState.updateBuildState(
        status: 'queued',
        repoFullName: _selectedRepo!.fullName,
      );
      
      await Future.delayed(const Duration(seconds: 3));
      _startPolling();
    } else {
      setState(() {
        _isTriggering = false;
        _errorMessage = result.error;
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      await _checkBuildStatus();
    });
    _checkBuildStatus();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _checkBuildStatus() async {
    final github = context.read<GitHubService>();
    final appState = context.read<AppState>();
    
    if (_selectedRepo == null || _selectedWorkflow == null) return;
    
    final result = await github.getLatestWorkflowRun(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: _selectedWorkflow!.fileName,
    );

    if (result.serverTime != null) {
      appState.updateClockOffset(result.serverTime!);
    }

    if (result.run != null) {
      appState.updateBuildState(
        runId: result.run!.id,
        status: result.run!.status,
        conclusion: result.run!.conclusion,
        startTime: result.run!.startTime,
      );
      
      if (result.run!.isInProgress && appState.buildStartTime == null) {
        appState.updateBuildState(startTime: result.run!.startTime);
      }
      
      if (appState.buildStartTime != null && _tickTimer == null) {
        _startTicking();
      }

      if (result.run!.isCompleted) {
        _stopPolling();
        _stopTicking();
        
        if (result.run!.isSuccess) {
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

  Future<void> _autoDownloadAndInstall() async {
    final appState = context.read<AppState>();
    
    if (appState.buildRunId == null || _selectedRepo == null) return;
    
    appState.updateDownloadState(isDownloading: true, progress: 0);

    final github = context.read<GitHubService>();

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

    try {
      final tempDir = await getTemporaryDirectory();
      final zipFile = File('${tempDir.path}/artifact.zip');
      await zipFile.writeAsBytes(downloadResult.bytes!);

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

      await OpenFilex.open(apkPath);
      
    } catch (e) {
      appState.updateDownloadState(isDownloading: false);
      setState(() {
        _errorMessage = '处理失败: $e';
      });
    }
  }

  Future<void> _installApk() async {
    final appState = context.read<AppState>();
    final apkPath = appState.downloadedApkPath;
    
    if (apkPath != null) {
      await OpenFilex.open(apkPath);
    }
  }

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
    
    // 使用 WithForegroundTask 包装，支持后台任务
    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('构建 APK'),
          actions: [
            // 后台运行指示器
            if (hasActiveTask)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: '退出应用后将在后台继续运行',
                  child: Icon(
                    Icons.sync,
                    color: Colors.green[400],
                    size: 20,
                  ),
                ),
              ),
          ],
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
                          final repo = _repos.firstWhere((r) => r.fullName == value);
                          setState(() {
                            _selectedRepo = repo;
                          });
                          _loadWorkflows(repo);
                        }
                      },
                      hint: const Text('请选择仓库'),
                    ),
                  ],
                ),
              ),
            ),
            
            // Workflow 信息显示
            if (_isLoadingWorkflows)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Text('正在获取 workflow...'),
                    ],
                  ),
                ),
              )
            else if (_selectedWorkflow != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Workflow: ${_selectedWorkflow!.name}',
                          style: TextStyle(color: Colors.green[700], fontSize: 13),
                        ),
                      ),
                      Text(
                        _selectedWorkflow!.fileName,
                        style: TextStyle(color: Colors.grey[600], fontSize: 11),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _isTriggering || hasActiveTask || _selectedWorkflow == null || _isLoadingWorkflows
                      ? null 
                      : _triggerBuild,
                  icon: _isTriggering
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.play_arrow),
                  label: Text(_isTriggering ? '触发中...' : (hasActiveTask ? '构建中...' : '开始构建')),
                ),
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
                                _stopBackgroundService();
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
            
            // 安装按钮
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
            
            // 重新构建按钮
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
                    const Text('5. 🆕 退出应用后会在后台继续运行'),
                    const Text('6. 🆕 下拉通知栏可查看构建进度'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
  bool _isPolling = false;
  bool _isDownloading = false;
  
  WorkflowRun? _currentRun;
  String? _statusMessage;
  String? _errorMessage;
  double _downloadProgress = 0;
  
  Timer? _pollTimer;
  
  // 计时相关
  DateTime? _startTime;
  Timer? _tickTimer;
  String _elapsedTime = '';

  @override
  void initState() {
    super.initState();
    _loadRepos();
    // 延迟检查，确保 context 可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkExistingBuild();
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

  /// 检查是否有正在进行的构建
  Future<void> _checkExistingBuild() async {
    if (_selectedRepo == null) return;
    
    final github = context.read<GitHubService>();
    final result = await github.getLatestWorkflowRun(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: 'android.yml',
    );

    if (result.run != null && result.run!.isRunning) {
      // 有正在进行的构建，恢复状态
      setState(() {
        _currentRun = result.run;
        _statusMessage = _getStatusMessage(result.run!);
        // 从 GitHub 的 created_at 解析开始时间
        _startTime = DateTime.tryParse(result.run!.createdAt);
      });
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
    if (_startTime != null) {
      final elapsed = DateTime.now().difference(_startTime!);
      setState(() {
        _elapsedTime = _formatDuration(elapsed);
      });
    }
  }

  /// 开始计时
  void _startTicking() {
    _tickTimer?.cancel();
    _updateElapsedTime(); // 立即更新一次
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

    setState(() {
      _isTriggering = true;
      _errorMessage = null;
      _statusMessage = '正在触发构建...';
      _currentRun = null;
      _startTime = null;
      _elapsedTime = '';
    });

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
        _statusMessage = '构建已触发，等待开始...';
        _startTime = DateTime.now(); // 记录开始时间
      });
      _startTicking(); // 开始计时
      // 等待一下再开始轮询
      await Future.delayed(const Duration(seconds: 3));
      _startPolling();
    } else {
      setState(() {
        _isTriggering = false;
        _errorMessage = result.error;
        _statusMessage = null;
      });
    }
  }

  /// 开始轮询构建状态
  void _startPolling() {
    setState(() => _isPolling = true);
    
    // 确保计时器在运行
    if (_tickTimer == null && _startTime != null) {
      _startTicking();
    }
    
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      await _checkBuildStatus();
    });
    
    // 立即检查一次
    _checkBuildStatus();
  }

  /// 检查构建状态
  Future<void> _checkBuildStatus() async {
    final github = context.read<GitHubService>();
    
    final result = await github.getLatestWorkflowRun(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      workflowId: 'android.yml',
    );

    if (result.run != null) {
      // 如果还没有开始时间，从 API 获取
      if (_startTime == null) {
        _startTime = DateTime.tryParse(result.run!.createdAt);
        if (_startTime != null) {
          _startTicking();
        }
      }

      setState(() {
        _currentRun = result.run;
        _statusMessage = _getStatusMessage(result.run!);
      });

      if (result.run!.isCompleted) {
        _pollTimer?.cancel();
        _stopTicking(); // 停止计时
        setState(() => _isPolling = false);
        
        if (result.run!.isSuccess) {
          setState(() => _statusMessage = '✅ 构建成功！');
        } else {
          setState(() {
            _statusMessage = null;
            _errorMessage = '❌ 构建失败: ${result.run!.conclusion}';
          });
        }
      }
    } else if (result.error != null) {
      setState(() => _errorMessage = result.error);
    }
  }

  String _getStatusMessage(WorkflowRun run) {
    switch (run.status) {
      case 'queued':
        return '⏳ 排队中...';
      case 'in_progress':
        return '🔨 正在构建...';
      case 'completed':
        return run.isSuccess ? '✅ 构建成功！' : '❌ 构建失败';
      default:
        return '状态: ${run.status}';
    }
  }

  /// 下载并安装 APK
  Future<void> _downloadAndInstall() async {
    if (_currentRun == null) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _errorMessage = null;
      _statusMessage = '获取下载链接...';
    });

    final github = context.read<GitHubService>();

    // 1. 获取 artifacts
    final artifactsResult = await github.getArtifacts(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      runId: _currentRun!.id,
    );

    if (artifactsResult.error != null || artifactsResult.artifacts.isEmpty) {
      setState(() {
        _isDownloading = false;
        _errorMessage = artifactsResult.error ?? '没有找到构建产物';
        _statusMessage = null;
      });
      return;
    }

    final artifact = artifactsResult.artifacts.first;
    setState(() => _statusMessage = '下载中... (${artifact.sizeFormatted})');

    // 2. 下载 artifact
    final downloadResult = await github.downloadArtifact(
      owner: _selectedRepo!.owner,
      repo: _selectedRepo!.name,
      artifactId: artifact.id,
    );

    if (downloadResult.error != null || downloadResult.bytes == null) {
      setState(() {
        _isDownloading = false;
        _errorMessage = downloadResult.error ?? '下载失败';
        _statusMessage = null;
      });
      return;
    }

    setState(() {
      _downloadProgress = 0.5;
      _statusMessage = '解压中...';
    });

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
        setState(() {
          _isDownloading = false;
          _errorMessage = '未找到 APK 文件';
          _statusMessage = null;
        });
        return;
      }

      setState(() {
        _downloadProgress = 1.0;
        _statusMessage = '准备安装...';
      });

      // 4. 安装 APK
      final result = await OpenFilex.open(apkPath);
      
      setState(() {
        _isDownloading = false;
        if (result.type == ResultType.done) {
          _statusMessage = '✅ 已打开安装程序';
        } else {
          _errorMessage = '打开安装程序失败: ${result.message}';
          _statusMessage = null;
        }
      });

    } catch (e) {
      setState(() {
        _isDownloading = false;
        _errorMessage = '处理失败: $e';
        _statusMessage = null;
      });
    }
  }

  /// 停止轮询
  void _stopPolling() {
    _pollTimer?.cancel();
    _stopTicking();
    setState(() {
      _isPolling = false;
      _statusMessage = null;
      _startTime = null;
      _elapsedTime = '';
    });
  }

  @override
  Widget build(BuildContext context) {
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
(height: 12),
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
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedRepo = _repos.firstWhere((r) => r.fullName == value);
                        });
                        // 切换仓库时检查该仓库是否有进行中的构建
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
                    onSelectionChanged: (value) {
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
              onPressed: _isTriggering || _isPolling || _isDownloading ? null : _triggerBuild,
              icon: _isTriggering
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(_isTriggering ? '触发中...' : '开始构建'),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // 状态显示
          if (_statusMessage != null || _errorMessage != null || _isPolling)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_isPolling || _isDownloading)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (_isPolling || _isDownloading) const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _statusMessage ?? '',
                                style: const TextStyle(fontSize: 16),
                              ),
                              // 显示已用时间
                              if (_elapsedTime.isNotEmpty && (_isPolling || _currentRun?.isSuccess == true))
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
                            ],
                          ),
                        ),
                        if (_isPolling)
                          TextButton(
                            onPressed: _stopPolling,
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
                    if (_isDownloading) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: _downloadProgress),
                    ],
                  ],
                ),
              ),
            ),
          
          // 下载按钮
          if (_currentRun != null && _currentRun!.isSuccess && !_isDownloading) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _downloadAndInstall,
                icon: const Icon(Icons.download),
                label: const Text('下载并安装'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                ),
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
                  const Text('3. 下载速度取决于网络环境'),
                  const Text('4. 安装时需要允许"未知来源"权限'),
                  const Text('5. 离开页面后返回会自动恢复构建状态'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

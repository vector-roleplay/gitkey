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

  @override
  void initState() {
    super.initState();
    _loadRepos();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _loadRepos() {
    final storage = context.read<StorageService>();
    setState(() {
      _repos = storage.getRepositories();
      _selectedRepo = storage.getDefaultRepository();
    });
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
      });
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
      setState(() {
        _currentRun = result.run;
        _statusMessage = _getStatusMessage(result.run!);
      });

      if (result.run!.isCompleted) {
        _pollTimer?.cancel();
        setState(() => _isPolling = false);
        
        if (result.run!.isSuccess) {
          setState(() => _statusMessage = '✅ 构建成功！可以下载了');
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
    setState(() {
      _isPolling = false;
      _statusMessage = null;
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
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedRepo = _repos.firstWhere((r) => r.fullName == value);
                        });
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
                          child: Text(
                            _statusMessage ?? '',
                            style: const TextStyle(fontSize: 16),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
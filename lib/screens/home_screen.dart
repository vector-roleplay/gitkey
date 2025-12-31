import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models.dart';
import '../services/storage_service.dart';
import '../services/github_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Repository> _repos = [];
  bool _isPushing = false;// 顶部提示消息
  String? _topMessage;
  bool _topMessageSuccess = true;

  
  @override
  void initState() {
    super.initState();
    _loadData();
  }
  
  void _loadData() {
    final storage = context.read<StorageService>();
    setState(() {
      _repos = storage.getRepositories();
    });
    
    final appState = context.read<AppState>();
    if (appState.selectedRepo == null && _repos.isNotEmpty) {
      appState.setSelectedRepo(storage.getDefaultRepository());
    }
  }/// 显示顶部提示消息
  void _showTopMessage(String message, {bool isSuccess = true}) {
    setState(() {
      _topMessage = message;
      _topMessageSuccess = isSuccess;
    });
    
    // 3秒后自动隐藏
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _topMessage == message) {
        setState(() {
          _topMessage = null;
        });
      }
    });
  }
  
  /// 隐藏顶部提示
  void _hideTopMessage() {
    setState(() {
      _topMessage = null;
    });
  }

  
  Future<void> _pushChanges() async {
    final appState = context.read<AppState>();
    final github = context.read<GitHubService>();
    final storage = context.read<StorageService>();
    
    final changes = appState.getSelectedChanges();
    if (changes.isEmpty) return;
    
    // 如果目标是本地工作区
    if (appState.targetIsWorkspace) {
      await _pushToWorkspace(changes, storage, appState);
      return;
    }
    
    final repo = appState.selectedRepo;
    if (repo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择仓库')),
      );
      return;
    }

    
    setState(() => _isPushing = true);
    
    int successCount = 0;
    int failCount = 0;
    
    for (final change in changes) {
      final result = await _pushSingleFile(github, repo, change);
      
      if (result) {
        successCount++;
        appState.updateFileChange(
          change.filePath,
          change.copyWith(status: FileChangeStatus.success),
        );
      } else {
        failCount++;
        appState.updateFileChange(
          change.filePath,
          change.copyWith(status: FileChangeStatus.failed),
        );
      }
    }
    
    // 移除成功的
    final successPaths = appState.fileChanges
        .where((c) => c.status == FileChangeStatus.success)
        .map((c) => c.filePath)
        .toList();
    for (final path in successPaths) {
      appState.removeFileChange(path);
    }
    
    // 保存历史
    await storage.addHistory(OperationHistory(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      repositoryName: repo.fullName,
      changes: changes.map((c) => FileChangeRecord(
        filePath: c.filePath,
        operationType: c.operationType,
        originalContent: c.originalContent,
        modifiedContent: c.modifiedContent,
      )).toList(),
      isSuccessful: failCount == 0,
    ));
    
    setState(() => _isPushing = false);
    
    // 显示顶部提示
    if (mounted) {
      _showTopMessage(
        '推送完成: $successCount 成功, $failCount 失败',
        isSuccess: failCount == 0,
      );
    }

  }

  
  Future<bool> _pushSingleFile(GitHubService github, Repository repo, FileChange change) async {
    if (change.operationType == OperationType.deleteFile) {
      if (change.sha == null) return false;
      final result = await github.deleteFile(
        owner: repo.owner,
        repo: repo.name,
        path: change.filePath,
        sha: change.sha!,
        message: 'Delete ${change.filePath} via AI Code Sync',
        branch: repo.branch,
      );
      return result.success;
    } else {
      final result = await github.createOrUpdateFile(
        owner: repo.owner,
        repo: repo.name,
        path: change.filePath,
        content: change.modifiedContent ?? '',
        message: '${change.operationType == OperationType.create ? "Create" : "Update"} ${change.filePath} via AI Code Sync',
        sha: change.sha,
        branch: repo.branch,
      );
      return result.success;
    }
  }/// 推送到本地工作区
  Future<void> _pushToWorkspace(List<FileChange> changes, StorageService storage, AppState appState) async {
    setState(() => _isPushing = true);
    
    int successCount = 0;
    
    for (final change in changes) {
      if (change.operationType == OperationType.deleteFile) {
        await storage.removeWorkspaceFile(change.filePath);
      } else {
        await storage.addOrUpdateWorkspaceFile(WorkspaceFile(
          path: change.filePath,
          content: change.modifiedContent ?? '',
        ));
      }
      successCount++;
      appState.updateFileChange(
        change.filePath,
        change.copyWith(status: FileChangeStatus.success),
      );
    }
    
    // 移除成功的
    final successPaths = appState.fileChanges
        .where((c) => c.status == FileChangeStatus.success)
        .map((c) => c.filePath)
        .toList();
    for (final path in successPaths) {
      appState.removeFileChange(path);
    }
    
    setState(() => _isPushing = false);
    
    // 显示顶部提示
    if (mounted) {
      _showTopMessage('已保存 $successCount 个文件到本地工作区', isSuccess: true);
    }
  }



  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final fileChanges = appState.fileChanges;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Code Sync'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () async {
              final result = await Navigator.pushNamed(context, '/history');
              if (result != null && result is String && mounted) {
                _showTopMessage(result, isSuccess: true);
              }
            },
          ),

          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.pushNamed(context, '/settings');
              _loadData();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部提示消息
          if (_topMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              decoration: BoxDecoration(
                color: _topMessageSuccess 
                    ? Colors.green.withOpacity(0.15) 
                    : Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _topMessageSuccess 
                      ? Colors.green.withOpacity(0.3) 
                      : Colors.orange.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _topMessageSuccess ? Icons.check_circle : Icons.info,
                    color: _topMessageSuccess ? Colors.green : Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _topMessage!,
                      style: TextStyle(
                        color: _topMessageSuccess ? Colors.green[700] : Colors.orange[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _hideTopMessage,
                    child: Icon(
                      Icons.close,
                      color: _topMessageSuccess ? Colors.green[400] : Colors.orange[400],
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
          
          // 推送目标选择
          Padding(

            padding: const EdgeInsets.all(16),
            child: DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: '推送目标',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cloud_upload),
              ),
              value: appState.targetIsWorkspace ? '_workspace_' : appState.selectedRepo?.fullName,
              items: [
                // 本地工作区选项
                const DropdownMenuItem(
                  value: '_workspace_',
                  child: Row(
                    children: [
                      Icon(Icons.phone_android, size: 20),
                      SizedBox(width: 8),
                      Text('本地工作区'),
                    ],
                  ),
                ),
                // 分隔线
                const DropdownMenuItem(
                  enabled: false,
                  value: '_divider_',
                  child: Divider(),
                ),
                // 仓库列表
                ..._repos.map((r) => DropdownMenuItem(
                  value: r.fullName,
                  child: Text(r.fullName),
                )),
              ],
              onChanged: (value) {
                if (value == '_divider_') return;
                if (value == '_workspace_') {
                  appState.setTargetIsWorkspace(true);
                } else if (value != null) {
                  appState.setTargetIsWorkspace(false);
                  final repo = _repos.firstWhere((r) => r.fullName == value);
                  appState.setSelectedRepo(repo);
                }
              },
              hint: const Text('请选择推送目标'),
            ),
          ),

          
          // 内容区域
          Expanded(
            child: fileChanges.isEmpty
                ? _buildEmptyState()
                : _buildFileList(fileChanges, appState),
          ),
          
          // 底部操作栏
          _buildBottomBar(appState, fileChanges.isNotEmpty),
        ],
      ),
    );
  }
  
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.code, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            '暂无待处理文件',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            '点击下方按钮解析AI消息',
            style: TextStyle(color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
  
  Widget _buildFileList(List<FileChange> changes, AppState appState) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: changes.length,
      itemBuilder: (context, index) {
        final change = changes[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Checkbox(
              value: change.isSelected,
              onChanged: (value) {
                appState.toggleFileSelection(change.filePath, value ?? false);
              },
            ),
            title: Text(
              change.filePath.split('/').last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              change.filePath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (change.totalModifications > 1)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: change.successfulModifications == change.totalModifications
                          ? Colors.green.withOpacity(0.2)
                          : Colors.orange.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${change.successfulModifications}/${change.totalModifications}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: change.successfulModifications == change.totalModifications
                            ? Colors.green
                            : Colors.orange,
                      ),
                    ),
                  ),
                _buildOperationChip(change.operationType),
                const SizedBox(width: 8),
                _buildStatusIcon(change.status, change),
              ],
            ),
            onTap: () {
              Navigator.pushNamed(context, '/editor', arguments: change.filePath);
            },
          ),
        );
      },
    );
  }
  
  Widget _buildOperationChip(OperationType type) {
    final (label, color) = switch (type) {
      OperationType.create => ('新建', Colors.green),
      OperationType.replace => ('替换', Colors.blue),
      OperationType.deleteFile => ('删除', Colors.red),
      OperationType.findReplace => ('修改', Colors.orange),
      OperationType.insertBefore || OperationType.insertAfter => ('插入', Colors.purple),
      OperationType.deleteContent => ('删除段', Colors.red),
    };
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }
  
  Widget _buildStatusIcon(FileChangeStatus status, FileChange change) {
    final icon = switch (status) {
      FileChangeStatus.pending => const Icon(Icons.schedule, color: Colors.grey),
      FileChangeStatus.success => const Icon(Icons.check_circle, color: Colors.green),
      FileChangeStatus.failed => const Icon(Icons.error, color: Colors.red),
      FileChangeStatus.anchorNotFound => const Icon(Icons.warning, color: Colors.orange),
    };
    
    // 如果有错误信息，用 IconButton 阻止事件冒泡
    if (change.errorMessage != null && change.errorMessage!.isNotEmpty) {
      return IconButton(
        icon: icon,
        onPressed: () => _showErrorDialog(change),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        splashRadius: 20,
      );
    }
    
    // 如果是失败状态但没有错误信息，也允许点击查看
    if (status == FileChangeStatus.failed || status == FileChangeStatus.anchorNotFound) {
      return IconButton(
        icon: icon,
        onPressed: () => _showErrorDialog(change),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        splashRadius: 20,
      );
    }
    
    return icon;
  }
  
  void _showErrorDialog(FileChange change) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              change.status == FileChangeStatus.failed ? Icons.error : Icons.warning,
              color: change.status == FileChangeStatus.failed ? Colors.red : Colors.orange,
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('错误详情', style: TextStyle(fontSize: 18))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '文件路径',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
              const SizedBox(height: 4),
              SelectableText(
                change.filePath,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              const SizedBox(height: 16),
              Text(
                '错误信息',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  change.errorMessage ?? '未知错误',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.red),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
  
  Widget _buildBottomBar(AppState appState, bool hasFiles) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 解析AI消息按钮 - 放在顶部
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () async {
                await Navigator.pushNamed(context, '/parser');
              },
              icon: const Icon(Icons.smart_toy),
              label: const Text('解析AI消息'),
            ),
          ),
          
          // 如果有文件，显示操作栏
          if (hasFiles) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    if (appState.selectedCount == appState.fileChanges.length) {
                      appState.deselectAll();
                    } else {
                      appState.selectAll();
                    }
                  },
                  child: Text(
                    appState.selectedCount == appState.fileChanges.length ? '取消全选' : '全选',
                  ),
                ),
                Text(
                  '已选 ${appState.selectedCount}/${appState.fileChanges.length}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('确认清空'),
                        content: const Text('确定要清空所有待处理文件吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              appState.clearAll();
                              Navigator.pop(context);
                            },
                            child: const Text('清空'),
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text('清空'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isPushing || appState.selectedCount == 0 ? null : _pushChanges,
                  icon: _isPushing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload),
                  label: const Text('推送'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models.dart';
import '../services/storage_service.dart';
import '../services/transfer_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<OperationHistory> _history = [];
  bool _isLoading = true;
  String? _error;
  
  @override
  void initState() {
    super.initState();
    // 延迟到下一帧加载，确保 context 可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHistory();
    });
  }
  
  void _loadHistory() {
    try {
      final storage = context.read<StorageService>();
      setState(() {
        _history = storage.getHistory();
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = '加载历史记录失败: $e';
      });
    }
  }

  
  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定要清空所有历史记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      final storage = context.read<StorageService>();
      await storage.clearHistory();
      _loadHistory();
    }
  }
  
  void _restoreHistory(OperationHistory history) {
    final appState = context.read<AppState>();
    
    final changes = history.changes.map((c) => FileChange(
      filePath: c.filePath,
      operationType: c.operationType,
      originalContent: c.originalContent,
      modifiedContent: c.modifiedContent,
      status: FileChangeStatus.pending,
    )).toList();
    
    appState.addFileChanges(changes);
    
    // 返回主界面并传递消息
    Navigator.pop(context, '已恢复 ${changes.length} 个文件');
  }

  /// 同步到工作区（清理后推送到本地工作区和中转站）
  Future<void> _syncToWorkspace(OperationHistory history) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.sync, color: Colors.blue),
            SizedBox(width: 8),
            Text('同步到工作区'),
          ],
        ),
        content: Text(
          '此操作将：\n'
          '1. 清空本地工作区\n'
          '2. 清空中转站\n'
          '3. 将 ${history.changes.length} 个文件同步到工作区和中转站\n\n'
          '确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定同步'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // 显示加载指示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final storage = context.read<StorageService>();
      
      // 1. 清空本地工作区
      await storage.clearWorkspace();
      
      // 2. 清空中转站
      await TransferService.instance.clear();
      
      // 3. 转换为工作区文件并保存
      final workspaceFiles = history.changes
          .where((c) => c.modifiedContent != null)
          .map((c) => WorkspaceFile(
                path: c.filePath,
                content: c.modifiedContent!,
              ))
          .toList();
      
      if (workspaceFiles.isNotEmpty) {
        await storage.addWorkspaceFiles(workspaceFiles);
        
        // 4. 同时上传到中转站
        final transferFiles = workspaceFiles
            .map((f) => TransferFile(path: f.path, content: f.content))
            .toList();
        await TransferService.instance.uploadFiles(transferFiles);
      }

      // 关闭加载指示
      if (mounted) Navigator.pop(context);

      // 返回并显示消息
      if (mounted) {
        Navigator.pop(context, '已同步 ${workspaceFiles.length} 个文件到工作区和中转站');
      }
    } catch (e) {
      // 关闭加载指示
      if (mounted) Navigator.pop(context);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('操作历史'),
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空历史',
              onPressed: _clearHistory,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _loadHistory,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _history.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.history, size: 64, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text(
                            '暂无操作历史',
                            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _history.length,
                      itemBuilder: (context, index) {
                        final item = _history[index];
                        return _buildHistoryItem(item);
                      },
                    ),
    );
  }
  
  Widget _buildHistoryItem(OperationHistory item) {
    final dateStr = '${item.timestamp.month}/${item.timestamp.day} ${item.timestamp.hour}:${item.timestamp.minute.toString().padLeft(2, '0')}';
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: Icon(
          item.isSuccessful ? Icons.check_circle : Icons.error,
          color: item.isSuccessful ? Colors.green : Colors.red,
        ),
        title: Text(item.repositoryName),
        subtitle: Text('$dateStr · ${item.changes.length} 个文件'),
        children: [
          const Divider(height: 1),
          ...item.changes.map((c) => ListTile(
            dense: true,
            leading: _buildTypeIcon(c.operationType),
            title: Text(
              c.filePath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          )),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _restoreHistory(item),
                    icon: const Icon(Icons.restore),
                    label: const Text('恢复'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _syncToWorkspace(item),
                    icon: const Icon(Icons.sync),
                    label: const Text('同步工作区'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.blue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildTypeIcon(OperationType type) {
    final (icon, color) = switch (type) {
      OperationType.create => (Icons.add, Colors.green),
      OperationType.replace => (Icons.edit, Colors.blue),
      OperationType.deleteFile => (Icons.delete, Colors.red),
      _ => (Icons.edit, Colors.orange),
    };
    return Icon(icon, size: 20, color: color);
  }
}

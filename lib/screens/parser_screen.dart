import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models.dart';
import '../services/parser_service.dart';
import '../services/github_service.dart';
import '../services/storage_service.dart';

class ParserScreen extends StatefulWidget {
  const ParserScreen({super.key});

  @override
  State<ParserScreen> createState() => _ParserScreenState();
}

class _ParserScreenState extends State<ParserScreen> {
  final _controller = TextEditingController();
  List<Instruction> _instructions = [];
  Set<int> _selectedIndices = {};
  List<String> _errors = [];
  bool _isProcessing = false;
  bool _hasText = false;  // 新增：跟踪是否有文本
  
  @override
  void initState() {
    super.initState();
    // 监听文本变化
    _controller.addListener(_onTextChanged);
  }
  
  void _onTextChanged() {
    final hasText = _controller.text.isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
  }
  
  void _parseMessage() {
    final parser = context.read<ParserService>();
    final result = parser.parse(_controller.text);
    
    setState(() {
      _instructions = result.instructions;
      _selectedIndices = Set.from(List.generate(_instructions.length, (i) => i));
      _errors = result.errors;
    });
  }
  
  Future<void> _applyInstructions() async {
    if (_selectedIndices.isEmpty) return;
    
    setState(() => _isProcessing = true);
    
    final appState = context.read<AppState>();
    final github = context.read<GitHubService>();
    final storage = context.read<StorageService>();
    final merger = context.read<CodeMerger>();
    final repo = appState.selectedRepo ?? storage.getDefaultRepository();
    
    if (repo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择仓库')),
      );
      setState(() => _isProcessing = false);
      return;
    }
    
    // 按文件分组
    final selectedInstructions = _selectedIndices.map((i) => _instructions[i]).toList();
    final byFile = <String, List<Instruction>>{};
    for (final inst in selectedInstructions) {
      byFile.putIfAbsent(inst.filePath, () => []).add(inst);
    }
    
    final fileChanges = <FileChange>[];
    
    for (final entry in byFile.entries) {
      final filePath = entry.key;
      final instructions = entry.value;
      
      // CREATE 不需要下载，其他都需要（包括 DELETE_FILE 需要获取 SHA）
      final needsDownload = instructions.any((i) => i.type != OperationType.create);
      
      String? originalContent;
      String? sha;
      
      if (needsDownload) {
        final result = await github.getFileContent(
          owner: repo.owner,
          repo: repo.name,
          path: filePath,
          branch: repo.branch,
        );
        if (result.success && !result.notFound) {
          originalContent = result.content;
          sha = result.sha;
        } else if (result.notFound) {
          // 文件不存在
          if (instructions.any((i) => i.type == OperationType.deleteFile)) {
            // 要删除的文件不存在，跳过
            continue;
          }
        }
      }
      
      // 执行合并
      String? modifiedContent = originalContent;
      bool hasError = false;
      String? errorMsg;
      
      // DELETE_FILE 不需要合并
      final isDeleteFile = instructions.any((i) => i.type == OperationType.deleteFile);
      
      if (!isDeleteFile) {
        for (final inst in instructions) {
          final result = merger.execute(inst, modifiedContent);
          if (result.success) {
            modifiedContent = result.content;
          } else {
            hasError = true;
            errorMsg = result.error;
            break;
          }
        }
      }
      
      fileChanges.add(FileChange(
        filePath: filePath,
        operationType: instructions.first.type,
        originalContent: originalContent,
        modifiedContent: isDeleteFile ? null : modifiedContent,
        status: hasError ? FileChangeStatus.anchorNotFound : FileChangeStatus.pending,
        errorMessage: errorMsg,
        sha: sha,
        instructions: instructions,
      ));
    }
    
    appState.addFileChanges(fileChanges);
    
    setState(() => _isProcessing = false);
    
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('解析AI消息'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              _controller.clear();
              setState(() {
                _instructions = [];
                _selectedIndices = {};
                _errors = [];
                _hasText = false;
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 输入区域
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: '粘贴AI回复的消息到这里...',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ),
          
          // 解析按钮
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _hasText ? _parseMessage : null,  // 使用 _hasText
                icon: const Icon(Icons.code),
                label: const Text('解析消息'),
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // 错误信息
          if (_errors.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '解析错误',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                  ),
                  const SizedBox(height: 4),
                  ..._errors.map((e) => Text('• $e', style: const TextStyle(color: Colors.red))),
                ],
              ),
            ),
          
          // 解析结果列表
          if (_instructions.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    '检测到 ${_instructions.length} 个操作',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        if (_selectedIndices.length == _instructions.length) {
                          _selectedIndices = {};
                        } else {
                          _selectedIndices = Set.from(List.generate(_instructions.length, (i) => i));
                        }
                      });
                    },
                    child: Text(_selectedIndices.length == _instructions.length ? '取消全选' : '全选'),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _instructions.length,
                itemBuilder: (context, index) {
                  final inst = _instructions[index];
                  final isSelected = _selectedIndices.contains(index);
                  
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: CheckboxListTile(
                      value: isSelected,
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            _selectedIndices.add(index);
                          } else {
                            _selectedIndices.remove(index);
                          }
                        });
                      },
                      title: Text(
                        inst.filePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(inst.typeDescription),
                      secondary: _buildTypeIcon(inst.type),
                    ),
                  );
                },
              ),
            ),
            
            // 应用按钮
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isProcessing || _selectedIndices.isEmpty ? null : _applyInstructions,
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check),
                  label: Text('应用到主界面 (${_selectedIndices.length})'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  Widget _buildTypeIcon(OperationType type) {
    final (icon, color) = switch (type) {
      OperationType.create => (Icons.add_circle, Colors.green),
      OperationType.replace => (Icons.edit, Colors.blue),
      OperationType.deleteFile => (Icons.delete, Colors.red),
      OperationType.findReplace => (Icons.find_replace, Colors.orange),
      OperationType.insertBefore || OperationType.insertAfter => (Icons.playlist_add, Colors.purple),
      OperationType.deleteContent => (Icons.remove_circle, Colors.red),
    };
    
    return Icon(icon, color: color);
  }
}

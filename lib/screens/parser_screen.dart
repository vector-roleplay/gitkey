import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models.dart';
import '../services/parser_service.dart';
import '../services/github_service.dart';
import '../services/storage_service.dart';

/// 代码块数据结构
class CodeBlock {
  final int index;
  final String filePath;
  final String rawContent;  // 包含 [FILESISU] 的原始内容
  String editedContent;     // 用户可能编辑过的内容
  
  CodeBlock({
    required this.index,
    required this.filePath,
    required this.rawContent,
    String? editedContent,
  }) : editedContent = editedContent ?? rawContent;
  
  /// 获取用于显示的文件名
  String get fileName => filePath.split('/').last;
}

class ParserScreen extends StatefulWidget {
  const ParserScreen({super.key});

  @override
  State<ParserScreen> createState() => _ParserScreenState();
}

class _ParserScreenState extends State<ParserScreen> {
  // 原始输入（用于粘贴）
  final _pasteController = TextEditingController();
  
  // 分割后的代码块
  List<CodeBlock> _blocks = [];
  int _currentBlockIndex = 0;
  
  // 当前块的编辑控制器
  TextEditingController? _blockController;
  final _blockScrollController = ScrollController();
  
  // 解析结果
  List<Instruction> _instructions = [];
  Set<int> _selectedIndices = {};
  List<String> _errors = [];
  bool _isProcessing = false;
  
  // 状态标记
  bool _hasPasted = false;  // 是否已粘贴内容
  bool _hasInput = false;   // 粘贴区是否有内容
  
  @override
  void initState() {
    super.initState();
    _pasteController.addListener(_onPasteTextChanged);
  }
  
  void _onPasteTextChanged() {
    final hasInput = _pasteController.text.isNotEmpty;
    if (hasInput != _hasInput) {
      setState(() {
        _hasInput = hasInput;
      });
    }
  }
  
  @override
  void dispose() {
    _pasteController.removeListener(_onPasteTextChanged);
    _pasteController.dispose();
    _blockController?.dispose();
    _blockScrollController.dispose();
    super.dispose();
  }
  
  /// 处理粘贴的内容，分割成块
  void _processPastedContent(String content) {
    if (content.trim().isEmpty) return;
    
    final blocks = _splitIntoBlocks(content);
    
    if (blocks.isEmpty) {
      // 没有找到 [FILESISU] 标记，显示错误
      setState(() {
        _errors = ['未找到 [FILESISU] 文件标记'];
        _hasPasted = false;
      });
      return;
    }
    
    setState(() {
      _blocks = blocks;
      _currentBlockIndex = 0;
      _hasPasted = true;
      _errors = [];
      _instructions = [];
      _selectedIndices = {};
    });
    
    _loadCurrentBlock();
  }
  
  /// 按 [FILESISU] 分割文本
  List<CodeBlock> _splitIntoBlocks(String content) {
    final blocks = <CodeBlock>[];
    
    // 匹配 [FILESISU] 及其后面的路径
    final pattern = RegExp(
      r'\[FILESISU\]\s*([^\n\[]+)',
      caseSensitive: false,
    );
    
    final matches = pattern.allMatches(content).toList();
    
    for (int i = 0; i < matches.length; i++) {
      final match = matches[i];
      final filePath = match.group(1)?.trim() ?? '';
      
      // 获取这个块的内容范围
      final startPos = match.start;
      final endPos = i < matches.length - 1 
          ? matches[i + 1].start 
          : content.length;
      
      final rawContent = content.substring(startPos, endPos).trim();
      
      blocks.add(CodeBlock(
        index: i,
        filePath: filePath,
        rawContent: rawContent,
      ));
    }
    
    return blocks;
  }
  
  /// 加载当前块到编辑器
  void _loadCurrentBlock() {
    if (_blocks.isEmpty) return;
    
    final block = _blocks[_currentBlockIndex];
    
    _blockController?.dispose();
    _blockController = TextEditingController(text: block.editedContent);
    
    // 滚动到顶部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_blockScrollController.hasClients) {
        _blockScrollController.jumpTo(0);
      }
    });
    
    setState(() {});
  }
  
  /// 保存当前块的编辑内容
  void _saveCurrentBlock() {
    if (_blocks.isEmpty || _blockController == null) return;
    _blocks[_currentBlockIndex].editedContent = _blockController!.text;
  }
  
  /// 导航到指定块
  void _navigateToBlock(int index) {
    if (index < 0 || index >= _blocks.length) return;
    if (index == _currentBlockIndex) return;
    
    _saveCurrentBlock();
    
    setState(() {
      _currentBlockIndex = index;
    });
    
    _loadCurrentBlock();
  }
  
  /// 到第一个块
  void _goToFirst() => _navigateToBlock(0);
  
  /// 到上一个块
  void _goToPrevious() => _navigateToBlock(_currentBlockIndex - 1);
  
  /// 到下一个块
  void _goToNext() => _navigateToBlock(_currentBlockIndex + 1);
  
  /// 到最后一个块
  void _goToLast() => _navigateToBlock(_blocks.length - 1);
  
  /// 解析所有块
  void _parseAllBlocks() {
    _saveCurrentBlock();
    
    // 合并所有块的内容
    final fullContent = _blocks.map((b) => b.editedContent).join('\n\n');
    
    final parser = context.read<ParserService>();
    final result = parser.parse(fullContent);
    
    setState(() {
      _instructions = result.instructions;
      _selectedIndices = Set.from(List.generate(_instructions.length, (i) => i));
      _errors = result.errors;
    });
  }
  
  /// 应用选中的指令
  Future<void> _applyInstructions() async {
    if (_selectedIndices.isEmpty) return;
    
    setState(() => _isProcessing = true);
    
    final appState = context.read<AppState>();
    final github = context.read<GitHubService>();
    final storage = context.read<StorageService>();
    final merger = context.read<CodeMerger>();
    
    final useWorkspace = storage.getWorkspaceMode();
    final repo = appState.selectedRepo ?? storage.getDefaultRepository();
    
    if (!useWorkspace && repo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择仓库')),
      );
      setState(() => _isProcessing = false);
      return;
    }
    
    final selectedInstructions = _selectedIndices.map((i) => _instructions[i]).toList();
    final byFile = <String, List<Instruction>>{};
    for (final inst in selectedInstructions) {
      byFile.putIfAbsent(inst.filePath, () => []).add(inst);
    }
    
    final fileChanges = <FileChange>[];
    
    for (final entry in byFile.entries) {
      final filePath = entry.key;
      final instructions = entry.value;
      
      final isOnlyCreate = instructions.every((i) => i.type == OperationType.create);
      final needsDownload = !isOnlyCreate;
      
      String? originalContent;
      String? sha;
      
      if (needsDownload) {
        if (useWorkspace) {
          final workspaceFile = storage.getWorkspaceFile(filePath);
          if (workspaceFile != null) {
            originalContent = workspaceFile.content;
          } else {
            if (instructions.any((i) => i.type == OperationType.deleteFile)) {
              continue;
            }
          }
        } else {
          final result = await github.getFileContent(
            owner: repo!.owner,
            repo: repo.name,
            path: filePath,
            branch: repo.branch,
          );
          if (result.success && !result.notFound) {
            originalContent = result.content;
            sha = result.sha;
          } else if (result.notFound) {
            if (instructions.any((i) => i.type == OperationType.deleteFile)) {
              continue;
            }
          }
        }
      }
      
      String? modifiedContent = originalContent;
      bool hasError = false;
      String? errorMsg;
      
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
  
  /// 清空所有内容
  void _clearAll() {
    _pasteController.clear();
    _blockController?.dispose();
    _blockController = null;
    
    setState(() {
      _blocks = [];
      _currentBlockIndex = 0;
      _hasPasted = false;
      _hasInput = false;
      _instructions = [];
      _selectedIndices = {};
      _errors = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    // 计算是否显示指令列表
    final showInstructions = _instructions.isNotEmpty;
    
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('解析AI消息'),
        actions: [
          if (_hasPasted || _hasInput)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: '清空',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: Column(
        children: [
          // 主内容区 - 根据是否有指令调整布局
          Expanded(
            flex: showInstructions ? 1 : 2,  // 有指令时缩小
            child: _hasPasted ? _buildBlockViewer() : _buildPasteArea(),
          ),
          
          // 错误显示
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
                  ..._errors.take(5).map((e) => Text(
                    '• $e',
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )),
                  if (_errors.length > 5)
                    Text(
                      '... 还有 ${_errors.length - 5} 个错误',
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                ],
              ),
            ),
          
          // 解析结果列表
          if (showInstructions) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
              flex: 1,
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
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(inst.typeDescription, style: const TextStyle(fontSize: 12)),
                      secondary: _buildTypeIcon(inst.type),
                      dense: true,
                    ),
                  );
                },
              ),
            ),
            
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
  
  /// 构建粘贴区域（初始状态）
  Widget _buildPasteArea() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: TextField(
              controller: _pasteController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
              ),
              decoration: const InputDecoration(
                hintText: '粘贴AI回复的消息到这里...\n\n支持包含多个 [FILESISU] 的长消息',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _hasInput 
                  ? () => _processPastedContent(_pasteController.text)
                  : null,
              icon: const Icon(Icons.content_paste),
              label: const Text('处理粘贴内容'),
            ),
          ),
          const SizedBox(height: 8),
          // 文件计数提示
          if (_hasInput)
            Builder(
              builder: (context) {
                final count = RegExp(r'\[FILESISU\]', caseSensitive: false)
                    .allMatches(_pasteController.text)
                    .length;
                return Text(
                  '检测到 $count 个文件标记',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                );
              },
            ),
        ],
      ),
    );
  }
  
  /// 构建块查看器（分块显示）
  Widget _buildBlockViewer() {
    if (_blocks.isEmpty) {
      return const Center(child: Text('无内容'));
    }
    
    final block = _blocks[_currentBlockIndex];
    final showInstructions = _instructions.isNotEmpty;
    
    return Column(
      children: [
        // 块信息栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${_currentBlockIndex + 1}/${_blocks.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  block.filePath,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        
        // 代码块内容
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.withOpacity(0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _blockController != null
                  ? Scrollbar(
                      controller: _blockScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _blockScrollController,
                        child: TextField(
                          controller: _blockController,
                          maxLines: null,
                          keyboardType: TextInputType.multiline,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.4,
                          ),
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.all(12),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
        
        // 导航按钮 - 有指令时简化显示
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              _buildNavButton(
                icon: Icons.first_page,
                tooltip: '第一个文件',
                onPressed: _currentBlockIndex > 0 ? _goToFirst : null,
              ),
              const SizedBox(width: 8),
              _buildNavButton(
                icon: Icons.chevron_left,
                tooltip: '上一个文件',
                onPressed: _currentBlockIndex > 0 ? _goToPrevious : null,
              ),
              Expanded(
                child: Center(
                  child: _buildFileSelector(),
                ),
              ),
              _buildNavButton(
                icon: Icons.chevron_right,
                tooltip: '下一个文件',
                onPressed: _currentBlockIndex < _blocks.length - 1 ? _goToNext : null,
              ),
              const SizedBox(width: 8),
              _buildNavButton(
                icon: Icons.last_page,
                tooltip: '最后一个文件',
                onPressed: _currentBlockIndex < _blocks.length - 1 ? _goToLast : null,
              ),
            ],
          ),
        ),
        
        // 解析按钮 - 已解析后隐藏
        if (!showInstructions)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _parseAllBlocks,
                icon: const Icon(Icons.code),
                label: Text('解析全部 (${_blocks.length}个文件)'),
              ),
            ),
          ),
      ],
    );
  }
  
  /// 构建文件选择下拉
  Widget _buildFileSelector() {
    return PopupMenuButton<int>(
      onSelected: _navigateToBlock,
      itemBuilder: (context) => List.generate(_blocks.length, (index) {
        final block = _blocks[index];
        final isCurrent = index == _currentBlockIndex;
        
        return PopupMenuItem(
          value: index,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: isCurrent ? Theme.of(context).colorScheme.primary : Colors.grey,
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  block.fileName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              if (isCurrent)
                Icon(Icons.check, size: 18, color: Theme.of(context).colorScheme.primary),
            ],
          ),
        );
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.list, size: 16),
            const SizedBox(width: 4),
            Text(
              '选择文件',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }
  
  Widget _buildNavButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 48,
      height: 40,
      child: IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: onPressed != null 
              ? Theme.of(context).colorScheme.surfaceVariant
              : Colors.grey.withOpacity(0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
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
    
    return Icon(icon, color: color, size: 24);
  }
}

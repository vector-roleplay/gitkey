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
  final _scrollController = ScrollController();
  
  // [FILESISU] 标记位置
  List<int> _fileMarkerPositions = [];
  int _currentMarkerIndex = 0;
  
  // 解析结果
  List<Instruction> _instructions = [];
  Set<int> _selectedIndices = {};
  List<String> _errors = [];
  bool _isProcessing = false;
  
  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }
  
  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
  
  void _onTextChanged() {
    _updateFileMarkerPositions();
  }
  
  /// 更新 [FILESISU] 标记位置
  void _updateFileMarkerPositions() {
    final text = _controller.text;
    final pattern = RegExp(r'\[FILESISU\]', caseSensitive: false);
    final matches = pattern.allMatches(text);
    
    setState(() {
      _fileMarkerPositions = matches.map((m) => m.start).toList();
      // 确保 index 在有效范围内
      if (_fileMarkerPositions.isEmpty) {
        _currentMarkerIndex = 0;
      } else if (_currentMarkerIndex >= _fileMarkerPositions.length) {
        _currentMarkerIndex = _fileMarkerPositions.length - 1;
      }
    });
  }
  
  /// 跳转到第一个标记
  void _goToFirst() {
    if (_fileMarkerPositions.isEmpty) return;
    _currentMarkerIndex = 0;
    _jumpToMarker(_fileMarkerPositions.first);
  }
  
  /// 跳转到上一个标记
  void _goToPrevious() {
    if (_fileMarkerPositions.isEmpty) return;
    if (_currentMarkerIndex > 0) {
      _currentMarkerIndex--;
      _jumpToMarker(_fileMarkerPositions[_currentMarkerIndex]);
    }
  }
  
  /// 跳转到下一个标记
  void _goToNext() {
    if (_fileMarkerPositions.isEmpty) return;
    if (_currentMarkerIndex < _fileMarkerPositions.length - 1) {
      _currentMarkerIndex++;
      _jumpToMarker(_fileMarkerPositions[_currentMarkerIndex]);
    }
  }
  
  /// 跳转到最后一个标记
  void _goToLast() {
    if (_fileMarkerPositions.isEmpty) return;
    _currentMarkerIndex = _fileMarkerPositions.length - 1;
    _jumpToMarker(_fileMarkerPositions.last);
  }
  
  /// 跳转到指定位置
  void _jumpToMarker(int position) {
    // 设置光标位置
    _controller.selection = TextSelection.collapsed(offset: position);
    
    // 计算滚动位置（估算）
    final text = _controller.text.substring(0, position);
    final lineCount = '\n'.allMatches(text).length;
    final lineHeight = 13 * 1.4; // fontSize * height
    final estimatedOffset = lineCount * lineHeight;
    
    // 延迟执行，确保布局完成
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        _scrollController.animateTo(
          estimatedOffset.clamp(0.0, maxScroll),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
    
    setState(() {});
  }
  
  /// 解析内容
  void _parseContent() {
    final parser = context.read<ParserService>();
    final result = parser.parse(_controller.text);
    
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
    _controller.clear();
    setState(() {
      _fileMarkerPositions = [];
      _currentMarkerIndex = 0;
      _instructions = [];
      _selectedIndices = {};
      _errors = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasContent = _controller.text.isNotEmpty;
    final hasMarkers = _fileMarkerPositions.isNotEmpty;
    final showInstructions = _instructions.isNotEmpty;
    
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('解析AI消息'),
        actions: [
          if (hasContent)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: '清空',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: Column(
        children: [
          // 文件标记计数
          if (hasMarkers)
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
                      '${_currentMarkerIndex + 1}/${_fileMarkerPositions.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '个文件标记',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                ],
              ),
            ),
          
          // 主编辑区
          Expanded(
            flex: showInstructions ? 1 : 2,
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    // 代码编辑区
                    Expanded(
                      child: _buildEditor(),
                    ),
                    // 右侧快捷按钮
                    if (hasMarkers)
                      Container(
                        width: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                          border: Border(
                            left: BorderSide(color: Colors.grey.withOpacity(0.3)),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildSideButton(
                              icon: Icons.keyboard_double_arrow_up,
                              tooltip: '第一个',
                              onPressed: _currentMarkerIndex > 0 ? _goToFirst : null,
                            ),
                            const SizedBox(height: 8),
                            _buildSideButton(
                              icon: Icons.keyboard_arrow_up,
                              tooltip: '上一个',
                              onPressed: _currentMarkerIndex > 0 ? _goToPrevious : null,
                            ),
                            const SizedBox(height: 16),
                            _buildSideButton(
                              icon: Icons.keyboard_arrow_down,
                              tooltip: '下一个',
                              onPressed: _currentMarkerIndex < _fileMarkerPositions.length - 1 ? _goToNext : null,
                            ),
                            const SizedBox(height: 8),
                            _buildSideButton(
                              icon: Icons.keyboard_double_arrow_down,
                              tooltip: '最后一个',
                              onPressed: _currentMarkerIndex < _fileMarkerPositions.length - 1 ? _goToLast : null,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
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
          ] else ...[
            // 解析按钮
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: hasMarkers ? _parseContent : null,
                  icon: const Icon(Icons.code),
                  label: Text(hasMarkers 
                    ? '解析 (${_fileMarkerPositions.length}个文件)' 
                    : '粘贴AI消息后点击解析'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  /// 构建编辑器（简化版，不使用Stack叠加）
  Widget _buildEditor() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        child: _controller.text.isEmpty
            ? TextField(
                controller: _controller,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.4,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                decoration: const InputDecoration(
                  hintText: '粘贴AI回复的消息到这里...',
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(12),
                ),
              )
            : GestureDetector(
                onTap: () {
                  // 点击时显示编辑模式
                  _showEditDialog();
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _buildHighlightedText(),
                ),
              ),
      ),
    );
  }
  
  /// 显示编辑对话框
  void _showEditDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.7,
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('编辑内容', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('完成'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.4,
                    color: Theme.of(context).brightness == Brightness.dark 
                        ? Colors.white 
                        : Colors.black87,
                  ),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  /// 构建高亮文本
  Widget _buildHighlightedText() {
    final text = _controller.text;
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normalColor = isDark ? Colors.white : Colors.black87;
    
    final pattern = RegExp(r'\[FILESISU\][^\n]*', caseSensitive: false);
    final spans = <TextSpan>[];
    int lastEnd = 0;
    
    for (final match in pattern.allMatches(text)) {
      // 匹配前的普通文本
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(color: normalColor),
        ));
      }
      
      // 高亮的 [FILESISU] 行
      spans.add(TextSpan(
        text: text.substring(match.start, match.end),
        style: const TextStyle(
          color: Colors.cyan,
          fontWeight: FontWeight.bold,
          backgroundColor: Color(0x2000BCD4),
        ),
      ));
      
      lastEnd = match.end;
    }
    
    // 剩余文本
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(color: normalColor),
      ));
    }
    
    return RichText(
      text: TextSpan(
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
        ),
        children: spans,
      ),
    );
  }
  
  Widget _buildSideButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      style: IconButton.styleFrom(
        backgroundColor: onPressed != null 
            ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
            : Colors.transparent,
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

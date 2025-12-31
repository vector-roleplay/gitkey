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
  final _textFieldFocusNode = FocusNode();

  List<Instruction> _instructions = [];
  Set<int> _selectedIndices = {};
  List<String> _errors = [];
  bool _isProcessing = false;
  bool _hasText = false;
  List<int> _fileMarkerPositions = [];
  
  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }
  
  void _onTextChanged() {
    final hasText = _controller.text.isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
    _updateFileMarkerPositions();
  }
  
  void _updateFileMarkerPositions() {
    final text = _controller.text;
    final pattern = RegExp(r'\[FILESISU\]', caseSensitive: false);
    _fileMarkerPositions = pattern.allMatches(text).map((m) => m.start).toList();
  }
  
  void _scrollToTop() {
    _scrollController.jumpTo(0);
  }
  
  void _scrollToBottom() {
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }
  
  void _scrollToPreviousFile() {
    final currentPosition = _controller.selection.baseOffset;
    if (currentPosition <= 0) return;
    
    for (int i = _fileMarkerPositions.length - 1; i >= 0; i--) {
      if (_fileMarkerPositions[i] < currentPosition - 1) {
        _controller.selection = TextSelection.collapsed(offset: _fileMarkerPositions[i]);
        _ensureCursorVisible();
        break;
      }
    }
  }
  
  void _scrollToNextFile() {
    final currentPosition = _controller.selection.baseOffset;
    
    for (int i = 0; i < _fileMarkerPositions.length; i++) {
      if (_fileMarkerPositions[i] > currentPosition) {
        _controller.selection = TextSelection.collapsed(offset: _fileMarkerPositions[i]);
        _ensureCursorVisible();
        break;
      }
    }
  }
  
  void _ensureCursorVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final textLength = _controller.text.length;
        if (textLength == 0) return;
        final cursorPosition = _controller.selection.baseOffset;
        final ratio = cursorPosition / textLength;
        final targetScroll = _scrollController.position.maxScrollExtent * ratio;
        _scrollController.jumpTo(targetScroll.clamp(0, _scrollController.position.maxScrollExtent));
      }
    });
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
    
    // 检查是否使用本地工作区模式
    final useWorkspace = storage.getWorkspaceMode();
    
    // 如果不是工作区模式，需要检查仓库
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
          // 从本地工作区获取文件
          final workspaceFile = storage.getWorkspaceFile(filePath);
          if (workspaceFile != null) {
            originalContent = workspaceFile.content;
            // 工作区文件没有 sha
          } else {
            // 工作区中没有该文件
            if (instructions.any((i) => i.type == OperationType.deleteFile)) {
              continue; // 跳过删除不存在的文件
            }
            // 其他操作会创建新文件
          }
        } else {
          // 从 GitHub 下载
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

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _scrollController.dispose();
    _textFieldFocusNode.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('解析AI消息'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear),
            tooltip: '清空',
            onPressed: () {
              _controller.clear();
              setState(() {
                _instructions = [];
                _selectedIndices = {};
                _errors = [];
                _hasText = false;
                _fileMarkerPositions = [];
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 4, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      thickness: 6,
                      radius: const Radius.circular(3),
                      child: TextField(
                        controller: _controller,
                        scrollController: _scrollController,
                        focusNode: _textFieldFocusNode,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        // 禁用双击和三击选择，只保留长按选择
                        magnifierConfiguration: TextMagnifierConfiguration.disabled,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.4,
                        ),
                        decoration: const InputDecoration(
                          hintText: '粘贴AI回复的消息到这里...\n(长按可选择文本)',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(12),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 4),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildNavButton(
                        icon: Icons.keyboard_double_arrow_up,
                        tooltip: '到顶部',
                        onPressed: _scrollToTop,
                      ),
                      const SizedBox(height: 8),
                      _buildNavButton(
                        icon: Icons.keyboard_arrow_up,
                        tooltip: '上一个文件',
                        onPressed: _scrollToPreviousFile,
                      ),
                      const SizedBox(height: 8),
                      _buildNavButton(
                        icon: Icons.keyboard_arrow_down,
                        tooltip: '下一个文件',
                        onPressed: _scrollToNextFile,
                      ),
                      const SizedBox(height: 8),
                      _buildNavButton(
                        icon: Icons.keyboard_double_arrow_down,
                        tooltip: '到底部',
                        onPressed: _scrollToBottom,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _hasText ? _parseMessage : null,
                icon: const Icon(Icons.code),
                label: const Text('解析消息'),
              ),
            ),
          ),
          
          const SizedBox(height: 12),
          
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
              flex: 2,
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
  
  Widget _buildNavButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
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
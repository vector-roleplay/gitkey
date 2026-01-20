import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../third_party/scrollable_positioned_list/lib/scrollable_positioned_list.dart';
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
  // 分段数据
  List<_TextSegment> _segments = [];
  
  // 记录每个带标记段落在 _segments 中的索引
  List<int> _markerSegmentIndices = [];
  
  // 滚动控制器
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  
  // 当前定位
  int _currentMarkerIndex = 0;
  int _markerCount = 0;
  
  // 解析结果
  List<Instruction> _instructions = [];
  Set<int> _selectedIndices = {};
  List<String> _errors = [];
  bool _isProcessing = false;
  
  // 输入控制器（用于空状态时的输入）
  final TextEditingController _inputController = TextEditingController();
  
  // 防止重复触发
  bool _isParsingText = false;

  @override
  void initState() {
    super.initState();
    _inputController.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _inputController.removeListener(_onInputChanged);
    _inputController.dispose();
    for (final seg in _segments) {
      seg.controller.removeListener(seg.listener);
      seg.controller.dispose();
    }
    super.dispose();
  }

  /// 当输入框内容变化时，检测是否有 [FILESISU] 标记
  void _onInputChanged() {
    if (_isParsingText) return;
    final text = _inputController.text;
    if (_hasFileMarker(text)) {
      _parseTextIntoSegments(text);
    }
  }

  /// 检测文本中是否有 [FILESISU] 标记
  bool _hasFileMarker(String text) {
    return RegExp(r'\[FILESISU\]', caseSensitive: false).hasMatch(text);
  }

  /// 将文本解析为分段
  void _parseTextIntoSegments(String text) {
    _isParsingText = true;
    
    // 清理旧的控制器和监听器
    for (final seg in _segments) {
      seg.controller.removeListener(seg.listener);
      seg.controller.dispose();
    }
    _segments.clear();
    _markerSegmentIndices.clear();

    // 找到所有 [FILESISU] 的位置
    final pattern = RegExp(r'\[FILESISU\]', caseSensitive: false);
    final matches = pattern.allMatches(text).toList();

    if (matches.isEmpty) {
      _isParsingText = false;
      setState(() {
        _markerCount = 0;
        _currentMarkerIndex = 0;
      });
      return;
    }

    // 按 [FILESISU] 位置分割文本
    int lastEnd = 0;
    int markerIndex = 0;
    
    for (int i = 0; i < matches.length; i++) {
      final match = matches[i];
      
      // 如果 [FILESISU] 前有内容，作为一个无标记段
      if (match.start > lastEnd) {
        final beforeText = text.substring(lastEnd, match.start);
        if (beforeText.trim().isNotEmpty) {
          _addSegment(beforeText, hasMarker: false, markerIndex: -1);
        }
      }

      // [FILESISU] 开始的段落（到下一个 [FILESISU] 或结尾）
      final segmentEnd = (i + 1 < matches.length) ? matches[i + 1].start : text.length;
      final segmentText = text.substring(match.start, segmentEnd);
      
      // 记录这个带标记段落在 _segments 中的索引
      _markerSegmentIndices.add(_segments.length);
      _addSegment(segmentText, hasMarker: true, markerIndex: markerIndex);
      markerIndex++;

      lastEnd = segmentEnd;
    }

    // 清空输入控制器
    _inputController.clear();
    
    _isParsingText = false;

    setState(() {
      _markerCount = matches.length;
      _currentMarkerIndex = _markerCount > 0 
          ? _currentMarkerIndex.clamp(0, _markerCount - 1) 
          : 0;
    });
  }

  /// 添加分段并设置监听器
  void _addSegment(String text, {required bool hasMarker, required int markerIndex}) {
    final segment = _TextSegment(
      text: text,
      hasMarker: hasMarker,
      markerIndex: markerIndex,
    );
    // 监听分段内容变化，触发重建以更新高亮
    segment.listener = () {
      if (mounted) setState(() {});
    };
    segment.controller.addListener(segment.listener);
    _segments.add(segment);
  }

  /// 获取完整文本（用于解析）
  String _getFullText() {
    if (_segments.isEmpty) {
      return _inputController.text;
    }
    return _segments.map((s) => s.controller.text).join();
  }

  /// 跳转到第一个标记
  void _goToFirst() {
    if (_markerCount == 0 || _currentMarkerIndex == 0) return;
    _currentMarkerIndex = 0;
    _scrollToCurrentMarker();
  }

  /// 跳转到上一个标记
  void _goToPrevious() {
    if (_markerCount == 0 || _currentMarkerIndex <= 0) return;
    _currentMarkerIndex--;
    _scrollToCurrentMarker();
  }

  /// 跳转到下一个标记
  void _goToNext() {
    if (_markerCount == 0 || _currentMarkerIndex >= _markerCount - 1) return;
    _currentMarkerIndex++;
    _scrollToCurrentMarker();
  }

  /// 跳转到最后一个标记
  void _goToLast() {
    if (_markerCount == 0 || _currentMarkerIndex == _markerCount - 1) return;
    _currentMarkerIndex = _markerCount - 1;
    _scrollToCurrentMarker(alignBottom: true);
  }

  /// 滚动到当前标记位置
  void _scrollToCurrentMarker({bool alignBottom = false}) {
    setState(() {});

    if (_currentMarkerIndex < 0 || _currentMarkerIndex >= _markerSegmentIndices.length) return;
    if (!_itemScrollController.isAttached) return;
    
    final segmentIndex = _markerSegmentIndices[_currentMarkerIndex];
    
    if (alignBottom) {
      // 跳到最后：先跳到目标，再跳到物理底部
      _itemScrollController.jumpTo(index: segmentIndex, alignment: 0.0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _itemScrollController.scrollToEnd();
      });
    } else if (_currentMarkerIndex == 0) {
      // 跳到第一个：先跳到目标，再跳到物理顶部
      _itemScrollController.jumpTo(index: segmentIndex, alignment: 0.0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _itemScrollController.scrollToStart();
      });
    } else {
      // 普通跳转：顶边对齐
      _itemScrollController.jumpTo(index: segmentIndex, alignment: 0.0);
    }
  }

  /// 解析内容
  void _parseContent() {
    final text = _getFullText();
    final parser = context.read<ParserService>();
    final result = parser.parse(text);

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
    _isParsingText = true;
    
    for (final seg in _segments) {
      seg.controller.removeListener(seg.listener);
      seg.controller.dispose();
    }
    _segments.clear();
    _markerSegmentIndices.clear();
    _inputController.clear();
    
    _isParsingText = false;

    setState(() {
      _markerCount = 0;
      _currentMarkerIndex = 0;
      _instructions = [];
      _selectedIndices = {};
      _errors = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasContent = _segments.isNotEmpty || _inputController.text.isNotEmpty;
    final hasMarkers = _markerCount > 0;
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
          // 文件标记计数和导航
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
                      '${_currentMarkerIndex + 1}/$_markerCount',
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
                  const Spacer(),
                  // 导航按钮
                  _buildNavButton(
                    icon: Icons.keyboard_double_arrow_up,
                    tooltip: '第一个',
                    onPressed: _currentMarkerIndex > 0 ? _goToFirst : null,
                  ),
                  _buildNavButton(
                    icon: Icons.keyboard_arrow_up,
                    tooltip: '上一个',
                    onPressed: _currentMarkerIndex > 0 ? _goToPrevious : null,
                  ),
                  _buildNavButton(
                    icon: Icons.keyboard_arrow_down,
                    tooltip: '下一个',
                    onPressed: _currentMarkerIndex < _markerCount - 1 ? _goToNext : null,
                  ),
                  _buildNavButton(
                    icon: Icons.keyboard_double_arrow_down,
                    tooltip: '最后一个',
                    onPressed: _currentMarkerIndex < _markerCount - 1 ? _goToLast : null,
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
                child: _segments.isEmpty
                    ? _buildEmptyInputArea()
                    : _buildSegmentedEditor(),
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
                  label: Text(hasMarkers ? '解析 ($_markerCount个文件)' : '粘贴AI消息后点击解析'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 构建导航按钮
  Widget _buildNavButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      style: IconButton.styleFrom(
        backgroundColor: onPressed != null
            ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
            : Colors.transparent,
      ),
    );
  }

  /// 空状态的输入区域
  Widget _buildEmptyInputArea() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return TextField(
      controller: _inputController,
      maxLines: null,
      expands: true,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
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
    );
  }

  /// 分段编辑器
  Widget _buildSegmentedEditor() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ScrollablePositionedList.builder(
      itemCount: _segments.length,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      padding: const EdgeInsets.all(12),
      itemBuilder: (context, index) {
        final segment = _segments[index];
        return _buildSegmentTextField(segment, isDark);
      },
    );
  }

  /// 构建单个分段的文本框
  Widget _buildSegmentTextField(_TextSegment segment, bool isDark) {
    final text = segment.controller.text;
    final hasContent = text.isNotEmpty;

    return Stack(
      children: [
        // 高亮层（底层显示）
        if (hasContent)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _buildHighlightedText(text, isDark),
          ),
        // 编辑层（顶层接收输入，文字透明）
        TextField(
          controller: segment.controller,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            height: 1.4,
            color: hasContent ? Colors.transparent : (isDark ? Colors.white : Colors.black87),
          ),
          cursorColor: Theme.of(context).colorScheme.primary,
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            hintText: hasContent ? null : '...',
            hintStyle: TextStyle(color: Colors.grey[500]),
          ),
        ),
      ],
    );
  }

  /// 高亮显示文本
  Widget _buildHighlightedText(String text, bool isDark) {
    final normalColor = isDark ? Colors.white : Colors.black87;
    final pattern = RegExp(r'\[FILESISU\][^\n]*', caseSensitive: false);
    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(color: normalColor),
        ));
      }

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

    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(color: normalColor),
      ));
    }

    return Text.rich(
      TextSpan(
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
        ),
        children: spans,
      ),
      softWrap: true,
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

/// 文本分段
class _TextSegment {
  final TextEditingController controller;
  final bool hasMarker;
  final int markerIndex;
  late VoidCallback listener;

  _TextSegment({
    required String text,
    required this.hasMarker,
    required this.markerIndex,
  }) : controller = TextEditingController(text: text);
}

import 'package:flutter/material.dart';

class CodeEditor extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback? onChanged;
  final String language;
  final bool readOnly;
  
  const CodeEditor({
    super.key,
    required this.controller,
    this.onChanged,
    this.language = 'text',
    this.readOnly = false,
  });

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _lineNumberController = ScrollController();
  int _lineCount = 1;

  @override
  void initState() {
    super.initState();
    _updateLineCount();
    widget.controller.addListener(_updateLineCount);
    // 监听代码区滚动，同步行号区
    _scrollController.addListener(_syncLineNumberScroll);
  }

  void _updateLineCount() {
    final count = '\n'.allMatches(widget.controller.text).length + 1;
    if (count != _lineCount) {
      setState(() {
        _lineCount = count;
      });
    }
  }

  void _syncLineNumberScroll() {
    if (_lineNumberController.hasClients && _scrollController.hasClients) {
      _lineNumberController.jumpTo(_scrollController.offset);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateLineCount);
    _scrollController.removeListener(_syncLineNumberScroll);
    _scrollController.dispose();
    _lineNumberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const double lineHeight = 24.0;
    
    return Container(
      color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFAFAFA),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行号列 - 与代码区同步滚动
          Container(
            width: 48,
            color: isDark ? const Color(0xFF252526) : const Color(0xFFE8E8E8),
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                controller: _lineNumberController,
                physics: const NeverScrollableScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(
                      _lineCount,
                      (i) => SizedBox(
                        height: lineHeight,
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            height: 1.7,
                            color: Colors.grey[500],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          // 代码编辑区
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scrollController,
                child: TextField(
                  controller: widget.controller,
                  onChanged: (_) => widget.onChanged?.call(),
                  readOnly: widget.readOnly,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    height: 1.7,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(12),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

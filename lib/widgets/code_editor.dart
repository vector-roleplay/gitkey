import 'package:flutter/material.dart';

class CodeEditor extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFAFAFA),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行号
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: isDark ? const Color(0xFF252526) : const Color(0xFFF0F0F0),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, child) {
                final lineCount = '\n'.allMatches(value.text).length + 1;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(
                    lineCount,
                    (index) => Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.5,
                        color: Colors.grey[500],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          
          // 代码区域
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicWidth(
                child: TextField(
                  controller: controller,
                  onChanged: (_) => onChanged?.call(),
                  readOnly: readOnly,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    height: 1.5,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(8),
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

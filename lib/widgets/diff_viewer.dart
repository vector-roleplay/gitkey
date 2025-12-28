import 'package:flutter/material.dart';
import '../models.dart';

class DiffViewer extends StatelessWidget {
  final List<DiffLine> diffLines;
  
  const DiffViewer({super.key, required this.diffLines});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // 统计
    final addedCount = diffLines.where((l) => l.type == DiffLineType.added).length;
    final removedCount = diffLines.where((l) => l.type == DiffLineType.removed).length;
    
    return Column(
      children: [
        // 统计栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: isDark ? const Color(0xFF252526) : const Color(0xFFF0F0F0),
          child: Row(
            children: [
              const Icon(Icons.difference, size: 18),
              const SizedBox(width: 8),
              const Text('差异预览'),
              const Spacer(),
              Text(
                '+$addedCount',
                style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 12),
              Text(
                '-$removedCount',
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        
        // Diff内容
        Expanded(
          child: diffLines.isEmpty
              ? const Center(child: Text('无差异'))
              : ListView.builder(
                  itemCount: diffLines.length,
                  itemBuilder: (context, index) {
                    final line = diffLines[index];
                    return _buildDiffLine(line, isDark);
                  },
                ),
        ),
      ],
    );
  }
  
  Widget _buildDiffLine(DiffLine line, bool isDark) {
    final (bgColor, textColor, prefix) = switch (line.type) {
      DiffLineType.added => (
        Colors.green.withOpacity(0.15),
        Colors.green[700],
        '+ ',
      ),
      DiffLineType.removed => (
        Colors.red.withOpacity(0.15),
        Colors.red[700],
        '- ',
      ),
      DiffLineType.unchanged => (
        Colors.transparent,
        isDark ? Colors.grey[300] : Colors.grey[700],
        '  ',
      ),
    };
    
    return Container(
      color: bgColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行号
          Container(
            width: 80,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            color: isDark ? const Color(0xFF252526) : const Color(0xFFF0F0F0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  line.oldLineNumber?.toString() ?? '',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.grey[500],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  line.newLineNumber?.toString() ?? '',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
          
          // 内容
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                  '$prefix${line.content}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: textColor,
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

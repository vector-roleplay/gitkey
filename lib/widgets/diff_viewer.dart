import 'package:flutter/material.dart';
import '../models.dart';

class DiffViewer extends StatelessWidget {
  final List<DiffLine> diffLines;
  
  const DiffViewer({super.key, required this.diffLines});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final addedCount = diffLines.where((l) => l.type == DiffLineType.added).length;
    final removedCount = diffLines.where((l) => l.type == DiffLineType.removed).length;
    
    return Column(
      children: [
        // 统计栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: isDark ? const Color(0xFF252526) : const Color(0xFFF0F0F0),
          child: Row(
            children: [
              const Icon(Icons.difference, size: 20),
              const SizedBox(width: 8),
              const Text('差异预览', style: TextStyle(fontWeight: FontWeight.w500)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '+$addedCount',
                  style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '-$removedCount',
                  style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        
        // 差异内容
        Expanded(
          child: diffLines.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, size: 48, color: Colors.grey[400]),
                      const SizedBox(height: 12),
                      Text('无变更', style: TextStyle(color: Colors.grey[500])),
                    ],
                  ),
                )
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
        Colors.green[400],
        '+',
      ),
      DiffLineType.removed => (
        Colors.red.withOpacity(0.15),
        Colors.red[400],
        '-',
      ),
      DiffLineType.unchanged => (
        Colors.transparent,
        isDark ? Colors.grey[300] : Colors.grey[700],
        ' ',
      ),
    };
    
    final lineNum = line.newLineNumber ?? line.oldLineNumber ?? 0;
    
    return Container(
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行号
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
              child: Text(
                lineNum > 0 ? '$lineNum' : '',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: Colors.grey[500],
                ),
              ),
            ),
          ),
          
          // 前缀
          SizedBox(
            width: 20,
            child: Text(
              prefix,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: textColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          
          // 内容（自动换行）
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line.content,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: textColor,
                ),
                softWrap: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
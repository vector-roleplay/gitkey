import '../models.dart';

class ParserService {
  static const _fileTag = 'FILESISU';
  
  /// 解析AI消息，提取所有文件操作指令
  ParseResult parse(String message) {
    final instructions = <Instruction>[];
    final errors = <String>[];
    
    // 匹配 [FILESISU] 标记 - 必须在行首或前面是空白
    final filePattern = RegExp(r'(?:^|\n)\s*\[FILESISU\]\s*(.+?)(?=\n|\[)', caseSensitive: false);
    final fileMatches = filePattern.allMatches(message);
    
    if (fileMatches.isEmpty) {
      errors.add('未找到文件标记');
      return ParseResult(instructions: instructions, errors: errors);
    }
    
    for (final fileMatch in fileMatches) {
      final filePath = fileMatch.group(1)?.trim() ?? '';
      if (filePath.isEmpty) {
        errors.add('文件路径为空');
        continue;
      }
      
      // 获取该文件后面的内容，直到下一个 [FILESISU] 或结尾
      final startPos = fileMatch.end;
      final nextFileMatch = filePattern.firstMatch(message.substring(startPos));
      final endPos = nextFileMatch != null ? startPos + nextFileMatch.start : message.length;
      final afterFile = message.substring(startPos, endPos);
      
      // 尝试匹配各种操作
      final instruction = _parseOperation(filePath, afterFile, errors);
      if (instruction != null) {
        instructions.add(instruction);
      }
    }
    
    return ParseResult(instructions: instructions, errors: errors);
  }
  
  Instruction? _parseOperation(String filePath, String content, List<String> errors) {
    // [CREATE] ... [/CREATE]
    final createPattern = RegExp(
      r'\[CREATE\]\s*\n?([\s\S]*?)\[/CREATE\]',
      caseSensitive: false,
    );
    final createMatch = createPattern.firstMatch(content);
    if (createMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.create,
        content: createMatch.group(1)?.trim(),
      );
    }
    
    // [REPLACE] ... [/REPLACE]
    final replacePattern = RegExp(
      r'\[REPLACE\]\s*\n?([\s\S]*?)\[/REPLACE\]',
      caseSensitive: false,
    );
    final replaceMatch = replacePattern.firstMatch(content);
    if (replaceMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.replace,
        content: replaceMatch.group(1),
      );
    }
    
    // [DELETE_FILE]
    final deleteFilePattern = RegExp(r'\[DELETE_FILE\]', caseSensitive: false);
    if (deleteFilePattern.hasMatch(content)) {
      return Instruction(
        filePath: filePath,
        type: OperationType.deleteFile,
      );
    }
    
    // [MODIFY] with [ANCHOR_START] [ANCHOR_END] [CONTENT]
    final modifyPattern = RegExp(
      r'\[MODIFY\]\s*\n?\[ANCHOR_START\]\s*\n?([\s\S]*?)\[/ANCHOR_START\]\s*\n?\[ANCHOR_END\]\s*\n?([\s\S]*?)\[/ANCHOR_END\]\s*\n?\[CONTENT\]\s*\n?([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final modifyMatch = modifyPattern.firstMatch(content);
    if (modifyMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.findReplace,
        anchorStart: modifyMatch.group(1)?.trim(),
        anchorEnd: modifyMatch.group(2)?.trim(),
        content: modifyMatch.group(3),
      );
    }
    
    // [DELETE] with [ANCHOR_START] [ANCHOR_END]
    final deletePattern = RegExp(
      r'\[DELETE\]\s*\n?\[ANCHOR_START\]\s*\n?([\s\S]*?)\[/ANCHOR_START\]\s*\n?\[ANCHOR_END\]\s*\n?([\s\S]*?)\[/ANCHOR_END\]',
      caseSensitive: false,
    );
    final deleteMatch = deletePattern.firstMatch(content);
    if (deleteMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.deleteContent,
        anchorStart: deleteMatch.group(1)?.trim(),
        anchorEnd: deleteMatch.group(2)?.trim(),
      );
    }
    
    // [INSERT_AFTER] with [ANCHOR] [CONTENT]
    final insertAfterPattern = RegExp(
      r'\[INSERT_AFTER\]\s*\n?\[ANCHOR\]\s*\n?([\s\S]*?)\[/ANCHOR\]\s*\n?\[CONTENT\]\s*\n?([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final insertAfterMatch = insertAfterPattern.firstMatch(content);
    if (insertAfterMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.insertAfter,
        anchor: insertAfterMatch.group(1)?.trim(),
        content: insertAfterMatch.group(2),
      );
    }
    
    // [INSERT_BEFORE] with [ANCHOR] [CONTENT]
    final insertBeforePattern = RegExp(
      r'\[INSERT_BEFORE\]\s*\n?\[ANCHOR\]\s*\n?([\s\S]*?)\[/ANCHOR\]\s*\n?\[CONTENT\]\s*\n?([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final insertBeforeMatch = insertBeforePattern.firstMatch(content);
    if (insertBeforeMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.insertBefore,
        anchor: insertBeforeMatch.group(1)?.trim(),
        content: insertBeforeMatch.group(2),
      );
    }
    
    errors.add('$filePath: 未识别到有效操作');
    return null;
  }
}

class ParseResult {
  final List<Instruction> instructions;
  final List<String> errors;
  
  ParseResult({required this.instructions, required this.errors});
}

/// 代码合并器
class CodeMerger {
  /// 执行指令，返回合并结果
  MergeResult execute(Instruction instruction, String? originalContent) {
    switch (instruction.type) {
      case OperationType.create:
      case OperationType.replace:
        return MergeResult(
          success: true,
          content: instruction.content ?? '',
        );
        
      case OperationType.deleteFile:
        return MergeResult(success: true, content: null);
        
      case OperationType.findReplace:
        return _findAndReplace(originalContent, instruction);
        
      case OperationType.deleteContent:
        return _deleteContent(originalContent, instruction);
        
      case OperationType.insertAfter:
        return _insertAfter(originalContent, instruction);
        
      case OperationType.insertBefore:
        return _insertBefore(originalContent, instruction);
    }
  }
  
  /// 规范化文本：去掉每行首尾空格，统一换行符
  String _normalize(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .join('\n')
        .trim();
  }
  
  /// 在原始内容中查找锚点位置（支持规范化匹配）
  AnchorMatch? _findAnchor(String content, String anchor) {
    // 先尝试精确匹配
    int index = content.indexOf(anchor);
    if (index != -1) {
      int count = anchor.allMatches(content).length;
      return AnchorMatch(
        start: index,
        end: index + anchor.length,
        matchedText: anchor,
        occurrences: count,
        isExactMatch: true,
      );
    }
    
    // 规范化匹配：逐行比较（忽略首尾空格）
    final anchorLines = anchor.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (anchorLines.isEmpty) return null;
    
    final contentLines = content.split('\n');
    
    List<int> matchPositions = [];
    
    for (int i = 0; i <= contentLines.length - anchorLines.length; i++) {
      bool match = true;
      for (int j = 0; j < anchorLines.length; j++) {
        if (contentLines[i + j].trim() != anchorLines[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        matchPositions.add(i);
      }
    }
    
    if (matchPositions.isEmpty) return null;
    
    // 计算第一个匹配的位置
    int lineIndex = matchPositions.first;
    int start = 0;
    for (int k = 0; k < lineIndex; k++) {
      start += contentLines[k].length + 1;
    }
    int end = start;
    for (int k = 0; k < anchorLines.length; k++) {
      end += contentLines[lineIndex + k].length + 1;
    }
    if (end > 0) end--;
    
    return AnchorMatch(
      start: start,
      end: end,
      matchedText: contentLines.sublist(lineIndex, lineIndex + anchorLines.length).join('\n'),
      occurrences: matchPositions.length,
      isExactMatch: false,
    );
  }
  
  MergeResult _findAndReplace(String? originalContent, Instruction instruction) {
    if (originalContent == null || originalContent.isEmpty) {
      return MergeResult(success: false, error: '原始内容为空');
    }
    
    final anchorStart = instruction.anchorStart;
    final anchorEnd = instruction.anchorEnd;
    final newContent = instruction.content ?? '';
    
    if (anchorStart == null || anchorStart.isEmpty) {
      return MergeResult(success: false, error: '开始锚点为空');
    }
    if (anchorEnd == null || anchorEnd.isEmpty) {
      return MergeResult(success: false, error: '结束锚点为空');
    }
    
    final startMatch = _findAnchor(originalContent, anchorStart);
    if (startMatch == null) {
      return MergeResult(success: false, error: '未找到开始锚点');
    }
    
    if (startMatch.occurrences > 1) {
      return MergeResult(
        success: false, 
        error: '开始锚点不唯一(${startMatch.occurrences}次)',
      );
    }
    
    final afterStart = originalContent.substring(startMatch.start);
    final endMatch = _findAnchor(afterStart, anchorEnd);
    if (endMatch == null) {
      return MergeResult(success: false, error: '未找到结束锚点');
    }
    
    final actualEndPos = startMatch.start + endMatch.end;
    
    final result = originalContent.substring(0, startMatch.start) +
        newContent +
        originalContent.substring(actualEndPos);
    
    return MergeResult(success: true, content: result);
  }
  
  MergeResult _deleteContent(String? originalContent, Instruction instruction) {
    if (originalContent == null || originalContent.isEmpty) {
      return MergeResult(success: false, error: '原始内容为空');
    }
    
    final anchorStart = instruction.anchorStart;
    final anchorEnd = instruction.anchorEnd;
    
    if (anchorStart == null || anchorStart.isEmpty) {
      return MergeResult(success: false, error: '开始锚点为空');
    }
    if (anchorEnd == null || anchorEnd.isEmpty) {
      return MergeResult(success: false, error: '结束锚点为空');
    }
    
    final startMatch = _findAnchor(originalContent, anchorStart);
    if (startMatch == null) {
      return MergeResult(success: false, error: '未找到开始锚点');
    }
    
    if (startMatch.occurrences > 1) {
      return MergeResult(
        success: false,
        error: '开始锚点不唯一(${startMatch.occurrences}次)',
      );
    }
    
    final afterStart = originalContent.substring(startMatch.start);
    final endMatch = _findAnchor(afterStart, anchorEnd);
    if (endMatch == null) {
      return MergeResult(success: false, error: '未找到结束锚点');
    }
    
    final actualEndPos = startMatch.start + endMatch.end;
    
    final result = originalContent.substring(0, startMatch.start) +
        originalContent.substring(actualEndPos);
    
    return MergeResult(success: true, content: result);
  }
  
  MergeResult _insertAfter(String? originalContent, Instruction instruction) {
    if (originalContent == null || originalContent.isEmpty) {
      return MergeResult(success: false, error: '原始内容为空');
    }
    
    final anchor = instruction.anchor;
    final newContent = instruction.content ?? '';
    
    if (anchor == null || anchor.isEmpty) {
      return MergeResult(success: false, error: '锚点为空');
    }
    
    final match = _findAnchor(originalContent, anchor);
    if (match == null) {
      return MergeResult(success: false, error: '未找到锚点');
    }
    
    if (match.occurrences > 1) {
      return MergeResult(
        success: false,
        error: '锚点不唯一(${match.occurrences}次)',
      );
    }
    
    final result = originalContent.substring(0, match.end) +
        newContent +
        originalContent.substring(match.end);
    
    return MergeResult(success: true, content: result);
  }
  
  MergeResult _insertBefore(String? originalContent, Instruction instruction) {
    if (originalContent == null || originalContent.isEmpty) {
      return MergeResult(success: false, error: '原始内容为空');
    }
    
    final anchor = instruction.anchor;
    final newContent = instruction.content ?? '';
    
    if (anchor == null || anchor.isEmpty) {
      return MergeResult(success: false, error: '锚点为空');
    }
    
    final match = _findAnchor(originalContent, anchor);
    if (match == null) {
      return MergeResult(success: false, error: '未找到锚点');
    }
    
    if (match.occurrences > 1) {
      return MergeResult(
        success: false,
        error: '锚点不唯一(${match.occurrences}次)',
      );
    }
    
    final result = originalContent.substring(0, match.start) +
        newContent +
        originalContent.substring(match.start);
    
    return MergeResult(success: true, content: result);
  }
}

class AnchorMatch {
  final int start;
  final int end;
  final String matchedText;
  final int occurrences;
  final bool isExactMatch;
  
  AnchorMatch({
    required this.start,
    required this.end,
    required this.matchedText,
    required this.occurrences,
    required this.isExactMatch,
  });
}

class MergeResult {
  final bool success;
  final String? content;
  final String? error;
  
  MergeResult({required this.success, this.content, this.error});
}

class DiffGenerator {
  List<DiffLine> generate(String? original, String? modified) {
    final lines = <DiffLine>[];
    
    if (original == null && modified == null) return lines;
    
    if (original == null || original.isEmpty) {
      final modLines = (modified ?? '').split('\n');
      for (int i = 0; i < modLines.length; i++) {
        lines.add(DiffLine(
          type: DiffLineType.added,
          content: modLines[i],
          newLineNumber: i + 1,
        ));
      }
      return lines;
    }
    
    if (modified == null || modified.isEmpty) {
      final origLines = original.split('\n');
      for (int i = 0; i < origLines.length; i++) {
        lines.add(DiffLine(
          type: DiffLineType.removed,
          content: origLines[i],
          oldLineNumber: i + 1,
        ));
      }
      return lines;
    }
    
    final origLines = original.split('\n');
    final modLines = modified.split('\n');
    
    int i = 0, j = 0;
    int oldNum = 1, newNum = 1;
    
    while (i < origLines.length || j < modLines.length) {
      if (i >= origLines.length) {
        lines.add(DiffLine(
          type: DiffLineType.added,
          content: modLines[j],
          newLineNumber: newNum++,
        ));
        j++;
      } else if (j >= modLines.length) {
        lines.add(DiffLine(
          type: DiffLineType.removed,
          content: origLines[i],
          oldLineNumber: oldNum++,
        ));
        i++;
      } else if (origLines[i] == modLines[j]) {
        lines.add(DiffLine(
          type: DiffLineType.unchanged,
          content: origLines[i],
          oldLineNumber: oldNum++,
          newLineNumber: newNum++,
        ));
        i++;
        j++;
      } else {
        lines.add(DiffLine(
          type: DiffLineType.removed,
          content: origLines[i],
          oldLineNumber: oldNum++,
        ));
        lines.add(DiffLine(
          type: DiffLineType.added,
          content: modLines[j],
          newLineNumber: newNum++,
        ));
        i++;
        j++;
      }
    }
    
    return lines;
  }
}

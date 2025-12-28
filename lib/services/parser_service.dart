import '../models.dart';

class ParserService {
  ParseResult parse(String message) {
    final instructions = <Instruction>[];
    final errors = <String>[];
    
    final filePattern = RegExp(r'\[FILE\]\s*(.+?)(?=\n|\[)', caseSensitive: false);
    final fileMatches = filePattern.allMatches(message).toList();
    
    if (fileMatches.isEmpty) {
      errors.add('未找到 [FILE] 标记');
      return ParseResult(instructions: instructions, errors: errors);
    }
    
    for (var i = 0; i < fileMatches.length; i++) {
      final filePath = fileMatches[i].group(1)!.trim();
      final startIndex = fileMatches[i].end;
      final endIndex = i < fileMatches.length - 1 
          ? fileMatches[i + 1].start 
          : message.length;
      final content = message.substring(startIndex, endIndex);
      
      try {
        final fileInstructions = _parseFileBlock(filePath, content);
        if (fileInstructions.isEmpty) {
          errors.add('$filePath: 未识别到有效操作');
        }
        instructions.addAll(fileInstructions);
      } catch (e) {
        errors.add('解析 $filePath 失败: $e');
      }
    }
    
    return ParseResult(instructions: instructions, errors: errors);
  }
  
  List<Instruction> _parseFileBlock(String filePath, String content) {
    final instructions = <Instruction>[];
    
    // [DELETE_FILE]
    if (RegExp(r'\[DELETE_FILE\]', caseSensitive: false).hasMatch(content)) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.deleteFile,
      ));
      return instructions;
    }
    
    // [CREATE] ... [/CREATE]
    final createPattern = RegExp(
      r'\[CREATE\]\s*\n?([\s\S]*?)\[/CREATE\]',
      caseSensitive: false,
    );
    final createMatch = createPattern.firstMatch(content);
    if (createMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.create,
        content: createMatch.group(1)!.trim(),
      ));
      return instructions;
    }
    
    // [REPLACE] ... [/REPLACE]
    final replacePattern = RegExp(
      r'\[REPLACE\]\s*\n?([\s\S]*?)\[/REPLACE\]',
      caseSensitive: false,
    );
    final replaceMatch = replacePattern.firstMatch(content);
    if (replaceMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.replace,
        content: replaceMatch.group(1)!.trim(),
      ));
      return instructions;
    }
    
    // [MODIFY] 双锚点替换
    final modifyPattern = RegExp(
      r'\[MODIFY\]\s*\[ANCHOR_START\]\s*\n?([\s\S]*?)\[/ANCHOR_START\]\s*\[ANCHOR_END\]\s*\n?([\s\S]*?)\[/ANCHOR_END\]\s*\[CONTENT\]\s*\n?([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final modifyMatch = modifyPattern.firstMatch(content);
    if (modifyMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.findReplace,
        anchor: modifyMatch.group(1)!.trim(),
        anchorEnd: modifyMatch.group(2)!.trim(),
        replaceWith: modifyMatch.group(3)!.trim(),
      ));
      return instructions;
    }
    
    // [DELETE] 双锚点删除
    final deletePattern = RegExp(
      r'\[DELETE\]\s*\[ANCHOR_START\]\s*\n?([\s\S]*?)\[/ANCHOR_START\]\s*\[ANCHOR_END\]\s*\n?([\s\S]*?)\[/ANCHOR_END\]',
      caseSensitive: false,
    );
    final deleteMatch = deletePattern.firstMatch(content);
    if (deleteMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.deleteContent,
        anchor: deleteMatch.group(1)!.trim(),
        anchorEnd: deleteMatch.group(2)!.trim(),
      ));
      return instructions;
    }
    
    // [INSERT_AFTER]
    final insertAfterPattern = RegExp(
      r'\[INSERT_AFTER\]\s*\[ANCHOR\]\s*\n?([\s\S]*?)\[/ANCHOR\]\s*\[CONTENT\]\s*\n?([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final insertAfterMatch = insertAfterPattern.firstMatch(content);
    if (insertAfterMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.insertAfter,
        anchor: insertAfterMatch.group(1)!.trim(),
        content: insertAfterMatch.group(2),
      ));
      return instructions;
    }
    
    // [INSERT_BEFORE]
    final insertBeforePattern = RegExp(
      r'\[INSERT_BEFORE\]\s*\[ANCHOR\]\s*\n?([\s\S]*?)\[/ANCHOR\]\s*\[CONTENT\]\s*\n?([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final insertBeforeMatch = insertBeforePattern.firstMatch(content);
    if (insertBeforeMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.insertBefore,
        anchor: insertBeforeMatch.group(1)!.trim(),
        content: insertBeforeMatch.group(2),
      ));
      return instructions;
    }
    
    return instructions;
  }
}

class ParseResult {
  final List<Instruction> instructions;
  final List<String> errors;
  
  ParseResult({required this.instructions, required this.errors});
}

class CodeMerger {
  MergeResult execute(Instruction instruction, String? currentContent) {
    switch (instruction.type) {
      case OperationType.create:
      case OperationType.replace:
        return MergeResult(
          success: true,
          content: instruction.content ?? '',
        );
        
      case OperationType.deleteFile:
        return MergeResult(success: true, content: '');
        
      case OperationType.findReplace:
        return _executeModify(instruction, currentContent);
        
      case OperationType.insertBefore:
        return _executeInsertBefore(instruction, currentContent);
        
      case OperationType.insertAfter:
        return _executeInsertAfter(instruction, currentContent);
        
      case OperationType.deleteContent:
        return _executeDelete(instruction, currentContent);
    }
  }
  
  // 双锚点替换
  MergeResult _executeModify(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchorStart = instruction.anchor!;
    final anchorEnd = instruction.anchorEnd!;
    final replacement = instruction.replaceWith ?? '';
    
    final startIndex = content.indexOf(anchorStart);
    if (startIndex == -1) {
      return MergeResult(success: false, error: '未找到开始锚点');
    }
    
    final endIndex = content.indexOf(anchorEnd, startIndex);
    if (endIndex == -1) {
      return MergeResult(success: false, error: '未找到结束锚点');
    }
    
    final actualEnd = endIndex + anchorEnd.length;
    
    final newContent = content.substring(0, startIndex) +
        replacement +
        content.substring(actualEnd);
    
    return MergeResult(success: true, content: newContent);
  }
  
  // 双锚点删除
  MergeResult _executeDelete(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchorStart = instruction.anchor!;
    final anchorEnd = instruction.anchorEnd!;
    
    final startIndex = content.indexOf(anchorStart);
    if (startIndex == -1) {
      return MergeResult(success: false, error: '未找到开始锚点');
    }
    
    final endIndex = content.indexOf(anchorEnd, startIndex);
    if (endIndex == -1) {
      return MergeResult(success: false, error: '未找到结束锚点');
    }
    
    final actualEnd = endIndex + anchorEnd.length;
    
    final newContent = content.substring(0, startIndex) +
        content.substring(actualEnd);
    
    return MergeResult(success: true, content: newContent);
  }
  
  MergeResult _executeInsertBefore(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchor = instruction.anchor!;
    final insertContent = instruction.content ?? '';
    
    final index = content.indexOf(anchor);
    if (index == -1) {
      return MergeResult(success: false, error: '未找到锚点');
    }
    
    final newContent = content.substring(0, index) +
        insertContent +
        content.substring(index);
    
    return MergeResult(success: true, content: newContent);
  }
  
  MergeResult _executeInsertAfter(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchor = instruction.anchor!;
    final insertContent = instruction.content ?? '';
    
    final index = content.indexOf(anchor);
    if (index == -1) {
      return MergeResult(success: false, error: '未找到锚点');
    }
    
    final insertPosition = index + anchor.length;
    
    final newContent = content.substring(0, insertPosition) +
        insertContent +
        content.substring(insertPosition);
    
    return MergeResult(success: true, content: newContent);
  }
}

class MergeResult {
  final bool success;
  final String? content;
  final String? error;
  
  MergeResult({required this.success, this.content, this.error});
}

class DiffGenerator {
  List<DiffLine> generate(String? original, String? modified) {
    final oldLines = original?.split('\n') ?? [];
    final newLines = modified?.split('\n') ?? [];
    
    final result = <DiffLine>[];
    final lcs = _lcs(oldLines, newLines);
    
    var oldIdx = 0;
    var newIdx = 0;
    var lcsIdx = 0;
    var newLineNum = 1;
    
    while (oldIdx < oldLines.length || newIdx < newLines.length) {
      if (lcsIdx < lcs.length &&
          oldIdx < oldLines.length &&
          newIdx < newLines.length &&
          oldLines[oldIdx] == lcs[lcsIdx] &&
          newLines[newIdx] == lcs[lcsIdx]) {
        result.add(DiffLine(
          oldLineNumber: oldIdx + 1,
          newLineNumber: newLineNum,
          content: oldLines[oldIdx],
          type: DiffLineType.unchanged,
        ));
        oldIdx++;
        newIdx++;
        lcsIdx++;
        newLineNum++;
      } else if (oldIdx < oldLines.length &&
          (lcsIdx >= lcs.length || oldLines[oldIdx] != lcs[lcsIdx])) {
        result.add(DiffLine(
          oldLineNumber: oldIdx + 1,
          content: oldLines[oldIdx],
          type: DiffLineType.removed,
        ));
        oldIdx++;
      } else if (newIdx < newLines.length &&
          (lcsIdx >= lcs.length || newLines[newIdx] != lcs[lcsIdx])) {
        result.add(DiffLine(
          newLineNumber: newLineNum,
          content: newLines[newIdx],
          type: DiffLineType.added,
        ));
        newIdx++;
        newLineNum++;
      } else {
        break;
      }
    }
    
    return result;
  }
  
  List<String> _lcs(List<String> a, List<String> b) {
    final m = a.length;
    final n = b.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (a[i - 1] == b[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }
    
    final result = <String>[];
    var i = m, j = n;
    while (i > 0 && j > 0) {
      if (a[i - 1] == b[j - 1]) {
        result.insert(0, a[i - 1]);
        i--;
        j--;
      } else if (dp[i - 1][j] > dp[i][j - 1]) {
        i--;
      } else {
        j--;
      }
    }
    
    return result;
  }
}

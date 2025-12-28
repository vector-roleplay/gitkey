import '../models.dart';

class ParserService {
  /// 解析AI消息
  ParseResult parse(String message) {
    final instructions = <Instruction>[];
    final errors = <String>[];
    
    // 按文件分割
    final filePattern = RegExp(r'\[FILE\]\s*(.+?)(?=\n|\[)', caseSensitive: false);
    final fileMatches = filePattern.allMatches(message).toList();
    
    for (var i = 0; i < fileMatches.length; i++) {
      final filePath = fileMatches[i].group(1)!.trim();
      final startIndex = fileMatches[i].end;
      final endIndex = i < fileMatches.length - 1 
          ? fileMatches[i + 1].start 
          : message.length;
      final content = message.substring(startIndex, endIndex);
      
      try {
        final fileInstructions = _parseFileBlock(filePath, content);
        instructions.addAll(fileInstructions);
      } catch (e) {
        errors.add('解析 $filePath 失败: $e');
      }
    }
    
    return ParseResult(instructions: instructions, errors: errors);
  }
  
  List<Instruction> _parseFileBlock(String filePath, String content) {
    final instructions = <Instruction>[];
    
    // [CREATE]
    final createPattern = RegExp(
      r'\[CREATE\]\s*```\w*\n([\s\S]*?)```\s*\[/CREATE\]',
      caseSensitive: false,
    );
    final createMatch = createPattern.firstMatch(content);
    if (createMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.create,
        content: createMatch.group(1)!.trimRight(),
      ));
      return instructions;
    }
    
    // [REPLACE]
    final replacePattern = RegExp(
      r'\[REPLACE\]\s*```\w*\n([\s\S]*?)```\s*$$/REPLACE$$',
      caseSensitive: false,
    );
    final replaceMatch = replacePattern.firstMatch(content);
    if (replaceMatch != null) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.replace,
        content: replaceMatch.group(1)!.trimRight(),
      ));
      return instructions;
    }
    
    // [DELETE_FILE]
    if (RegExp(r'$$DELETE_FILE$$', caseSensitive: false).hasMatch(content)) {
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.deleteFile,
      ));
      return instructions;
    }
    
    // [FIND]...[/FIND] + [REPLACE_WITH]...[/REPLACE_WITH]
    final findPattern = RegExp(
      r'$$FIND(?::(\w+))?$$\s*\n?([\s\S]*?)$$/FIND$$',
      caseSensitive: false,
    );
    final replaceWithPattern = RegExp(
      r'$$REPLACE_WITH$$\s*\n?([\s\S]*?)$$/REPLACE_WITH$$',
      caseSensitive: false,
    );
    
    final findMatches = findPattern.allMatches(content).toList();
    final replaceWithMatches = replaceWithPattern.allMatches(content).toList();
    
    for (var i = 0; i < findMatches.length && i < replaceWithMatches.length; i++) {
      final mode = _parseAnchorMode(findMatches[i].group(1));
      instructions.add(Instruction(
        filePath: filePath,
        type: OperationType.findReplace,
        anchor: findMatches[i].group(2)!.trim(),
        replaceWith: replaceWithMatches[i].group(1)!.trim(),
        anchorMode: mode,
        isRegex: mode == AnchorMode.regex,
      ));
    }
    
    // [INSERT_AFTER] / [INSERT_BEFORE]
    _parseInsertOperations(filePath, content, instructions);
    
    // [DELETE]
    _parseDeleteOperations(filePath, content, instructions);
    
    return instructions;
  }
  
  void _parseInsertOperations(String filePath, String content, List<Instruction> instructions) {
    final insertAfterPattern = RegExp(r'$$INSERT_AFTER(?::(\w+))?$$', caseSensitive: false);
    final insertBeforePattern = RegExp(r'$$INSERT_BEFORE(?::(\w+))?$$', caseSensitive: false);
    final anchorPattern = RegExp(r'$$ANCHOR$$\s*\n?([\s\S]*?)$$/ANCHOR$$', caseSensitive: false);
    final contentPattern = RegExp(r'$$CONTENT$$\s*\n?([\s\S]*?)$$/CONTENT$$', caseSensitive: false);
    
    // INSERT_AFTER
    final afterMatch = insertAfterPattern.firstMatch(content);
    if (afterMatch != null) {
      final remaining = content.substring(afterMatch.end);
      final anchor = anchorPattern.firstMatch(remaining)?.group(1)?.trim();
      final insertContent = contentPattern.firstMatch(remaining)?.group(1);
      
      if (anchor != null && insertContent != null) {
        final mode = _parseAnchorMode(afterMatch.group(1));
        instructions.add(Instruction(
          filePath: filePath,
          type: OperationType.insertAfter,
          anchor: anchor,
          content: insertContent,
          anchorMode: mode,
          isRegex: mode == AnchorMode.regex,
        ));
      }
    }
    
    // INSERT_BEFORE
    final beforeMatch = insertBeforePattern.firstMatch(content);
    if (beforeMatch != null) {
      final remaining = content.substring(beforeMatch.end);
      final anchor = anchorPattern.firstMatch(remaining)?.group(1)?.trim();
      final insertContent = contentPattern.firstMatch(remaining)?.group(1);
      
      if (anchor != null && insertContent != null) {
        final mode = _parseAnchorMode(beforeMatch.group(1));
        instructions.add(Instruction(
          filePath: filePath,
          type: OperationType.insertBefore,
          anchor: anchor,
          content: insertContent,
          anchorMode: mode,
          isRegex: mode == AnchorMode.regex,
        ));
      }
    }
  }
  
  void _parseDeleteOperations(String filePath, String content, List<Instruction> instructions) {
    final deletePattern = RegExp(r'$$DELETE(?::(\w+))?$$', caseSensitive: false);
    final anchorPattern = RegExp(r'$$ANCHOR$$\s*\n?([\s\S]*?)$$/ANCHOR$$', caseSensitive: false);
    
    final deleteMatch = deletePattern.firstMatch(content);
    if (deleteMatch != null) {
      final remaining = content.substring(deleteMatch.end);
      final anchor = anchorPattern.firstMatch(remaining)?.group(1)?.trim();
      
      if (anchor != null) {
        final mode = _parseAnchorMode(deleteMatch.group(1));
        instructions.add(Instruction(
          filePath: filePath,
          type: OperationType.deleteContent,
          anchor: anchor,
          anchorMode: mode,
          isRegex: mode == AnchorMode.regex,
        ));
      }
    }
  }
  
  AnchorMode _parseAnchorMode(String? modeStr) {
    switch (modeStr?.toUpperCase()) {
      case 'REGEX': return AnchorMode.regex;
      case 'IGNORE_SPACE':
      case 'NOSPACE': return AnchorMode.ignoreSpace;
      default: return AnchorMode.exact;
    }
  }
  
  /// 提取文件路径列表
  List<String> extractFilePaths(String message) {
    final pattern = RegExp(r'$$FILE$$\s*(.+?)(?=\n|\[)', caseSensitive: false);
    return pattern.allMatches(message)
        .map((m) => m.group(1)!.trim())
        .toSet()
        .toList();
  }
}

class ParseResult {
  final List<Instruction> instructions;
  final List<String> errors;
  
  ParseResult({required this.instructions, required this.errors});
}


/// 代码合并器
class CodeMerger {
  /// 执行指令
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
        return _executeFindReplace(instruction, currentContent);
        
      case OperationType.insertBefore:
        return _executeInsertBefore(instruction, currentContent);
        
      case OperationType.insertAfter:
        return _executeInsertAfter(instruction, currentContent);
        
      case OperationType.deleteContent:
        return _executeDeleteContent(instruction, currentContent);
    }
  }
  
  MergeResult _executeFindReplace(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchor = instruction.anchor!;
    final replaceWith = instruction.replaceWith ?? '';
    
    final location = _locate(content, anchor, instruction.anchorMode, instruction.isRegex);
    
    if (location == null) {
      return MergeResult(success: false, error: '未找到锚点: ${anchor.substring(0, anchor.length.clamp(0, 50))}...');
    }
    
    final newContent = content.substring(0, location.start) +
        replaceWith +
        content.substring(location.end);
    
    return MergeResult(success: true, content: newContent);
  }
  
  MergeResult _executeInsertBefore(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchor = instruction.anchor!;
    final insertContent = instruction.content ?? '';
    
    final location = _locate(content, anchor, instruction.anchorMode, instruction.isRegex);
    
    if (location == null) {
      return MergeResult(success: false, error: '未找到锚点');
    }
    
    final newContent = content.substring(0, location.start) +
        insertContent +
        content.substring(location.start);
    
    return MergeResult(success: true, content: newContent);
  }
  
  MergeResult _executeInsertAfter(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchor = instruction.anchor!;
    final insertContent = instruction.content ?? '';
    
    final location = _locate(content, anchor, instruction.anchorMode, instruction.isRegex);
    
    if (location == null) {
      return MergeResult(success: false, error: '未找到锚点');
    }
    
    final newContent = content.substring(0, location.end) +
        insertContent +
        content.substring(location.end);
    
    return MergeResult(success: true, content: newContent);
  }
  
  MergeResult _executeDeleteContent(Instruction instruction, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '文件内容为空');
    }
    
    final anchor = instruction.anchor!;
    
    final location = _locate(content, anchor, instruction.anchorMode, instruction.isRegex);
    
    if (location == null) {
      return MergeResult(success: false, error: '未找到要删除的内容');
    }
    
    final newContent = content.substring(0, location.start) +
        content.substring(location.end);
    
    return MergeResult(success: true, content: newContent);
  }
  
  /// 定位锚点
  _Location? _locate(String content, String anchor, AnchorMode mode, bool isRegex) {
    if (isRegex || mode == AnchorMode.regex) {
      return _locateByRegex(content, anchor);
    } else if (mode == AnchorMode.ignoreSpace) {
      return _locateIgnoreSpace(content, anchor);
    } else {
      return _locateExact(content, anchor);
    }
  }
  
  _Location? _locateExact(String content, String anchor) {
    final trimmed = anchor.trim();
    final index = content.indexOf(trimmed);
    if (index == -1) return null;
    return _Location(index, index + trimmed.length);
  }
  
  _Location? _locateIgnoreSpace(String content, String anchor) {
    // 将锚点转为忽略空白的正则
    final parts = anchor.trim().split(RegExp(r'\s+'));
    final pattern = parts.map((p) => RegExp.escape(p)).join(r'\s*');
    return _locateByRegex(content, pattern);
  }
  
  _Location? _locateByRegex(String content, String pattern) {
    try {
      final regex = RegExp(pattern, multiLine: true, dotAll: true);
      final match = regex.firstMatch(content);
      if (match == null) return null;
      return _Location(match.start, match.end);
    } catch (e) {
      return null;
    }
  }
}

class _Location {
  final int start;
  final int end;
  _Location(this.start, this.end);
}

class MergeResult {
  final bool success;
  final String? content;
  final String? error;
  
  MergeResult({required this.success, this.content, this.error});
}

/// Diff生成器
class DiffGenerator {
  List<DiffLine> generate(String? original, String? modified) {
    final oldLines = original?.split('\n') ?? [];
    final newLines = modified?.split('\n') ?? [];
    
    final result = <DiffLine>[];
    
    // 简化的LCS算法
    final lcs = _longestCommonSubsequence(oldLines, newLines);
    
    var oldIndex = 0;
    var newIndex = 0;
    var lcsIndex = 0;
    var newLineNum = 1;
    
    while (oldIndex < oldLines.length || newIndex < newLines.length) {
      if (lcsIndex < lcs.length &&
          oldIndex < oldLines.length &&
          newIndex < newLines.length &&
          oldLines[oldIndex] == lcs[lcsIndex] &&
          newLines[newIndex] == lcs[lcsIndex]) {
        // 相同行
        result.add(DiffLine(
          oldLineNumber: oldIndex + 1,
          newLineNumber: newLineNum,
          content: oldLines[oldIndex],
          type: DiffLineType.unchanged,
        ));
        oldIndex++;
        newIndex++;
        lcsIndex++;
        newLineNum++;
      } else if (oldIndex < oldLines.length &&
          (lcsIndex >= lcs.length || oldLines[oldIndex] != lcs[lcsIndex])) {
        // 删除的行
        result.add(DiffLine(
          oldLineNumber: oldIndex + 1,
          content: oldLines[oldIndex],
          type: DiffLineType.removed,
        ));
        oldIndex++;
      } else if (newIndex < newLines.length &&
          (lcsIndex >= lcs.length || newLines[newIndex] != lcs[lcsIndex])) {
        // 新增的行
        result.add(DiffLine(
          newLineNumber: newLineNum,
          content: newLines[newIndex],
          type: DiffLineType.added,
        ));
        newIndex++;
        newLineNum++;
      } else {
        break;
      }
    }
    
    return result;
  }
  
  List<String> _longestCommonSubsequence(List<String> a, List<String> b) {
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
    
    // 回溯
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

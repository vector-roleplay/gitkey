import '../models.dart';

class ParserService {
  static const _fileTag = 'FILESISU';
  
  // 常见的顶级目录名（不是仓库名）
  static const _commonTopDirs = [
    'lib', 'src', 'test', 'tests', 'android', 'ios', 'web', 'windows', 'linux', 'macos',
    '.github', 'assets', 'docs', 'bin', 'build', 'config', 'scripts', 'tools',
  ];
  
  /// 从路径中检测可能的仓库名
  /// 如 "gitkey/lib/main.dart" -> "gitkey"
  /// 如 "lib/main.dart" -> null
  String? _detectRepoFromPath(String path) {
    final parts = path.split('/');
    if (parts.length >= 2) {
      final firstPart = parts[0].toLowerCase();
      // 如果第一部分不是常见的顶级目录名，可能是仓库名
      if (!_commonTopDirs.contains(firstPart) && !firstPart.startsWith('.')) {
        return parts[0];  // 返回原始大小写
      }
    }
    return null;
  }
  
  /// 解析AI消息，提取所有文件操作指令
  ParseResult parse(String message) {
    final instructions = <Instruction>[];
    final errors = <String>[];
    
    // 匹配 [FILESISU] 文件路径
    final filePattern = RegExp(
      r'\[' + _fileTag + r'\]\s*([^\n\[\]]+)',
      caseSensitive: false,
    );
    
    final fileMatches = filePattern.allMatches(message);
    
    for (final fileMatch in fileMatches) {
      final filePath = fileMatch.group(1)?.trim() ?? '';
      if (filePath.isEmpty) {
        errors.add('文件路径为空');
        continue;
      }
      
      // 检测路径中可能的仓库名
      final detectedRepo = _detectRepoFromPath(filePath);
      
      // 获取该文件后面的内容，直到下一个 [FILESISU] 或结尾
      final startPos = fileMatch.end;
      final nextFileMatch = filePattern.firstMatch(message.substring(startPos));
      final endPos = nextFileMatch != null ? startPos + nextFileMatch.start : message.length;
      final afterFile = message.substring(startPos, endPos);
      
      // 尝试匹配各种操作
      final instruction = _parseOperation(filePath, afterFile, errors, detectedRepo);
      if (instruction != null) {
        instructions.add(instruction);
      }
    }
    
    return ParseResult(instructions: instructions, errors: errors);
  }
  
  Instruction? _parseOperation(String filePath, String content, List<String> errors, [String? detectedRepo]) {
    // [SYNC_FROM] owner/repo:branch:path 或 owner/repo::path (默认main分支)
    final syncFromPattern = RegExp(
      r'\[SYNC_FROM\]\s*([^/\s]+)/([^:\s]+):([^:]*):(.+)',
      caseSensitive: false,
    );
    final syncFromMatch = syncFromPattern.firstMatch(content);
    if (syncFromMatch != null) {
      final owner = syncFromMatch.group(1)?.trim();
      final repo = syncFromMatch.group(2)?.trim();
      final branch = syncFromMatch.group(3)?.trim();
      final sourcePath = syncFromMatch.group(4)?.trim();
      
      return Instruction(
        filePath: filePath,
        type: OperationType.syncFrom,
        sourceOwner: owner,
        sourceRepo: repo,
        sourceBranch: branch?.isNotEmpty == true ? branch : 'main',
        sourcePath: sourcePath,
        detectedTargetRepo: detectedRepo,
      );
    }
    
    // [CREATE] ... [/CREATE]
    final createPattern = RegExp(
      r'\[CREATE\]([\s\S]*?)\[/CREATE\]',
      caseSensitive: false,
    );
    final createMatch = createPattern.firstMatch(content);
    if (createMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.create,
        content: createMatch.group(1)?.trim(),
        detectedTargetRepo: detectedRepo,
      );
    }
    
    // [REPLACE] ... [/REPLACE]
    final replacePattern = RegExp(
      r'\[REPLACE\]([\s\S]*?)\[/REPLACE\]',
      caseSensitive: false,
    );
    final replaceMatch = replacePattern.firstMatch(content);
    if (replaceMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.replace,
        content: replaceMatch.group(1),
        detectedTargetRepo: detectedRepo,
      );
    }
    
    // [DELETE_FILE]
    final deleteFilePattern = RegExp(r'\[DELETE_FILE\]', caseSensitive: false);
    if (deleteFilePattern.hasMatch(content)) {
      return Instruction(
        filePath: filePath,
        type: OperationType.deleteFile,
        detectedTargetRepo: detectedRepo,
      );
    }
    
    // [MODIFY] with [ANCHOR_START] [ANCHOR_END] [CONTENT]
    final modifyPattern = RegExp(
      r'\[MODIFY\][\s\S]*?\[ANCHOR_START\]([\s\S]*?)\[/ANCHOR_START\][\s\S]*?\[ANCHOR_END\]([\s\S]*?)\[/ANCHOR_END\][\s\S]*?\[CONTENT\]([\s\S]*?)\[/CONTENT\]',
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
        detectedTargetRepo: detectedRepo,
      );
    }
    
    // [DELETE] with [ANCHOR_START] [ANCHOR_END]
    final deletePattern = RegExp(
      r'\[DELETE\][\s\S]*?\[ANCHOR_START\]([\s\S]*?)\[/ANCHOR_START\][\s\S]*?\[ANCHOR_END\]([\s\S]*?)\[/ANCHOR_END\]',
      caseSensitive: false,
    );
    final deleteMatch = deletePattern.firstMatch(content);
    if (deleteMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.deleteContent,
        anchorStart: deleteMatch.group(1)?.trim(),
        anchorEnd: deleteMatch.group(2)?.trim(),
        detectedTargetRepo: detectedRepo,
      );
    }
    
    // [INSERT_AFTER] with [ANCHOR] [CONTENT]
    final insertAfterPattern = RegExp(
      r'\[INSERT_AFTER\][\s\S]*?\[ANCHOR\]([\s\S]*?)\[/ANCHOR\][\s\S]*?\[CONTENT\]([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final insertAfterMatch = insertAfterPattern.firstMatch(content);
    if (insertAfterMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.insertAfter,
        anchor: insertAfterMatch.group(1)?.trim(),
        content: insertAfterMatch.group(2),
        detectedTargetRepo: detectedRepo,
      );
    }
    
    // [INSERT_BEFORE] with [ANCHOR] [CONTENT]
    final insertBeforePattern = RegExp(
      r'\[INSERT_BEFORE\][\s\S]*?\[ANCHOR\]([\s\S]*?)\[/ANCHOR\][\s\S]*?\[CONTENT\]([\s\S]*?)\[/CONTENT\]',
      caseSensitive: false,
    );
    final insertBeforeMatch = insertBeforePattern.firstMatch(content);
    if (insertBeforeMatch != null) {
      return Instruction(
        filePath: filePath,
        type: OperationType.insertBefore,
        anchor: insertBeforeMatch.group(1)?.trim(),
        content: insertBeforeMatch.group(2),
        detectedTargetRepo: detectedRepo,
      );
    }
    
    errors.add('$filePath: 未识别到有效操作');
    return null;
  }
}

class ParseResult {
  final List<Instruction> instructions;
  final List<String> errors;
  
  ParseResult({
    required this.instructions,
    required this.errors,
  });
}

/// 代码融合器 - 执行代码修改操作
class CodeMerger {
  MergeResult execute(Instruction instruction, String? originalContent) {
    switch (instruction.type) {
      case OperationType.create:
      case OperationType.replace:
      case OperationType.syncFrom:
        return MergeResult(
          success: true,
          content: instruction.content,
        );
        
      case OperationType.deleteFile:
        return MergeResult(success: true, content: null);
        
      case OperationType.findReplace:
        return _executeModify(instruction, originalContent);
        
      case OperationType.insertAfter:
        return _executeInsertAfter(instruction, originalContent);
        
      case OperationType.insertBefore:
        return _executeInsertBefore(instruction, originalContent);
        
      case OperationType.deleteContent:
        return _executeDelete(instruction, originalContent);
    }
  }
  
  /// 骨架匹配 - 去掉所有空白字符后比对
  int _findSkeletonMatch(String content, String anchor) {
    final contentSkeleton = content.replaceAll(RegExp(r'\s'), '');
    final anchorSkeleton = anchor.replaceAll(RegExp(r'\s'), '');
    
    if (anchorSkeleton.isEmpty) return -1;
    
    final skeletonIndex = contentSkeleton.indexOf(anchorSkeleton);
    if (skeletonIndex == -1) return -1;
    
    // 将骨架位置映射回原始内容位置
    int originalIndex = 0;
    int skeletonCount = 0;
    
    while (skeletonCount < skeletonIndex && originalIndex < content.length) {
      if (!RegExp(r'\s').hasMatch(content[originalIndex])) {
        skeletonCount++;
      }
      originalIndex++;
    }
    
    return originalIndex;
  }
  
  /// 找到锚点范围的结束位置
  int _findSkeletonMatchEnd(String content, String anchor, int startFrom) {
    final searchContent = content.substring(startFrom);
    final contentSkeleton = searchContent.replaceAll(RegExp(r'\s'), '');
    final anchorSkeleton = anchor.replaceAll(RegExp(r'\s'), '');
    
    if (anchorSkeleton.isEmpty) return -1;
    
    final skeletonIndex = contentSkeleton.indexOf(anchorSkeleton);
    if (skeletonIndex == -1) return -1;
    
    // 找到锚点匹配的结束位置
    int originalIndex = 0;
    int skeletonCount = 0;
    final targetCount = skeletonIndex + anchorSkeleton.length;
    
    while (skeletonCount < targetCount && originalIndex < searchContent.length) {
      if (!RegExp(r'\s').hasMatch(searchContent[originalIndex])) {
        skeletonCount++;
      }
      originalIndex++;
    }
    
    return startFrom + originalIndex;
  }
  
  MergeResult _executeModify(Instruction inst, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '原始内容为空，无法执行 MODIFY');
    }
    
    final anchorStart = inst.anchorStart;
    final anchorEnd = inst.anchorEnd;
    final newContent = inst.content;
    
    if (anchorStart == null || anchorEnd == null) {
      return MergeResult(success: false, error: '缺少锚点');
    }
    
    // 找到开始锚点位置
    final startIndex = _findSkeletonMatch(content, anchorStart);
    if (startIndex == -1) {
      return MergeResult(
        success: false,
        error: '找不到开始锚点:\n${anchorStart.substring(0, anchorStart.length.clamp(0, 100))}...',
      );
    }
    
    // 找到结束锚点的结束位置
    final endIndex = _findSkeletonMatchEnd(content, anchorEnd, startIndex);
    if (endIndex == -1) {
      return MergeResult(
        success: false,
        error: '找不到结束锚点:\n${anchorEnd.substring(0, anchorEnd.length.clamp(0, 100))}...',
      );
    }
    
    // 替换内容
    final result = content.substring(0, startIndex) + 
                   (newContent ?? '') + 
                   content.substring(endIndex);
    
    return MergeResult(success: true, content: result);
  }
  
  MergeResult _executeInsertAfter(Instruction inst, String? content) {
    if (content == null) {
      // 如果原内容为空，直接返回新内容
      return MergeResult(success: true, content: inst.content);
    }
    
    final anchor = inst.anchor;
    final newContent = inst.content;
    
    if (anchor == null) {
      return MergeResult(success: false, error: '缺少锚点');
    }
    
    // 找到锚点结束位置
    final anchorEndIndex = _findSkeletonMatchEnd(content, anchor, 0);
    if (anchorEndIndex == -1) {
      return MergeResult(
        success: false,
        error: '找不到锚点:\n${anchor.substring(0, anchor.length.clamp(0, 100))}...',
      );
    }
    
    // 在锚点后插入
    final result = content.substring(0, anchorEndIndex) + 
                   (newContent ?? '') + 
                   content.substring(anchorEndIndex);
    
    return MergeResult(success: true, content: result);
  }
  
  MergeResult _executeInsertBefore(Instruction inst, String? content) {
    if (content == null) {
      return MergeResult(success: true, content: inst.content);
    }
    
    final anchor = inst.anchor;
    final newContent = inst.content;
    
    if (anchor == null) {
      return MergeResult(success: false, error: '缺少锚点');
    }
    
    // 找到锚点开始位置
    final anchorStartIndex = _findSkeletonMatch(content, anchor);
    if (anchorStartIndex == -1) {
      return MergeResult(
        success: false,
        error: '找不到锚点:\n${anchor.substring(0, anchor.length.clamp(0, 100))}...',
      );
    }
    
    // 在锚点前插入
    final result = content.substring(0, anchorStartIndex) + 
                   (newContent ?? '') + 
                   content.substring(anchorStartIndex);
    
    return MergeResult(success: true, content: result);
  }
  
  MergeResult _executeDelete(Instruction inst, String? content) {
    if (content == null) {
      return MergeResult(success: false, error: '原始内容为空，无法执行 DELETE');
    }
    
    final anchorStart = inst.anchorStart;
    final anchorEnd = inst.anchorEnd;
    
    if (anchorStart == null || anchorEnd == null) {
      return MergeResult(success: false, error: '缺少锚点');
    }
    
    // 找到开始锚点位置
    final startIndex = _findSkeletonMatch(content, anchorStart);
    if (startIndex == -1) {
      return MergeResult(
        success: false,
        error: '找不到开始锚点',
      );
    }
    
    // 找到结束锚点的结束位置
    final endIndex = _findSkeletonMatchEnd(content, anchorEnd, startIndex);
    if (endIndex == -1) {
      return MergeResult(
        success: false,
        error: '找不到结束锚点',
      );
    }
    
    // 删除内容
    final result = content.substring(0, startIndex) + content.substring(endIndex);
    
    return MergeResult(success: true, content: result);
  }
}

class MergeResult {
  final bool success;
  final String? content;
  final String? error;
  
  MergeResult({
    required this.success,
    this.content,
    this.error,
  });
}

/// 差异生成器
class DiffGenerator {
  List<DiffLine> generate(String? original, String? modified) {
    final originalLines = original?.split('\n') ?? [];
    final modifiedLines = modified?.split('\n') ?? [];
    
    final diffLines = <DiffLine>[];
    
    // 简单的逐行对比
    final maxLen = originalLines.length > modifiedLines.length 
        ? originalLines.length 
        : modifiedLines.length;
    
    int oldLineNum = 1;
    int newLineNum = 1;
    
    for (var i = 0; i < maxLen; i++) {
      final oldLine = i < originalLines.length ? originalLines[i] : null;
      final newLine = i < modifiedLines.length ? modifiedLines[i] : null;
      
      if (oldLine == newLine) {
        if (oldLine != null) {
          diffLines.add(DiffLine(
            type: DiffLineType.unchanged,
            content: oldLine,
            oldLineNumber: oldLineNum++,
            newLineNumber: newLineNum++,
          ));
        }
      } else {
        if (oldLine != null) {
          diffLines.add(DiffLine(
            type: DiffLineType.removed,
            content: oldLine,
            oldLineNumber: oldLineNum++,
          ));
        }
        if (newLine != null) {
          diffLines.add(DiffLine(
            type: DiffLineType.added,
            content: newLine,
            newLineNumber: newLineNum++,
          ));
        }
      }
    }
    
    return diffLines;
  }
}

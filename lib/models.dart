/// 操作类型
enum OperationType {
  create,       // 创建新文件
  replace,      // 替换整个文件
  deleteFile,   // 删除文件
  findReplace,  // 查找替换
  insertBefore, // 在锚点前插入
  insertAfter,  // 在锚点后插入
  deleteContent // 删除代码段
}

/// 锚点匹配模式
enum AnchorMode {
  exact,       // 精确匹配
  ignoreSpace, // 忽略空白
  regex        // 正则表达式
}

/// 文件变更状态
enum FileChangeStatus {
  pending,        // 待处理
  success,        // 成功
  failed,         // 失败
  anchorNotFound  // 锚点未找到
}

/// 指令基类
class Instruction {
  final String filePath;
  final OperationType type;
  final String? content;
  final String? anchor;
  final String? replaceWith;
  final AnchorMode anchorMode;
  final bool isRegex;
  
  Instruction({
    required this.filePath,
    required this.type,
    this.content,
    this.anchor,
    this.replaceWith,
    this.anchorMode = AnchorMode.exact,
    this.isRegex = false,
  });
  
  String get typeDescription {
    switch (type) {
      case OperationType.create: return '创建文件';
      case OperationType.replace: return '替换文件';
      case OperationType.deleteFile: return '删除文件';
      case OperationType.findReplace: return '查找替换';
      case OperationType.insertBefore: return '在锚点前插入';
      case OperationType.insertAfter: return '在锚点后插入';
      case OperationType.deleteContent: return '删除代码段';
    }
  }
}

/// 文件变更
class FileChange {
  final String filePath;
  final OperationType operationType;
  final String? originalContent;
  String? modifiedContent;
  FileChangeStatus status;
  String? errorMessage;
  String? sha; // GitHub文件SHA
  final List<Instruction> instructions;
  bool isSelected;
  
  FileChange({
    required this.filePath,
    required this.operationType,
    this.originalContent,
    this.modifiedContent,
    this.status = FileChangeStatus.pending,
    this.errorMessage,
    this.sha,
    this.instructions = const [],
    this.isSelected = true,
  });
  
  FileChange copyWith({
    String? filePath,
    OperationType? operationType,
    String? originalContent,
    String? modifiedContent,
    FileChangeStatus? status,
    String? errorMessage,
    String? sha,
    List<Instruction>? instructions,
    bool? isSelected,
  }) {
    return FileChange(
      filePath: filePath ?? this.filePath,
      operationType: operationType ?? this.operationType,
      originalContent: originalContent ?? this.originalContent,
      modifiedContent: modifiedContent ?? this.modifiedContent,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      sha: sha ?? this.sha,
      instructions: instructions ?? this.instructions,
      isSelected: isSelected ?? this.isSelected,
    );
  }
}

/// 仓库配置
class Repository {
  final String owner;
  final String name;
  final String branch;
  final bool isDefault;
  
  Repository({
    required this.owner,
    required this.name,
    this.branch = 'main',
    this.isDefault = false,
  });
  
  String get fullName => '$owner/$name';
  
  Map<String, dynamic> toJson() => {
    'owner': owner,
    'name': name,
    'branch': branch,
    'isDefault': isDefault,
  };
  
  factory Repository.fromJson(Map<String, dynamic> json) => Repository(
    owner: json['owner'],
    name: json['name'],
    branch: json['branch'] ?? 'main',
    isDefault: json['isDefault'] ?? false,
  );
}

/// 操作历史
class OperationHistory {
  final String id;
  final DateTime timestamp;
  final String repositoryName;
  final List<FileChangeRecord> changes;
  final bool isSuccessful;
  
  OperationHistory({
    required this.id,
    required this.timestamp,
    required this.repositoryName,
    required this.changes,
    required this.isSuccessful,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'repositoryName': repositoryName,
    'changes': changes.map((c) => c.toJson()).toList(),
    'isSuccessful': isSuccessful,
  };
  
  factory OperationHistory.fromJson(Map<String, dynamic> json) => OperationHistory(
    id: json['id'],
    timestamp: DateTime.parse(json['timestamp']),
    repositoryName: json['repositoryName'],
    changes: (json['changes'] as List).map((c) => FileChangeRecord.fromJson(c)).toList(),
    isSuccessful: json['isSuccessful'],
  );
}

/// 文件变更记录（用于历史）
class FileChangeRecord {
  final String filePath;
  final OperationType operationType;
  final String? originalContent;
  final String? modifiedContent;
  
  FileChangeRecord({
    required this.filePath,
    required this.operationType,
    this.originalContent,
    this.modifiedContent,
  });
  
  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'operationType': operationType.index,
    'originalContent': originalContent,
    'modifiedContent': modifiedContent,
  };
  
  factory FileChangeRecord.fromJson(Map<String, dynamic> json) => FileChangeRecord(
    filePath: json['filePath'],
    operationType: OperationType.values[json['operationType']],
    originalContent: json['originalContent'],
    modifiedContent: json['modifiedContent'],
  );
}

/// Diff行
class DiffLine {
  final int? oldLineNumber;
  final int? newLineNumber;
  final String content;
  final DiffLineType type;
  
  DiffLine({
    this.oldLineNumber,
    this.newLineNumber,
    required this.content,
    required this.type,
  });
}

enum DiffLineType { unchanged, added, removed }

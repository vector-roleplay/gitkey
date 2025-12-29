import 'package:flutter/foundation.dart';

/// 仓库信息
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

  Repository copyWith({
    String? owner,
    String? name,
    String? branch,
    bool? isDefault,
  }) {
    return Repository(
      owner: owner ?? this.owner,
      name: name ?? this.name,
      branch: branch ?? this.branch,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toJson() => {
    'owner': owner,
    'name': name,
    'branch': branch,
    'isDefault': isDefault,
  };

  factory Repository.fromJson(Map<String, dynamic> json) => Repository(
    owner: json['owner'] as String,
    name: json['name'] as String,
    branch: json['branch'] as String? ?? 'main',
    isDefault: json['isDefault'] as bool? ?? false,
  );
}

/// 操作类型
enum OperationType {
  create,
  replace,
  deleteFile,
  findReplace,
  insertBefore,
  insertAfter,
  deleteContent,
}

/// 解析出的指令
class Instruction {
  final String filePath;
  final OperationType type;
  final String? content;
  final String? anchorStart;
  final String? anchorEnd;
  final String? anchor;
  final String? replaceWith;

  Instruction({
    required this.filePath,
    required this.type,
    this.content,
    this.anchorStart,
    this.anchorEnd,
    this.anchor,
    this.replaceWith,
  });

  String get typeDescription {
    return switch (type) {
      OperationType.create => '创建文件',
      OperationType.replace => '替换文件',
      OperationType.deleteFile => '删除文件',
      OperationType.findReplace => '替换代码段',
      OperationType.insertBefore => '在锚点前插入',
      OperationType.insertAfter => '在锚点后插入',
      OperationType.deleteContent => '删除代码段',
    };
  }
}

/// 文件变更状态
enum FileChangeStatus {
  pending,
  success,
  failed,
  anchorNotFound,
}

/// 文件变更
class FileChange {
  final String filePath;
  final OperationType operationType;
  final String? originalContent;
  final String? modifiedContent;
  final FileChangeStatus status;
  final String? errorMessage;
  final String? sha;
  final bool isSelected;
  final List<Instruction>? instructions;
  final int totalModifications;
  final int successfulModifications;

  FileChange({
    required this.filePath,
    required this.operationType,
    this.originalContent,
    this.modifiedContent,
    this.status = FileChangeStatus.pending,
    this.errorMessage,
    this.sha,
    this.isSelected = true,
    this.instructions,
    this.totalModifications = 1,
    this.successfulModifications = 1,
  });

  FileChange copyWith({
    String? filePath,
    OperationType? operationType,
    String? originalContent,
    String? modifiedContent,
    FileChangeStatus? status,
    String? errorMessage,
    String? sha,
    bool? isSelected,
    List<Instruction>? instructions,
    int? totalModifications,
    int? successfulModifications,
  }) {
    return FileChange(
      filePath: filePath ?? this.filePath,
      operationType: operationType ?? this.operationType,
      originalContent: originalContent ?? this.originalContent,
      modifiedContent: modifiedContent ?? this.modifiedContent,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      sha: sha ?? this.sha,
      isSelected: isSelected ?? this.isSelected,
      instructions: instructions ?? this.instructions,
      totalModifications: totalModifications ?? this.totalModifications,
      successfulModifications: successfulModifications ?? this.successfulModifications,
    );
  }
}

/// 差异行类型
enum DiffLineType {
  added,
  removed,
  unchanged,
}

/// 差异行
class DiffLine {
  final DiffLineType type;
  final String content;
  final int? oldLineNumber;
  final int? newLineNumber;

  DiffLine({
    required this.type,
    required this.content,
    this.oldLineNumber,
    this.newLineNumber,
  });
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
    id: json['id'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
    repositoryName: json['repositoryName'] as String,
    changes: (json['changes'] as List).map((c) => FileChangeRecord.fromJson(c)).toList(),
    isSuccessful: json['isSuccessful'] as bool,
  );
}

/// 文件变更记录
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
    'operationType': operationType.name,
    'originalContent': originalContent,
    'modifiedContent': modifiedContent,
  };

  factory FileChangeRecord.fromJson(Map<String, dynamic> json) => FileChangeRecord(
    filePath: json['filePath'] as String,
    operationType: OperationType.values.firstWhere((e) => e.name == json['operationType']),
    originalContent: json['originalContent'] as String?,
    modifiedContent: json['modifiedContent'] as String?,
  );
}
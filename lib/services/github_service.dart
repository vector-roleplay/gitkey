import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

class GitHubService {
  static const _baseUrl = 'https://api.github.com';
  String? _token;
  
  void setToken(String token) {
    _token = token.trim();
  }
  
  Map<String, String> get _headers => {
    'Accept': 'application/vnd.github.v3+json',
    if (_token != null && _token!.isNotEmpty) 'Authorization': 'token $_token',
  };
  
  /// 验证Token，返回用户名
  Future<String?> validateToken() async {
    final result = await validateTokenWithDetails();
    return result['username'];
  }
  
  /// 验证Token，返回详细信息
  Future<Map<String, String?>> validateTokenWithDetails() async {
    if (_token == null || _token!.isEmpty) {
      return {'error': 'Token 为空'};
    }
    
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/user'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {'username': data['login']};
      } else {
        return {'error': 'HTTP ${response.statusCode}'};
      }
    } on TimeoutException {
      return {'error': '请求超时(15秒)'};
    } catch (e) {
      return {'error': e.toString()};
    }
  }
  
  /// 获取文件内容
  Future<GitHubFileResult> getFileContent({
    required String owner,
    required String repo,
    required String path,
    String? branch,
  }) async {
    try {
      var url = '$_baseUrl/repos/$owner/$repo/contents/$path';
      if (branch != null) url += '?ref=$branch';
      
      final response = await http.get(
        Uri.parse(url),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final contentBase64 = (data['content'] as String).replaceAll('\n', '');
        final content = utf8.decode(base64Decode(contentBase64));
        return GitHubFileResult(
          success: true,
          content: content,
          sha: data['sha'],
        );
      } else if (response.statusCode == 404) {
        return GitHubFileResult(success: true, notFound: true);
      } else {
        return GitHubFileResult(
          success: false,
          error: 'HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      return GitHubFileResult(success: false, error: e.toString());
    }
  }
  
  /// 创建或更新文件
  Future<GitHubCommitResult> createOrUpdateFile({
    required String owner,
    required String repo,
    required String path,
    required String content,
    required String message,
    String? sha,
    String? branch,
  }) async {
    try {
      final body = {
        'message': message,
        'content': base64Encode(utf8.encode(content)),
        if (sha != null) 'sha': sha,
        if (branch != null) 'branch': branch,
      };
      
      final response = await http.put(
        Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$path'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return GitHubCommitResult(
          success: true,
          sha: data['commit']['sha'],
        );
      } else {
        return GitHubCommitResult(
          success: false,
          error: 'HTTP ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      return GitHubCommitResult(success: false, error: e.toString());
    }
  }
  
  /// 删除文件
  Future<GitHubCommitResult> deleteFile({
    required String owner,
    required String repo,
    required String path,
    required String sha,
    required String message,
    String? branch,
  }) async {
    try {
      final body = {
        'message': message,
        'sha': sha,
        if (branch != null) 'branch': branch,
      };
      
      final request = http.Request(
        'DELETE',
        Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$path'),
      );
      request.headers.addAll({..._headers, 'Content-Type': 'application/json'});
      request.body = jsonEncode(body);
      
      final streamedResponse = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        return GitHubCommitResult(success: true);
      } else {
        return GitHubCommitResult(
          success: false,
          error: 'HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      return GitHubCommitResult(success: false, error: e.toString());
    }
  }

  // ========== GitHub Actions API ==========

  /// 触发 workflow 构建
  Future<({bool success, String? error})> triggerWorkflow({
    required String owner,
    required String repo,
    required String workflowId,
    required String ref,
    Map<String, String>? inputs,
  }) async {
    try {
      final body = <String, dynamic>{
        'ref': ref,
      };
      if (inputs != null && inputs.isNotEmpty) {
        body['inputs'] = inputs;
      }


      final response = await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repo/actions/workflows/$workflowId/dispatches'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 204) {
        return (success: true, error: null);
      } else {
        return (success: false, error: 'HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      return (success: false, error: e.toString());
    }
  }

  /// 获取最新的 workflow 运行
  Future<({WorkflowRun? run, String? error})> getLatestWorkflowRun({
    required String owner,
    required String repo,
    String? workflowId,
  }) async {
    try {
      var url = '$_baseUrl/repos/$owner/$repo/actions/runs?per_page=1';
      if (workflowId != null) {
        url = '$_baseUrl/repos/$owner/$repo/actions/workflows/$workflowId/runs?per_page=1';
      }

      final response = await http.get(
        Uri.parse(url),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final runs = data['workflow_runs'] as List;
        if (runs.isEmpty) {
          return (run: null, error: '没有找到构建记录');
        }
        return (run: WorkflowRun.fromJson(runs.first), error: null);
      } else {
        return (run: null, error: 'HTTP ${response.statusCode}');
      }
    } catch (e) {
      return (run: null, error: e.toString());
    }
  }

  /// 获取 workflow 运行状态
  Future<({WorkflowRun? run, String? error})> getWorkflowRun({
    required String owner,
    required String repo,
    required int runId,
  }) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repo/actions/runs/$runId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (run: WorkflowRun.fromJson(data), error: null);
      } else {
        return (run: null, error: 'HTTP ${response.statusCode}');
      }
    } catch (e) {
      return (run: null, error: e.toString());
    }
  }

  /// 获取构建产物列表
  Future<({List<Artifact> artifacts, String? error})> getArtifacts({
    required String owner,
    required String repo,
    required int runId,
  }) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repo/actions/runs/$runId/artifacts'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final list = (data['artifacts'] as List)
            .map((e) => Artifact.fromJson(e))
            .toList();
        return (artifacts: list, error: null);
      } else {
        return (artifacts: <Artifact>[], error: 'HTTP ${response.statusCode}');
      }
    } catch (e) {
      return (artifacts: <Artifact>[], error: e.toString());
    }
  }

  /// 下载 artifact（返回 zip 字节数据）
  Future<({List<int>? bytes, String? error})> downloadArtifact({
    required String owner,
    required String repo,
    required int artifactId,
  }) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repo/actions/artifacts/$artifactId/zip'),
        headers: _headers,
      ).timeout(const Duration(minutes: 5));

      if (response.statusCode == 200) {
        return (bytes: response.bodyBytes, error: null);
      } else if (response.statusCode == 302) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl != null) {
          final redirectResponse = await http.get(
            Uri.parse(redirectUrl),
          ).timeout(const Duration(minutes: 5));
          
          if (redirectResponse.statusCode == 200) {
            return (bytes: redirectResponse.bodyBytes, error: null);
          }
        }
        return (bytes: null, error: '重定向失败');
      } else {
        return (bytes: null, error: 'HTTP ${response.statusCode}');
      }
    } catch (e) {
      return (bytes: null, error: e.toString());
    }
  }
}

/// 获取仓库的 workflows 列表
  Future<({List<WorkflowInfo> workflows, String? error})> getWorkflows({
    required String owner,
    required String repo,
  }) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repo/actions/workflows'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final list = (data['workflows'] as List)
            .map((e) => WorkflowInfo.fromJson(e))
            .where((w) => w.state == 'active')  // 只返回激活的 workflow
            .toList();
        return (workflows: list, error: null);
      } else {
        return (workflows: <WorkflowInfo>[], error: 'HTTP ${response.statusCode}');
      }
    } catch (e) {
      return (workflows: <WorkflowInfo>[], error: e.toString());
    }
  }

class GitHubFileResult {
  final bool success;
  final String? content;
  final String? sha;
  final String? error;
  final bool notFound;
  
  GitHubFileResult({
    required this.success,
    this.content,
    this.sha,
    this.error,
    this.notFound = false,
  });
}

class GitHubCommitResult {
  final bool success;
  final String? sha;
  final String? error;
  
  GitHubCommitResult({
    required this.success,
    this.sha,
    this.error,
  });
}

class WorkflowInfo {
  final int id;
  final String name;
  final String path;  // 如 ".github/workflows/android.yml"
  final String state; // "active", "disabled_manually", etc.

  WorkflowInfo({
    required this.id,
    required this.name,
    required this.path,
    required this.state,
  });

  factory WorkflowInfo.fromJson(Map<String, dynamic> json) => WorkflowInfo(
    id: json['id'] as int,
    name: json['name'] as String,
    path: json['path'] as String,
    state: json['state'] as String,
  );

  /// 获取文件名（用于 API 调用）
  String get fileName => path.split('/').last;
}

class WorkflowRun {
  final int id;
  final String status;
  final String? conclusion;
  final String createdAt;
  final String? runStartedAt;  // 实际开始执行的时间（用于计时同步）
  final String? htmlUrl;

  WorkflowRun({
    required this.id,
    required this.status,
    this.conclusion,
    required this.createdAt,
    this.runStartedAt,
    this.htmlUrl,
  });

  factory WorkflowRun.fromJson(Map<String, dynamic> json) => WorkflowRun(
    id: json['id'] as int,
    status: json['status'] as String,
    conclusion: json['conclusion'] as String?,
    createdAt: json['created_at'] as String,
    runStartedAt: json['run_started_at'] as String?,
    htmlUrl: json['html_url'] as String?,
  );

  /// 获取用于计时的开始时间（优先使用 runStartedAt，与官网同步）
  DateTime? get startTime {
    if (runStartedAt != null) {
      return DateTime.tryParse(runStartedAt!);
    }
    return DateTime.tryParse(createdAt);
  }

  bool get isCompleted => status == 'completed';
  bool get isSuccess => conclusion == 'success';
  bool get isRunning => status == 'in_progress' || status == 'queued';
  bool get isQueued => status == 'queued';
  bool get isInProgress => status == 'in_progress';
}


class Artifact {
  final int id;
  final String name;
  final int sizeInBytes;
  final String archiveDownloadUrl;

  Artifact({
    required this.id,
    required this.name,
    required this.sizeInBytes,
    required this.archiveDownloadUrl,
  });

  factory Artifact.fromJson(Map<String, dynamic> json) => Artifact(
    id: json['id'] as int,
    name: json['name'] as String,
    sizeInBytes: json['size_in_bytes'] as int,
    archiveDownloadUrl: json['archive_download_url'] as String,
  );

  String get sizeFormatted {
    if (sizeInBytes < 1024) return '$sizeInBytes B';
    if (sizeInBytes < 1024 * 1024) return '${(sizeInBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeInBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

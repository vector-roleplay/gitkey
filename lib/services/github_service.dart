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

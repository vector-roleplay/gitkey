import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/storage_service.dart';
import '../services/github_service.dart';
import '../models.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Repository> _repos = [];
  String? _tokenUser;
  bool _hasToken = false;
  bool _isValidating = false;
  String? _validateError;
  
  @override
  void initState() {
    super.initState();
    _loadData();
  }
  
  Future<void> _loadData() async {
    final storage = context.read<StorageService>();
    final github = context.read<GitHubService>();
    
    final token = storage.getToken();
    _hasToken = token != null && token.isNotEmpty;
    
    setState(() {
      _repos = storage.getRepositories();
      _isValidating = _hasToken;
      _validateError = null;
      _tokenUser = null;
    });
    
    if (_hasToken) {
      github.setToken(token!);
      try {
        final user = await github.validateToken();
        setState(() {
          _tokenUser = user;
          _isValidating = false;
          if (user == null) {
            _validateError = 'Token 无效或已过期';
          }
        });
      } catch (e) {
        setState(() {
          _isValidating = false;
          _validateError = e.toString();
        });
      }
    }
  }
  
  Future<void> _setToken() async {
    final storage = context.read<StorageService>();
    final currentToken = storage.getToken() ?? '';
    final controller = TextEditingController(text: currentToken);
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置 GitHub Token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请输入 GitHub Personal Access Token'),
            const SizedBox(height: 8),
            Text(
              '获取方式: GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Token',
                hintText: 'ghp_xxxxxxxxxxxx',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Text(
              '需要勾选 repo 权限',
              style: TextStyle(color: Colors.orange[700], fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      final github = context.read<GitHubService>();
      
      await storage.setToken(result);
      github.setToken(result);
      
      await _loadData();
    }
  }
  
  Future<void> _addRepository() async {
    final ownerController = TextEditingController();
    final nameController = TextEditingController();
    final branchController = TextEditingController(text: 'main');
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加仓库'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ownerController,
              decoration: const InputDecoration(
                labelText: '用户名/组织名',
                hintText: '例如: octocat',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '仓库名',
                hintText: '例如: my-repo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: branchController,
              decoration: const InputDecoration(
                labelText: '分支',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    
    if (result == true) {
      final owner = ownerController.text.trim();
      final name = nameController.text.trim();
      final branch = branchController.text.trim();
      
      if (owner.isNotEmpty && name.isNotEmpty) {
        final storage = context.read<StorageService>();
        await storage.addRepository(Repository(
          owner: owner,
          name: name,
          branch: branch.isNotEmpty ? branch : 'main',
        ));
        _loadData();
      }
    }
  }
  
  Future<void> _removeRepository(Repository repo) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除仓库'),
        content: Text('确定要删除 ${repo.fullName} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      final storage = context.read<StorageService>();
      await storage.removeRepository(repo.fullName);
      _loadData();
    }
  }
  
  Future<void> _setDefault(Repository repo) async {
    final storage = context.read<StorageService>();
    await storage.setDefaultRepository(repo.fullName);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          // GitHub Token
          _buildSection(
            title: 'GitHub 认证',
            children: [
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('Personal Access Token'),
                subtitle: Text(_hasToken ? '已设置' : '未设置'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _setToken,
              ),
              if (_isValidating)
                const ListTile(
                  leading: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text('正在验证 Token...'),
                ),
              if (_tokenUser != null)
                ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: const Text('已登录'),
                  subtitle: Text(_tokenUser!),
                ),
              if (_validateError != null)
                ListTile(
                  leading: const Icon(Icons.error, color: Colors.red),
                  title: const Text('验证失败'),
                  subtitle: Text(
                    _validateError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
          
          // 仓库管理
          _buildSection(
            title: '仓库管理',
            trailing: IconButton(
              icon: const Icon(Icons.add),
              onPressed: _addRepository,
            ),
            children: [
              if (_repos.isEmpty)
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('暂无仓库'),
                  subtitle: Text('点击右上角 + 添加仓库'),
                )
              else
                ..._repos.map((repo) => ListTile(
                  leading: Icon(
                    repo.isDefault ? Icons.star : Icons.folder,
                    color: repo.isDefault ? Colors.amber : null,
                  ),
                  title: Text(repo.fullName),
                  subtitle: Text('分支: ${repo.branch}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!repo.isDefault)
                        IconButton(
                          icon: const Icon(Icons.star_border),
                          tooltip: '设为默认',
                          onPressed: () => _setDefault(repo),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        tooltip: '删除',
                        onPressed: () => _removeRepository(repo),
                      ),
                    ],
                  ),
                )),
            ],
          ),
          
          // 关于
          _buildSection(
            title: '关于',
            children: [
              const ListTile(
                leading: Icon(Icons.info),
                title: Text('版本'),
                subtitle: Text('1.0.0'),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildSection({
    required String title,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: children),
        ),
      ],
    );
  }
}

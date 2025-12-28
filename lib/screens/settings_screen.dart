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
    
    if (_hasToken) {
      _tokenUser = await github.validateToken();
    }
    
    setState(() {
      _repos = storage.getRepositories();
    });
  }
  
  Future<void> _setToken() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置 GitHub Token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请输入 GitHub Personal Access Token'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '需要 repo 权限',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      final storage = context.read<StorageService>();
      final github = context.read<GitHubService>();
      
      await storage.setToken(result);
      github.setToken(result);
      
      _loadData();
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
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '仓库名',
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
      final storage = context.read<StorageService>();
      await storage.addRepository(Repository(
        owner: ownerController.text.trim(),
        name: nameController.text.trim(),
        branch: branchController.text.trim(),
      ));
      _loadData();
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
              if (_tokenUser != null)
                ListTile(
                  leading: const Icon(Icons.person),
                  title: const Text('已登录用户'),
                  subtitle: Text(_tokenUser!),
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
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('暂无仓库，点击右上角添加'),
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

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/storage_service.dart';
import '../services/github_service.dart';
import '../services/transfer_service.dart';
import '../models.dart';
import '../main.dart';


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
  String? _tokenPreview;
  
  // 工作区相关
  List<WorkspaceFile> _workspaceFiles = [];
  bool _workspaceMode = false;
  
  // 中转站相关
  int _transferFileCount = 0;
  Set<String> _selectedForTransfer = {};
  
  // 顶部提示消息
  String? _topMessage;
  bool _topMessageSuccess = true;

  /// 显示顶部提示消息
  void _showTopMessage(String message, {bool isSuccess = true}) {
    setState(() {
      _topMessage = message;
      _topMessageSuccess = isSuccess;
    });
    
    // 3秒后自动隐藏
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _topMessage == message) {
        setState(() {
          _topMessage = null;
        });
      }
    });
  }
  
  /// 隐藏顶部提示
  void _hideTopMessage() {
    setState(() {
      _topMessage = null;
    });
  }

  @override
  void initState() {


    super.initState();
    _loadData();
    _loadWorkspace();
  }
  
  void _loadWorkspace() {
    final storage = context.read<StorageService>();
    setState(() {
      _workspaceFiles = storage.getWorkspaceFiles();
      _workspaceMode = storage.getWorkspaceMode();
    });
    _loadTransferCount();
  }

  Future<void> _loadTransferCount() async {
    final count = await TransferService.instance.getFileCount();
    setState(() {
      _transferFileCount = count;
    });
  }

  /// 上传单个文件到中转站
  Future<void> _uploadToTransfer(WorkspaceFile file) async {
    final result = await TransferService.instance.uploadFile(
      TransferFile(path: file.path, content: file.content),
    );
    
    if (mounted) {
      if (result.success) {
        _showTopMessage('已上传: ${file.fileName}', isSuccess: true);
        _loadTransferCount();
      } else {
        _handleUploadError(result.error);
      }
    }
  }



  /// 批量上传到中转站
  Future<void> _uploadSelectedToTransfer() async {
    if (_selectedForTransfer.isEmpty) {
      _showTopMessage('请先选择文件', isSuccess: false);
      return;
    }

    final filesToUpload = _workspaceFiles
        .where((f) => _selectedForTransfer.contains(f.path))
        .map((f) => TransferFile(path: f.path, content: f.content))
        .toList();

    final result = await TransferService.instance.uploadFiles(filesToUpload);
    
    if (mounted) {
      if (result.success) {
        _showTopMessage('已上传 ${filesToUpload.length} 个文件到中转站', isSuccess: true);
        setState(() {
          _selectedForTransfer.clear();
        });
        _loadTransferCount();
      } else {
        _handleUploadError(result.error);
      }
    }
  }


  /// 上传全部工作区文件到中转站

  Future<void> _uploadAllToTransfer() async {
    if (_workspaceFiles.isEmpty) {
      _showTopMessage('工作区没有文件', isSuccess: false);
      return;
    }


    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('上传全部文件'),
        content: Text('确定要上传全部 ${_workspaceFiles.length} 个文件到中转站吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('上传'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final filesToUpload = _workspaceFiles
        .map((f) => TransferFile(path: f.path, content: f.content))
        .toList();

    final result = await TransferService.instance.uploadFiles(filesToUpload);
    
    if (mounted) {
      if (result.success) {
        _showTopMessage('已上传 ${filesToUpload.length} 个文件到中转站', isSuccess: true);
        _loadTransferCount();
      } else {
        _handleUploadError(result.error);
      }
    }
  }

  /// 处理上传错误（显示权限引导对话框）

  void _handleUploadError(String? error) {
    if (error != null && error.contains('权限')) {
      // 显示权限引导对话框
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.folder_off, color: Colors.orange),
              SizedBox(width: 8),
              Text('需要存储权限'),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('中转站功能需要"所有文件访问权限"才能在公共目录存储文件。'),
              SizedBox(height: 12),
              Text('请按以下步骤操作：', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('1. 点击"去设置"按钮'),
              Text('2. 找到"所有文件访问权限"或"文件和媒体"'),
              Text('3. 开启权限'),
              Text('4. 返回应用重试'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await TransferService.instance.openSettings();
              },
              icon: const Icon(Icons.settings),
              label: const Text('去设置'),
            ),
          ],
        ),
      );
    } else {
      _showTopMessage('上传失败: ${error ?? "未知错误"}', isSuccess: false);
    }
  }

  /// 查看中转站内容


  Future<void> _viewTransferStation() async {
    final files = await TransferService.instance.getFiles();
    
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(
                    '中转站 (${files.length}个文件)',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (files.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await TransferService.instance.clear();
                        _loadTransferCount();
                        if (mounted) {
                          _showTopMessage('中转站已清空', isSuccess: true);
                        }
                      },
                      icon: const Icon(Icons.delete_sweep, size: 18, color: Colors.red),
                      label: const Text('清空', style: TextStyle(color: Colors.red)),
                    ),

                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (files.isEmpty)
              const Expanded(
                child: Center(
                  child: Text('中转站是空的', style: TextStyle(color: Colors.grey)),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: files.length,
                  itemBuilder: (ctx, index) {
                    final file = files[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.description, size: 20),
                      title: Text(
                        file.fileName,
                        style: const TextStyle(fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        file.path,
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                        onPressed: () async {
                          await TransferService.instance.removeFile(file.path);
                          Navigator.pop(ctx);
                          _viewTransferStation(); // 重新打开
                          _loadTransferCount();
                        },
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadData() async {

    final storage = context.read<StorageService>();
    final github = context.read<GitHubService>();
    
    final token = storage.getToken();
    _hasToken = token != null && token.isNotEmpty;
    
    if (_hasToken && token != null) {
      _tokenPreview = '${token.substring(0, 8)}...${token.substring(token.length - 4)}';
    }
    
    setState(() {
      _repos = storage.getRepositories();
      _isValidating = _hasToken;
      _validateError = null;
      _tokenUser = null;
    });
    
    if (_hasToken && token != null) {
      github.setToken(token);
      final result = await github.validateTokenWithDetails();
      setState(() {
        _isValidating = false;
        if (result.containsKey('username') && result['username'] != null) {
          _tokenUser = result['username'];
        } else {
          _validateError = result['error'] ?? '未知错误';
        }
      });
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
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Token',
                  hintText: 'ghp_xxxxxxxxxxxx',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 12),
              Text(
                '格式: ghp_开头的字符串',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ],
          ),
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
    final storage = context.read<StorageService>();
    await storage.removeRepository(repo.fullName);
    _loadData();
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
      body: Column(
        children: [
          // 顶部提示消息
          if (_topMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              decoration: BoxDecoration(
                color: _topMessageSuccess 
                    ? Colors.green.withOpacity(0.15) 
                    : Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _topMessageSuccess 
                      ? Colors.green.withOpacity(0.3) 
                      : Colors.orange.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _topMessageSuccess ? Icons.check_circle : Icons.info,
                    color: _topMessageSuccess ? Colors.green : Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _topMessage!,
                      style: TextStyle(
                        color: _topMessageSuccess ? Colors.green[700] : Colors.orange[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _hideTopMessage,
                    child: Icon(
                      Icons.close,
                      color: _topMessageSuccess ? Colors.green[400] : Colors.orange[400],
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
          
          // 主体内容
          Expanded(
            child: ListView(
              children: [

          _buildSection(
            title: 'GitHub 认证',
            children: [
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('Personal Access Token'),
                subtitle: _tokenPreview != null 
                    ? Text(_tokenPreview!, style: const TextStyle(fontFamily: 'monospace'))
                    : const Text('未设置'),
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
                  title: Text('正在验证...'),
                ),
              if (_tokenUser != null)
                ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: Text('已登录: $_tokenUser'),
                ),
              if (_validateError != null)
                ListTile(
                  leading: const Icon(Icons.error, color: Colors.red),
                  title: const Text('验证失败'),
                  subtitle: Text(
                    _validateError!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
            ],
          ),
          
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
                  subtitle: Text('点击右上角 + 添加'),
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
                          onPressed: () => _setDefault(repo),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _removeRepository(repo),
                      ),
                    ],
                  ),
                )),
            ],
          ),
          
          _buildSection(
            title: '本地工作区',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _workspaceMode ? '已启用' : '已禁用',
                  style: TextStyle(
                    fontSize: 12,
                    color: _workspaceMode ? Colors.green : Colors.grey,
                  ),
                ),
                Switch(
                  value: _workspaceMode,
                  onChanged: _toggleWorkspaceMode,
                ),
              ],
            ),
            children: [
              // 操作按钮
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _importLocalFiles,
                            icon: const Icon(Icons.file_upload, size: 18),
                            label: const Text('导入文件'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _importFromGit,
                            icon: const Icon(Icons.cloud_download, size: 18),
                            label: const Text('从Git导入'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 中转站按钮行
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _viewTransferStation,
                            icon: Badge(
                              isLabelVisible: _transferFileCount > 0,
                              label: Text('$_transferFileCount'),
                              child: const Icon(Icons.swap_horiz, size: 18),
                            ),
                            label: const Text('查看中转站'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.blue,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _workspaceFiles.isEmpty ? null : _uploadAllToTransfer,
                            icon: const Icon(Icons.upload, size: 18),
                            label: const Text('全部上传'),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.blue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_workspaceFiles.isNotEmpty) ...[
                const Divider(height: 1),
                Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _workspaceFiles.length,
                    itemBuilder: (context, index) {
                      final file = _workspaceFiles[index];
                      final isSelected = _selectedForTransfer.contains(file.path);
                      return ListTile(

                        dense: true,
                        leading: const Icon(Icons.description, size: 20),
                        title: Text(
                          file.fileName,
                          style: const TextStyle(fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          file.path,
                          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.upload, size: 18, color: Colors.blue),
                              tooltip: '上传到中转站',
                              onPressed: () => _uploadToTransfer(file),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18, color: Colors.red),
                              onPressed: () => _removeWorkspaceFile(file.path),
                            ),
                          ],
                        ),
                        onTap: () => _viewWorkspaceFile(file),
                      );
                    },
                  ),
                ),

                const Divider(height: 1),
                // 底部统计和清空
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.folder, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 8),
                      Text(
                        '共 ${_workspaceFiles.length} 个文件',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _clearWorkspace,
                        icon: const Icon(Icons.delete_sweep, size: 18, color: Colors.red),
                        label: const Text('清空', style: TextStyle(color: Colors.red)),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _clearAllData,
                        icon: const Icon(Icons.cleaning_services, size: 18, color: Colors.orange),
                        label: const Text('一键清理', style: TextStyle(color: Colors.orange)),
                      ),
                    ],
                  ),
                ),

              ] else ...[
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      '暂无文件，点击上方按钮导入',
                      style: TextStyle(color: Colors.grey[500]),
                    ),
                  ),
                ),
                // 即使工作区为空，也显示一键清理按钮（用于清理中转站）
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _clearAllData,
                      icon: const Icon(Icons.cleaning_services, size: 18, color: Colors.orange),
                      label: const Text('一键清理中转站', style: TextStyle(color: Colors.orange)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.orange),
                      ),
                    ),
                  ),
                ),
              ],

            ],
          ),
          
          _buildSection(
            title: '应用更新',
            children: [
              ListTile(
                leading: const Icon(Icons.build_circle, color: Colors.blue),
                title: const Text('构建新版本'),
                subtitle: const Text('触发 GitHub Actions 构建 APK'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pushNamed(context, '/build'),
              ),
            ],
          ),
          
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
          ),
        ],
      ),
    );
  }


  
  Future<void> _toggleWorkspaceMode(bool enabled) async {
    final storage = context.read<StorageService>();
    final appState = context.read<AppState>();
    await storage.setWorkspaceMode(enabled);
    appState.setWorkspaceMode(enabled);
    setState(() => _workspaceMode = enabled);
  }
  
  Future<void> _importLocalFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    
    if (result == null || result.files.isEmpty) return;
    
    final storage = context.read<StorageService>();
    final newFiles = <WorkspaceFile>[];
    
    for (final file in result.files) {
      if (file.path == null) continue;
      try {
        final content = await File(file.path!).readAsString();
        // 使用文件名作为路径，用户可以后续编辑
        newFiles.add(WorkspaceFile(
          path: file.name,
          content: content,
        ));
      } catch (e) {
        // 跳过无法读取的文件
      }
    }
    
    if (newFiles.isNotEmpty) {
      await storage.addWorkspaceFiles(newFiles);
      _loadWorkspace();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 ${newFiles.length} 个文件')),
        );
      }
    }
  }
  
  Future<void> _importFromGit() async {
    if (_repos.isEmpty) {
      _showTopMessage('请先添加仓库', isSuccess: false);
      return;
    }

    
    // 选择仓库
    final selectedRepo = await showDialog<Repository>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择仓库'),
        children: _repos.map((repo) => SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, repo),
          child: Text(repo.fullName),
        )).toList(),
      ),
    );
    
    if (selectedRepo == null) return;
    
    // 输入文件路径
    final pathController = TextEditingController();
    final paths = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入文件路径'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('每行一个路径，例如：\nlib/main.dart\nlib/models.dart', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: pathController,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'lib/main.dart',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final lines = pathController.text
                  .split('\n')
                  .map((l) => l.trim())
                  .where((l) => l.isNotEmpty)
                  .toList();
              Navigator.pop(ctx, lines);
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
    
    if (paths == null || paths.isEmpty) return;
    
    // 从 GitHub 下载文件
    final github = context.read<GitHubService>();
    final storage = context.read<StorageService>();
    final newFiles = <WorkspaceFile>[];
    int failCount = 0;
    
    // 显示加载指示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    
    for (final path in paths) {
      final result = await github.getFileContent(
        owner: selectedRepo.owner,
        repo: selectedRepo.name,
        path: path,
        branch: selectedRepo.branch,
      );
      
      if (result.success && result.content != null) {
        newFiles.add(WorkspaceFile(
          path: path,
          content: result.content!,
        ));
      } else {
        failCount++;
      }
    }
    
    Navigator.pop(context); // 关闭加载指示
    
    if (newFiles.isNotEmpty) {
      await storage.addWorkspaceFiles(newFiles);
      _loadWorkspace();
    }
    
    if (mounted) {
      _showTopMessage(
        '已导入 ${newFiles.length} 个文件${failCount > 0 ? '，$failCount 个失败' : ''}',
        isSuccess: failCount == 0,
      );
    }
  }
  
  Future<void> _removeWorkspaceFile(String path) async {

    final storage = context.read<StorageService>();
    await storage.removeWorkspaceFile(path);
    _loadWorkspace();
  }
  
  Future<void> _clearWorkspace() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空工作区'),
        content: const Text('确定要清空所有本地工作区文件吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      final storage = context.read<StorageService>();
      await storage.clearWorkspace();
      _loadWorkspace();
    }
  }/// 一键清理工作区和中转站
  Future<void> _clearAllData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.cleaning_services, color: Colors.orange),
            SizedBox(width: 8),
            Text('一键清理'),
          ],
        ),
        content: const Text('确定要同时清空本地工作区和中转站的所有文件吗？\n\n此操作不可恢复！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('确定清理'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      final storage = context.read<StorageService>();
      await storage.clearWorkspace();
      await TransferService.instance.clear();
      _loadWorkspace();
      if (mounted) {
        _showTopMessage('已清理工作区和中转站', isSuccess: true);
      }
    }
  }

  
  void _viewWorkspaceFile(WorkspaceFile file) {

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(file.fileName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        Text(file.path, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  file.content,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
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

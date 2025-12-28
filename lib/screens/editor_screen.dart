import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models.dart';
import '../services/parser_service.dart';
import '../widgets/code_editor.dart';
import '../widgets/diff_viewer.dart';

class EditorScreen extends StatefulWidget {
  final String filePath;
  
  const EditorScreen({super.key, required this.filePath});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late TextEditingController _controller;
  FileChange? _fileChange;
  bool _showDiff = true;
  List<DiffLine> _diffLines = [];
  
  // 撤销/重做
  final List<String> _history = [];
  int _historyIndex = -1;
  
  @override
  void initState() {
    super.initState();
    _loadFile();
  }
  
  void _loadFile() {
    final appState = context.read<AppState>();
    _fileChange = appState.getFileChange(widget.filePath);
    
    final content = _fileChange?.modifiedContent ?? _fileChange?.originalContent ?? '';
    _controller = TextEditingController(text: content);
    
    _history.add(content);
    _historyIndex = 0;
    
    _updateDiff();
  }
  
  void _updateDiff() {
    if (_fileChange == null) return;
    
    final diffGenerator = context.read<DiffGenerator>();
    setState(() {
      _diffLines = diffGenerator.generate(
        _fileChange!.originalContent,
        _controller.text,
      );
    });
  }
  
  void _onTextChanged() {
    // 添加到历史
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(_controller.text);
    _historyIndex = _history.length - 1;
    
    // 限制历史数量
    if (_history.length > 50) {
      _history.removeAt(0);
      _historyIndex--;
    }
    
    _updateDiff();
  }
  
  void _undo() {
    if (_historyIndex > 0) {
      _historyIndex--;
      _controller.text = _history[_historyIndex];
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      _updateDiff();
    }
  }
  
  void _redo() {
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      _controller.text = _history[_historyIndex];
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      _updateDiff();
    }
  }
  
  void _reset() {
    _controller.text = _fileChange?.originalContent ?? '';
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    _onTextChanged();
  }
  
  void _save() {
    final appState = context.read<AppState>();
    if (_fileChange != null) {
      appState.updateFileChange(
        widget.filePath,
        _fileChange!.copyWith(modifiedContent: _controller.text),
      );
    }
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.filePath.split('/').last;
    final filePath = widget.filePath.contains('/')
        ? widget.filePath.substring(0, widget.filePath.lastIndexOf('/'))
        : '';
    
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fileName, style: const TextStyle(fontSize: 16)),
            if (filePath.isNotEmpty)
              Text(
                filePath,
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
          ],
        ),
        actions: [
          // 切换视图
          IconButton(
            icon: Icon(_showDiff ? Icons.edit : Icons.difference),
            tooltip: _showDiff ? '编辑模式' : '差异模式',
            onPressed: () => setState(() => _showDiff = !_showDiff),
          ),
          // 撤销
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: '撤销',
            onPressed: _historyIndex > 0 ? _undo : null,
          ),
          // 重做
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: '重做',
            onPressed: _historyIndex < _history.length - 1 ? _redo : null,
          ),
        ],
      ),
      body: _showDiff
          ? DiffViewer(diffLines: _diffLines)
          : CodeEditor(
              controller: _controller,
              onChanged: _onTextChanged,
              language: _getLanguage(widget.filePath),
            ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: _reset,
              child: const Text('重置'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
  
  String _getLanguage(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'kt' || 'kts' => 'kotlin',
      'java' => 'java',
      'dart' => 'dart',
      'js' => 'javascript',
      'ts' => 'typescript',
      'xml' => 'xml',
      'json' => 'json',
      'yaml' || 'yml' => 'yaml',
      _ => 'text',
    };
  }
}

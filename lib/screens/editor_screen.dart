import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models.dart';
import '../services/parser_service.dart';
import '../widgets/code_editor.dart';

class EditorScreen extends StatefulWidget {
  final String filePath;
  
  const EditorScreen({super.key, required this.filePath});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late TextEditingController _controller;
  FileChange? _fileChange;
  
  // 撤销/重做
  final List<String> _history = [];
  int _historyIndex = -1;
  bool _isModified = false;
  
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
    
    setState(() {
      _isModified = true;
    });
  }
  
  void _undo() {
    if (_historyIndex > 0) {
      _historyIndex--;
      _controller.text = _history[_historyIndex];
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      setState(() {});
    }
  }
  
  void _redo() {
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      _controller.text = _history[_historyIndex];
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      setState(() {});
    }
  }
  
  void _reset() {
    final original = _fileChange?.originalContent ?? '';
    _controller.text = original;
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    _history.add(original);
    _historyIndex = _history.length - 1;
    setState(() {
      _isModified = false;
    });
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
    
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: '撤销',
            onPressed: _historyIndex > 0 ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: '重做',
            onPressed: _historyIndex < _history.length - 1 ? _redo : null,
          ),
        ],
      ),
      body: CodeEditor(
        controller: _controller,
        onChanged: _onTextChanged,
      ),
      bottomNavigationBar: Container(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: 12 + MediaQuery.of(context).padding.bottom,
        ),
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
          children: [
            if (_fileChange?.originalContent != null)
              Text(
                widget.filePath,
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            const Spacer(),
            OutlinedButton(
              onPressed: _reset,
              child: const Text('重置'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
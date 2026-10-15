import 'package:flutter/material.dart';

import '../../app/services/system_font_service.dart';

/// Searchable system-font selector with a manual family-name fallback.
class SystemFontPicker extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final String label;

  const SystemFontPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = '字体',
  });

  @override
  State<SystemFontPicker> createState() => _SystemFontPickerState();
}

class _SystemFontPickerState extends State<SystemFontPicker> {
  late final TextEditingController _controller;
  late String _value;
  List<String> _families = const [];
  bool _loading = SystemFontService.supported;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
    _controller = TextEditingController(text: widget.value);
    _loadFamilies();
  }

  @override
  void didUpdateWidget(SystemFontPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _controller.text != widget.value) {
      _value = widget.value;
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadFamilies() async {
    final families = await SystemFontService.availableFamilies();
    if (!mounted) return;
    setState(() {
      _families = families;
      _loading = false;
    });
  }

  Future<void> _selectFont() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) =>
          _SystemFontDialog(families: _families, selected: _value),
    );
    if (selected == null) return;
    setState(() {
      _value = selected;
      _controller.text = selected;
    });
    widget.onChanged(selected);
  }

  void _saveManualValue() {
    final value = _controller.text.trim();
    _value = value;
    widget.onChanged(value);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!SystemFontService.supported) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final value = _value.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _loading ? null : _selectFont,
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: widget.label,
              helperText: SystemFontService.supported
                  ? _loading
                        ? '正在读取本机字体…'
                        : '已读取 ${_families.length} 个本机字体，点击搜索选择'
                  : '当前平台使用系统默认或手动输入的字体',
              border: const OutlineInputBorder(),
              suffixIcon: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : const Icon(Icons.search_rounded),
            ),
            child: Text(
              value.isEmpty ? '跟随系统' : value,
              style: TextStyle(
                fontFamily: value.isEmpty ? null : value,
                color: colors.onSurface,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            labelText: '手动输入字体名称（可选）',
            hintText: '留空即跟随系统',
            helperText: '字体不存在时会由系统自动回退',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: '跟随系统',
              onPressed: () {
                _value = '';
                _controller.clear();
                widget.onChanged('');
                setState(() {});
              },
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ),
          onSubmitted: (_) => _saveManualValue(),
          onEditingComplete: _saveManualValue,
        ),
      ],
    );
  }
}

class _SystemFontDialog extends StatefulWidget {
  final List<String> families;
  final String selected;

  const _SystemFontDialog({required this.families, required this.selected});

  @override
  State<_SystemFontDialog> createState() => _SystemFontDialogState();
}

class _SystemFontDialogState extends State<_SystemFontDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.families
        : widget.families
              .where((family) => family.toLowerCase().contains(query))
              .toList();
    return AlertDialog(
      title: const Text('选择字体'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索本机字体',
                prefixIcon: Icon(Icons.search_rounded),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length + 1,
                itemBuilder: (context, index) {
                  final family = index == 0 ? '' : filtered[index - 1];
                  final label = family.isEmpty ? '跟随系统' : family;
                  return ListTile(
                    title: Text(
                      label,
                      style: TextStyle(
                        fontFamily: family.isEmpty ? null : family,
                      ),
                    ),
                    trailing: widget.selected == family
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.pop(context, family),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

import 'package:flutter/widgets.dart';

import '../theme.dart';

/// Single-line text field built on [EditableText], styled for the console.
class TextInput extends StatefulWidget {
  const TextInput({
    super.key,
    required this.controller,
    this.placeholder = '',
    this.onSubmitted,
    this.obscure = false,
    this.keyboardType = TextInputType.text,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String>? onSubmitted;
  final bool obscure;
  final TextInputType keyboardType;
  final bool autofocus;

  @override
  State<TextInput> createState() => _TextInputState();
}

class _TextInputState extends State<TextInput> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Palette.slot,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: _focus.hasFocus ? Palette.live : Palette.edge),
        ),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            ValueListenableBuilder(
              valueListenable: widget.controller,
              builder: (context, value, _) => value.text.isEmpty
                  ? Text(widget.placeholder, style: TextStyles.body.copyWith(fontSize: 15, color: Palette.textDim))
                  : const SizedBox.shrink(),
            ),
            EditableText(
              controller: widget.controller,
              focusNode: _focus,
              autofocus: widget.autofocus,
              obscureText: widget.obscure,
              keyboardType: widget.keyboardType,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyles.body.copyWith(fontSize: 15),
              cursorColor: Palette.live,
              backgroundCursorColor: Palette.textDim,
              selectionColor: Palette.live.withValues(alpha: 0.35),
              onSubmitted: widget.onSubmitted,
            ),
          ],
        ),
      ),
    );
  }
}

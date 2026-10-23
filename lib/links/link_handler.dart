import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'webview_screen.dart';

final RegExp twiceUrlRegex = RegExp(
  r'(https?://[^\s<>"\u0000-\u001F]+)',
  caseSensitive: false,
);

bool twiceIsHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

Future<void> twiceOpenLink(BuildContext context, String raw) async {
  final value = raw.trim();
  if (value.isEmpty) return;

  if (twiceIsHttpUrl(value)) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LinkWebViewScreen(url: value),
      ),
    );
    return;
  }

  final uri = Uri.tryParse(value);
  if (uri == null) return;
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('This link cannot be opened on this device.')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not open link: $e')),
      );
    }
  }
}

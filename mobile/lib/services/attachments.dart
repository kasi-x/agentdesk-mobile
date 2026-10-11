import 'package:flutter/foundation.dart';

/// Uploaded attachment value stored into form data on submit (I-1001):
/// `{attachmentId, kind, contentType}` — the same passthrough path as
/// every other form value (hub forwards `data` to `replyUrl` unchecked).
@immutable
class AttachmentValue {
  final String attachmentId;
  final String kind;
  final String contentType;

  /// Local bytes kept for preview/replay until upload succeeds.
  final Uint8List? previewBytes;

  /// Local file path (audio recording before upload), if any.
  final String? localPath;

  const AttachmentValue({
    required this.attachmentId,
    required this.kind,
    required this.contentType,
    this.previewBytes,
    this.localPath,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'attachmentId': attachmentId,
        'kind': kind,
        'contentType': contentType,
      };
}

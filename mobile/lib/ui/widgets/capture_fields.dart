import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import '../../services/attachments.dart';
import '../../services/hub_api.dart';

/// MIME guess for picked images (image_picker gives no content type).
String _imageContentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
    return 'image/heic';
  }
  return 'image/jpeg';
}

/// Audio note field (I-1001): record/stop, duration, replay, remove.
///
/// Uploads on stop via [HubGuardrailsApi.uploadAttachment] and reports
/// the stored [AttachmentValue] through [onChanged]. The value stays
/// local-only (`attachmentId == ''`) when the hub has no upload surface
/// or the upload fails — submit then omits the field rather than
/// sending a dangling reference.
///
/// On web the same flow runs through record_web/audioplayers_web
/// (blob URL stop path → bytes upload → BytesSource replay). When the
/// microphone permission is denied the widget renders a disabled state.
class AudioCaptureField extends StatefulWidget {
  final String componentId;
  final String label;
  final AttachmentValue? value;
  final ValueChanged<AttachmentValue?> onChanged;
  final HubGuardrailsApi? uploader;

  const AudioCaptureField({
    super.key,
    required this.componentId,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.uploader,
  });

  @override
  State<AudioCaptureField> createState() => _AudioCaptureFieldState();
}

class _AudioCaptureFieldState extends State<AudioCaptureField> {
  AudioRecorder? _recorder;
  AudioPlayer? _player;
  bool _recording = false;
  bool _playing = false;
  bool _busy = false;
  bool _denied = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  Uint8List? _localBytes;
  String? _localPath;
  String? _localContentType;

  @override
  void dispose() {
    _ticker?.cancel();
    _stopReplay();
    _recorder?.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<DirectoryLike> _tmpDir() async {
    // record needs a file path on IO platforms; web ignores it.
    if (kIsWeb) return _WebTmp();
    final dir = Directory.systemTemp;
    return _IoTmp(dir.path);
  }

  Future<void> _toggleRecord() async {
    if (_busy) return;
    if (_recording) {
      await _stop();
      return;
    }
    setState(() {
      _busy = true;
      _denied = false;
    });
    try {
      final recorder = AudioRecorder();
      _recorder = recorder;
      final allowed = await recorder.hasPermission();
      if (!allowed) {
        await recorder.dispose();
        _recorder = null;
        if (mounted) setState(() => _denied = true);
        return;
      }
      final tmp = await _tmpDir();
      final path = tmp.join(
          'agentdesk_${widget.componentId}_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path);
      if (!mounted) return;
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
      });
    } catch (_) {
      // Emulator without a mic, missing plugin on desktop, etc:
      // surface the disabled state instead of crashing (FR-1.3).
      await _recorder?.dispose();
      _recorder = null;
      if (mounted) setState(() => _denied = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    final recorder = _recorder;
    if (recorder == null) return;
    setState(() => _busy = true);
    try {
      _ticker?.cancel();
      final outPath = await recorder.stop();
      await recorder.dispose();
      _recorder = null;
      if (!mounted) return;
      setState(() => _recording = false);
      String? dataBase64;
      String contentType = 'audio/mp4';
      Uint8List? bytes;
      if (!kIsWeb && outPath != null && outPath.isNotEmpty) {
        bytes = await _readBytes(outPath);
        if (bytes != null) dataBase64 = base64Encode(bytes);
        _localPath = outPath;
      } else if (outPath != null && outPath.isNotEmpty) {
        // record_web returns a blob URL: fetch its bytes for upload.
        bytes = await _readBytes(outPath);
        if (bytes != null) dataBase64 = base64Encode(bytes);
        _localPath = outPath;
      }
      _localBytes = bytes;
      _localContentType = contentType;
      final uploader = widget.uploader;
      if (uploader != null && dataBase64 != null) {
        final ref = await uploader.uploadAttachment(
          kind: 'audio',
          contentType: contentType,
          dataBase64: dataBase64,
        );
        if (!mounted) return;
        if (ref != null) {
          widget.onChanged(AttachmentValue(
            attachmentId: ref.id,
            kind: 'audio',
            contentType: contentType,
            previewBytes: bytes,
            localPath: _localPath,
          ));
          return;
        }
      }
      // No uploader (old hub) or upload failed: keep the local clip for
      // replay, but report no value so submit omits the field.
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _recording = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List?> _readBytes(String path) async {
    try {
      if (path.startsWith('blob:')) {
        // Web blob URL from record_web — not directly readable as a
        // file; leave replay to the URL and skip upload bytes.
        return null;
      }
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _toggleReplay() async {
    if (_playing) {
      await _stopReplay();
      if (mounted) setState(() => _playing = false);
      return;
    }
    try {
      final player = AudioPlayer();
      _player?.dispose();
      _player = player;
      player.onPlayerStateChanged.listen((state) {
        if (!mounted) return;
        if (state == PlayerState.completed ||
            state == PlayerState.stopped) {
          setState(() => _playing = false);
        }
      });
      final existing = widget.value;
      if (_localBytes != null && _localBytes!.isNotEmpty) {
        await player.play(BytesSource(_localBytes!,
            mimeType: _localContentType ?? 'audio/mp4'));
      } else if (_localPath != null && _localPath!.isNotEmpty) {
        if (_localPath!.startsWith('blob:')) {
          await player.play(UrlSource(_localPath!));
        } else {
          await player.play(
              DeviceFileSource(_localPath!, mimeType: 'audio/mp4'));
        }
      } else if (existing?.localPath != null &&
          existing!.localPath!.isNotEmpty) {
        final p = existing.localPath!;
        if (p.startsWith('blob:')) {
          await player.play(UrlSource(p));
        } else {
          await player
              .play(DeviceFileSource(p, mimeType: existing.contentType));
        }
      } else {
        await player.dispose();
        _player = null;
        return;
      }
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      // No codec on this desktop build — stay quiet, keep the tile.
      await _stopReplay();
    }
  }

  Future<void> _stopReplay() async {
    try {
      await _player?.stop();
    } catch (_) {
      // Player already gone; nothing to stop.
    }
    await _player?.dispose();
    _player = null;
  }

  void _remove() {
    _stopReplay();
    setState(() {
      _localBytes = null;
      _localPath = null;
      _elapsed = Duration.zero;
    });
    widget.onChanged(null);
  }

  String _format(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final hasClip = widget.value != null ||
        _localBytes != null ||
        _localPath != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label,
            style: const TextStyle(fontSize: 13, color: Colors.white70)),
        const SizedBox(height: 4),
        Row(
          children: [
            FilledButton.icon(
              onPressed: (_busy || _denied) ? null : _toggleRecord,
              icon: Icon(_recording ? Icons.stop : Icons.mic, size: 18),
              label: Text(_recording
                  ? '停止'
                  : hasClip
                      ? '録り直す'
                      : '録音する'),
            ),
            if (hasClip && !_recording) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                tooltip: '再生',
                onPressed: _toggleReplay,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: '削除',
                onPressed: _remove,
              ),
            ],
            if (_busy && !_recording)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (_recording)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fiber_manual_record,
                          size: 10, color: Colors.redAccent),
                      const SizedBox(width: 4),
                      Text(
                        _format(_elapsed),
                        style: const TextStyle(
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (_denied)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('権限がありません',
                style: TextStyle(fontSize: 12, color: Colors.white38)),
          ),
        if (widget.uploader == null && hasClip)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('このハブは添付に対応していません（送信時に省略）',
                style: TextStyle(fontSize: 12, color: Colors.white38)),
          ),
      ],
    );
  }
}

/// Image field (I-1001): camera/gallery pick, thumbnail, remove.
///
/// Same upload-then-reference flow as [AudioCaptureField]. Web uses the
/// image_picker web backend (no manifest/plist needed there).
class ImageCaptureField extends StatefulWidget {
  final String componentId;
  final String label;
  final AttachmentValue? value;
  final ValueChanged<AttachmentValue?> onChanged;
  final HubGuardrailsApi? uploader;
  final bool allowCamera;
  final bool allowGallery;

  const ImageCaptureField({
    super.key,
    required this.componentId,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.uploader,
    this.allowCamera = true,
    this.allowGallery = true,
  });

  @override
  State<ImageCaptureField> createState() => _ImageCaptureFieldState();
}

class _ImageCaptureFieldState extends State<ImageCaptureField> {
  final ImagePicker _picker = ImagePicker();
  bool _busy = false;
  bool _denied = false;
  Uint8List? _localBytes;

  Future<void> _pick(ImageSource source) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _denied = false;
    });
    try {
      final file = await _picker.pickImage(source: source, imageQuality: 85);
      if (file == null) return; // user cancelled — not an error.
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _localBytes = bytes;
      });
      final contentType = _imageContentType(file.path);
      final uploader = widget.uploader;
      if (uploader != null) {
        final ref = await uploader.uploadAttachment(
          kind: 'image',
          contentType: contentType,
          dataBase64: base64Encode(bytes),
        );
        if (!mounted) return;
        if (ref != null) {
          widget.onChanged(AttachmentValue(
            attachmentId: ref.id,
            kind: 'image',
            contentType: contentType,
            previewBytes: bytes,
            localPath: file.path,
          ));
          return;
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Permission denied or no camera on this device/desktop:
      // disabled state, never a crash.
      if (mounted) setState(() => _denied = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove() {
    setState(() => _localBytes = null);
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.value?.previewBytes ?? _localBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label,
            style: const TextStyle(fontSize: 13, color: Colors.white70)),
        const SizedBox(height: 4),
        if (bytes != null && bytes.isNotEmpty)
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(bytes,
                    width: 160, height: 160, fit: BoxFit.cover),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton.filledTonal(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '削除',
                  onPressed: _remove,
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              if (widget.allowCamera)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera, size: 18),
                  label: const Text('撮る'),
                ),
              if (widget.allowCamera && widget.allowGallery)
                const SizedBox(width: 8),
              if (widget.allowGallery)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library, size: 18),
                  label: const Text('選ぶ'),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        if (bytes != null && bytes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                if (widget.allowCamera)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera, size: 16),
                    label: const Text('撮り直す'),
                  ),
                if (widget.allowGallery)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library, size: 16),
                    label: const Text('選び直す'),
                  ),
              ],
            ),
          ),
        if (_denied)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('権限がありません',
                style: TextStyle(fontSize: 12, color: Colors.white38)),
          ),
        if (widget.uploader == null &&
            (bytes != null && bytes.isNotEmpty))
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('このハブは添付に対応していません（送信時に省略）',
                style: TextStyle(fontSize: 12, color: Colors.white38)),
          ),
      ],
    );
  }
}

// -- tiny temp-path helpers (record wants a path on IO; web ignores it)

abstract class DirectoryLike {
  String join(String name);
}

class _WebTmp implements DirectoryLike {
  @override
  String join(String name) => name;
}

class _IoTmp implements DirectoryLike {
  final String dir;
  _IoTmp(this.dir);

  @override
  String join(String name) =>
      '$dir${Platform.pathSeparator}$name';
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'gif_saver.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 自检：确认 ffmpeg 原生内核能跑（结果打印在控制台）
  try {
    final s = await FFmpegKit.execute('-version');
    final rc = await s.getReturnCode();
    debugPrint(ReturnCode.isSuccess(rc) ? 'FFMPEG_VERSION_OK' : 'FFMPEG_EXEC_FAILED');
  } catch (e) {
    debugPrint('FFMPEG_INIT_FAILED: $e');
  }
  runApp(const VideoToGifApp());
}

/// 原生选视频通道（对应 MainActivity.kt 里的 pickChannelName）
const MethodChannel _pickChannel =
MethodChannel('com.example.video_to_gif/picker');

class VideoToGifApp extends StatelessWidget {
  const VideoToGifApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '短视频转GIF',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _videoPath;
  String? _previewPath;
  bool _videoReady = false;
  double _durationSec = 0;
  double _startSec = 0;
  double _endSec = 0;

  final TextEditingController _fpsCtrl = TextEditingController(text: '15');
  final TextEditingController _widthCtrl = TextEditingController(text: '480');
  bool _keepOriginalSize = false;
  bool _usePalette = true;

  bool _converting = false;
  double _progress = 0;
  String _statusText = '';
  String? _outputPath;
  String? _galleryResult;
  int? _actualFrames;
  int? _expectedFrames;

  @override
  void dispose() {
    _fpsCtrl.dispose();
    _widthCtrl.dispose();
    super.dispose();
  }

  // ================= 选择视频（原生 Intent）=================
  Future<void> _pickVideo() async {
    if (_converting) return;
    try {
      final String? path =
      await _pickChannel.invokeMethod<String>('pickVideo');
      if (path == null || path.isEmpty) return;

      setState(() {
        _videoPath = path;
        _videoReady = false;
        _previewPath = null;
        _outputPath = null;
        _galleryResult = null;
        _actualFrames = null;
        _expectedFrames = null;
        _statusText = '正在分析视频…';
      });

      final dur = await _getVideoDuration(path);
      final frame = await _extractFrame(path);

      setState(() {
        _previewPath = frame;
        _durationSec = dur;
        _startSec = 0;
        _endSec = dur;
        _videoReady = dur > 0;
        _statusText = '';
      });
    } catch (e) {
      _showSnack('加载视频失败：$e');
    }
  }

  Future<double> _getVideoDuration(String path) async {
    try {
      final session = await FFprobeKit.execute(
          '-v error -show_entries format=duration '
              '-of default=noprint_wrappers=1:nokey=1 "$path"');
      final output = (await session.getOutput() ?? '').trim();
      return double.tryParse(output) ?? 0;
    } catch (e) {
      debugPrint('获取时长失败: $e');
      return 0;
    }
  }

  Future<String?> _extractFrame(String path) async {
    try {
      final dir = await getTemporaryDirectory();
      final framePath =
          '${dir.path}/preview_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final session = await FFmpegKit.execute(
          '-y -i "$path" -vframes 1 -vf "scale=480:-2" -q:v 3 "$framePath"');
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc) && File(framePath).existsSync()) {
        return framePath;
      }
      return null;
    } catch (e) {
      debugPrint('抽帧失败: $e');
      return null;
    }
  }

  // ================= 转换 =================
  Future<void> _convert() async {
    if (_videoPath == null || !_videoReady) {
      _showSnack('请先选择视频');
      return;
    }
    final fps = int.tryParse(_fpsCtrl.text.trim());
    if (fps == null || fps < 1 || fps > 30) {
      _showSnack('FPS 必须是 1~30 的整数');
      return;
    }
    final width = int.tryParse(_widthCtrl.text.trim());
    if (!_keepOriginalSize && (width == null || width < 16 || width > 4096)) {
      _showSnack('分辨率宽度必须是 16~4096 的整数');
      return;
    }
    if (_endSec <= _startSec) {
      _showSnack('截取结束时间必须大于开始时间');
      return;
    }

    setState(() {
      _converting = true;
      _progress = 0;
      _statusText = '准备中…';
      _outputPath = null;
      _galleryResult = null;
      _actualFrames = null;
      _expectedFrames = null;
    });

    try {
      final baseDir = await getExternalStorageDirectory();
      if (baseDir == null) throw Exception('无法获取外部存储目录');
      final outDir = Directory('${baseDir.path}/gif_output');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${outDir.path}/gif_$stamp.gif';
      final palettePath = '${outDir.path}/palette_$stamp.png';

      bool ok;
      if (_usePalette) {
        ok = await _runCommand(
          _buildPaletteCommand(palettePath),
          label: '第一遍：生成调色板…',
        );
        if (ok) {
          setState(() => _progress = 0.45);
          ok = await _runCommand(
            _buildGifCommand(outputPath, palettePath),
            label: '第二遍：合成 GIF…',
          );
        }
        try {
          if (File(palettePath).existsSync()) File(palettePath).deleteSync();
        } catch (_) {}
      } else {
        ok = await _runCommand(
          _buildGifCommand(outputPath, null),
          label: '正在转换…',
        );
      }

      if (!ok) {
        _showSnack('转换失败，请查看日志');
        setState(() => _converting = false);
        return;
      }
      setState(() => _progress = 0.9);

      final actual = await _countFrames(outputPath);
      final expected = ((_endSec - _startSec) * fps).round();

      String? gallery;
      try {
        gallery = await GifSaver.saveToGallery(
          srcPath: outputPath,
          displayName: 'video_to_gif_$stamp.gif',
        );
      } catch (e) {
        gallery = null;
        debugPrint('保存到相册失败: $e');
      }

      setState(() {
        _converting = false;
        _progress = 1;
        _statusText = '完成';
        _outputPath = outputPath;
        _galleryResult = gallery;
        _actualFrames = actual;
        _expectedFrames = expected;
      });
    } catch (e) {
      setState(() => _converting = false);
      _showSnack('转换出错：$e');
    }
  }

  /// 执行一条 ffmpeg 命令（_new 同步 API，最稳定）
  Future<bool> _runCommand(String command, {required String label}) async {
    setState(() => _statusText = label);
    try {
      final session = await FFmpegKit.execute(command);
      final rc = await session.getReturnCode();
      final success = ReturnCode.isSuccess(rc);
      if (!success) {
        try {
          final logs = await session.getAllLogsAsString();
          debugPrint('FFmpeg 日志:\n$logs');
        } catch (_) {}
      }
      return success;
    } catch (e) {
      debugPrint('FFmpeg 执行异常: $e');
      return false;
    }
  }

  /// 最终 GIF 命令。palettePath 非空时走双通道调色板。
  /// 关键点：用 fps=N 过滤器控制帧率（真正生效），而不是 -r。
  String _buildGifCommand(String outputPath, String? palettePath) {
    final fps = int.parse(_fpsCtrl.text.trim());
    final width = int.tryParse(_widthCtrl.text.trim()) ?? 480;
    final ss = _fmtSec(_startSec);
    final t = _fmtSec(_endSec - _startSec);
    final scale = _keepOriginalSize ? '' : ',scale=$width:-2:flags=lanczos';

    if (palettePath != null) {
      return '-y -ss $ss -i "${_videoPath}" -i "$palettePath" -t $t -an '
          '-filter_complex "fps=$fps$scale[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" '
          '-loop 0 "$outputPath"';
    }
    return '-y -ss $ss -i "${_videoPath}" -t $t -an '
        '-vf "fps=$fps$scale" -loop 0 "$outputPath"';
  }

  /// 第一遍：生成调色板图片
  String _buildPaletteCommand(String palettePath) {
    final fps = int.parse(_fpsCtrl.text.trim());
    final width = int.tryParse(_widthCtrl.text.trim()) ?? 480;
    final ss = _fmtSec(_startSec);
    final t = _fmtSec(_endSec - _startSec);
    final scale = _keepOriginalSize ? '' : ',scale=$width:-2:flags=lanczos';
    return '-y -ss $ss -i "${_videoPath}" -t $t -an '
        '-vf "fps=$fps$scale,palettegen=max_colors=256" "$palettePath"';
  }

  /// ffprobe 数出 GIF 实际帧数，用于验证 FPS 是否生效
  Future<int> _countFrames(String path) async {
    try {
      final session = await FFprobeKit.execute(
        '-v error -count_frames -select_streams v:0 '
            '-show_entries stream=nb_read_frames '
            '-of default=noprint_wrappers=1:nokey=1 "$path"',
      );
      final output = await session.getOutput() ?? '';
      final m = RegExp(r'\d+').firstMatch(output);
      return m == null ? 0 : int.parse(m.group(0)!);
    } catch (e) {
      debugPrint('统计帧数失败: $e');
      return 0;
    }
  }

  // ================= 工具函数 =================
  String _fmtSec(double s) => s.toStringAsFixed(2);

  String _fmtClock(double seconds) {
    final d = Duration(milliseconds: (seconds * 1000).round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final ms = d.inMilliseconds.remainder(1000) ~/ 100;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.$ms';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.$ms';
  }

  String? get _outputSizeText {
    if (!_videoReady || _videoPath == null) return null;
    if (_keepOriginalSize) return '保持原分辨率';
    final w = int.tryParse(_widthCtrl.text.trim()) ?? 0;
    if (w <= 0) return null;
    return '$w px 宽（高度自动等比）';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('短视频转GIF'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _videoCard(),
          const SizedBox(height: 16),
          _trimCard(),
          const SizedBox(height: 16),
          _paramsCard(),
          const SizedBox(height: 16),
          _convertCard(),
          if (_outputPath != null) ...[const SizedBox(height: 16), _resultCard()],
        ],
      ),
    );
  }

  Widget _videoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.video_library, color: Colors.deepPurple),
                const SizedBox(width: 8),
                const Text('① 选择视频',
                    style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _converting ? null : _pickVideo,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('从相册选择'),
                ),
              ],
            ),
            if (_videoPath != null) ...[
              const SizedBox(height: 8),
              Text('已选：${_videoPath!.split('/').last}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
            ],
            if (_previewPath != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(_previewPath!),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    height: 100,
                    child: Center(child: Text('预览生成失败')),
                  ),
                ),
              ),
            ],
            if (_videoReady) ...[
              const SizedBox(height: 4),
              Text('总时长 ${_fmtClock(_durationSec)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _trimCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('② 截取片段',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (!_videoReady || _durationSec <= 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('请先选择视频', style: TextStyle(color: Colors.grey)),
              )
            else ...[
              const SizedBox(height: 12),
              RangeSlider(
                min: 0,
                max: _durationSec,
                values: RangeValues(_startSec, _endSec),
                divisions: max(1, (_durationSec * 10).round()),
                labels: RangeLabels(_fmtClock(_startSec), _fmtClock(_endSec)),
                onChanged: (v) {
                  setState(() {
                    _startSec = v.start;
                    _endSec = v.end;
                  });
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('开始 ${_fmtClock(_startSec)}'),
                  Text('结束 ${_fmtClock(_endSec)}'),
                ],
              ),
              const SizedBox(height: 8),
              Text('片段时长 ${_fmtClock(_endSec - _startSec)}',
                  style: const TextStyle(
                      color: Colors.deepPurple, fontWeight: FontWeight.bold)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _paramsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('③ 输出参数',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _fpsCtrl,
                    enabled: !_converting,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'GIF 帧率 (FPS)',
                      helperText: '范围 1~30，越小文件越小',
                      border: OutlineInputBorder(),
                      suffixText: 'fps',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _widthCtrl,
                    enabled: !_converting && !_keepOriginalSize,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '输出宽度 (px)',
                      helperText: '高度自动等比',
                      border: OutlineInputBorder(),
                      suffixText: 'px',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_outputSizeText != null)
              Text('输出分辨率：$_outputSizeText',
                  style: const TextStyle(fontSize: 13)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('保持原分辨率（不缩放）'),
              value: _keepOriginalSize,
              onChanged: _converting
                  ? null
                  : (v) => setState(() => _keepOriginalSize = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('高质量（双通道调色板）'),
              subtitle: const Text('颜色更细腻，转换时间约为 2 倍'),
              value: _usePalette,
              onChanged:
              _converting ? null : (v) => setState(() => _usePalette = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _convertCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('④ 开始转换',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_converting)
                  TextButton(
                      onPressed: () => FFmpegKit.cancel(),
                      child: const Text('取消'))
                else
                  FilledButton.icon(
                    onPressed: _videoReady ? _convert : null,
                    icon: const Icon(Icons.auto_awesome_motion),
                    label: const Text('转为 GIF'),
                  ),
              ],
            ),
            if (_converting) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                  value: _progress,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 8),
              Text('$_statusText'),
            ],
            const SizedBox(height: 4),
            const Text('全程本地 ffmpeg 处理，不上传网络',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _resultCard() {
    final fpsOk = _actualFrames != null &&
        _expectedFrames != null &&
        (_actualFrames! >= _expectedFrames! - 2 &&
            _actualFrames! <= _expectedFrames! + 2);
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text('转换完成',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.green)),
            ]),
            const SizedBox(height: 12),
            if (_actualFrames != null && _expectedFrames != null) ...[
              Text('实际输出帧数：$_actualFrames 帧（预期 $_expectedFrames 帧'
                  ' = 时长 ${_fmtClock(_endSec - _startSec)} × ${_fpsCtrl.text}fps）'),
              const SizedBox(height: 4),
              Text(
                fpsOk
                    ? '✓ FPS 参数已生效，帧数与设定一致'
                    : '帧数与理论值有偏差，可尝试关闭“高质量”模式',
                style: TextStyle(
                    color:
                    fpsOk ? Colors.green.shade800 : Colors.orange.shade800),
              ),
              const SizedBox(height: 8),
            ],
            Text('本地文件：$_outputPath',
                style: const TextStyle(fontSize: 12)),
            if (_galleryResult != null) ...[
              const SizedBox(height: 4),
              Text('相册：$_galleryResult',
                  style: const TextStyle(fontSize: 12)),
            ] else ...[
              const SizedBox(height: 4),
              const Text('相册：未写入（可在文件管理器中打开上述路径）',
                  style: TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 8),
            Row(children: [
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _outputPath ?? ''));
                  _showSnack('路径已复制');
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制路径'),
              ),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _outputPath = null;
                    _galleryResult = null;
                    _actualFrames = null;
                    _expectedFrames = null;
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('再转一个'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
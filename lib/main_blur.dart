import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_gpux/flutter_gpux.dart';
import 'package:image/image.dart' as img;

const _sizes = [512, 1024, 2048, 4096];

void main() => runApp(const BlurBenchmarkApp());

class BlurBenchmarkApp extends StatelessWidget {
  const BlurBenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const BlurBenchmarkPage(),
      );
}

class BlurBenchmarkPage extends StatefulWidget {
  const BlurBenchmarkPage({super.key});

  @override
  State<BlurBenchmarkPage> createState() => _BlurBenchmarkPageState();
}

class _BlurBenchmarkPageState extends State<BlurBenchmarkPage> {
  final _repaint = ValueNotifier<int>(0);
  BlurRenderer? _renderer;
  GpuDevice? _device;
  int _size = 2048;
  Uint8List? _imageData;
  int _radius = 20;
  double? _cpuMs;
  double? _gpuMs;
  ui.Image? _cpuResultImage;
  ui.Image? _sourceUiImage;
  bool _cpuRunning = false;
  bool _gpuReady = false;

  @override
  void initState() {
    super.initState();
    _rebuildImage();
  }

  @override
  void dispose() {
    _repaint.dispose();
    _renderer?.dispose();
    super.dispose();
  }

  void _rebuildImage() {
    _imageData = _generateImage(_size);
    _cpuMs = null;
    _gpuMs = null;
    _cpuResultImage = null;
    _toUiImage(_imageData!).then((i) {
      if (mounted) setState(() => _sourceUiImage = i);
    });
    if (_device != null) _initGpu(_device!);
  }

  void _initGpu(GpuDevice device) {
    _device = device;
    _renderer?.dispose();
    _renderer = BlurRenderer(repaint: _repaint)
      ..init(device, _imageData!, _size);
    WidgetsBinding.instance.addPostFrameCallback((_) => _repaint.value++);
  }

  Future<ui.Image> _toUiImage(Uint8List rgba) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba, _size, _size, ui.PixelFormat.rgba8888, c.complete,
    );
    return c.future;
  }

  void _onSizeChanged(int size) {
    setState(() {
      _size = size;
      _gpuReady = false;
    });
    _rebuildImage();
    if (_device != null) {
      _gpuReady = true;
      setState(() {});
    }
  }

  Future<void> _onRadiusChanged(double value) async {
    final r = value.round();
    setState(() => _radius = r);
    if (_renderer == null) return;
    _gpuMs = await _renderer!.computeBlur(r);
    _repaint.value++;
    if (mounted) setState(() {});
  }

  Future<void> _runCpuBlur() async {
    setState(() => _cpuRunning = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final sw = Stopwatch()..start();
    final src = img.Image.fromBytes(
      width: _size,
      height: _size,
      bytes: Uint8List.fromList(_imageData!).buffer,
      numChannels: 4,
    );
    final blurred = img.gaussianBlur(src, radius: _radius);
    final ms = sw.elapsedMicroseconds / 1000.0;
    final result = await _toUiImage(blurred.toUint8List());
    if (!mounted) return;
    setState(() {
      _cpuMs = ms;
      _cpuResultImage = result;
      _cpuRunning = false;
    });
  }

  @override
  Widget build(BuildContext context) => DefaultGpu(
        child: Scaffold(
          backgroundColor: const Color(0xFF12121a),
          body: Builder(builder: (ctx) {
            final gpu = DefaultGpu.maybeOf(ctx);
            if (gpu != null && gpu.isInitialized && !_gpuReady) {
              _gpuReady = true;
              _initGpu(gpu.device);
            }
            return SafeArea(
              child: Column(children: [
                const SizedBox(height: 12),
                Text('Gaussian Blur  ${_size}x$_size',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                _timingRow(),
                const SizedBox(height: 4),
                Expanded(child: _resultRow()),
                _controls(),
              ]),
            );
          }),
        ),
      );

  Widget _timingRow() {
    final speedup = (_cpuMs != null && _gpuMs != null && _gpuMs! > 0)
        ? (_cpuMs! / _gpuMs!).toStringAsFixed(0)
        : null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _timing('CPU', _cpuMs, Colors.redAccent),
        if (speedup != null)
          Text('${speedup}x faster',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.greenAccent,
              )),
        _timing('GPU', _gpuMs, Colors.cyanAccent),
      ],
    );
  }

  Widget _timing(String label, double? ms, Color color) => Column(children: [
        Text(label, style: TextStyle(fontSize: 12, color: color)),
        Text(ms != null ? '${ms.toStringAsFixed(1)} ms' : '--',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
      ]);

  Widget _resultRow() => Row(children: [
        Expanded(
            child: _resultPanel(
          'CPU (image pkg)',
          child: _cpuResultImage != null
              ? RawImage(image: _cpuResultImage, fit: BoxFit.contain)
              : _sourceUiImage != null
                  ? RawImage(image: _sourceUiImage, fit: BoxFit.contain)
                  : const CircularProgressIndicator(),
        )),
        const VerticalDivider(width: 1),
        Expanded(
            child: _resultPanel(
          'GPU (compute shader)',
          child: _renderer != null
              ? GpuView(
                    key: ValueKey(_renderer),
                    renderer: _renderer!,
                  )
              : const CircularProgressIndicator(),
        )),
      ]);

  Widget _resultPanel(String label, {required Widget child}) =>
      Column(children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Expanded(
          child: Center(
            child: AspectRatio(aspectRatio: 1, child: child),
          ),
        ),
      ]);

  Widget _controls() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(children: [
          Row(children: [
            const Text('Size'),
            const SizedBox(width: 8),
            SegmentedButton<int>(
              segments: [
                for (final s in _sizes)
                  ButtonSegment(value: s, label: Text('$s')),
              ],
              selected: {_size},
              onSelectionChanged: (v) => _onSizeChanged(v.first),
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Text('Radius'),
            Expanded(
              child: Slider(
                value: _radius.toDouble(),
                min: 1,
                max: 50,
                divisions: 49,
                label: '$_radius',
                onChanged: _gpuReady ? _onRadiusChanged : null,
              ),
            ),
            SizedBox(width: 32, child: Text('$_radius')),
          ]),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _cpuRunning ? null : _runCpuBlur,
              child: Text(_cpuRunning
                  ? 'CPU processing...'
                  : 'Run CPU Blur (radius $_radius)'),
            ),
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Image generation
// ---------------------------------------------------------------------------

Uint8List _generateImage(int size) {
  final data = Uint8List(size * size * 4);
  final rng = Random(42);
  // Set alpha to 255
  for (var i = 3; i < data.length; i += 4) {
    data[i] = 255;
  }
  // Bright circles on dark background
  for (var c = 0; c < 500; c++) {
    final cx = rng.nextInt(size), cy = rng.nextInt(size);
    final cr = rng.nextInt(80) + 5;
    final r = 128 + rng.nextInt(128);
    final g = 128 + rng.nextInt(128);
    final b = 128 + rng.nextInt(128);
    final cr2 = cr * cr;
    final y0 = max(0, cy - cr), y1 = min(size - 1, cy + cr);
    final x0 = max(0, cx - cr), x1 = min(size - 1, cx + cr);
    for (var y = y0; y <= y1; y++) {
      final dy = y - cy;
      for (var x = x0; x <= x1; x++) {
        final dx = x - cx;
        if (dx * dx + dy * dy > cr2) continue;
        final i = (y * size + x) * 4;
        data[i] = r;
        data[i + 1] = g;
        data[i + 2] = b;
      }
    }
  }
  return data;
}

// ---------------------------------------------------------------------------
// WGSL shaders
// ---------------------------------------------------------------------------

const _blurWgsl = '''
struct Params {
  radius: i32,
  width: i32,
  height: i32,
  horizontal: u32,
}

@group(0) @binding(0) var inputTex: texture_2d<f32>;
@group(0) @binding(1) var outputTex: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var<uniform> params: Params;

// Reflect edge handling (matches image package)
fn reflect(maxVal: i32, x: i32) -> i32 {
  if (x < 0) { return -x; }
  if (x >= maxVal) { return maxVal - (x - maxVal) - 1; }
  return x;
}

@compute @workgroup_size(16, 16)
fn blur(@builtin(global_invocation_id) gid: vec3u) {
  let x = i32(gid.x);
  let y = i32(gid.y);
  if (x >= params.width || y >= params.height) { return; }

  let r = params.radius;
  // sigma = radius * (2/3), matching image package
  let sigma = f32(r) * 0.6666667;
  let s = 2.0 * sigma * sigma;

  var sum = vec4f(0.0);
  var wsum = 0.0;

  for (var i = -r; i <= r; i++) {
    var sx = x;
    var sy = y;
    if (params.horizontal != 0u) {
      sx = reflect(params.width, x + i);
    } else {
      sy = reflect(params.height, y + i);
    }
    let w = exp(-f32(i * i) / s);
    sum += textureLoad(inputTex, vec2u(u32(sx), u32(sy)), 0) * w;
    wsum += w;
  }

  textureStore(outputTex, gid.xy, sum / wsum);
}
''';

const _quadWgsl = '''
struct VsOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
}

@vertex fn vs(@builtin(vertex_index) vi: u32) -> VsOut {
  let uv = vec2f(f32((vi << 1u) & 2u), f32(vi & 2u));
  return VsOut(vec4f(uv * 2.0 - 1.0, 0.0, 1.0), vec2f(uv.x, 1.0 - uv.y));
}

@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

@fragment fn fs(in: VsOut) -> @location(0) vec4f {
  return textureSample(tex, samp, in.uv);
}
''';

// ---------------------------------------------------------------------------
// GPU blur renderer
// ---------------------------------------------------------------------------

class BlurRenderer extends GpuRenderer {
  BlurRenderer({required super.repaint});

  GpuDevice? _device;
  int _texSize = 0;

  GpuTexture? _sourceTex;
  GpuTexture? _tempTex;
  GpuTexture? _outputTex;
  GpuTextureView? _sourceView;
  GpuTextureView? _outputView;

  GpuComputePipeline? _computePipeline;
  GpuBuffer? _hParams;
  GpuBuffer? _vParams;
  GpuBindGroup? _hBindGroup;
  GpuBindGroup? _vBindGroup;

  GpuRenderPipeline? _renderPipeline;
  GpuSampler? _sampler;
  GpuBindGroup? _quadBindGroup;
  GpuTextureView? _displayView;

  bool _ready = false;

  void init(GpuDevice device, Uint8List imageData, int size) {
    _device = device;
    _texSize = size;

    _sourceTex = device.createTexture(
      width: size,
      height: size,
      format: GpuTextureFormat.rgba8Unorm,
      usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
    );
    device.queue.writeTexture(
      texture: _sourceTex!,
      data: imageData,
      bytesPerRow: size * 4,
      width: size,
      height: size,
    );
    _sourceView = _sourceTex!.createView();

    _tempTex = device.createTexture(
      width: size,
      height: size,
      format: GpuTextureFormat.rgba8Unorm,
      usage: GpuTextureUsage.textureBinding | GpuTextureUsage.storageBinding,
    );

    _outputTex = device.createTexture(
      width: size,
      height: size,
      format: GpuTextureFormat.rgba8Unorm,
      usage: GpuTextureUsage.textureBinding | GpuTextureUsage.storageBinding,
    );
    _outputView = _outputTex!.createView();

    _hParams = device.createBuffer(
      size: 16,
      usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
    );
    _vParams = device.createBuffer(
      size: 16,
      usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
    );

    final shader = device.createShaderModule(_blurWgsl);
    _computePipeline = device.createComputePipeline(
      module: shader,
      entryPoint: 'blur',
      layout: null,
    );

    final layout = _computePipeline!.getBindGroupLayout(0);

    _hBindGroup = device.createBindGroup(
      layout: layout,
      entries: [
        GpuBindGroupEntry.textureView(binding: 0, view: _sourceView!),
        GpuBindGroupEntry.textureView(
            binding: 1, view: _tempTex!.createView()),
        GpuBindGroupEntry.buffer(binding: 2, buffer: _hParams!),
      ],
    );

    _vBindGroup = device.createBindGroup(
      layout: layout,
      entries: [
        GpuBindGroupEntry.textureView(
            binding: 0, view: _tempTex!.createView()),
        GpuBindGroupEntry.textureView(binding: 1, view: _outputView!),
        GpuBindGroupEntry.buffer(binding: 2, buffer: _vParams!),
      ],
    );

    _sampler = device.createSampler(
      magFilter: GpuFilterMode.linear,
      minFilter: GpuFilterMode.linear,
    );

    _displayView = _sourceView;
    _ready = true;
  }

  Future<double> computeBlur(int radius) async {
    final d = _device!;
    final s = _texSize;
    final wg = (s + 15) ~/ 16;

    final hp = Int32List(4)..[0] = radius..[1] = s..[2] = s..[3] = 1;
    d.queue.writeBuffer(_hParams!, hp.buffer.asUint8List());

    final vp = Int32List(4)..[0] = radius..[1] = s..[2] = s..[3] = 0;
    d.queue.writeBuffer(_vParams!, vp.buffer.asUint8List());

    final sw = Stopwatch()..start();
    final enc = d.createCommandEncoder();

    final pass1 = enc.beginComputePass();
    pass1.setPipeline(_computePipeline!);
    pass1.setBindGroup(0, _hBindGroup!);
    pass1.dispatchWorkgroups(wg, wg, 1);
    pass1.end();

    final pass2 = enc.beginComputePass();
    pass2.setPipeline(_computePipeline!);
    pass2.setBindGroup(0, _vBindGroup!);
    pass2.dispatchWorkgroups(wg, wg, 1);
    pass2.end();

    d.queue.submit([enc.finish()]);
    await d.queue.onSubmittedWorkDone();

    _displayView = _outputView;
    _quadBindGroup = null;
    return sw.elapsedMicroseconds / 1000.0;
  }

  @override
  bool render(GpuFrame frame) {
    if (!_ready) return false;

    if (_renderPipeline == null) {
      final shader = frame.device.createShaderModule(_quadWgsl);
      _renderPipeline = frame.device.createRenderPipeline(
        GpuRenderPipelineDescriptor(
          vertexModule: shader,
          vertexEntryPoint: 'vs',
          fragmentModule: shader,
          fragmentEntryPoint: 'fs',
          colorTargets: [GpuColorTargetState(format: frame.format)],
          layout: null,
        ),
      );
    }

    _quadBindGroup ??= frame.device.createBindGroup(
      layout: _renderPipeline!.getBindGroupLayout(0),
      entries: [
        GpuBindGroupEntry.textureView(binding: 0, view: _displayView!),
        GpuBindGroupEntry.sampler(binding: 1, sampler: _sampler!),
      ],
    );

    final enc = frame.device.createCommandEncoder();
    final pass = enc.beginRenderPass(
      colorAttachments: [
        GpuColorAttachment(
          view: frame.targetView,
          loadOp: GpuLoadOp.clear,
          storeOp: GpuStoreOp.store,
          clearValue: const GpuColor(0.07, 0.07, 0.1, 1),
        ),
      ],
    );
    pass.setPipeline(_renderPipeline!);
    pass.setBindGroup(0, _quadBindGroup!);
    pass.draw(vertexCount: 3);
    pass.end();
    frame.device.queue.submit([enc.finish()]);
    return true;
  }

  @override
  bool shouldUpdate(covariant BlurRenderer oldRenderer) => false;

  @override
  void dispose() {
    _sourceTex?.destroy();
    _tempTex?.destroy();
    _outputTex?.destroy();
    _hParams?.destroy();
    _vParams?.destroy();
    super.dispose();
  }
}

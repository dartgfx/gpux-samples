import 'dart:typed_data';
import 'dart:ui' as ui show ImageByteFormat, instantiateImageCodec;

import 'package:flutter/material.dart' hide Color, Texture;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gpux/flutter_gpux.dart';
import 'package:gltfx/gltfx.dart';
import 'package:gm/gm.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: const Demo(),
  );
}

class Demo extends StatefulWidget {
  const Demo({super.key});
  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> with SingleTickerProviderStateMixin {
  GpuController? _gpu;
  Renderer? _renderer;
  Object? _gpuError;
  late final AnimationController _loop;

  @override
  void initState() {
    super.initState();
    _loop = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _initGpu();
  }

  Future<void> _initGpu() async {
    final gpu = GpuController();
    try {
      await gpu.initialize();
      if (!mounted) {
        gpu.dispose();
        return;
      }
      setState(() => _gpu = gpu);
      await _initScene(gpu.device);
    } catch (error) {
      gpu.dispose();
      if (!mounted) return;
      setState(() => _gpuError = error);
    }
  }

  Future<void> _initScene(GpuDevice device) async {
    final meshes = await _loadGlb('assets/models/DamagedHelmet.glb', device);
    if (!mounted) return;
    final r = Renderer(repaint: _loop);
    r.meshes.addAll(meshes);
    for (final m in meshes) {
      r.baseMats.add(m.worldMatrix);
    }
    setState(() => _renderer = r);
  }

  @override
  void dispose() {
    _loop.dispose();
    _renderer?.dispose();
    _gpu?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: _gpuError != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'GPU initialization failed:\n$_gpuError',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          )
        : _renderer != null
        ? GpuView(controller: _gpu, renderer: _renderer!)
        : const Center(child: CircularProgressIndicator()),
  );
}

class Color {
  const Color(this.value);
  factory Color.fromARGB(int a, int r, int g, int b) =>
      Color((a << 24) | (r << 16) | (g << 8) | b);
  final int value;
  double get a => ((value >> 24) & 0xFF) / 255.0;
  double get r => ((value >> 16) & 0xFF) / 255.0;
  double get g => ((value >> 8) & 0xFF) / 255.0;
  double get b => (value & 0xFF) / 255.0;
}

class GpuTex {
  GpuTex(this.gpuTexture, this.view);
  final GpuTexture gpuTexture;
  final GpuTextureView view;
  void dispose() => gpuTexture.destroy();
}

class Material {
  Material({
    this.color = const Color(0xFFFFFFFF),
    this.roughness = 0.5,
    this.metallic = 0.0,
    this.emissiveColor = const Color(0xFF000000),
  });
  Color color;
  double roughness;
  double metallic;
  Color emissiveColor;
  GpuTex? map;
  GpuTex? normalMap;
  GpuTex? metallicRoughnessMap;
  GpuTex? emissiveMap;
}

class MeshData {
  MeshData(this.vb, this.ib, this.indexCount, this.material);
  final GpuBuffer vb;
  final GpuBuffer ib;
  final int indexCount;
  final Material material;
  mat4 worldMatrix = mat4.identity;
}

class Camera {
  Camera({this.fov = 60, this.aspect = 1.0, this.near = 0.1, this.far = 1000});
  double fov, aspect, near, far;
  vec3 position = vec3.zero;
  quat rotation = quat.identity;

  void lookAt(vec3 target) {
    var fwd = (target - position);
    if (fwd.lengthSquared < 1e-10) return;
    fwd = fwd.normalized;
    var right = cross(fwd, vec3.unitY);
    if (right.lengthSquared < 1e-10) right = vec3.unitX;
    right = right.normalized;
    rotation = quat.fromMat3(mat3(right, cross(right, fwd), -fwd));
  }

  mat4 get viewProjection =>
      mat4.perspective(
        fovY: fov * 3.14159265 / 180,
        aspect: aspect,
        near: near,
        far: far,
      ) *
      mat4.trs(position, rotation, vec3.one).inversed;
}

Set<int> _srgbImages(GltfDocument doc) {
  final s = <int>{};
  for (final m in doc.materials.items) {
    if (m.pbrMetallicRoughness?.baseColorTexture case final t?) {
      if (doc.textures[t.index].source case final i?) s.add(i.value);
    }
    if (m.emissiveTexture case final t?) {
      if (doc.textures[t.index].source case final i?) s.add(i.value);
    }
  }
  return s;
}

Material _parseMaterial(GltfMaterial m) {
  final pbr = m.pbrMetallicRoughness;
  final bcf = pbr?.baseColorFactor;
  final ef = m.emissiveFactor;
  return Material(
    color: bcf != null
        ? Color.fromARGB(
            (bcf[3] * 255).round(),
            (bcf[0] * 255).round(),
            (bcf[1] * 255).round(),
            (bcf[2] * 255).round(),
          )
        : const Color(0xFFFFFFFF),
    roughness: pbr?.roughnessFactor ?? 1.0,
    metallic: pbr?.metallicFactor ?? 1.0,
    emissiveColor: ef != null
        ? Color.fromARGB(
            255,
            (ef[0] * 255).round(),
            (ef[1] * 255).round(),
            (ef[2] * 255).round(),
          )
        : const Color(0xFF000000),
  );
}

Future<List<MeshData>> _loadGlb(String asset, GpuDevice device) async {
  final doc = Glb.parse((await rootBundle.load(asset)).buffer.asUint8List());
  final srgb = _srgbImages(doc);
  final bindings = <int, List<void Function(GpuTex)>>{};

  // Parse materials
  final mats = <int, Material>{};
  for (var i = 0; i < doc.materials.items.length; i++) {
    final gm = doc.materials.items[i];
    final m = mats[i] = _parseMaterial(gm);
    void bind(TextureIdx? ti, void Function(GpuTex) set) {
      if (ti == null) return;
      if (doc.textures[ti].source case final s?) {
        (bindings[s.value] ??= []).add(set);
      }
    }

    final pbr = gm.pbrMetallicRoughness;
    if (pbr != null) {
      bind(pbr.baseColorTexture?.index, (v) => m.map = v);
      bind(
        pbr.metallicRoughnessTexture?.index,
        (v) => m.metallicRoughnessMap = v,
      );
    }
    bind(gm.normalTexture?.index, (v) => m.normalMap = v);
    bind(gm.emissiveTexture?.index, (v) => m.emissiveMap = v);
  }

  // Walk scene tree, extract meshes with world matrices
  final meshes = <MeshData>[];
  void visit(NodeIdx ni, mat4 parent) {
    final node = doc.nodes[ni];
    final local = switch (node.transform) {
      TrsTransform(:final translation, :final rotation, :final scale) =>
        mat4.trs(
          translation != null
              ? vec3(translation[0], translation[1], translation[2])
              : vec3.zero,
          rotation != null
              ? quat(rotation[0], rotation[1], rotation[2], rotation[3])
              : quat.identity,
          scale != null ? vec3(scale[0], scale[1], scale[2]) : vec3.one,
        ),
      MatrixTransform(:final matrix) => mat4.fromColsArray(matrix),
    };
    final world = parent * local;

    if (node.mesh case final mi?) {
      for (final prim in doc.meshes[mi].primitives) {
        if (prim.mode is! Triangles) continue;
        final pos = prim.getPositions(doc);
        if (pos == null) continue;
        final n = prim.getNormals(doc);
        final uv = prim.getTexCoord0(doc);
        final tan = prim.getTangents(doc);
        final idx = prim.getIndicesAsUint32(doc);
        final vc = pos.length ~/ 3;

        // Interleave [pos.xyz, normal.xyz, uv.xy, tangent.xyzw]
        final buf = Float32List(vc * 12);
        for (var i = 0; i < vc; i++) {
          final d = i * 12;
          final p = i * 3;
          final u = i * 2;
          final t = i * 4;
          buf[d] = pos[p];
          buf[d + 1] = pos[p + 1];
          buf[d + 2] = pos[p + 2];
          buf[d + 3] = n != null ? n[p] : 0;
          buf[d + 4] = n != null ? n[p + 1] : 0;
          buf[d + 5] = n != null ? n[p + 2] : 1;
          buf[d + 6] = uv != null ? uv[u] : 0;
          buf[d + 7] = uv != null ? uv[u + 1] : 0;
          buf[d + 8] = tan != null ? tan[t] : 0;
          buf[d + 9] = tan != null ? tan[t + 1] : 0;
          buf[d + 10] = tan != null ? tan[t + 2] : 0;
          buf[d + 11] = tan != null ? tan[t + 3] : 0;
        }

        final vb = device.createBuffer(
          size: buf.lengthInBytes,
          usage: GpuBufferUsage.vertex | GpuBufferUsage.copyDst,
        );
        device.queue.writeBuffer(
          vb,
          buf.buffer.asUint8List(buf.offsetInBytes, buf.lengthInBytes),
        );
        GpuBuffer? ib;
        if (idx != null) {
          ib = device.createBuffer(
            size: idx.lengthInBytes,
            usage: GpuBufferUsage.index | GpuBufferUsage.copyDst,
          );
          device.queue.writeBuffer(
            ib,
            idx.buffer.asUint8List(idx.offsetInBytes, idx.lengthInBytes),
          );
        }

        final mat =
            (prim.material != null ? mats[prim.material!.value] : null) ??
            Material();
        meshes.add(MeshData(vb, ib!, idx!.length, mat)..worldMatrix = world);
      }
    }
    for (final c in node.children) {
      visit(c, world);
    }
  }

  final scene = doc.defaultScene;
  if (scene != null) {
    for (final ni in scene.nodes) {
      visit(ni, mat4.identity);
    }
  }

  // Decode and upload textures
  for (var i = 0; i < doc.images.items.length; i++) {
    final bytes = doc.imageData[ImageIdx(i)];
    if (bytes == null) continue;
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final w = img.width, h = img.height;
    img.dispose();
    codec.dispose();
    final fmt = srgb.contains(i)
        ? GpuTextureFormat.rgba8UnormSrgb
        : GpuTextureFormat.rgba8Unorm;
    final tex = device.createTexture(
      width: w,
      height: h,
      format: fmt,
      usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
    );
    device.queue.writeTexture(
      texture: tex,
      data: bd!.buffer.asUint8List(),
      bytesPerRow: w * 4,
      width: w,
      height: h,
    );
    final gpuTex = GpuTex(tex, tex.createView());
    if (bindings[i] case final setters?) {
      for (final s in setters) {
        s(gpuTex);
      }
    }
  }

  return meshes;
}

const _wgsl = r'''
const pi: f32 = 3.14159265359;
struct Camera { viewProjection: mat4x4<f32>, eyePos: vec3<f32> }
struct Model { worldMatrix: mat4x4<f32>, color: vec4<f32>, emissive: vec4<f32>, roughnessMetallic: vec2<f32> }
struct VsOut { @builtin(position) position: vec4<f32>, @location(0) worldPos: vec3<f32>, @location(1) worldNormal: vec3<f32>, @location(2) uv: vec2<f32>, @location(3) worldTangent: vec4<f32> }

@group(0) @binding(0) var<uniform> camera: Camera;
@group(1) @binding(0) var<uniform> model: Model;
@group(1) @binding(1) var baseTexture: texture_2d<f32>;
@group(1) @binding(2) var baseSampler: sampler;
@group(1) @binding(3) var normalMap: texture_2d<f32>;
@group(1) @binding(4) var mrMap: texture_2d<f32>;
@group(1) @binding(5) var emissiveMap: texture_2d<f32>;

@vertex fn vs(@location(0) pos: vec3f, @location(1) norm: vec3f, @location(2) uv: vec2f, @location(3) tan: vec4f) -> VsOut {
  let wp = model.worldMatrix * vec4(pos, 1.0);
  return VsOut(camera.viewProjection * wp, wp.xyz, normalize((model.worldMatrix * vec4(norm, 0.0)).xyz), uv,
    vec4((model.worldMatrix * vec4(tan.xyz, 0.0)).xyz, tan.w));
}

fn D_GGX(r: f32, NoH: f32) -> f32 { let a = NoH*r; let k = r/(1.0-NoH*NoH+a*a); return k*k*(1.0/pi); }
fn V_Smith(r: f32, NoV: f32, NoL: f32) -> f32 { let a2=r*r; return 0.5/max(NoL*sqrt((NoV-a2*NoV)*NoV+a2)+NoV*sqrt((NoL-a2*NoL)*NoL+a2),0.0001); }
fn pow5(x: f32) -> f32 { let x2=x*x; return x2*x2*x; }
fn F_Schlick(f0: vec3f, f90: f32, VoH: f32) -> vec3f { return f0+(vec3(f90)-f0)*pow5(1.0-VoH); }

fn shade(n: vec3f, v: vec3f, noV: f32, f0: vec3f, f90: f32, diff: vec3f, r2: f32, l: vec3f, lc: vec3f) -> vec3f {
  let h=normalize(v+l); let noL=saturate(dot(n,l)); let noH=saturate(dot(n,h)); let loH=saturate(dot(l,h));
  return (diff*(1.0/pi) + F_Schlick(f0,f90,loH)*(D_GGX(r2,noH)*V_Smith(r2,noV,noL))) * noL * lc;
}

@fragment fn fs(in: VsOut) -> @location(0) vec4f {
  let tc = textureSample(baseTexture, baseSampler, in.uv);
  let albedo = tc.rgb * model.color.rgb;
  let mr = textureSample(mrMap, baseSampler, in.uv);
  let rough = clamp(model.roughnessMetallic.x * mr.g, 0.04, 1.0);
  let metal = model.roughnessMetallic.y * mr.b;
  let r2 = rough*rough;
  let f0 = mix(vec3(0.04), albedo, metal);
  let f90 = saturate(dot(f0, vec3(50.0*0.33)));
  let diff = albedo * (1.0 - metal);

  var n = normalize(in.worldNormal);
  let ns = textureSample(normalMap, baseSampler, in.uv).rg;
  if (in.worldTangent.w != 0.0) {
    let t = normalize(in.worldTangent.xyz); let b = cross(n,t)*in.worldTangent.w;
    let xy = ns*2.0-vec2(1.0); n = normalize(t*xy.x + b*xy.y + n*sqrt(max(1.0-dot(xy,xy),0.0)));
  }
  let v = normalize(camera.eyePos - in.worldPos);
  let noV = max(dot(n,v), 0.0001);

  var c = shade(n,v,noV,f0,f90,diff,r2, normalize(vec3(1,2,1)), vec3(3,2.9,2.7))
        + shade(n,v,noV,f0,f90,diff,r2, normalize(vec3(-1,0.5,-0.5)), vec3(1,1.1,1.3))
        + shade(n,v,noV,f0,f90,diff,r2, normalize(vec3(0,-0.5,1)), vec3(0.5,0.5,0.6));
  c += diff * 0.5;
  let rd = reflect(-v,n); let sky = saturate(rd.y*0.5+0.5);
  c += f0 * mix(vec3(0.15,0.13,0.1), vec3(0.5,0.55,0.65), sky) * mix(1.0,0.3,r2) * 2.0;
  c += f0 * 0.15 * metal + vec3(0.2,0.25,0.3) * pow5(1.0-noV);
  c += model.emissive.rgb * textureSample(emissiveMap, baseSampler, in.uv).rgb;
  c = c*(c+vec3(0.024))/(c*(0.98*c+vec3(0.29))+vec3(0.14));
  return vec4(c, tc.a * model.color.a);
}
''';

class Renderer extends GpuRenderer {
  Renderer({required super.repaint});

  final _clock = Stopwatch()..start();
  GpuRenderPipeline? _pipeline;
  GpuBindGroupLayout? _modelLayout;
  GpuBindGroup? _cameraBindGroup;
  GpuBuffer? _cameraBuffer;
  GpuSampler? _sampler;
  GpuTexture? _depthTex;
  GpuTextureView? _depthView;
  int _dw = 0, _dh = 0;
  GpuTextureView? _white, _flatNormal, _black;
  final _owned = <GpuTexture>[];
  final meshes = <MeshData>[];
  final baseMats = <mat4>[];
  final _bgs = <GpuBindGroup>[];
  final _ubufs = <GpuBuffer>[];
  final camera = Camera(fov: 45)
    ..position = vec3(0, 0.5, 4)
    ..lookAt(vec3.zero);

  GpuTextureView _make1x1(GpuDevice d, List<int> rgba, {bool srgb = false}) {
    final t = d.createTexture(
      width: 1,
      height: 1,
      format: srgb
          ? GpuTextureFormat.rgba8UnormSrgb
          : GpuTextureFormat.rgba8Unorm,
      usage: GpuTextureUsage.textureBinding | GpuTextureUsage.copyDst,
    );
    d.queue.writeTexture(
      texture: t,
      data: Uint8List.fromList(rgba),
      bytesPerRow: 4,
      width: 1,
      height: 1,
    );
    _owned.add(t);
    return t.createView();
  }

  void _init(GpuFrame frame) {
    if (_pipeline != null) return;
    final d = frame.device;
    _white = _make1x1(d, [255, 255, 255, 255], srgb: true);
    _flatNormal = _make1x1(d, [128, 128, 255, 255]);
    _black = _make1x1(d, [0, 0, 0, 255], srgb: true);
    _sampler = d.createSampler(
      magFilter: GpuFilterMode.linear,
      minFilter: GpuFilterMode.linear,
      mipmapFilter: GpuMipmapFilterMode.linear,
      addressModeU: GpuAddressMode.repeat,
      addressModeV: GpuAddressMode.repeat,
      maxAnisotropy: 16,
    );
    _cameraBuffer = d.createBuffer(
      size: 80,
      usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
    );
    final cLayout = d.createBindGroupLayout([
      GpuBindGroupLayoutEntry.buffer(
        binding: 0,
        visibility: GpuShaderStage.vertex | GpuShaderStage.fragment,
      ),
    ]);
    _cameraBindGroup = d.createBindGroup(
      layout: cLayout,
      entries: [GpuBindGroupEntry.buffer(binding: 0, buffer: _cameraBuffer!)],
    );
    _modelLayout = d.createBindGroupLayout([
      GpuBindGroupLayoutEntry.buffer(
        binding: 0,
        visibility: GpuShaderStage.vertex | GpuShaderStage.fragment,
      ),
      GpuBindGroupLayoutEntry.texture(
        binding: 1,
        visibility: GpuShaderStage.fragment,
      ),
      GpuBindGroupLayoutEntry.sampler(
        binding: 2,
        visibility: GpuShaderStage.fragment,
      ),
      GpuBindGroupLayoutEntry.texture(
        binding: 3,
        visibility: GpuShaderStage.fragment,
      ),
      GpuBindGroupLayoutEntry.texture(
        binding: 4,
        visibility: GpuShaderStage.fragment,
      ),
      GpuBindGroupLayoutEntry.texture(
        binding: 5,
        visibility: GpuShaderStage.fragment,
      ),
    ]);
    for (final m in meshes) {
      final b = d.createBuffer(
        size: 112,
        usage: GpuBufferUsage.uniform | GpuBufferUsage.copyDst,
      );
      _ubufs.add(b);
      _bgs.add(_bg(d, b, m));
    }
    final shader = d.createShaderModule(_wgsl);
    _pipeline = d.createRenderPipeline(
      GpuRenderPipelineDescriptor(
        layout: d.createPipelineLayout([cLayout, _modelLayout!]),
        vertexModule: shader,
        vertexEntryPoint: 'vs',
        fragmentModule: shader,
        fragmentEntryPoint: 'fs',
        cullMode: GpuCullMode.back,
        vertexBuffers: [
          const GpuVertexBufferLayout(
            arrayStride: 48,
            attributes: [
              GpuVertexAttribute(
                format: GpuVertexFormat.float32x3,
                offset: 0,
                shaderLocation: 0,
              ),
              GpuVertexAttribute(
                format: GpuVertexFormat.float32x3,
                offset: 12,
                shaderLocation: 1,
              ),
              GpuVertexAttribute(
                format: GpuVertexFormat.float32x2,
                offset: 24,
                shaderLocation: 2,
              ),
              GpuVertexAttribute(
                format: GpuVertexFormat.float32x4,
                offset: 32,
                shaderLocation: 3,
              ),
            ],
          ),
        ],
        colorTargets: [GpuColorTargetState(format: frame.format)],
        depthStencil: const GpuDepthStencilState(
          format: GpuTextureFormat.depth32Float,
          depthWriteEnabled: true,
          depthCompare: GpuCompareFunction.less,
        ),
      ),
    );
  }

  GpuBindGroup _bg(GpuDevice d, GpuBuffer b, MeshData m) => d.createBindGroup(
    layout: _modelLayout!,
    entries: [
      GpuBindGroupEntry.buffer(binding: 0, buffer: b),
      GpuBindGroupEntry.textureView(
        binding: 1,
        view: m.material.map?.view ?? _white!,
      ),
      GpuBindGroupEntry.sampler(binding: 2, sampler: _sampler!),
      GpuBindGroupEntry.textureView(
        binding: 3,
        view: m.material.normalMap?.view ?? _flatNormal!,
      ),
      GpuBindGroupEntry.textureView(
        binding: 4,
        view: m.material.metallicRoughnessMap?.view ?? _white!,
      ),
      GpuBindGroupEntry.textureView(
        binding: 5,
        view: m.material.emissiveMap?.view ?? _black!,
      ),
    ],
  );

  @override
  bool render(GpuFrame frame) {
    if (meshes.isEmpty) return false;
    _init(frame);
    final d = frame.device;
    final w = frame.width, h = frame.height;
    if (_dw != w || _dh != h) {
      _depthTex?.destroy();
      _depthTex = d.createTexture(
        width: w,
        height: h,
        format: GpuTextureFormat.depth32Float,
        usage: GpuTextureUsage.renderAttachment,
      );
      _depthView = _depthTex!.createView();
      _dw = w;
      _dh = h;
    }

    final t = _clock.elapsedMicroseconds / 1e6;
    camera.aspect = w / h;
    final spin = mat4.rotationY(t * 0.5);
    for (var i = 0; i < meshes.length; i++) {
      meshes[i].worldMatrix = spin * baseMats[i];
    }

    final cam = Float32List(20);
    final vp = camera.viewProjection;
    cam[0] = vp.c0.x;
    cam[1] = vp.c0.y;
    cam[2] = vp.c0.z;
    cam[3] = vp.c0.w;
    cam[4] = vp.c1.x;
    cam[5] = vp.c1.y;
    cam[6] = vp.c1.z;
    cam[7] = vp.c1.w;
    cam[8] = vp.c2.x;
    cam[9] = vp.c2.y;
    cam[10] = vp.c2.z;
    cam[11] = vp.c2.w;
    cam[12] = vp.c3.x;
    cam[13] = vp.c3.y;
    cam[14] = vp.c3.z;
    cam[15] = vp.c3.w;
    cam[16] = camera.position.x;
    cam[17] = camera.position.y;
    cam[18] = camera.position.z;
    d.queue.writeBuffer(_cameraBuffer!, cam.buffer.asUint8List());

    final md = Float32List(28);
    for (var i = 0; i < meshes.length; i++) {
      final m = meshes[i];
      final mt = m.material;
      final wm = m.worldMatrix;
      md[0] = wm.c0.x;
      md[1] = wm.c0.y;
      md[2] = wm.c0.z;
      md[3] = wm.c0.w;
      md[4] = wm.c1.x;
      md[5] = wm.c1.y;
      md[6] = wm.c1.z;
      md[7] = wm.c1.w;
      md[8] = wm.c2.x;
      md[9] = wm.c2.y;
      md[10] = wm.c2.z;
      md[11] = wm.c2.w;
      md[12] = wm.c3.x;
      md[13] = wm.c3.y;
      md[14] = wm.c3.z;
      md[15] = wm.c3.w;
      md[16] = mt.color.r;
      md[17] = mt.color.g;
      md[18] = mt.color.b;
      md[19] = mt.color.a;
      md[20] = mt.emissiveColor.r;
      md[21] = mt.emissiveColor.g;
      md[22] = mt.emissiveColor.b;
      md[23] = 1;
      md[24] = mt.roughness;
      md[25] = mt.metallic;
      d.queue.writeBuffer(_ubufs[i], md.buffer.asUint8List());
    }

    final enc = d.createCommandEncoder();
    final pass = enc.beginRenderPass(
      colorAttachments: [
        GpuColorAttachment(
          view: frame.targetView,
          loadOp: GpuLoadOp.clear,
          storeOp: GpuStoreOp.store,
          clearValue: const GpuColor(0.08, 0.08, 0.12, 1),
        ),
      ],
      depthStencilAttachment: GpuDepthStencilAttachment(
        view: _depthView!,
        depthLoadOp: GpuLoadOp.clear,
        depthStoreOp: GpuStoreOp.store,
        depthClearValue: 1,
      ),
    );
    pass.setPipeline(_pipeline!);
    pass.setBindGroup(0, _cameraBindGroup!);
    for (var i = 0; i < meshes.length; i++) {
      pass.setBindGroup(1, _bgs[i]);
      pass.setVertexBuffer(0, meshes[i].vb);
      pass.setIndexBuffer(meshes[i].ib, GpuIndexFormat.uint32);
      pass.drawIndexed(indexCount: meshes[i].indexCount);
    }
    pass.end();
    d.queue.submit([enc.finish()]);
    return true;
  }

  @override
  bool shouldUpdate(covariant Renderer oldRenderer) => false;

  @override
  void dispose() {
    for (final m in meshes) {
      m.vb.destroy();
      m.ib.destroy();
    }
    for (final b in _ubufs) {
      b.destroy();
    }
    _cameraBuffer?.destroy();
    _depthTex?.destroy();
    for (final t in _owned) {
      t.destroy();
    }
    super.dispose();
  }
}

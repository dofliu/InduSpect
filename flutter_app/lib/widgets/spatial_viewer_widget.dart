import 'dart:math';
import 'package:flutter/material.dart';
import '../models/spatial_point_cloud.dart';

class SpatialViewerWidget extends StatefulWidget {
  final SpatialPointCloud model;
  final Function(SpatialAnchor anchor)? onAnchorSelected;
  final Function(double x, double y, double z)? onPointTapped;

  const SpatialViewerWidget({
    Key? key,
    required this.model,
    this.onAnchorSelected,
    this.onPointTapped,
  }) : super(key: key);

  @override
  State<SpatialViewerWidget> createState() => _SpatialViewerWidgetState();
}

class _SpatialViewerWidgetState extends State<SpatialViewerWidget> {
  double _rotationX = -0.3;
  double _rotationY = 0.6;
  double _zoom = 1.0;
  Offset _panOffset = Offset.zero;

  Offset? _lastFocalPoint;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (details) {
        _lastFocalPoint = details.focalPoint;
      },
      onScaleUpdate: (details) {
        setState(() {
          // 雙指觸控縮放
          _zoom = (_zoom * details.scale).clamp(0.4, 3.5);

          // 單指拖拽旋轉視角
          if (_lastFocalPoint != null) {
            final delta = details.focalPoint - _lastFocalPoint!;
            _rotationY += delta.dx * 0.008;
            _rotationX += delta.dy * 0.008;
            _lastFocalPoint = details.focalPoint;
          }
        });
      },
      onScaleEnd: (_) {
        _lastFocalPoint = null;
      },
      child: Container(
        color: const Color(0xFF0F172A), // 科技深藍黑背景
        child: Stack(
          children: [
            // 3D Canvas 渲染
            CustomPaint(
              size: Size.infinite,
              painter: _SpatialCanvasPainter(
                model: widget.model,
                rotationX: _rotationX,
                rotationY: _rotationY,
                zoom: _zoom,
                panOffset: _panOffset,
              ),
            ),

            // 視角重設與縮放控制按鈕
            Positioned(
              right: 16,
              bottom: 16,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'btn_zoom_in',
                    backgroundColor: const Color(0xFF1E293B),
                    child: const Icon(Icons.add, color: Colors.cyanAccent),
                    onPressed: () => setState(() => _zoom = (_zoom + 0.2).clamp(0.4, 3.5)),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'btn_zoom_out',
                    backgroundColor: const Color(0xFF1E293B),
                    child: const Icon(Icons.remove, color: Colors.cyanAccent),
                    onPressed: () => setState(() => _zoom = (_zoom - 0.2).clamp(0.4, 3.5)),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'btn_reset_view',
                    backgroundColor: const Color(0xFF1E293B),
                    child: const Icon(Icons.center_focus_strong, color: Colors.cyanAccent),
                    onPressed: () => setState(() {
                      _rotationX = -0.3;
                      _rotationY = 0.6;
                      _zoom = 1.0;
                      _panOffset = Offset.zero;
                    }),
                  ),
                ],
              ),
            ),

            // 3D 圖例與數據面板
            Positioned(
              left: 16,
              top: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.model.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '特徵點: ${widget.model.points.length}  |  空間錨點: ${widget.model.anchors.length}',
                      style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                    ),
                    Text(
                      '預估體積: ${widget.model.estimatedVolumeM3.toStringAsFixed(2)} m³',
                      style: TextStyle(color: Colors.grey.shade300, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 3D 空間 3D Canvas 畫筆
class _SpatialCanvasPainter extends CustomPainter {
  final SpatialPointCloud model;
  final double rotationX;
  final double rotationY;
  final double zoom;
  final Offset panOffset;

  _SpatialCanvasPainter({
    required this.model,
    required this.rotationX,
    required this.rotationY,
    required this.zoom,
    required this.panOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2 + panOffset.dx;
    final centerY = size.height / 2 + panOffset.dy;
    final scale = min(size.width, size.height) * 0.22 * zoom;

    // 繪製 3D XYZ 網格線 (Floor Grid)
    final gridPaint = Paint()
      ..color = Colors.cyan.withOpacity(0.15)
      ..strokeWidth = 1.0;

    for (int i = -4; i <= 4; i++) {
      final p1 = _project3D(i * 0.5, -1.2, -2.0, rotationX, rotationY, scale, centerX, centerY);
      final p2 = _project3D(i * 0.5, -1.2, 2.0, rotationX, rotationY, scale, centerX, centerY);
      canvas.drawLine(p1, p2, gridPaint);

      final p3 = _project3D(-2.0, -1.2, i * 0.5, rotationX, rotationY, scale, centerX, centerY);
      final p4 = _project3D(2.0, -1.2, i * 0.5, rotationX, rotationY, scale, centerX, centerY);
      canvas.drawLine(p3, p4, gridPaint);
    }

    // 繪製 3D 點雲 (Point Cloud)
    for (final pt in model.points) {
      final projected = _project3D(pt.x, pt.y, pt.z, rotationX, rotationY, scale, centerX, centerY);
      final dotPaint = Paint()
        ..color = Color.fromRGBO(pt.r, pt.g, pt.b, 0.85)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = (2.2 * zoom).clamp(1.5, 4.5);

      canvas.drawCircle(projected, (1.8 * zoom).clamp(1.0, 3.5), dotPaint);
    }

    // 繪製 3D 空間巡檢錨點 (Spatial Anchors)
    for (final anchor in model.anchors) {
      final p = _project3D(anchor.x, anchor.y, anchor.z, rotationX, rotationY, scale, centerX, centerY);

      final color = anchor.status == 'abnormal'
          ? Colors.redAccent
          : (anchor.status == 'warning' ? Colors.orangeAccent : Colors.greenAccent);

      // 外發光圈
      canvas.drawCircle(
        p,
        14 * zoom,
        Paint()..color = color.withOpacity(0.25),
      );

      // 核心圖示
      canvas.drawCircle(
        p,
        7 * zoom,
        Paint()..color = color,
      );

      // 標籤文字說明
      final textSpan = TextSpan(
        text: '📍 ${anchor.title}',
        style: TextStyle(
          color: Colors.white,
          fontSize: (11 * zoom).clamp(9.0, 14.0),
          fontWeight: FontWeight.bold,
          shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(p.dx + 10, p.dy - 8));
    }
  }

  /// 3D 透視投影矩陣運算 (3D to 2D Screen Coordinate Conversion)
  Offset _project3D(
    double x,
    double y,
    double z,
    double rx,
    double ry,
    double scale,
    double centerX,
    double centerY,
  ) {
    // 圍繞 Y 軸旋轉
    double x1 = x * cos(ry) + z * sin(ry);
    double y1 = y;
    double z1 = -x * sin(ry) + z * cos(ry);

    // 圍繞 X 軸旋轉
    double x2 = x1;
    double y2 = y1 * cos(rx) - z1 * sin(rx);
    double z2 = y1 * sin(rx) + z1 * cos(rx);

    // 簡單透視效果 (Perspective projection)
    double distance = 4.0;
    double fov = distance / (distance + z2);

    double screenX = centerX + x2 * scale * fov;
    double screenY = centerY - y2 * scale * fov; // Y 軸向上為正

    return Offset(screenX, screenY);
  }

  @override
  bool shouldRepaint(covariant _SpatialCanvasPainter oldDelegate) {
    return oldDelegate.rotationX != rotationX ||
        oldDelegate.rotationY != rotationY ||
        oldDelegate.zoom != zoom ||
        oldDelegate.panOffset != panOffset;
  }
}

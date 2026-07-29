import 'dart:io';
import 'package:flutter/material.dart';
import '../models/spatial_point_cloud.dart';
import '../services/spatial_mapping_service.dart';
import '../widgets/spatial_viewer_widget.dart';

class SpatialMappingScreen extends StatefulWidget {
  const SpatialMappingScreen({Key? key}) : super(key: key);

  @override
  State<SpatialMappingScreen> createState() => _SpatialMappingScreenState();
}

class _SpatialMappingScreenState extends State<SpatialMappingScreen> {
  final _service = SpatialMappingService();
  final _nameController = TextEditingController(text: '發電機房 3D 空間');

  bool _isScanning = false;
  double _progress = 0.0;
  int _pointCount = 0;
  SpatialPointCloud? _currentModel;
  List<SpatialPointCloud> _savedModels = [];

  @override
  void initState() {
    super.initState();
    _loadSavedModels();
  }

  Future<void> _loadSavedModels() async {
    final models = await _service.loadSavedSpatialModels();
    setState(() {
      _savedModels = models;
      if (models.isNotEmpty && _currentModel == null) {
        _currentModel = models.first;
      }
    });
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _progress = 0.0;
      _pointCount = 0;
    });

    final model = await _service.startSpatialScan(
      spaceName: _nameController.text.trim(),
      pointDensity: 1500,
      onProgress: (progress, count) {
        setState(() {
          _progress = progress;
          _pointCount = count;
        });
      },
    );

    await _service.saveSpatialModelJson(model);
    await _service.saveSpatialModelAsPly(model);

    setState(() {
      _isScanning = false;
      _currentModel = model;
    });

    await _loadSavedModels();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ 3D 空間建立完成！特徵點: ${model.points.length} 個'),
          backgroundColor: Colors.teal,
        ),
      );
    }
  }

  void _addNewAnchor() {
    if (_currentModel == null) return;
    final titleController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('📍 新增 3D 空間巡檢標籤', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '設備/標籤名稱',
                labelStyle: TextStyle(color: Colors.cyanAccent),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '巡檢狀態/備註說明',
                labelStyle: TextStyle(color: Colors.cyanAccent),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan),
            child: const Text('釘選至 3D 空間', style: TextStyle(color: Colors.black)),
            onPressed: () {
              if (titleController.text.isNotEmpty) {
                final newAnchor = SpatialAnchor(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  title: titleController.text,
                  description: descController.text,
                  x: (0.2 + (titleController.text.length % 5) * 0.2),
                  y: 0.1,
                  z: 1.0,
                  status: 'normal',
                );

                setState(() {
                  _currentModel!.anchors.add(newAnchor);
                });
                _service.saveSpatialModelJson(_currentModel!);
                Navigator.pop(ctx);
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('3D 空間建模與巡檢', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF0F172A),
        actions: [
          if (_currentModel != null)
            IconButton(
              icon: const Icon(Icons.add_location_alt, color: Colors.cyanAccent),
              tooltip: '新增 3D 標籤',
              onPressed: _addNewAnchor,
            ),
          IconButton(
            icon: const Icon(Icons.folder_zip, color: Colors.amberAccent),
            tooltip: '導出 PLY 檔案',
            onPressed: () async {
              if (_currentModel != null) {
                final file = await _service.saveSpatialModelAsPly(_currentModel!);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已導出 .ply 檔案至: ${file.path}')),
                  );
                }
              }
            },
          ),
        ],
      ),
      body: Container(
        color: const Color(0xFF0B0F19),
        child: Column(
          children: [
            // 頂部名稱與掃描控制區
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF1E293B),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: '空間/場域名稱',
                            labelStyle: const TextStyle(color: Colors.cyanAccent),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        icon: Icon(_isScanning ? Icons.sync : Icons.view_in_ar),
                        label: Text(_isScanning ? '掃描中...' : '開始 3D 掃描'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isScanning ? Colors.amber : Colors.cyan,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        ),
                        onPressed: _isScanning ? null : _startScan,
                      ),
                    ],
                  ),

                  // 掃描中進度條
                  if (_isScanning) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: Colors.black38,
                      color: Colors.cyanAccent,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '實態進度: ${(_progress * 100).toInt()}%',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        Text(
                          '擷取點數: $_pointCount pts',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // 3D 畫布檢視區
            Expanded(
              child: _currentModel != null
                  ? SpatialViewerWidget(
                      model: _currentModel!,
                      onAnchorSelected: (anchor) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('選取錨點: ${anchor.title} - ${anchor.description}')),
                        );
                      },
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.view_in_ar_sharp, size: 72, color: Colors.cyanAccent),
                          SizedBox(height: 16),
                          Text(
                            '點擊上方「開始 3D 掃描」按鈕\n建立 Android 手機 3D 空間模型',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70, fontSize: 15),
                          ),
                        ],
                      ),
                    ),
            ),

            // 歷史 3D 模型列表 Drawer / Bottom Sheet
            if (_savedModels.isNotEmpty)
              Container(
                height: 56,
                color: const Color(0xFF1E293B),
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  itemCount: _savedModels.length,
                  itemBuilder: (ctx, idx) {
                    final item = _savedModels[idx];
                    final isSelected = item.id == _currentModel?.id;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(item.name),
                        selected: isSelected,
                        selectedColor: Colors.cyan,
                        backgroundColor: const Color(0xFF0F172A),
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.black : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        onSelected: (_) {
                          setState(() => _currentModel = item);
                        },
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

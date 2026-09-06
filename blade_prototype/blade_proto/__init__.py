"""風力機葉片地面目視檢測 — Phase 0 演算法原型（純 Python / OpenCV）。

對應 `BLADE_INSPECTION_SPEC.md` §5.1–5.4：
- `synth`        合成風機影像（測試夾具 + 靈敏度分析）
- `segmentation` 葉片/塔架分割、輪轂定位、葉片分離
- `geometry`     中心線抽取、彎曲係數、三片互比
- `surface`      前緣輪廓粗糙度、紋理
- `dynamics`     影片葉尖追蹤、轉速、六點鐘取幀

此原型用來在外業前驗證「能做到哪」，並作為日後 Dart 移植的參考實作。
"""

__version__ = "0.1.0"

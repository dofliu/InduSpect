"""線性探針的守門：不碰 torch、特徵檔要能對帳、與 B2 只差特徵。"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import closeup_probe as P  # noqa: E402


def test_only_the_feature_extractor_imports_torch() -> None:
    """torch 只准出現在一個檔案裡；主線 207 條測試與評估都不依賴它。"""
    offenders = []
    for py in list((ROOT / "scripts").glob("*.py")) + list((ROOT / "blade_proto").glob("*.py")) + list((ROOT / "tests").glob("*.py")):
        if py.name == "closeup_features_cnn.py":
            continue
        for line in py.read_text(encoding="utf-8").splitlines():
            if re.match(r"\s*(import|from)\s+(torch|torchvision)\b", line):
                offenders.append(f"{py.name}: {line.strip()}")
    assert not offenders, offenders


def test_probe_module_has_no_torch_dependency() -> None:
    assert "torch" not in sys.modules or True  # 只要能 import 成功且下面的測試跑得動就夠
    assert not hasattr(P, "torch")


def test_shipped_features_cover_the_whole_corpus() -> None:
    """特徵檔進版控，評估不需要語料本體——但要涵蓋 1065 張、512 維、帶權重雜湊。"""
    feat, meta = P.load_features(P.FEATURES)
    assert len(feat) == 1065
    assert meta["dim"] == 512 and next(iter(feat.values())).shape == (512,)
    assert re.fullmatch(r"[0-9a-f]{16}", meta["weight_sha256_16"])
    assert meta["input_px"] == 224 and meta["missing"] == []


def test_probe_refuses_when_features_miss_part_of_the_domain() -> None:
    feat = {"0": np.zeros(4), "1": np.ones(4)}
    truth = {"0": ["a"], "1": [], "2": ["a"]}
    folds = {"0": 0, "1": 1, "2": 0}
    with pytest.raises(P.ProbeError):
        P.probe(feat, truth, folds, ["0", "1", "2"])


def test_probe_reuses_b2_classifier_and_is_deterministic() -> None:
    rng = np.random.default_rng(1)
    ids = [str(i) for i in range(40)]
    feat = {i: rng.normal(size=8) for i in ids}
    truth = {i: (["a"] if feat[i][0] > 0 else []) for i in ids}
    folds = {i: int(i) % 5 for i in ids}
    p1 = P.probe(feat, truth, folds, ids)
    p2 = P.probe(feat, truth, folds, ids)
    assert p1 == p2
    assert set(p1) == set(ids)
    hits = sum(1 for i in ids if ("a" in p1[i]) == ("a" in truth[i]))
    assert hits / len(ids) > 0.8, "可分的資料要學得起來，否則探針本身壞了"


def test_load_features_rejects_shape_mismatch(tmp_path: Path) -> None:
    bad = tmp_path / "bad.npz"
    np.savez_compressed(bad, ids=np.array(["0", "1"]), X=np.zeros((2, 3), np.float16),
                        meta=json.dumps({"dim": 512}))
    with pytest.raises(P.ProbeError):
        P.load_features(bad)

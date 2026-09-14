"""B2 離線基線的守門：它是「地板」，所以必須可重現、而且不能偷看測試折。

基線的價值全在「這個數字別人重跑得到一樣的」。這裡守四件事：維度、決定性、
折與折之間不相通、標準化只用訓練集的統計量。
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import closeup_baseline as bl  # noqa: E402

N_FEATURES = 123  # CLOSEUP_EVAL_PROTOCOL.md §3.6 寫的維度


def _scene(seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    img = rng.integers(90, 170, size=(300, 400, 3), dtype=np.uint8)
    img[120:150, :, :] = 40          # 一條暗帶（長直線 + 暗元件）
    img[:, 300:320, 1] = 210         # 一塊亮的
    return img


def test_feature_vector_has_the_documented_width():
    assert len(bl.image_features(_scene())) == N_FEATURES


def test_features_are_deterministic():
    a, b = bl.image_features(_scene(1)), bl.image_features(_scene(1))
    assert np.array_equal(a, b)


def test_fit_is_bit_for_bit_reproducible():
    """零初始化 + 固定迭代數，沒有隨機種子可以忘記設。"""
    rng = np.random.default_rng(3)
    X = np.c_[np.ones(60), rng.normal(size=(60, 4))]
    y = (X[:, 1] > 0).astype(float)
    assert np.array_equal(bl.fit_logreg(X, y), bl.fit_logreg(X, y))


def test_fit_actually_separates_a_separable_problem():
    """梯度寫錯時上一條測試照樣會過——所以要有一條看它學不學得起來。"""
    rng = np.random.default_rng(5)
    X = np.c_[np.ones(200), rng.normal(size=(200, 3))]
    y = (X[:, 1] + X[:, 2] > 0).astype(float)
    p = 1.0 / (1.0 + np.exp(-(X @ bl.fit_logreg(X, y))))
    assert ((p >= 0.5) == (y == 1)).mean() > 0.9


def test_standardise_uses_only_the_training_statistics():
    train = np.array([[0.0, 10.0], [2.0, 14.0]])
    a, _ = bl.standardise(train, np.array([[100.0, 100.0]]))
    b, _ = bl.standardise(train, np.array([[-50.0, 0.0]]))
    assert np.array_equal(a, b), "測試集換了，訓練集的標準化結果就不該變"
    _, other = bl.standardise(train, np.array([[1.0, 12.0]]))
    assert other[0, 0] == 1.0                    # 截距項
    assert other[0, 1:] == pytest.approx([0.0, 0.0], abs=1e-6)  # 正好是訓練集均值


def test_a_fold_is_never_trained_on_itself(monkeypatch):
    ids = [str(i) for i in range(20)]
    folds = {i: int(i) % 4 for i in ids}
    feat = {i: np.full(3, float(i)) for i in ids}
    truth = {i: ["craze"] if int(i) % 2 else [] for i in ids}

    seen: list[tuple[int, ...]] = []
    real = bl.fit_logreg

    def spy(X, y, **kw):
        seen.append(X.shape)
        return real(X, y, **kw)

    monkeypatch.setattr(bl, "fit_logreg", spy)
    pred = bl.run_folds(feat, truth, ["craze"], folds, ids)
    assert set(pred) == set(ids)                     # 每張都被預測到，剛好一次
    assert all(n == 15 for n, _ in seen)             # 20 − 5：訓練池永遠不含被預測的那一折


def test_a_class_absent_from_the_training_fold_is_not_invented(monkeypatch):
    """`crack` 在取像合格域裡真值 0 張——模型不該憑空生出那一類。"""
    ids = [str(i) for i in range(8)]
    folds = {i: int(i) % 2 for i in ids}
    feat = {i: np.array([float(i), 1.0]) for i in ids}
    truth = {i: [] for i in ids}
    pred = bl.run_folds(feat, truth, ["crack"], folds, ids)
    assert all(v == [] for v in pred.values())

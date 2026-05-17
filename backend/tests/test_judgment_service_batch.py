"""
JudgmentService.batch_process 直接單元測試（weekly routine — 2026-05-16 Session #8）

batch_process 是 Sprint 5 新增的批次設備處理 API，目前僅透過 e2e/integration 測試
間接覆蓋。本檔補上直接測試：

涵蓋面：
- 空清單邊界
- 單台設備（全 pass / 有 fail / 有 warning / unknown 欄位）
- 多台設備（混合結果、順序保留）
- 設備缺欄位（equipment_info 不完整、readings 為空）
- 回傳 dict contract（必含 success / total_equipment / processed_count / failed_count
  / results / overall_summary 六欄位）
- 警告文字格式（fail / warning 都應出現在 warnings 字串中）

所有 async 透過 CI 的 --asyncio-mode=auto 跑（無需 @pytest.mark.asyncio 裝飾）。
"""

import sys
import os

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

import pytest

from app.services.judgment_service import JudgmentService


# batch_process 回傳的頂層 dict 必含欄位（contract）
TOP_LEVEL_REQUIRED = {
    "success",
    "total_equipment",
    "processed_count",
    "failed_count",
    "results",
    "overall_summary",
}

# 每台設備結果 dict 的必含欄位
PER_EQUIPMENT_REQUIRED = {
    "equipment_id",
    "equipment_name",
    "success",
    "judgments",
    "warnings",
    "summary",
    "error",
}

# overall_summary 的必含欄位
OVERALL_SUMMARY_REQUIRED = {
    "total_equipment",
    "processed_count",
    "failed_count",
    "total_pass",
    "total_fail",
    "total_warning",
    "total_unknown",
}


# ============================================================
# 邊界：空清單
# ============================================================


async def test_batch_process_empty_list_returns_zero_stats():
    """空 equipment_list → success=True、所有 counter 為 0、results 為空"""
    svc = JudgmentService()
    result = await svc.batch_process([], field_map=[])

    assert result["success"] is True
    assert result["total_equipment"] == 0
    assert result["processed_count"] == 0
    assert result["failed_count"] == 0
    assert result["results"] == []
    overall = result["overall_summary"]
    assert overall["total_pass"] == 0
    assert overall["total_fail"] == 0
    assert overall["total_warning"] == 0
    assert overall["total_unknown"] == 0


async def test_batch_process_top_level_contract():
    """回傳 dict 的頂層 6 欄位必須齊全（即使空清單也是）"""
    svc = JudgmentService()
    result = await svc.batch_process([], field_map=[])

    missing = TOP_LEVEL_REQUIRED - set(result.keys())
    assert not missing, f"缺少頂層欄位: {missing}"

    missing_overall = OVERALL_SUMMARY_REQUIRED - set(result["overall_summary"].keys())
    assert not missing_overall, f"overall_summary 缺少欄位: {missing_overall}"


# ============================================================
# 單台設備：全 pass / 有 fail / 有 warning
# ============================================================


async def test_batch_process_single_equipment_all_pass():
    """一台設備、所有量測值合格 → summary.pass_count 與 overall.total_pass 一致"""
    svc = JudgmentService()
    equipment_list = [
        {
            "equipment_info": {
                "equipment_id": "EQ-001",
                "equipment_name": "B棟1F配電盤",
                "equipment_type": "低壓配電設備",
            },
            "readings": [
                {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ"},
                {"field_name": "接地電阻", "value": 50.0, "unit": "Ω"},
            ],
        }
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    assert result["success"] is True
    assert result["processed_count"] == 1
    assert result["failed_count"] == 0

    eq_result = result["results"][0]
    assert eq_result["equipment_id"] == "EQ-001"
    assert eq_result["success"] is True
    assert eq_result["error"] is None
    assert eq_result["summary"]["pass_count"] == 2
    assert eq_result["summary"]["fail_count"] == 0
    assert eq_result["warnings"] == []
    assert result["overall_summary"]["total_pass"] == 2


async def test_batch_process_single_equipment_with_fail_populates_warnings():
    """一台設備有不合格項目 → warnings 含「不合格」字樣 + 標準值"""
    svc = JudgmentService()
    equipment_list = [
        {
            "equipment_info": {
                "equipment_id": "EQ-002",
                "equipment_name": "馬達 A",
                "equipment_type": "馬達",
            },
            "readings": [
                {"field_name": "馬達溫度", "value": 95.0, "unit": "°C"},  # fail >80°C
            ],
        }
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    eq_result = result["results"][0]
    assert eq_result["summary"]["fail_count"] == 1
    assert len(eq_result["warnings"]) == 1
    # warnings 文字應同時含「不合格」與量測值
    assert "不合格" in eq_result["warnings"][0]
    assert "95" in eq_result["warnings"][0]
    assert result["overall_summary"]["total_fail"] == 1


async def test_batch_process_warning_judgment_populates_warnings():
    """量測值落在 warning_value 與 pass_value 之間 → 出現「警告」字樣"""
    svc = JudgmentService()
    # 絕緣電阻：pass_value=1.0, warning_value=2.0 → 1.5 為 warning
    equipment_list = [
        {
            "equipment_info": {"equipment_id": "EQ-003", "equipment_name": "Panel"},
            "readings": [
                {"field_name": "絕緣電阻", "value": 1.5, "unit": "MΩ"},
            ],
        }
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    eq_result = result["results"][0]
    assert eq_result["summary"]["warning_count"] == 1
    assert len(eq_result["warnings"]) == 1
    assert "警告" in eq_result["warnings"][0]
    assert result["overall_summary"]["total_warning"] == 1


# ============================================================
# Unknown 處理
# ============================================================


async def test_batch_process_unknown_readings_counted_separately():
    """無匹配標準的欄位 → unknown_count 增加，不計入 pass/fail"""
    svc = JudgmentService()
    equipment_list = [
        {
            "equipment_info": {"equipment_id": "EQ-004", "equipment_name": "Test"},
            "readings": [
                {"field_name": "某不存在的奇怪欄位 XYZ", "value": 42.0, "unit": ""},
                {"field_name": "絕緣電阻", "value": 52.3, "unit": "MΩ"},  # pass
            ],
        }
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    eq_result = result["results"][0]
    assert eq_result["summary"]["unknown_count"] == 1
    assert eq_result["summary"]["pass_count"] == 1
    assert eq_result["summary"]["fail_count"] == 0
    # unknown 不應產生 warnings（保留給使用者人工判定）
    assert eq_result["warnings"] == []


# ============================================================
# 多台設備
# ============================================================


async def test_batch_process_multiple_equipment_aggregates_correctly():
    """三台設備混合結果 → overall_summary 為各台加總"""
    svc = JudgmentService()
    equipment_list = [
        {
            "equipment_info": {"equipment_id": "EQ-A", "equipment_name": "A"},
            "readings": [
                {"field_name": "絕緣電阻", "value": 52.3, "unit": "MΩ"},  # pass
                {"field_name": "接地電阻", "value": 50.0, "unit": "Ω"},   # pass
            ],
        },
        {
            "equipment_info": {"equipment_id": "EQ-B", "equipment_name": "B"},
            "readings": [
                {"field_name": "接地電阻", "value": 150.0, "unit": "Ω"},  # fail
            ],
        },
        {
            "equipment_info": {"equipment_id": "EQ-C", "equipment_name": "C"},
            "readings": [
                {"field_name": "絕緣電阻", "value": 1.5, "unit": "MΩ"},  # warning
                {"field_name": "未知欄位 ZZZ", "value": 1.0, "unit": ""}, # unknown
            ],
        },
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    assert result["total_equipment"] == 3
    assert result["processed_count"] == 3
    assert result["failed_count"] == 0
    overall = result["overall_summary"]
    assert overall["total_pass"] == 2
    assert overall["total_fail"] == 1
    assert overall["total_warning"] == 1
    assert overall["total_unknown"] == 1


async def test_batch_process_preserves_equipment_order():
    """results 順序與 equipment_list 輸入順序一致"""
    svc = JudgmentService()
    equipment_list = [
        {"equipment_info": {"equipment_id": f"EQ-{i:03d}", "equipment_name": f"Dev{i}"},
         "readings": []}
        for i in range(5)
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    ids = [r["equipment_id"] for r in result["results"]]
    assert ids == ["EQ-000", "EQ-001", "EQ-002", "EQ-003", "EQ-004"]


# ============================================================
# 設備缺欄位 / readings 為空
# ============================================================


async def test_batch_process_empty_readings_no_error():
    """設備 readings 為空 → 不 raise、summary 全 0"""
    svc = JudgmentService()
    equipment_list = [
        {
            "equipment_info": {"equipment_id": "EQ-NONE", "equipment_name": "Empty"},
            "readings": [],
        }
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    assert result["success"] is True
    eq_result = result["results"][0]
    assert eq_result["success"] is True
    assert eq_result["summary"]["total_readings"] == 0
    assert eq_result["summary"]["pass_count"] == 0
    assert eq_result["judgments"] == []


async def test_batch_process_missing_equipment_info_uses_empty_defaults():
    """equipment_info 缺欄位 → 用空字串 default、不 raise"""
    svc = JudgmentService()
    equipment_list = [
        {
            "equipment_info": {},  # 完全空
            "readings": [
                {"field_name": "絕緣電阻", "value": 52.3, "unit": "MΩ"},
            ],
        }
    ]
    result = await svc.batch_process(equipment_list, field_map=[])

    eq_result = result["results"][0]
    assert eq_result["equipment_id"] == ""
    assert eq_result["equipment_name"] == ""
    assert eq_result["success"] is True
    assert eq_result["summary"]["pass_count"] == 1


async def test_batch_process_per_equipment_dict_contract():
    """每台設備 result dict 必含 7 個 contract 欄位"""
    svc = JudgmentService()
    result = await svc.batch_process(
        [{"equipment_info": {"equipment_id": "X"}, "readings": []}],
        field_map=[],
    )
    eq_result = result["results"][0]
    missing = PER_EQUIPMENT_REQUIRED - set(eq_result.keys())
    assert not missing, f"per-equipment 缺欄位: {missing}"


# 允許此檔以 `python test_judgment_service_batch.py` 直接執行
if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))

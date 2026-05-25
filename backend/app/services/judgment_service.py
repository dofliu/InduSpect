import logging

from app.data.inspection_standards import InspectionStandardsDB, normalize_unit

logger = logging.getLogger(__name__)


class JudgmentService:
    def __init__(self):
        pass

    def __init_standards_db(self):
        """延遲初始化標準資料庫"""
        if not hasattr(self, '_standards_db'):
            self._standards_db = InspectionStandardsDB()

    async def auto_judge(
        self,
        field_name: str,
        measured_value,
        unit: str = "",
        equipment_type: str = "",
    ) -> dict:
        """
        自動判定量測值是否合格

        回傳:
        {
            "field_name": "絕緣電阻",
            "measured_value": 52.3,
            "unit": "MΩ",
            "judgment": "pass" | "fail" | "warning" | "unknown",
            "standard_text": "≥1.0 MΩ",
            "regulation": "屋內線路裝置規則 第59條",
            "confidence": 0.98,
            "standard_id": "elec_insulation_lv"
        }
        """
        self.__init_standards_db()

        # 查找匹配的標準
        standard = self._standards_db.find_matching_standard(
            field_name=field_name,
            unit=unit,
            equipment_type=equipment_type,
        )

        if standard is None:
            return {
                "field_name": field_name,
                "measured_value": measured_value,
                "unit": unit,
                "judgment": "unknown",
                "standard_text": "",
                "regulation": "",
                "confidence": 0.0,
                "standard_id": None,
                "converted_value": None,
                "converted_unit": None,
            }

        # 判定前先把讀數換算成標準單位，避免單位數量級不一致造成誤判
        # （例：500 kΩ = 0.5 MΩ 應為不合格，若不換算會誤判為合格）
        std_unit = standard.get("unit", "")
        value_for_judge = measured_value
        converted = False
        if unit and std_unit:
            cv, ok = self._standards_db.convert_value(measured_value, unit, std_unit)
            if ok and cv is not None:
                value_for_judge = cv
                converted = normalize_unit(unit) != normalize_unit(std_unit)

        # 執行判定
        result = self._standards_db.judge_value(standard, value_for_judge)

        confidence = 0.98 if result["judgment"] in ("pass", "fail") else 0.7

        return {
            "field_name": field_name,
            "measured_value": measured_value,
            "unit": unit or std_unit,
            "judgment": result["judgment"],
            "standard_text": result["standard_text"],
            "regulation": result["regulation"],
            "confidence": confidence,
            "standard_id": standard["standard_id"],
            "converted_value": value_for_judge if converted else None,
            "converted_unit": std_unit if converted else None,
        }

    async def batch_auto_judge(
        self,
        readings: list[dict],
        equipment_type: str = "",
    ) -> list[dict]:
        """
        批次判定多筆量測值

        readings 格式:
        [
            {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ"},
            {"field_name": "接地電阻", "value": 85.2, "unit": "Ω"},
            ...
        ]
        """
        results = []
        for reading in readings:
            result = await self.auto_judge(
                field_name=reading.get("field_name", ""),
                measured_value=reading.get("value"),
                unit=reading.get("unit", ""),
                equipment_type=equipment_type,
            )
            results.append(result)
        return results

    # ================================================================
    # 批次設備處理（Sprint 5 新增）
    # ================================================================

    async def batch_process(
        self,
        equipment_list: list[dict],
        field_map: list[dict],
    ) -> dict:
        """
        批次處理多台設備的定檢

        對每台設備呼叫 batch_auto_judge 進行自動判定，
        回傳所有設備的彙總結果。

        equipment_list 格式:
        [
            {
                "equipment_info": {"equipment_id": "...", "equipment_name": "...", ...},
                "readings": [{"field_name": "...", "value": ..., "unit": "..."}],
                "inspector_name": "...",
                "inspection_date": "..."
            },
            ...
        ]
        """
        results = []
        processed_count = 0
        failed_count = 0
        total_pass = 0
        total_fail = 0
        total_warning = 0
        total_unknown = 0

        for item in equipment_list:
            eq_info = item.get("equipment_info", {})
            eq_id = eq_info.get("equipment_id", "")
            eq_name = eq_info.get("equipment_name", "")
            eq_type = eq_info.get("equipment_type", "")
            readings = item.get("readings", [])

            try:
                # 執行批次判定
                readings_for_judge = [
                    {
                        "field_name": r.get("field_name", ""),
                        "value": r.get("value"),
                        "unit": r.get("unit", ""),
                    }
                    for r in readings
                ]

                judgments = await self.batch_auto_judge(
                    readings=readings_for_judge,
                    equipment_type=eq_type,
                )

                # 組裝警告
                warnings = []
                pass_count = 0
                fail_count_eq = 0
                warning_count = 0
                unknown_count = 0

                for j in judgments:
                    if j["judgment"] == "pass":
                        pass_count += 1
                    elif j["judgment"] == "fail":
                        fail_count_eq += 1
                        warnings.append(
                            f"不合格: {j['field_name']} = {j['measured_value']}{j.get('unit', '')}，"
                            f"標準: {j.get('standard_text', '')}"
                        )
                    elif j["judgment"] == "warning":
                        warning_count += 1
                        warnings.append(
                            f"警告: {j['field_name']} = {j['measured_value']}{j.get('unit', '')} 接近不合格"
                        )
                    else:
                        unknown_count += 1

                summary = {
                    "total_readings": len(readings),
                    "pass_count": pass_count,
                    "fail_count": fail_count_eq,
                    "warning_count": warning_count,
                    "unknown_count": unknown_count,
                }

                results.append({
                    "equipment_id": eq_id,
                    "equipment_name": eq_name,
                    "success": True,
                    "judgments": judgments,
                    "warnings": warnings,
                    "summary": summary,
                    "error": None,
                })

                processed_count += 1
                total_pass += pass_count
                total_fail += fail_count_eq
                total_warning += warning_count
                total_unknown += unknown_count

            except Exception as e:
                logger.error(f"Batch process failed for {eq_id}: {e}")
                results.append({
                    "equipment_id": eq_id,
                    "equipment_name": eq_name,
                    "success": False,
                    "judgments": [],
                    "warnings": [],
                    "summary": {},
                    "error": str(e),
                })
                failed_count += 1

        overall_summary = {
            "total_equipment": len(equipment_list),
            "processed_count": processed_count,
            "failed_count": failed_count,
            "total_pass": total_pass,
            "total_fail": total_fail,
            "total_warning": total_warning,
            "total_unknown": total_unknown,
        }

        return {
            "success": failed_count == 0,
            "total_equipment": len(equipment_list),
            "processed_count": processed_count,
            "failed_count": failed_count,
            "results": results,
            "overall_summary": overall_summary,
        }

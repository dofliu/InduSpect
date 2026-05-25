"""
定檢法規標準值資料庫

Sprint 3 Task 3.1: 覆蓋電氣、消防、機械、壓力容器四大類
每項標準包含:
- standard_id: 唯一識別碼
- category: 大類 (electrical/fire/mechanical/pressure)
- equipment_type: 適用設備類型
- inspection_item: 檢查項目名稱
- keywords: 模糊匹配關鍵字
- unit: 量測單位
- pass_condition: 比較方式 (gte/lte/range/eq/in_set)
- pass_value: 合格閾值 (數值或 [min, max] 或 set)
- warning_value: 警告閾值（接近不合格）
- regulation: 法規依據
- notes: 備註
"""

from typing import Optional

# ============ 電氣設備標準 (15項) ============

ELECTRICAL_STANDARDS = [
    {
        "standard_id": "elec_insulation_lv",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "絕緣電阻",
        "keywords": ["絕緣", "insulation", "IR"],
        "unit": "MΩ",
        "pass_condition": "gte",
        "pass_value": 1.0,
        "warning_value": 2.0,
        "regulation": "屋內線路裝置規則 第59條",
        "notes": "三相各相分別量測，對地絕緣電阻",
    },
    {
        "standard_id": "elec_ground_resistance",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "接地電阻",
        "keywords": ["接地", "ground", "earth"],
        "unit": "Ω",
        "pass_condition": "lte",
        "pass_value": 100.0,
        "warning_value": 80.0,
        "regulation": "屋內線路裝置規則 第59條",
        "notes": "第三種接地工程",
    },
    {
        "standard_id": "elec_rcd_time",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "漏電斷路器動作時間",
        "keywords": ["漏電", "動作時間", "RCD", "ELCB", "斷路器"],
        "unit": "ms",
        "pass_condition": "lte",
        "pass_value": 100.0,
        "warning_value": 80.0,
        "regulation": "CNS 14816",
        "notes": "額定動作電流下之動作時間",
    },
    {
        "standard_id": "elec_rcd_current",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "漏電斷路器動作電流",
        "keywords": ["漏電", "動作電流", "RCD", "ELCB"],
        "unit": "mA",
        "pass_condition": "lte",
        "pass_value": 30.0,
        "warning_value": 25.0,
        "regulation": "CNS 14816",
        "notes": "額定感度電流",
    },
    {
        "standard_id": "elec_voltage_deviation",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "電壓偏差率",
        "keywords": ["電壓", "偏差", "voltage"],
        "unit": "%",
        "pass_condition": "lte",
        "pass_value": 5.0,
        "warning_value": 4.0,
        "regulation": "電業法施行細則 第38條",
        "notes": "額定電壓 ±5% 以內",
    },
    {
        "standard_id": "elec_transformer_temp",
        "category": "electrical",
        "equipment_type": "變壓器",
        "inspection_item": "變壓器油溫",
        "keywords": ["變壓器", "油溫", "transformer", "temperature"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 85.0,
        "warning_value": 75.0,
        "regulation": "CNS 1390",
        "notes": "油浸式變壓器頂層油溫",
    },
    {
        "standard_id": "elec_transformer_insulation_hv",
        "category": "electrical",
        "equipment_type": "高壓配電設備",
        "inspection_item": "高壓絕緣電阻",
        "keywords": ["高壓", "絕緣", "HV"],
        "unit": "MΩ",
        "pass_condition": "gte",
        "pass_value": 100.0,
        "warning_value": 200.0,
        "regulation": "屋內線路裝置規則 第59條",
        "notes": "高壓設備對地絕緣電阻",
    },
    {
        "standard_id": "elec_contact_resistance",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "接觸電阻",
        "keywords": ["接觸", "contact"],
        "unit": "μΩ",
        "pass_condition": "lte",
        "pass_value": 100.0,
        "warning_value": 80.0,
        "regulation": "IEC 62271",
        "notes": "斷路器接觸電阻",
    },
    {
        "standard_id": "elec_harmonic_thd",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "諧波失真率",
        "keywords": ["諧波", "THD", "harmonic"],
        "unit": "%",
        "pass_condition": "lte",
        "pass_value": 5.0,
        "warning_value": 4.0,
        "regulation": "IEEE 519",
        "notes": "總諧波失真率 THD",
    },
    {
        "standard_id": "elec_power_factor",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "功率因數",
        "keywords": ["功率因數", "power factor", "PF", "cosφ"],
        "unit": "",
        "pass_condition": "gte",
        "pass_value": 0.85,
        "warning_value": 0.9,
        "regulation": "電業法 第45條",
        "notes": "用戶功率因數不得低於 0.85",
    },
    {
        "standard_id": "elec_busbar_temp",
        "category": "electrical",
        "equipment_type": "低壓配電設備",
        "inspection_item": "匯流排溫度",
        "keywords": ["匯流排", "busbar", "溫度", "溫升"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 70.0,
        "warning_value": 60.0,
        "regulation": "IEC 61439",
        "notes": "銅匯流排最高容許溫度",
    },
    {
        "standard_id": "elec_cable_insulation",
        "category": "electrical",
        "equipment_type": "電纜",
        "inspection_item": "電纜絕緣電阻",
        "keywords": ["電纜", "cable", "絕緣"],
        "unit": "MΩ",
        "pass_condition": "gte",
        "pass_value": 1.0,
        "warning_value": 5.0,
        "regulation": "屋內線路裝置規則 第59條",
        "notes": "電力電纜對地絕緣電阻",
    },
    {
        "standard_id": "elec_ups_battery_voltage",
        "category": "electrical",
        "equipment_type": "UPS",
        "inspection_item": "UPS 電池電壓",
        "keywords": ["UPS", "電池", "battery", "voltage"],
        "unit": "V",
        "pass_condition": "range",
        "pass_value": [10.8, 13.8],
        "warning_value": None,
        "regulation": "IEEE 1188",
        "notes": "單節鉛酸蓄電池，浮充電壓",
    },
    {
        "standard_id": "elec_lightning_arrester",
        "category": "electrical",
        "equipment_type": "避雷設備",
        "inspection_item": "避雷器接地電阻",
        "keywords": ["避雷", "lightning", "SPD"],
        "unit": "Ω",
        "pass_condition": "lte",
        "pass_value": 10.0,
        "warning_value": 8.0,
        "regulation": "建築技術規則 第25條",
        "notes": "避雷導線接地電阻",
    },
    {
        "standard_id": "elec_emergency_gen_start",
        "category": "electrical",
        "equipment_type": "發電機",
        "inspection_item": "緊急發電機啟動時間",
        "keywords": ["發電機", "generator", "啟動"],
        "unit": "s",
        "pass_condition": "lte",
        "pass_value": 10.0,
        "warning_value": 8.0,
        "regulation": "消防法施行細則 第15條",
        "notes": "緊急發電機應於 10 秒內啟動供電",
    },
]

# ============ 消防設備標準 (15項) ============

FIRE_STANDARDS = [
    {
        "standard_id": "fire_extinguisher_pressure",
        "category": "fire",
        "equipment_type": "滅火器",
        "inspection_item": "滅火器壓力",
        "keywords": ["滅火器", "壓力", "extinguisher", "pressure"],
        "unit": "MPa",
        "pass_condition": "range",
        "pass_value": [0.7, 0.98],
        "warning_value": None,
        "regulation": "消防法 第6條 / 各類場所消防安全設備設置標準",
        "notes": "綠色區域為合格範圍",
    },
    {
        "standard_id": "fire_emergency_light_duration",
        "category": "fire",
        "equipment_type": "緊急照明",
        "inspection_item": "緊急照明持續時間",
        "keywords": ["緊急照明", "emergency light", "持續"],
        "unit": "min",
        "pass_condition": "gte",
        "pass_value": 30.0,
        "warning_value": 35.0,
        "regulation": "消防法 第6條",
        "notes": "停電後應持續照明至少 30 分鐘",
    },
    {
        "standard_id": "fire_emergency_light_lux",
        "category": "fire",
        "equipment_type": "緊急照明",
        "inspection_item": "緊急照明照度",
        "keywords": ["照度", "lux", "照明"],
        "unit": "lux",
        "pass_condition": "gte",
        "pass_value": 1.0,
        "warning_value": 2.0,
        "regulation": "消防法 第6條",
        "notes": "地面照度 1 lux 以上",
    },
    {
        "standard_id": "fire_smoke_detector_sensitivity",
        "category": "fire",
        "equipment_type": "偵煙探測器",
        "inspection_item": "偵煙探測器靈敏度",
        "keywords": ["偵煙", "smoke", "探測器", "靈敏度"],
        "unit": "%/m",
        "pass_condition": "range",
        "pass_value": [5.0, 20.0],
        "warning_value": None,
        "regulation": "CNS 11877",
        "notes": "光電式偵煙探測器每公尺減光率",
    },
    {
        "standard_id": "fire_sprinkler_pressure",
        "category": "fire",
        "equipment_type": "灑水設備",
        "inspection_item": "灑水頭放水壓力",
        "keywords": ["灑水", "sprinkler", "放水壓力"],
        "unit": "kgf/cm²",
        "pass_condition": "gte",
        "pass_value": 1.0,
        "warning_value": 1.5,
        "regulation": "各類場所消防安全設備設置標準 第46條",
        "notes": "最遠灑水頭放水壓力",
    },
    {
        "standard_id": "fire_hydrant_pressure",
        "category": "fire",
        "equipment_type": "消防栓",
        "inspection_item": "消防栓放水壓力",
        "keywords": ["消防栓", "hydrant", "放水壓力"],
        "unit": "kgf/cm²",
        "pass_condition": "gte",
        "pass_value": 1.7,
        "warning_value": 2.0,
        "regulation": "各類場所消防安全設備設置標準 第31條",
        "notes": "室內消防栓瞄子放水壓力",
    },
    {
        "standard_id": "fire_hydrant_flow",
        "category": "fire",
        "equipment_type": "消防栓",
        "inspection_item": "消防栓放水量",
        "keywords": ["消防栓", "hydrant", "放水量", "流量"],
        "unit": "L/min",
        "pass_condition": "gte",
        "pass_value": 130.0,
        "warning_value": 150.0,
        "regulation": "各類場所消防安全設備設置標準 第31條",
        "notes": "第一種消防栓每支瞄子放水量",
    },
    {
        "standard_id": "fire_exit_sign_lux",
        "category": "fire",
        "equipment_type": "出口標示燈",
        "inspection_item": "出口標示燈亮度",
        "keywords": ["出口", "標示燈", "exit", "亮度"],
        "unit": "cd/m²",
        "pass_condition": "gte",
        "pass_value": 50.0,
        "warning_value": 60.0,
        "regulation": "CNS 11820",
        "notes": "出口標示燈面板亮度",
    },
    {
        "standard_id": "fire_co_detector",
        "category": "fire",
        "equipment_type": "一氧化碳偵測器",
        "inspection_item": "CO 偵測器動作濃度",
        "keywords": ["CO", "一氧化碳", "carbon monoxide"],
        "unit": "ppm",
        "pass_condition": "lte",
        "pass_value": 200.0,
        "warning_value": 150.0,
        "regulation": "CNS 15440",
        "notes": "應於 CO 濃度 200ppm 以下時動作",
    },
    {
        "standard_id": "fire_fire_door_closing",
        "category": "fire",
        "equipment_type": "防火門",
        "inspection_item": "防火門關閉時間",
        "keywords": ["防火門", "fire door", "關閉"],
        "unit": "s",
        "pass_condition": "lte",
        "pass_value": 5.0,
        "warning_value": 4.0,
        "regulation": "建築技術規則 第76條",
        "notes": "防火門應能自動關閉",
    },
    # —— Session #5 新增（消防擴充，2026-05-16） ——
    {
        "standard_id": "fire_alarm_panel_indicator",
        "category": "fire",
        "equipment_type": "火警受信總機",
        "inspection_item": "火警受信總機指示燈",
        "keywords": ["受信總機", "alarm panel", "指示燈", "fire panel"],
        "unit": "",
        "pass_condition": "in_set",
        "pass_value": ["正常", "綠燈", "OK"],
        "warning_value": None,
        "regulation": "各類場所消防安全設備設置標準 第120條",
        "notes": "受信總機運轉狀態，紅燈或閃爍代表異常",
    },
    {
        "standard_id": "fire_extinguisher_gauge_zone",
        "category": "fire",
        "equipment_type": "滅火器",
        "inspection_item": "滅火器壓力錶顯示區域",
        "keywords": ["滅火器", "壓力錶", "綠區", "extinguisher gauge"],
        "unit": "",
        "pass_condition": "in_set",
        "pass_value": ["綠區", "正常", "OK"],
        "warning_value": None,
        "regulation": "CNS 1387 / 消防法 第6條",
        "notes": "目視檢查，指針落在紅區（過壓/欠壓）需更換",
    },
    {
        "standard_id": "fire_evacuation_sign_battery_duration",
        "category": "fire",
        "equipment_type": "避難方向指示燈",
        "inspection_item": "避難方向指示燈電池續航時間",
        "keywords": ["避難", "方向指示", "exit sign", "battery"],
        "unit": "min",
        "pass_condition": "gte",
        "pass_value": 20.0,
        "warning_value": 25.0,
        "regulation": "各類場所消防安全設備設置標準 第175條",
        "notes": "停電後內建電池應能維持至少 20 分鐘",
    },
    {
        "standard_id": "fire_heat_detector_response_temp",
        "category": "fire",
        "equipment_type": "定溫式探測器",
        "inspection_item": "定溫式探測器動作溫度",
        "keywords": ["定溫", "heat detector", "探測器", "動作溫度"],
        "unit": "°C",
        "pass_condition": "range",
        "pass_value": [65.0, 75.0],
        "warning_value": None,
        "regulation": "CNS 8884 / 消防安全設備設置標準",
        "notes": "標稱動作溫度範圍，公差依型式認證",
    },
    {
        "standard_id": "fire_alarm_bell_db",
        "category": "fire",
        "equipment_type": "火警警鈴",
        "inspection_item": "火警警鈴音壓",
        "keywords": ["警鈴", "alarm bell", "音壓", "dB"],
        "unit": "dB",
        "pass_condition": "gte",
        "pass_value": 90.0,
        "warning_value": 95.0,
        "regulation": "各類場所消防安全設備設置標準 第127條",
        "notes": "距警鈴 1 公尺處量測，應 ≥90 dB",
    },
]

# ============ 機械設備標準 (15項) ============

MECHANICAL_STANDARDS = [
    {
        "standard_id": "mech_motor_temp",
        "category": "mechanical",
        "equipment_type": "馬達",
        "inspection_item": "馬達溫度",
        "keywords": ["馬達", "motor", "溫度", "temperature"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 80.0,
        "warning_value": 70.0,
        "regulation": "CNS 14400 / IEC 60034",
        "notes": "B級絕緣馬達表面溫度",
    },
    {
        "standard_id": "mech_vibration",
        "category": "mechanical",
        "equipment_type": "旋轉機械",
        "inspection_item": "振動值",
        "keywords": ["振動", "vibration"],
        "unit": "mm/s",
        "pass_condition": "lte",
        "pass_value": 4.5,
        "warning_value": 3.5,
        "regulation": "ISO 10816-3",
        "notes": "Group 2 (15-75kW) 中型旋轉機械",
    },
    {
        "standard_id": "mech_bearing_temp",
        "category": "mechanical",
        "equipment_type": "軸承",
        "inspection_item": "軸承溫度",
        "keywords": ["軸承", "bearing", "溫度"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 70.0,
        "warning_value": 60.0,
        "regulation": "ISO 10816",
        "notes": "滾動軸承表面溫度",
    },
    {
        "standard_id": "mech_pump_flow",
        "category": "mechanical",
        "equipment_type": "泵浦",
        "inspection_item": "泵浦流量",
        "keywords": ["泵浦", "pump", "流量", "flow"],
        "unit": "m³/h",
        "pass_condition": "gte",
        "pass_value": None,  # 依設計值而定
        "warning_value": None,
        "regulation": "CNS 7783",
        "notes": "應不低於設計流量的 90%（需配合設計值）",
    },
    {
        "standard_id": "mech_belt_tension",
        "category": "mechanical",
        "equipment_type": "皮帶傳動",
        "inspection_item": "皮帶張力",
        "keywords": ["皮帶", "belt", "張力", "tension"],
        "unit": "mm",
        "pass_condition": "range",
        "pass_value": [10, 25],
        "warning_value": None,
        "regulation": "設備廠商規範",
        "notes": "每 100mm 跨距下壓 10-25mm 撓度",
    },
    {
        "standard_id": "mech_oil_level",
        "category": "mechanical",
        "equipment_type": "潤滑系統",
        "inspection_item": "潤滑油液位",
        "keywords": ["油位", "oil level", "潤滑油"],
        "unit": "",
        "pass_condition": "in_set",
        "pass_value": ["正常", "合格", "OK", "normal"],
        "warning_value": None,
        "regulation": "設備維護手冊",
        "notes": "油位應在上下限標記之間",
    },
    {
        "standard_id": "mech_noise_level",
        "category": "mechanical",
        "equipment_type": "旋轉機械",
        "inspection_item": "噪音值",
        "keywords": ["噪音", "noise", "dB"],
        "unit": "dB(A)",
        "pass_condition": "lte",
        "pass_value": 85.0,
        "warning_value": 80.0,
        "regulation": "職業安全衛生設施規則 第300條",
        "notes": "勞工八小時日時量平均音壓級",
    },
    {
        "standard_id": "mech_alignment",
        "category": "mechanical",
        "equipment_type": "旋轉機械",
        "inspection_item": "軸心偏移量",
        "keywords": ["偏移", "alignment", "軸心"],
        "unit": "mm",
        "pass_condition": "lte",
        "pass_value": 0.05,
        "warning_value": 0.03,
        "regulation": "ISO 10816",
        "notes": "徑向偏移量",
    },
    {
        "standard_id": "mech_fan_airflow",
        "category": "mechanical",
        "equipment_type": "風機",
        "inspection_item": "風量",
        "keywords": ["風量", "airflow", "風機", "fan"],
        "unit": "CMM",
        "pass_condition": "gte",
        "pass_value": None,
        "warning_value": None,
        "regulation": "設計規範",
        "notes": "應不低於設計風量的 90%",
    },
    {
        "standard_id": "mech_compressor_pressure",
        "category": "mechanical",
        "equipment_type": "空壓機",
        "inspection_item": "空壓機出口壓力",
        "keywords": ["空壓機", "compressor", "壓力"],
        "unit": "kgf/cm²",
        "pass_condition": "range",
        "pass_value": [6.0, 8.0],
        "warning_value": None,
        "regulation": "設備規範",
        "notes": "一般工業用空壓機出口壓力",
    },
    # —— Session #4 新增（機械類擴充，2026-05-16） ——
    {
        "standard_id": "mech_motor_insulation",
        "category": "mechanical",
        "equipment_type": "馬達",
        "inspection_item": "馬達絕緣電阻",
        "keywords": ["馬達絕緣", "motor insulation", "繞組絕緣"],
        "unit": "MΩ",
        "pass_condition": "gte",
        "pass_value": 1.0,
        "warning_value": 5.0,
        "regulation": "IEEE 43 / CNS 14400",
        "notes": "馬達停機冷態量測，最低標準為每千伏特額定電壓 1MΩ",
    },
    {
        "standard_id": "mech_motor_current_balance",
        "category": "mechanical",
        "equipment_type": "馬達",
        "inspection_item": "馬達三相電流不平衡率",
        "keywords": ["三相", "不平衡", "current balance", "phase imbalance"],
        "unit": "%",
        "pass_condition": "lte",
        "pass_value": 10.0,
        "warning_value": 5.0,
        "regulation": "NEMA MG-1 / IEEE 141",
        "notes": "不平衡率 > 10% 會顯著縮短馬達壽命並增加溫升",
    },
    {
        "standard_id": "mech_lube_oil_temp",
        "category": "mechanical",
        "equipment_type": "減速機/泵浦",
        "inspection_item": "潤滑油溫度",
        "keywords": ["潤滑油", "lube oil", "oil temperature"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 70.0,
        "warning_value": 60.0,
        "regulation": "ISO 6743 / 設備商建議",
        "notes": "油溫過高加速油品劣化、降低黏度",
    },
    {
        "standard_id": "mech_cooling_water_temp",
        "category": "mechanical",
        "equipment_type": "冷卻系統",
        "inspection_item": "冷卻水出口溫度",
        "keywords": ["冷卻水", "cooling water", "outlet temperature"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 35.0,
        "warning_value": 32.0,
        "regulation": "設備商建議",
        "notes": "冷卻塔/熱交換器出口水溫，過高代表冷卻效能不足",
    },
    {
        "standard_id": "mech_pump_seal_leakage",
        "category": "mechanical",
        "equipment_type": "泵浦",
        "inspection_item": "泵浦軸封漏液",
        "keywords": ["軸封", "seal", "leakage", "漏液", "漏油"],
        "unit": "",
        "pass_condition": "in_set",
        "pass_value": ["無", "正常", "微滲(可接受)", "OK"],
        "warning_value": None,
        "regulation": "API 682 / 設備商規範",
        "notes": "機械軸封容許微量滴漏，明顯洩漏需停機檢修",
    },
]

# ============ 壓力容器標準 (11項) ============

PRESSURE_STANDARDS = [
    {
        "standard_id": "pres_vessel_thickness",
        "category": "pressure",
        "equipment_type": "壓力容器",
        "inspection_item": "壓力容器壁厚",
        "keywords": ["壁厚", "thickness", "壓力容器"],
        "unit": "mm",
        "pass_condition": "gte",
        "pass_value": None,
        "warning_value": None,
        "regulation": "鍋爐及壓力容器安全規則 第39條",
        "notes": "不得低於設計最小壁厚",
    },
    {
        "standard_id": "pres_relief_valve",
        "category": "pressure",
        "equipment_type": "壓力容器",
        "inspection_item": "安全閥動作壓力",
        "keywords": ["安全閥", "relief valve", "安全裝置"],
        "unit": "kgf/cm²",
        "pass_condition": "lte",
        "pass_value": None,
        "warning_value": None,
        "regulation": "鍋爐及壓力容器安全規則 第42條",
        "notes": "不得超過最高使用壓力之 1.1 倍",
    },
    {
        "standard_id": "pres_boiler_water_level",
        "category": "pressure",
        "equipment_type": "鍋爐",
        "inspection_item": "鍋爐水位",
        "keywords": ["鍋爐", "boiler", "水位"],
        "unit": "",
        "pass_condition": "in_set",
        "pass_value": ["正常", "合格", "OK"],
        "warning_value": None,
        "regulation": "鍋爐及壓力容器安全規則 第51條",
        "notes": "水位應在正常操作範圍內",
    },
    {
        "standard_id": "pres_pipe_pressure_test",
        "category": "pressure",
        "equipment_type": "壓力管路",
        "inspection_item": "管路耐壓試驗",
        "keywords": ["管路", "pipe", "耐壓"],
        "unit": "kgf/cm²",
        "pass_condition": "gte",
        "pass_value": None,
        "warning_value": None,
        "regulation": "鍋爐及壓力容器安全規則",
        "notes": "試驗壓力為最高使用壓力之 1.5 倍，維持 30 分鐘無洩漏",
    },
    {
        "standard_id": "pres_boiler_stack_temp",
        "category": "pressure",
        "equipment_type": "鍋爐",
        "inspection_item": "鍋爐排氣溫度",
        "keywords": ["排氣", "stack", "煙囪", "排煙"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 250.0,
        "warning_value": 220.0,
        "regulation": "鍋爐效率管理規範",
        "notes": "排氣溫度過高表示熱交換效率不足",
    },
    # —— Session #3 新增（壓力/管線擴充，2026-05-16） ——
    {
        "standard_id": "pres_boiler_feedwater_ph",
        "category": "pressure",
        "equipment_type": "鍋爐",
        "inspection_item": "鍋爐給水 pH 值",
        "keywords": ["pH", "給水", "feedwater", "酸鹼"],
        "unit": "",
        "pass_condition": "range",
        "pass_value": [8.5, 10.5],
        "warning_value": None,
        "regulation": "CNS 10861 鍋爐用水水質",
        "notes": "pH 過低易腐蝕、過高易結垢；爐水範圍以鍋爐使用壓力為準",
    },
    {
        "standard_id": "pres_boiler_feedwater_hardness",
        "category": "pressure",
        "equipment_type": "鍋爐",
        "inspection_item": "鍋爐給水硬度",
        "keywords": ["硬度", "hardness", "給水", "CaCO3"],
        "unit": "mg/L",
        "pass_condition": "lte",
        "pass_value": 1.0,
        "warning_value": 0.5,
        "regulation": "CNS 10861 鍋爐用水水質",
        "notes": "以 CaCO3 計，硬度過高易在加熱面結垢降低熱效率",
    },
    {
        "standard_id": "pres_steam_insulation_surface_temp",
        "category": "pressure",
        "equipment_type": "蒸汽管路",
        "inspection_item": "保溫外表面溫度",
        "keywords": ["保溫", "insulation", "管路表面", "燙傷"],
        "unit": "°C",
        "pass_condition": "lte",
        "pass_value": 60.0,
        "warning_value": 50.0,
        "regulation": "職業安全衛生設施規則 第229條",
        "notes": "勞工易接觸之高溫管路表面溫度應降至 60°C 以下防灼傷",
    },
    {
        "standard_id": "pres_chimney_co_concentration",
        "category": "pressure",
        "equipment_type": "鍋爐",
        "inspection_item": "煙道 CO 濃度",
        "keywords": ["CO", "一氧化碳", "煙道", "排煙"],
        "unit": "ppm",
        "pass_condition": "lte",
        "pass_value": 400.0,
        "warning_value": 300.0,
        "regulation": "鍋爐效率管理規範 / 固定污染源空污排放標準",
        "notes": "CO 高表示燃燒不完全，需調整空燃比",
    },
    {
        "standard_id": "pres_relief_valve_seal_intact",
        "category": "pressure",
        "equipment_type": "壓力容器",
        "inspection_item": "安全閥鉛封完整性",
        "keywords": ["鉛封", "安全閥", "seal"],
        "unit": "",
        "pass_condition": "in_set",
        "pass_value": ["完整", "良好", "OK"],
        "warning_value": None,
        "regulation": "鍋爐及壓力容器安全規則 第42條",
        "notes": "鉛封破損代表設定壓力可能遭更動，須重新校驗",
    },
    {
        "standard_id": "pres_pressure_gauge_calibration",
        "category": "pressure",
        "equipment_type": "壓力容器",
        "inspection_item": "壓力錶檢校有效期",
        "keywords": ["壓力錶", "gauge", "檢校", "校驗"],
        "unit": "",
        "pass_condition": "in_set",
        "pass_value": ["有效", "在期", "OK"],
        "warning_value": None,
        "regulation": "度量衡法 / 鍋爐及壓力容器安全規則",
        "notes": "壓力錶應依規定期間檢校，過期需更換或送驗",
    },
]


# ============ 統一標準資料庫 ============

ALL_STANDARDS = (
    ELECTRICAL_STANDARDS +
    FIRE_STANDARDS +
    MECHANICAL_STANDARDS +
    PRESSURE_STANDARDS
)


# ============ 單位正規化與換算 ============
#
# AI 從照片抽取的讀數，單位寫法常與標準不一致（例如 kΩ vs MΩ、℃ vs °C、
# Mohm vs MΩ）。若直接拿原始數值與標準閾值比較，會造成嚴重的誤判
# （例如 500 kΩ = 0.5 MΩ 應為不合格，卻因 500 ≥ 1.0 被判合格）。
# 以下提供單位正規化與同維度換算，於判定前先把讀數轉成標準單位。

# 變體寫法 → 標準寫法（區分大小寫，優先比對）
_UNIT_ALIASES = {
    "℃": "°C", "C": "°C",
    "℉": "°F", "F": "°F",
    "Mohm": "MΩ", "MOhm": "MΩ", "MΩ": "MΩ",
    "kohm": "kΩ", "kOhm": "kΩ", "Kohm": "kΩ",
    "Gohm": "GΩ", "GOhm": "GΩ",
    "ohm": "Ω", "Ohm": "Ω", "OHM": "Ω",
    "uΩ": "μΩ", "uohm": "μΩ",
    "uA": "μA", "uV": "μV", "um": "μm",
    "kgf/cm2": "kgf/cm²", "kg/cm²": "kgf/cm²", "kg/cm2": "kgf/cm²",
    "cd/m2": "cd/m²", "m3/h": "m³/h", "m3/min": "CMM",
}

# 不分大小寫的變體（小寫鍵）
_UNIT_ALIASES_CI = {
    "degc": "°C", "°c": "°C", "oc": "°C", "deg c": "°C",
    "degf": "°F", "°f": "°F", "of": "°F", "deg f": "°F",
}

# 同維度換算：單位 → (維度, 對基準單位的倍率)
# value_in_base = value * factor
_CONVERSION_FACTORS = {
    # 電阻，基準 Ω
    "Ω": ("resistance", 1.0),
    "mΩ": ("resistance", 1e-3),
    "μΩ": ("resistance", 1e-6),
    "kΩ": ("resistance", 1e3),
    "MΩ": ("resistance", 1e6),
    "GΩ": ("resistance", 1e9),
    # 電流，基準 A
    "A": ("current", 1.0),
    "mA": ("current", 1e-3),
    "μA": ("current", 1e-6),
    "kA": ("current", 1e3),
    # 電壓，基準 V
    "V": ("voltage", 1.0),
    "mV": ("voltage", 1e-3),
    "kV": ("voltage", 1e3),
    # 壓力，基準 kPa
    "Pa": ("pressure", 1e-3),
    "kPa": ("pressure", 1.0),
    "MPa": ("pressure", 1e3),
    "bar": ("pressure", 100.0),
    "mbar": ("pressure", 0.1),
    "kgf/cm²": ("pressure", 98.0665),
    "psi": ("pressure", 6.894757),
    "atm": ("pressure", 101.325),
    # 時間，基準 s
    "s": ("time", 1.0),
    "ms": ("time", 1e-3),
    "min": ("time", 60.0),
    "h": ("time", 3600.0),
    # 長度，基準 mm
    "mm": ("length", 1.0),
    "cm": ("length", 10.0),
    "m": ("length", 1000.0),
    "μm": ("length", 1e-3),
    "km": ("length", 1e6),
    # 速度，基準 mm/s
    "mm/s": ("velocity", 1.0),
    "cm/s": ("velocity", 10.0),
    "m/s": ("velocity", 1000.0),
}


def normalize_unit(unit: str) -> str:
    """將單位變體寫法正規化為標準寫法。無對應者原樣回傳（去空白）。"""
    if unit is None:
        return ""
    u = unit.strip()
    if not u:
        return ""
    if u in _UNIT_ALIASES:
        return _UNIT_ALIASES[u]
    lowered = u.lower()
    if lowered in _UNIT_ALIASES_CI:
        return _UNIT_ALIASES_CI[lowered]
    return u


def convert_value(value, from_unit: str, to_unit: str):
    """
    將 value 由 from_unit 換算為 to_unit。

    回傳 (converted_value, ok)：
    - ok=True 表示成功換算（含兩單位相同的情形）
    - ok=False 表示無法換算（單位空白、非數值、或維度不相容）
    """
    fu = normalize_unit(from_unit)
    tu = normalize_unit(to_unit)
    if not fu or not tu:
        return (None, False)

    try:
        v = float(value)
    except (ValueError, TypeError):
        return (None, False)

    if fu == tu:
        return (v, True)

    # 溫度為仿射換算，需特別處理
    if fu in ("°C", "°F") and tu in ("°C", "°F"):
        if fu == "°F" and tu == "°C":
            return ((v - 32.0) * 5.0 / 9.0, True)
        if fu == "°C" and tu == "°F":
            return (v * 9.0 / 5.0 + 32.0, True)
        return (v, True)

    a = _CONVERSION_FACTORS.get(fu)
    b = _CONVERSION_FACTORS.get(tu)
    if a and b and a[0] == b[0]:
        base = v * a[1]
        return (base / b[1], True)

    return (None, False)


class InspectionStandardsDB:
    """定檢標準值資料庫查詢引擎"""

    def __init__(self, standards: list[dict] = None):
        self.standards = standards or ALL_STANDARDS

    def get_all(self) -> list[dict]:
        """取得所有標準"""
        return self.standards

    def get_by_category(self, category: str) -> list[dict]:
        """按大類查詢"""
        return [s for s in self.standards if s["category"] == category]

    def get_by_id(self, standard_id: str) -> Optional[dict]:
        """按 ID 查詢"""
        for s in self.standards:
            if s["standard_id"] == standard_id:
                return s
        return None

    def convert_value(self, value, from_unit: str, to_unit: str):
        """將讀數由 from_unit 換算為 to_unit。回傳 (converted_value, ok)。"""
        return convert_value(value, from_unit, to_unit)

    def find_matching_standard(
        self,
        field_name: str,
        unit: str = "",
        equipment_type: str = "",
    ) -> Optional[dict]:
        """
        根據欄位名稱、單位、設備類型 模糊匹配最佳標準

        匹配邏輯:
        1. 必須先有「欄位名稱」相關性（inspection_item 或 keyword 命中）才列為候選，
           避免不相干欄位僅因設備類型/單位相同就被硬湊到某條標準而產生假判定。
        2. 單位、設備類型僅作為加分（tie-break），不能單獨成為候選。
        """
        candidates = []
        field_lower = field_name.lower().strip()

        for std in self.standards:
            # 欄位名稱相關性（必要條件）
            name_score = 0
            if std["inspection_item"] in field_name or field_name in std["inspection_item"]:
                name_score += 10
            for kw in std.get("keywords", []):
                if kw.lower() in field_lower:
                    name_score += 3

            # 名稱完全不相關者不列入候選
            if name_score == 0:
                continue

            score = name_score

            # 單位匹配加分（正規化後比對，使 Mohm/℃ 等變體也能匹配）
            if unit and std["unit"] and normalize_unit(unit) == normalize_unit(std["unit"]):
                score += 5

            # 設備類型匹配加分
            if equipment_type:
                if equipment_type in std.get("equipment_type", ""):
                    score += 4
                elif std.get("equipment_type", "") in equipment_type:
                    score += 3

            candidates.append((score, std))

        if not candidates:
            return None

        # 回傳最高分的
        candidates.sort(key=lambda x: x[0], reverse=True)
        return candidates[0][1]

    def judge_value(
        self,
        standard: dict,
        measured_value,
    ) -> dict:
        """
        根據標準值判定量測值

        回傳:
        {
            "judgment": "pass" | "fail" | "warning" | "unknown",
            "standard_text": ">=1.0 MΩ",
            "regulation": "屋內線路裝置規則 第59條",
        }
        """
        condition = standard.get("pass_condition")
        pass_val = standard.get("pass_value")
        warning_val = standard.get("warning_value")
        unit = standard.get("unit", "")
        regulation = standard.get("regulation", "")

        # 如果沒有標準值，無法判定
        if pass_val is None:
            return {
                "judgment": "unknown",
                "standard_text": f"依設計值 ({unit})" if unit else "依設計值",
                "regulation": regulation,
            }

        # in_set 比較（文字值）
        if condition == "in_set":
            value_str = str(measured_value).strip()
            is_pass = value_str in pass_val
            return {
                "judgment": "pass" if is_pass else "fail",
                "standard_text": f"必須為: {'/'.join(pass_val)}",
                "regulation": regulation,
            }

        # 數值型比較
        try:
            num_val = float(measured_value)
        except (ValueError, TypeError):
            return {
                "judgment": "unknown",
                "standard_text": self._format_standard_text(condition, pass_val, unit),
                "regulation": regulation,
            }

        standard_text = self._format_standard_text(condition, pass_val, unit)

        if condition == "gte":
            if num_val >= pass_val:
                if warning_val is not None and num_val < warning_val:
                    return {"judgment": "warning", "standard_text": standard_text, "regulation": regulation}
                return {"judgment": "pass", "standard_text": standard_text, "regulation": regulation}
            return {"judgment": "fail", "standard_text": standard_text, "regulation": regulation}

        elif condition == "lte":
            if num_val <= pass_val:
                if warning_val is not None and num_val > warning_val:
                    return {"judgment": "warning", "standard_text": standard_text, "regulation": regulation}
                return {"judgment": "pass", "standard_text": standard_text, "regulation": regulation}
            return {"judgment": "fail", "standard_text": standard_text, "regulation": regulation}

        elif condition == "range":
            min_val, max_val = pass_val[0], pass_val[1]
            if min_val <= num_val <= max_val:
                return {"judgment": "pass", "standard_text": standard_text, "regulation": regulation}
            return {"judgment": "fail", "standard_text": standard_text, "regulation": regulation}

        elif condition == "eq":
            if abs(num_val - pass_val) < 0.001:
                return {"judgment": "pass", "standard_text": standard_text, "regulation": regulation}
            return {"judgment": "fail", "standard_text": standard_text, "regulation": regulation}

        return {"judgment": "unknown", "standard_text": standard_text, "regulation": regulation}

    def _format_standard_text(self, condition: str, pass_val, unit: str) -> str:
        """格式化標準值文字"""
        if condition == "gte":
            return f"≥{pass_val} {unit}".strip()
        elif condition == "lte":
            return f"≤{pass_val} {unit}".strip()
        elif condition == "range":
            return f"{pass_val[0]}~{pass_val[1]} {unit}".strip()
        elif condition == "eq":
            return f"={pass_val} {unit}".strip()
        elif condition == "in_set":
            return f"{'|'.join(str(v) for v in pass_val)}"
        return str(pass_val)

    def get_stats(self) -> dict:
        """取得標準資料庫統計"""
        categories = {}
        for s in self.standards:
            cat = s["category"]
            categories[cat] = categories.get(cat, 0) + 1

        return {
            "total": len(self.standards),
            "categories": categories,
            "with_regulation": sum(1 for s in self.standards if s.get("regulation")),
        }

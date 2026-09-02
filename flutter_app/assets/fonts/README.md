# assets/fonts

| 檔案 | 用途 | 授權 |
|------|------|------|
| `NotoSansTC-Regular-subset.ttf` | PDF 報告（`lib/services/pdf_report_service.dart`）內嵌繁中字型；Big5 全字元 + Latin/希臘/單位符號子集，約 4.9 MB | SIL Open Font License 1.1（`OFL.txt`） |

- 來源：Google Fonts [Noto Sans TC](https://fonts.google.com/noto/specimen/Noto+Sans+TC)（可變字型固定為 Regular 400）
- 重新產生：`python flutter_app/scripts/subset_pdf_font.py <NotoSansTC[wght].ttf>`（腳本內有說明）
- 為何內嵌而非系統字型：PDF 需跨裝置一致顯示，且產品原則為「斷網可完成拍照 → 判定 → 匯出」，
  不能依賴網路下載字型；Android 也沒有可靠的系統繁中 TTF 路徑可讀。
- `pdf` 套件輸出時只嵌入實際用到的字元，單份報告的字型負擔通常 < 200 KB。

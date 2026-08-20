# MT5 Demo to Real Copy Trade EA

Expert Advisor สำหรับ MetaTrader 5 (MQL5 ล้วน ไม่มี DLL ไม่มี WebRequest) ที่คัดลอกคำสั่งเทรดจาก
บัญชี **DEMO (Master)** ไปยังบัญชี **REAL (Slave)** แบบเรียลไทม์ ผ่านไฟล์ใน **Common Files Folder**
ของ MT5 (โฟลเดอร์เดียวที่ทุก Terminal บนเครื่องเดียวกันมองเห็นร่วมกัน)

EA ตัวเดียว ใช้ได้ 2 บทบาท เลือกจาก input `CopyMode`:

| CopyMode | รันที่ไหน | หน้าที่ |
|---|---|---|
| `MODE_MASTER` | Terminal บัญชี DEMO | อ่านสถานะบัญชี+Position+Pending Order แล้วเขียนเป็น "Snapshot" ลงไฟล์ทุกครั้งที่มีการเทรด และซ้ำทุก 1 วินาที |
| `MODE_SLAVE` | Terminal บัญชี REAL | อ่าน Snapshot แล้ว "reconcile" (เทียบ+ปรับ) Position/Pending Order ของตัวเองให้ตรงกับ Master |

## โครงสร้างไฟล์

```
mt5-ea/
├── MQL5/
│   ├── Experts/CopyTrade/
│   │   └── MT5_DemoToReal_CopyTrade.mq5      <- EA หลัก (ไฟล์เดียวที่ compile)
│   └── Include/CopyTrade/
│       ├── Logger.mqh          Log ระดับ DEBUG/INFO/TRADE/WARNING/ERROR -> Journal + ไฟล์
│       ├── FileProtocol.mqh    รูปแบบไฟล์ Snapshot/Heartbeat, atomic write, CRC32, SHA-256 hash
│       ├── SymbolMapper.mqh    แปลงชื่อ Symbol ระหว่างโบรกเกอร์ (manual/prefix/suffix/auto-scan)
│       ├── AccountValidator.mqh ตรวจ DEMO/REAL, Hedging/Netting
│       ├── RiskManager.mqh     Daily loss %, Drawdown %, Max positions/lots, Spread guard
│       ├── TradeManager.mqh    ครอบ CTrade พร้อมตรวจ retcode จริง + retry ตาม policy
│       └── CopyManager.mqh     ตรรกะหลัก: CMasterEngine + CSlaveEngine
└── docs/
    ├── Installation.md
    ├── Configuration.md
    ├── Testing.md
    └── Troubleshooting.md
```

## สถาปัตยกรรม (สรุปสั้น)

- **ไม่มี Event-log แยก** — Master สร้าง **Full Snapshot** (สถานะ ณ ปัจจุบันทั้งหมด) ทับไฟล์เดียวทุกครั้ง
  ด้วย `OnTradeTransaction()` (เร็ว) และซ้ำอีกทีทุก `UpdateIntervalSeconds` วินาทีผ่าน `OnTimer()`
  (กัน Master พลาด event หรือ terminal reconnect) เขียนแบบ **atomic**: เขียนลง `.tmp` ก่อนแล้ว
  `FileMove` เปลี่ยนชื่อทับ `.dat` — Slave จึงไม่มีทางอ่านไฟล์ที่เขียนค้างอยู่ครึ่งเดียว
- **ไม่มี "state file" แยกสำหรับกันซ้ำ** — Slave ระบุว่า Position ใดถูก copy ไปแล้วโดยดูจาก
  **Magic Number + Comment** (`COPY|MASTER_LOGIN|MASTER_POSITION_ID`) ของ Position/Order ที่มีอยู่จริง
  ใน MT5 เท่านั้น วิธีนี้ทำให้ **Duplicate Protection กับ Restart Recovery เป็นกลไกเดียวกัน**
  โดยอัตโนมัติ — Restart เมื่อไหร่ก็ได้ ระบบ scan ของจริงในบัญชีแล้วเทียบกับ Snapshot ใหม่เสมอ
- **CRC32 + PROTOCOL_VERSION** ป้องกันไฟล์เสีย/เขียนไม่ครบ — ถ้า checksum ไม่ตรงหรือ version ไม่รู้จัก
  Slave จะไม่เทรดในรอบนั้นเลย (skip cycle, log ERROR)
- **Heartbeat แยกไฟล์** จาก Snapshot — Slave เช็ค heartbeat ก่อนเสมอ ถ้าเกิน `MasterTimeoutSeconds`
  จะถือว่า Master ออฟไลน์ และ**ไม่เปิดเทรดใหม่**ระหว่างนั้น (ปิด Position เดิมหรือไม่ ขึ้นกับ
  `CloseTradesWhenMasterOffline`)

## ข้อจำกัดที่ต้องรู้ก่อนใช้งานจริง (อ่านให้ครบ)

1. **รองรับเฉพาะ Hedging Account เท่านั้น (v1)** — ถ้า Slave เป็นบัญชี Netting EA จะปฏิเสธการเทรดทันที
   พร้อม log ERROR อธิบายเหตุผล (Netting รวมหลาย Position ต่อ Symbol เป็นก้อนเดียว ทำให้ map
   Position ต่อ Position แบบ 1:1 ไม่ได้แม่นยำ) — ไม่มีการ "เดา" วิธีแก้แบบเงียบๆ
2. **ราคาตอน Copy Market Order ใช้ราคาจริงของฝั่ง Slave เสมอ** (Ask สำหรับ BUY, Bid สำหรับ SELL)
   ไม่เคย copy ราคาจาก Master ตรงๆ
3. **Pending Order แปลงราคาโดยใช้ "ระยะห่างจากราคาตลาด" ไม่ใช่ราคาตรงๆ** — Master บันทึกราคาตลาด
   ของตัวเอง ณ เวลา snapshot ไปด้วย (`market_price_ref`) แล้ว Slave คำนวณระยะห่างเดิมมาเทียบกับ
   ราคาตลาดของตัวเอง ถ้า Master ไม่มี tick ราคาในจังหวะนั้น (ตลาดปิด) EA จะ fallback ไปใช้ราคาตรงจาก
   Master พร้อม log WARNING ชัดเจนว่ากำลังทำเช่นนั้น
4. **Lot ที่คำนวณได้ต่ำกว่า Volume ขั้นต่ำของโบรกเกอร์ = ไม่เปิด** (ไม่ปัดขึ้นให้ เพราะจะเป็นการ
   "เพิ่ม Lot เอง" ซึ่งขัดกับข้อกำหนด) ส่วน Lot ที่เกิน Volume สูงสุด จะถูก "หั่นลง" มาเท่ากับสูงสุด (ปลอดภัยกว่า)
5. **Pending Order ที่ Trigger บน Master** ถูก map กลับไปยัง Pending Order เดิมของ Slave ผ่านฟิลด์
   `source_order_id` (Master สืบจาก Deal History ว่า Position เกิดจาก Order ใบไหน) — ป้องกันการเปิดซ้ำ
   ตอน Pending Order ถูก Trigger
6. **`#property strict` ไม่ได้ใส่ในไฟล์ .mq5** เพราะเป็น pragma ของ MQL4 เท่านั้น ไม่มีผลใดๆ ใน MQL5
   (MQL5 บังคับ strict type-checking อยู่แล้วเป็นค่าเริ่มต้น) — ใส่ไปจะไม่มีผลอะไร จึงตัดออกตามหลัก
   "ไม่ทำอะไรที่ไม่มีความหมาย" แทนที่จะใส่ตามฟอร์มไปเฉยๆ
7. **`OnlyManageCopiedTrades`** มีไว้เป็น input ตามสเปก แต่พฤติกรรม "ห้ามยุ่งกับ Position ที่ไม่ได้
   สร้างโดย EA" ถูก**บังคับใช้เสมอ**ในระดับ engine (เช็ค Magic Number + Comment tag ทุกจุดที่แตะ
   Position/Order) ตั้งเป็น false จะได้แค่ log คำเตือนว่าค่านี้ถูกมองข้าม เพื่อไม่ให้เกิดพฤติกรรมเสี่ยง
   แบบเงียบๆ

## เอกสารเพิ่มเติม

- [docs/Installation.md](docs/Installation.md) — ติดตั้ง Terminal 2 ตัว, Common Folder, EA
- [docs/Configuration.md](docs/Configuration.md) — คำอธิบาย Input ทุกตัว
- [docs/Testing.md](docs/Testing.md) — TestMode/DryRun + Test Plan 15 ข้อ
- [docs/Troubleshooting.md](docs/Troubleshooting.md) — ปัญหาที่พบบ่อยและวิธีแก้

## Quick Start

1. เปิด MT5 2 ตัว (คนละ instance/คนละโฟลเดอร์ติดตั้ง) — ตัวหนึ่ง Login DEMO, อีกตัว Login REAL
2. Copy โฟลเดอร์ `MQL5/Experts/CopyTrade/` และ `MQL5/Include/CopyTrade/` ไปวางใน `MQL5/` ของ
   **ทั้งสอง** Terminal (ทับ path เดิม)
3. เปิด MetaEditor แล้ว Compile `MT5_DemoToReal_CopyTrade.mq5` (F7) — ต้องไม่มี Error
4. ที่ Terminal DEMO: ลาก EA ขึ้นชาร์ต ตั้ง `CopyMode = MODE_MASTER`
5. ที่ Terminal REAL: ลาก EA ขึ้นชาร์ต ตั้ง `CopyMode = MODE_SLAVE`, `TestMode = true` ก่อนเสมอ
6. เปิด Journal ทั้งสองฝั่ง ดู log `[INFO]` ยืนยันว่า publish/read snapshot สำเร็จ และ Dashboard
   บนชาร์ตแสดง `MASTER CONNECTION: ONLINE`
7. ทดสอบเปิด/ปิด/แก้ Order บน DEMO แล้วดู log ฝั่ง SLAVE ว่าขึ้น `[TEST] Would ...` ตรงตามที่คาด
8. ผ่านการทดสอบแล้วค่อยปิด `TestMode` บน Slave (อ่าน docs/Testing.md ก่อน)

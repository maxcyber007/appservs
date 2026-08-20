# Testing Guide

## ขั้นตอนการทดสอบก่อนใช้เงินจริง (บังคับ)

1. ตั้งฝั่ง Slave: `TestMode = true` (ค่าเริ่มต้นอยู่แล้ว)
2. เปิด `EnableDebugLog = true` ชั่วคราวทั้งสองฝั่ง เพื่อเห็น log ละเอียดที่สุด
3. เปิด Journal (Ctrl+J) ทั้งสอง Terminal ค้างไว้ตลอดการทดสอบ
4. ทำตาม Test Plan ด้านล่างทีละข้อ **ห้ามข้าม**
5. ผ่านครบทุกข้อแล้วค่อยพิจารณาปิด `TestMode` — แนะนำให้เปิด `DryRun = true` อีกสักพักก่อน (จะไม่
   ยุ่งกับสถานะจริง แต่จะเห็นว่า EA "จะ" ทำอะไรบ้างในสถานการณ์จริง) ก่อนปิดทั้งคู่

## Test Plan (15 ข้อ)

| # | สถานการณ์ | ขั้นตอนทดสอบ | ผลที่ควรเห็น |
|---|---|---|---|
| 1 | Master เปิด BUY | เปิด Order BUY บน Master ด้วยมือ | Journal ฝั่ง Slave ขึ้น `Master detected BUY ...` ตามด้วย `[TEST] Would BUY ...` |
| 2 | Master เปิด SELL | เปิด Order SELL บน Master | เหมือนข้อ 1 แต่เป็น SELL |
| 3 | Master Close | ปิด Position ที่เปิดไว้ในบน Master ทั้งหมด | Slave log `Master position closed -> Slave CLOSE ...` |
| 4 | Master Partial Close | เปิด Position 0.10 lot แล้วปิดบางส่วน (เช่น 0.04) | Slave log `Master partial close detected -> Slave partial close volume=...` ปริมาณตามสัดส่วน Lot ที่ตั้งไว้ |
| 5 | Master Modify SL | แก้ SL ของ Position ที่เปิดอยู่ | Slave log `Master SL/TP change detected -> Slave modify sl=...` |
| 6 | Master Modify TP | แก้ TP | เหมือนข้อ 5 แต่เป็น tp |
| 7 | Master Restart | ปิด-เปิด Terminal ฝั่ง Master ใหม่ (มี Position ค้างอยู่) | ไม่มี Log เปิดซ้ำฝั่ง Slave สำหรับ Position เดิม (เพราะ Master จะ publish Snapshot รอบใหม่ที่มี Position เดิมอยู่ ตรงกับที่ Slave "ถือ" อยู่แล้ว — ในโหมด TestMode ให้ตรวจจาก log ว่าไม่มีบรรทัด `Would BUY/SELL` ซ้ำสำหรับ copy_id เดิม) |
| 8 | Slave Restart | ปิด-เปิด Terminal ฝั่ง Slave ใหม่ | Log แสดง `SLAVE initialized` ใหม่ แล้ว reconcile รอบแรกไม่เปิดซ้ำ Position ที่มี comment tag ตรงกับ Master อยู่แล้ว |
| 9 | File Corrupted | ปิด Master EA ชั่วคราว แล้วแก้ไฟล์ `Common\Files\CopyTrade\MasterToSlave_Snapshot.dat` ด้วยมือ (เช่น ลบบรรทัดท้ายทิ้ง) | Slave log `ERROR ... Checksum mismatch` หรือ `Missing END marker` และไม่เทรดรอบนั้น |
| 10 | Master Offline | ปิด Master Terminal ทั้งตัว (หรือลบ EA ออกจากชาร์ต) รอเกิน `MasterTimeoutSeconds` | Slave Dashboard ขึ้น `MASTER CONNECTION: OFFLINE`, log `Master heartbeat stale` หรือ `Master OFFLINE`, ไม่มีการเปิด Position ใหม่ |
| 11 | Insufficient Margin | ตั้ง Lot ให้สูงเกินทุนของบัญชี Slave (เช่น `LotMultiplier` สูงมาก) | Slave log `ERROR ... Insufficient margin for ... required=... free=...` และไม่เปิด Position |
| 12 | Spread Too High | ตั้ง `MaxSpreadPoints` ต่ำมาก (เช่น 1) แล้วเปิด Order บน Master | Slave log `Spread too high on ... deferred` และไม่เปิด (ถ้า `CopyDelayedTrades=false` จะ log `permanently skipped` ด้วย) |
| 13 | Different Symbol Name | ตั้ง `ManualSymbolMapping = "XAUUSD=XAUUSDtest"` (ชื่อสมมติที่ไม่มีจริง) แล้วเปิด Order XAUUSD บน Master | Slave log `ERROR ... Symbol mapping failed` เพราะ symbol ปลายทางไม่มีจริง/เทรดไม่ได้ |
| 14 | Different Lot Step | เปิด Order บน Master ด้วย Lot ที่เมื่อคูณ Multiplier แล้วไม่ลงตัวกับ `SYMBOL_VOLUME_STEP` ของ Slave (เช่น step=0.01 แต่คำนวณได้ 0.017) | Lot ที่ log ออกมาต้องถูกปัด**ลง**ให้ลงตัวกับ step เสมอ (ไม่ปัดขึ้น) |
| 15 | Market Closed | ทดสอบนอกเวลาเทรดของ Symbol นั้น (เช่น เสาร์-อาทิตย์) หรือ Symbol ที่ปิดตลาด | Slave log `No valid tick / market closed for ... skipping` และไม่เทรด |

## การตรวจสอบ Log

- Journal (มุมล่างของ MT5): เห็นทุกบรรทัดแบบเรียลไทม์
- ไฟล์ log (ถ้า `LogToFile=true`): `[Data Folder]\MQL5\Files\CopyTrade\Master_YYYYMMDD.log` หรือ
  `Slave_YYYYMMDD.log` — เปิดด้วย Notepad ได้ตรงๆ
- Dashboard บนชาร์ต: ดูค่า `COPY SUCCESS` / `COPY FAILED` สะสมได้แบบคร่าวๆ ระหว่างทดสอบ

## หลังผ่านการทดสอบครบ

1. ปิด `EnableDebugLog` กลับเป็น `false` (log จะได้ไม่รก)
2. ปิด `TestMode = false` บน Slave **เท่านั้น** เมื่อมั่นใจแล้วจริงๆ
3. เริ่มด้วย Lot เล็กที่สุดเท่าที่โบรกเกอร์อนุญาต (`LotMode = LOT_FIXED`, `FixedLot` = ค่าต่ำสุด) ก่อน
   สักระยะ แล้วค่อยปรับเป็นโหมด/อัตราส่วนที่ต้องการจริง

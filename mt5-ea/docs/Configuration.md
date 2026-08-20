# Configuration Guide

คำอธิบาย Input ทั้งหมด จัดกลุ่มตามที่ปรากฏใน MetaTrader (input group)

## --- GENERAL ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `CopyMode` | `MODE_MASTER` | `MODE_MASTER` = รันที่บัญชี DEMO, `MODE_SLAVE` = รันที่บัญชี REAL |
| `EnableDebugLog` | `false` | เปิดจะเห็น log ระดับ `[DEBUG]` เพิ่ม (ละเอียดมาก) |
| `LogToFile` | `true` | เขียน log ลง `MQL5\Files\CopyTrade\Master_YYYYMMDD.log` หรือ `Slave_...` ด้วย (นอกจากขึ้น Journal) |
| `UpdateIntervalSeconds` | `1` | ความถี่ในการ publish snapshot (ฝั่ง Master) หรือ reconcile (ฝั่ง Slave) |

## --- MASTER ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `RequireDemoMaster` | `true` | ถ้าบัญชีที่รันเป็น MASTER ไม่ใช่ DEMO จริง EA จะปฏิเสธไม่ทำงาน (ป้องกันเผลอตั้งบัญชี REAL เป็น Master) |

## --- SLAVE ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `RequireRealAccount` | `true` | ถ้าบัญชี Slave ไม่ใช่ REAL จริง EA จะปฏิเสธไม่เทรด |
| `SlaveMagicNumber` | `26082026` | Magic Number เฉพาะของ Order ที่ EA copy มา ห้ามซ้ำกับ EA ตัวอื่นในบัญชีเดียวกัน |
| `OnlyManageCopiedTrades` | `true` | เก็บไว้ตามสเปก — พฤติกรรมนี้ EA บังคับใช้เสมออยู่แล้ว (ดู README ข้อจำกัดข้อ 7) |

## --- LOT ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `LotMode` | `LOT_MULTIPLIER` | `LOT_FIXED` / `LOT_MULTIPLIER` / `LOT_BALANCE_RATIO` / `LOT_EQUITY_RATIO` |
| `FixedLot` | `0.01` | ใช้เมื่อ `LotMode = LOT_FIXED` — ทุก Position ใช้ lot นี้เท่ากันหมด |
| `LotMultiplier` | `1.0` | ตัวคูณสำหรับโหมด MULTIPLIER/BALANCE_RATIO/EQUITY_RATIO |

รายละเอียดสูตร:
- **LOT_FIXED**: `slave_lot = FixedLot` เสมอ
- **LOT_MULTIPLIER**: `slave_lot = master_lot * LotMultiplier`
- **LOT_BALANCE_RATIO**: `slave_lot = master_lot * (slave_balance / master_balance) * LotMultiplier`
- **LOT_EQUITY_RATIO**: `slave_lot = master_lot * (slave_equity / master_equity) * LotMultiplier`

ทุกโหมดจะถูก normalize ตาม `SYMBOL_VOLUME_MIN/MAX/STEP` ของ Symbol ฝั่ง Slave เสมอ ถ้าปัดแล้วต่ำกว่า
ค่าต่ำสุด **จะไม่เปิด Position นั้นเลย** (ไม่ปัดขึ้นให้ เพราะถือเป็นการเพิ่ม Lot เอง)

## --- SYMBOL ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `EnableAutoSymbolMapping` | `true` | เปิดให้ EA เดา Symbol ฝั่ง Slave อัตโนมัติด้วย prefix/suffix แล้วสแกนหาชื่อที่ใกล้เคียง |
| `SymbolPrefix` | `""` | เติมหน้าไปก่อนชื่อ Master symbol เวลาเดา เช่น `"m."` |
| `SymbolSuffix` | `""` | เติมท้าย เช่น `"m"` (XAUUSD -> XAUUSDm) |
| `ManualSymbolMapping` | `""` | รายการ mapping ตายตัว รูปแบบ `"XAUUSD=XAUUSDm;EURUSD=EURUSD.a"` — มีสิทธิ์เหนือ auto mapping เสมอ |

ลำดับการค้นหา Symbol: (1) Manual mapping ตรงตัว -> (2) ชื่อเดียวกันเป๊ะ -> (3) ถ้าเปิด Auto:
prefix+symbol+suffix -> (4) สแกนชื่อ Symbol ทั้งหมดของโบรกเกอร์หาชื่อที่มีคำว่า Master symbol
อยู่ในนั้น ถ้าหาไม่เจอเลย **จะไม่เทรด Symbol นั้น** พร้อม log ERROR ระบุชื่อ Master symbol

## --- SLIPPAGE ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `MaxDeviationPoints` | `20` | ค่า Deviation (slippage) สูงสุดที่ยอมรับตอนส่งคำสั่ง Market Order |

## --- SL/TP ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `SLTPMode` | `SLTP_MODE_COPY` | `SLTP_MODE_NONE` ไม่ตั้ง SL/TP เลย / `SLTP_MODE_COPY` คัดลอกระยะห่างจาก Master / `SLTP_MODE_DISTANCE` ใช้ระยะคงที่ (points) |
| `CopySL` | `true` | เปิด/ปิดการคัดลอก SL (ใช้ร่วมกับ SLTPMode) |
| `CopyTP` | `true` | เปิด/ปิดการคัดลอก TP |
| `SLDistancePoints` | `0` | ใช้เมื่อ `SLTPMode = SLTP_MODE_DISTANCE` เท่านั้น — ระยะ SL เป็น points จากราคาเปิดฝั่ง Slave |
| `TPDistancePoints` | `0` | เช่นเดียวกันสำหรับ TP |

**SLTP_MODE_COPY ทำงานอย่างไร:** คำนวณ "ระยะห่างราคา" ระหว่างราคาเปิดกับ SL/TP ของ Master แล้วนำ
ระยะนั้น (หน่วยราคา ไม่ใช่ points) ไปบวก/ลบจากราคาเปิดจริงของ Slave — วิธีนี้ไม่ต้องอาศัยสมมติฐานว่า
Digits/Point ของสอง broker เท่ากัน หากระยะที่ได้ผิดกฎ `SYMBOL_TRADE_STOPS_LEVEL` ของโบรกเกอร์ Slave
EA จะขยายระยะให้พอดีกับขั้นต่ำที่โบรกเกอร์กำหนด (ปลอดภัยกว่าการไม่ตั้ง SL เลย)

## --- PENDING ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `EnablePendingOrders` | `true` | เปิดให้ copy Pending Order (Limit/Stop/Stop-Limit) ด้วย ไม่ใช่แค่ Market Position |

## --- RISK ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `MaxDailyLossPercent` | `5.0` | ถ้า Equity ของ Slave ลดลงเกิน % นี้จากค่า Equity ตอนต้นวัน จะหยุดเปิดเทรดใหม่ (0 = ปิดการเช็ค) |
| `MaxEquityDrawdownPercent` | `10.0` | ถ้า Equity ลดลงเกิน % นี้จากจุดสูงสุดที่เคยทำได้ (peak) จะหยุดเปิดเทรดใหม่ (0 = ปิด) |
| `MaxOpenPositions` | `20` | จำนวน Position ที่ copy ได้พร้อมกันสูงสุด (0 = ปิด) |
| `MaxTotalLots` | `5.0` | รวม Lot ของ Position ที่ copy ทั้งหมดห้ามเกินนี้ (0 = ปิด) |
| `EnableSpreadFilter` | `true` | เปิดการเช็ค Spread ก่อนเปิด Position ใหม่ |
| `MaxSpreadPoints` | `50` | Spread สูงสุดที่ยอมให้เปิด (points) |
| `CopyDelayedTrades` | `false` | ถ้า Spread สูงเกินตอนนั้น: `false` = ข้าม Position นั้นไปถาวร (ไม่ลองใหม่อีกแม้ Spread จะกลับปกติ), `true` = ลองใหม่ทุกรอบจนกว่าจะสำเร็จหรือ Master ปิด Position นั้น |

ทุก Limit ข้างบนมีผลแค่ **"หยุดเปิดเทรดใหม่"** เท่านั้น — Position ที่เปิดค้างอยู่แล้วจะไม่ถูกปิด
อัตโนมัติ เว้นแต่เปิด `EmergencyCloseAll`

## --- CONNECTION ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `MasterTimeoutSeconds` | `10` | ถ้า Slave ไม่เห็น Heartbeat ใหม่จาก Master เกินกี่วินาที ถือว่า Master offline |

## --- SAFETY ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `CloseTradesWhenMasterOffline` | `false` | ถ้า Master ขาดการติดต่อเกิน timeout: `true` = ปิด Position ที่ copy มาทั้งหมด, `false` = ปล่อยไว้เฉยๆ (ค่าเริ่มต้น เพื่อกันการปิดโดยไม่ตั้งใจ) |
| `EmergencyCloseAll` | `false` | ถ้า `true` และชน Limit `MaxDailyLossPercent`/`MaxEquityDrawdownPercent` จะปิด Position ที่ copy มาทั้งหมดทันที |

## --- SECURITY ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `CopyPassword` | `""` | รหัสลับร่วม (ใส่ค่าเดียวกันทั้ง Master และ Slave) ใช้ยืนยันว่า snapshot มาจาก Master ที่ตั้งใจจริง ค่านี้จะถูกแฮชด้วย SHA-256 ก่อนเขียนลงไฟล์เสมอ ไม่มีการเก็บรหัสผ่านแบบข้อความล้วนที่ใดเลย เว้นว่างเพื่อปิดการเช็คนี้ |

## --- RETRY ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `MaxRetryCount` | `3` | จำนวนครั้งที่ลองส่งคำสั่งซ้ำเมื่อเจอ error ชั่วคราว (Requote/Price Changed/Connection/Timeout/Too Many Requests) |
| `RetryDelayMilliseconds` | `300` | หน่วงเวลาระหว่างแต่ละครั้งที่ retry |

**หมายเหตุ:** จะไม่ retry เด็ดขาดถ้า error เป็น Invalid Volume, Invalid Stops, Not Enough Money,
Market Closed หรือ Trade Disabled — เพราะ retry ไปก็ได้ผลเหมือนเดิม มีแต่จะยิ่งดีเลย์

## --- TEST MODE ---

| Input | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `TestMode` | `true` | `true` = ไม่ส่งคำสั่งจริง แค่ log `[TEST] Would BUY ...` ไว้ดู — **ตั้ง true เสมอตอนติดตั้งครั้งแรก** |
| `DryRun` | `false` | เหมือน TestMode แต่แยก tag log เป็น `[DRYRUN]` — ใช้เพื่อดูการคำนวณ (lot/SL/TP) โดยไม่ยุ่งกับสถานะจริง |

# Troubleshooting Guide

## Dashboard ฝั่ง Slave ค้างที่ `MASTER CONNECTION: OFFLINE`

1. เช็ค `COMMON PATH:` บน Dashboard ทั้งสองฝั่งว่าตรงกันเป๊ะ — ถ้าไม่ตรง แปลว่า MT5 สองตัวรันคนละ
   Windows user account กัน หรือ MT5 ตัวใดตัวหนึ่งใช้ portable mode ที่แยก data folder ออกไป
   (แก้โดยรันทั้งคู่ภายใต้ user account เดียวกัน)
2. เช็คว่า Master EA รันอยู่จริงและมีหน้ายิ้ม (Expert enabled) มุมขวาบนของชาร์ต ไม่ใช่หน้าเศร้า
3. เช็ค **Tools > Options > Expert Advisors > Allow algorithmic trading** เปิดอยู่ทั้งสองฝั่ง
4. เช็ค Journal ฝั่ง Master ว่ามี error ตอนเขียนไฟล์หรือไม่ (เช่น `Failed to write heartbeat`) —
   ถ้ามักเกิดจากสิทธิ์เขียนไฟล์ใน Common Folder ไม่พอ ลองรัน MT5 ในโหมด "Run as Administrator" ทั้งคู่
5. เช็คนาฬิกาเครื่อง/Server time ต่างกันมากผิดปกติหรือไม่ (Heartbeat ใช้ `TimeCurrent()` เทียบกับ
   `MasterTimeoutSeconds`)

## Slave ไม่เปิด Position เลยทั้งที่ Master เปิดแล้ว

ไล่เช็คตามลำดับที่ EA ตรวจสอบจริง (อ่านจาก log จะบอกสาเหตุตรงๆ อยู่แล้ว):

| Log ที่เห็น | สาเหตุ | วิธีแก้ |
|---|---|---|
| `Symbol mapping failed` | หา Symbol ฝั่ง Slave ไม่เจอ | ตั้ง `ManualSymbolMapping` หรือ `SymbolSuffix/Prefix` ให้ตรงกับชื่อจริงของโบรกเกอร์ Slave |
| `Trading disabled for ...` / `is close-only` | Symbol นั้นเทรดไม่ได้ตอนนี้ (ตลาดปิด/ปิดชั่วคราว) | รอเปิดตลาด หรือเช็คใน Market Watch ว่า symbol enable อยู่ |
| `No valid tick / market closed` | ไม่มีราคาล่าสุดของ symbol นั้น | เปิด symbol ใน Market Watch ของ Slave ก่อน (คลิกขวา > Show All หรือ Symbols... > เพิ่ม) |
| `Spread too high on ...` | Spread ตอนนั้นเกิน `MaxSpreadPoints` | ปรับ `MaxSpreadPoints` ให้เหมาะกับ symbol นั้น (Gold/Exotic pair spread สูงกว่าปกติ) |
| `Risk limit blocks new trades` | ชน `MaxDailyLossPercent`/`MaxEquityDrawdownPercent` | ตรวจสอบว่าตั้งใจหรือไม่ ถ้าไม่ตั้งใจให้ปรับค่าหรือรอวันถัดไป (reset ทุกเที่ยงคืน) |
| `Max open positions reached` | ชน `MaxOpenPositions` | ปิด Position เก่าบางส่วน หรือปรับค่าให้สูงขึ้น |
| `Calculated lot invalid/below broker minimum` | Lot ที่คำนวณได้ต่ำกว่า `SYMBOL_VOLUME_MIN` ของ Slave | เพิ่ม `LotMultiplier` หรือใช้ `LOT_FIXED` แทน |
| `Insufficient margin` | เงินในบัญชี Slave ไม่พอเปิด Lot ขนาดนั้น | ลด Lot / เติมทุน / ใช้ `LOT_BALANCE_RATIO` |
| ไม่มี log อะไรเลย | `TestMode`/`DryRun` เปิดอยู่ (ตั้งใจ) หรือ `CopyMode` ตั้งผิดฝั่ง | เช็ค input ให้ตรง |

## Log ขึ้น `Unsupported Protocol Version`

Master กับ Slave ใช้คนละเวอร์ชันไฟล์ EA (ไฟล์ `.mqh`/`.mq5` ไม่ตรงกันระหว่างสอง Terminal) —
Copy ไฟล์ทั้งชุดจากโปรเจกต์เดียวกันไปวางทั้งสองฝั่งใหม่ แล้ว Compile ใหม่ทั้งคู่

## Log ขึ้น `Checksum mismatch` บ่อยๆ

ปกติไม่ควรเกิดเลยเพราะเขียนไฟล์แบบ atomic (`.tmp` แล้วค่อย rename) — ถ้าเกิดถี่ๆ ให้เช็ค:

- โปรแกรมป้องกันไวรัส/แบ็คอัพ (เช่น OneDrive sync) กำลัง lock ไฟล์ในโฟลเดอร์ Common Files อยู่หรือไม่
  — เพิ่ม exception ให้โฟลเดอร์นี้
- มี Master EA มากกว่า 1 ตัวรันพร้อมกันเขียนไฟล์เดียวกันชนกันหรือไม่ (ควรมี Master ตัวเดียวต่อ 1 ชุด
  Common Folder เท่านั้น)

## Slave ปฏิเสธไม่เทรดตั้งแต่ `OnInit`

| Log | สาเหตุ |
|---|---|
| `Slave account is NOT a REAL account but RequireRealAccount=true` | Login ผิดบัญชี หรือทดสอบด้วย Demo จริง — ถ้าตั้งใจทดสอบบน Demo ให้ตั้ง `RequireRealAccount=false` ชั่วคราว |
| `Slave account is a NETTING account` | บัญชีนี้เป็น Netting mode ซึ่ง v1 ยังไม่รองรับ (ดู README ข้อจำกัดข้อ 1) — ต้องใช้บัญชี Hedging |
| `Master account is NOT a DEMO account but RequireDemoMaster=true` | ตั้ง `CopyMode=MODE_MASTER` ผิดฝั่ง (ไปตั้งที่บัญชี REAL) |

## Pending Order ราคาที่ Slave ได้ดูเพี้ยนจาก Master มาก

ปกติ EA แปลงราคาด้วย "ระยะห่างจากราคาตลาดปัจจุบัน" ไม่ใช่ราคาตรงๆ (ดู README ข้อจำกัดข้อ 3) —
ถ้า log ขึ้น `Master had no live tick for ... falling back to literal price` แปลว่า Master ไม่มี
ราคาล่าสุดของ symbol นั้นตอนสร้าง snapshot (เช่น Symbol นั้นไม่ได้เปิดอยู่ใน Market Watch ของ Master)
ให้เพิ่ม symbol นั้นใน Market Watch ฝั่ง Master ด้วย

## ต้องการหยุด EA ฉุกเฉิน

1. ลาก EA ออกจากชาร์ต หรือกดปุ่ม "หน้ายิ้ม" มุมขวาบนของชาร์ตให้เป็นหน้าเศร้า (ปิด Algo Trading เฉพาะ
   EA นั้น) — Position ที่เปิดค้างจะไม่ถูกปิดอัตโนมัติ ต้องปิดเองด้วยมือถ้าต้องการ
2. หากต้องการให้ EA ปิด Position ที่ copy มาทั้งหมดอัตโนมัติเมื่อชน risk limit ให้เปิด
   `EmergencyCloseAll = true` ล่วงหน้า (ไม่มีปุ่ม "ปิดทั้งหมดทันที" แบบ manual ใน EA นี้ตามสเปกที่ระบุ
   ว่าห้ามปิด Position อัตโนมัติโดยไม่ได้เปิด option ไว้ก่อน)

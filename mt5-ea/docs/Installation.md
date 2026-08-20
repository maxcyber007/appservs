# Installation Guide

## 1. ติดตั้ง MT5 Terminal 2 ตัว

MetaTrader 5 ปกติอนุญาตให้ติดตั้งได้หลาย instance บนเครื่องเดียวกัน ตราบใดที่แต่ละตัวอยู่คนละโฟลเดอร์:

1. ดาวน์โหลดตัวติดตั้ง MT5 จากโบรกเกอร์ของบัญชี DEMO -> ติดตั้งลงโฟลเดอร์ เช่น `C:\MT5-Demo\`
2. ดาวน์โหลดตัวติดตั้ง MT5 จากโบรกเกอร์ของบัญชี REAL -> ติดตั้งลงโฟลเดอร์ เช่น `C:\MT5-Real\`
3. เปิดทั้งสองตัวพร้อมกันได้ตามปกติ (แต่ละตัวมี process แยกกัน)

> ถ้าบัญชี DEMO และ REAL อยู่ที่**โบรกเกอร์เดียวกัน** ก็ยังต้องรันเป็นคนละ Terminal instance
> (คนละโฟลเดอร์ติดตั้ง หรือ MT5 portable mode คนละ path) เพราะ MT5 หนึ่ง Terminal Login ได้ทีละ
> 1 บัญชีเท่านั้น

## 2. ตรวจสอบ Common Files Folder

EA ใช้ **Common Files Folder** เป็นช่องทางสื่อสาร ซึ่งเป็นโฟลเดอร์เดียวกันสำหรับ**ทุก MT5 Terminal
ที่ติดตั้งบนเครื่อง/user account เดียวกัน** (ไม่ขึ้นกับว่าติดตั้งคนละโฟลเดอร์หรือ Login คนละบัญชี)

วิธีดู path: ใน MT5 ไปที่ **File > Open Data Folder** แล้วดู path ของ `Common\Files` หรือให้ EA
บอกให้เอง — Dashboard บนชาร์ต (บรรทัด `COMMON PATH:`) และ Journal ตอน `OnInit()` จะพิมพ์ path นี้
ออกมาเสมอ (มาจาก `TerminalInfoString(TERMINAL_COMMONDATA_PATH)`)

**สำคัญ:** เปิด Dashboard ทั้งสอง Terminal เทียบ `COMMON PATH:` ให้เหมือนกันเป๊ะ ถ้าไม่เหมือนกัน
แปลว่า Master กับ Slave เขียน/อ่านคนละโฟลเดอร์ ระบบจะไม่เห็นกันเลย (แก้โดยรัน MT5 ทั้งสองตัวด้วย
Windows user account เดียวกัน)

## 3. ติดตั้งไฟล์ EA ลงทั้งสอง Terminal

ทำ**เหมือนกันทุกขั้นตอน**กับทั้งสอง Terminal (DEMO และ REAL):

1. เปิด MT5 -> **File > Open Data Folder** -> เข้าไปที่ `MQL5\`
2. Copy โฟลเดอร์จากโปรเจกต์นี้:
   - `MQL5/Experts/CopyTrade/` -> วางทับใน `MQL5/Experts/`
   - `MQL5/Include/CopyTrade/` -> วางทับใน `MQL5/Include/`
3. เปิด **MetaEditor** (กด F4 ใน MT5) -> เปิดไฟล์ `Experts/CopyTrade/MT5_DemoToReal_CopyTrade.mq5`
4. กด **F7 (Compile)** -> ต้องเห็น `0 error(s), 0 warning(s)` (หรือมี warning เล็กน้อยเรื่อง unused
   parameter ใน `OnTradeTransaction` ซึ่งไม่กระทบการทำงาน) แล้วจะได้ไฟล์
   `MT5_DemoToReal_CopyTrade.ex5` ในโฟลเดอร์เดียวกัน
5. กลับไปที่ MT5 -> Navigator (Ctrl+N) -> Expert Advisors -> ต้องเห็น `CopyTrade\MT5_DemoToReal_CopyTrade`

ทำซ้ำขั้นตอน 1-5 กับ Terminal อีกตัว

## 4. ตั้งค่าบัญชี DEMO (Master)

1. Login เข้าบัญชี DEMO ผ่าน Terminal ตัวแรก (**File > Login to Trade Account**)
2. เปิด **Tools > Options > Expert Advisors** -> ติ๊ก **Allow algorithmic trading**
3. ลาก EA `MT5_DemoToReal_CopyTrade` จาก Navigator ไปวางบนชาร์ตของ Symbol ใดก็ได้ (ชาร์ตที่วาง
   ไม่จำเป็นต้องตรงกับ Symbol ที่จะเทรด — EA อ่านทุก Position/Order ของทั้งบัญชี ไม่ใช่แค่ชาร์ตนั้น)
4. ในหน้าต่าง Inputs: ตั้ง **`CopyMode = MODE_MASTER`**, `RequireDemoMaster = true`
5. ในแท็บ **Common** ของหน้าต่าง EA settings: ติ๊ก **Allow Algo Trading**
6. กด OK — ดู Journal ต้องขึ้น `MASTER initialized. login=... type=DEMO`

## 5. ตั้งค่าบัญชี REAL (Slave)

1. Login เข้าบัญชี REAL ผ่าน Terminal ตัวที่สอง
2. เปิด **Tools > Options > Expert Advisors** -> ติ๊ก **Allow algorithmic trading**
3. ลาก EA เดียวกันไปวางบนชาร์ต
4. ในหน้าต่าง Inputs: ตั้ง **`CopyMode = MODE_SLAVE`**, `RequireRealAccount = true`,
   **`TestMode = true`** (บังคับให้เป็น true ในการติดตั้งครั้งแรกเสมอ — อย่าเพิ่งปิด)
5. ตั้งค่า Lot / Symbol Mapping / Risk ตาม [Configuration.md](Configuration.md)
6. กด OK — ดู Journal ต้องขึ้น `WARNING: REAL ACCOUNT COPY TRADE ENABLED` ตามด้วย
   `SLAVE initialized. login=... type=REAL`

## 6. ยืนยันว่าทั้งสองฝั่งเห็นกัน

เปิด Dashboard บนชาร์ตทั้งสองฝั่ง (มุมซ้ายบน):

- ฝั่ง Slave ต้องเห็น `MASTER CONNECTION: ONLINE` ภายในไม่กี่วินาที
- ถ้ายังเป็น `OFFLINE` ให้ดู [Troubleshooting.md](Troubleshooting.md)

## 7. ไปทดสอบต่อที่ Testing.md

**อย่าปิด `TestMode` จนกว่าจะทดสอบตาม [Testing.md](Testing.md) ครบทุกข้อ**

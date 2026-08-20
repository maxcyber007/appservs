//+------------------------------------------------------------------+
//|                                                 FileProtocol.mqh |
//|  Shared file-based communication protocol between MASTER and     |
//|  SLAVE terminals via the Common Files folder (no DLL, no         |
//|  WebRequest). Plain delimited text, atomic write (.tmp->rename), |
//|  versioned, CRC32-protected.                                     |
//+------------------------------------------------------------------+
#ifndef __CT_FILEPROTOCOL_MQH__
#define __CT_FILEPROTOCOL_MQH__

#define CT_PROTOCOL_VERSION 1

const string CT_DIR             = "CopyTrade\\";
const string CT_SNAPSHOT_FILE   = "CopyTrade\\MasterToSlave_Snapshot.dat";
const string CT_SNAPSHOT_TMP    = "CopyTrade\\MasterToSlave_Snapshot.tmp";
const string CT_HEARTBEAT_FILE  = "CopyTrade\\MasterToSlave_Heartbeat.dat";
const string CT_HEARTBEAT_TMP   = "CopyTrade\\MasterToSlave_Heartbeat.tmp";

//--- record of one MASTER position -----------------------------------
struct CopyPositionRecord
  {
   string            copy_id;         // MASTERLOGIN_POSITIONID
   long              position_id;     // POSITION_IDENTIFIER on master
   string            symbol;
   int               type;            // POSITION_TYPE_BUY / POSITION_TYPE_SELL
   double            volume;
   double            price_open;
   double            sl;
   double            tp;
   long              magic;
   string            comment;
   datetime          time_open;
   long              source_order_id; // master pending-order ticket that triggered this position, 0 if none
  };

//--- record of one MASTER pending order --------------------------------
struct CopyOrderRecord
  {
   string            copy_id;         // MASTERLOGIN_Oorderticket
   long              order_id;        // order ticket on master
   string            symbol;
   int               type;            // ORDER_TYPE_* (pending types only)
   double            volume;
   double            price_open;
   double            price_stoplimit;
   double            sl;
   double            tp;
   long              magic;
   string            comment;
   datetime          expiration;
   double            market_price_ref; // master's live bid/ask at snapshot time (relevant side); used
                                        // to translate the pending price by DISTANCE, never copied raw
  };

//--- full state of the master account ----------------------------------
struct MasterSnapshot
  {
   int               version;
   long              master_login;
   string            master_server;
   int               account_trade_mode;   // ENUM_ACCOUNT_TRADE_MODE
   int               account_margin_mode;  // ENUM_ACCOUNT_MARGIN_MODE
   datetime          timestamp;
   double            balance;
   double            equity;
   double            margin;
   double            free_margin;
   string            currency;
   int               leverage;
   string            password_hash;
   CopyPositionRecord positions[];
   CopyOrderRecord    orders[];
  };

struct MasterHeartbeat
  {
   int               version;
   long              login;
   string            server;
   datetime          timestamp;
   double            balance;
   double            equity;
   datetime          last_trade_time;
   string            password_hash;
  };

//+------------------------------------------------------------------+
//| CRC32 (no lookup table, bit-by-bit; snapshots are small)         |
//+------------------------------------------------------------------+
uint CT_CRC32(const string &text)
  {
   uchar bytes[];
   int len = StringToCharArray(text, bytes, 0, -1, CP_UTF8);
   if(len > 0 && bytes[len-1] == 0)
      len--; // drop terminating zero added by StringToCharArray

   uint crc = 0xFFFFFFFF;
   for(int i = 0; i < len; i++)
     {
      crc ^= (uint)bytes[i];
      for(int j = 0; j < 8; j++)
        {
         if((crc & 1) != 0)
            crc = (crc >> 1) ^ 0xEDB88320;
         else
            crc = crc >> 1;
        }
     }
   return ~crc;
  }

//+------------------------------------------------------------------+
//| Strip protocol-delimiter / line-break characters from free text  |
//+------------------------------------------------------------------+
string CT_SanitizeField(const string value)
  {
   string s = value;
   StringReplace(s, "|", "/");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
  }

//+------------------------------------------------------------------+
//| SHA-256 password hash (built-in CryptEncode, no plaintext stored)|
//+------------------------------------------------------------------+
string CT_HashPassword(const string password)
  {
   if(password == "")
      return "";

   uchar data[];
   int len = StringToCharArray(password, data, 0, -1, CP_UTF8);
   if(len > 0 && data[len-1] == 0)
      ArrayResize(data, len-1);

   uchar key[];
   uchar result[];
   int res = CryptEncode(CRYPT_HASH_SHA256, data, key, result);
   if(res <= 0)
      return "";

   string hex = "";
   for(int i = 0; i < ArraySize(result); i++)
      hex += StringFormat("%02X", result[i]);
   return hex;
  }

//+------------------------------------------------------------------+
//| Build a Master<->Slave copy identifier                           |
//+------------------------------------------------------------------+
string CT_BuildPositionCopyId(const long master_login, const long position_id)
  {
   return StringFormat("%d_%d", master_login, position_id);
  }

string CT_BuildOrderCopyId(const long master_login, const long order_ticket)
  {
   return StringFormat("%d_O%d", master_login, order_ticket);
  }

//+------------------------------------------------------------------+
//| Atomically write the master snapshot (tmp file then rename)      |
//+------------------------------------------------------------------+
bool CT_WriteMasterSnapshot(const MasterSnapshot &snap, string &error)
  {
   string body = "";
   body += StringFormat("VERSION|%d\r\n", snap.version);
   body += StringFormat("MASTER_LOGIN|%d\r\n", (int)snap.master_login);
   body += StringFormat("MASTER_SERVER|%s\r\n", CT_SanitizeField(snap.master_server));
   body += StringFormat("ACCOUNT_TRADE_MODE|%d\r\n", snap.account_trade_mode);
   body += StringFormat("ACCOUNT_MARGIN_MODE|%d\r\n", snap.account_margin_mode);
   body += StringFormat("TIMESTAMP|%d\r\n", (long)snap.timestamp);
   body += StringFormat("BALANCE|%.2f\r\n", snap.balance);
   body += StringFormat("EQUITY|%.2f\r\n", snap.equity);
   body += StringFormat("MARGIN|%.2f\r\n", snap.margin);
   body += StringFormat("FREEMARGIN|%.2f\r\n", snap.free_margin);
   body += StringFormat("CURRENCY|%s\r\n", CT_SanitizeField(snap.currency));
   body += StringFormat("LEVERAGE|%d\r\n", snap.leverage);
   body += StringFormat("PASSWORD_HASH|%s\r\n", snap.password_hash);

   int pos_count = ArraySize(snap.positions);
   body += StringFormat("POSITION_COUNT|%d\r\n", pos_count);
   for(int i = 0; i < pos_count; i++)
     {
      CopyPositionRecord r = snap.positions[i];
      body += StringFormat("POSITION|%s|%d|%s|%d|%.2f|%.5f|%.5f|%.5f|%d|%s|%d|%d\r\n",
                            r.copy_id, r.position_id, r.symbol, r.type, r.volume,
                            r.price_open, r.sl, r.tp, r.magic,
                            CT_SanitizeField(r.comment), (long)r.time_open, r.source_order_id);
     }

   int ord_count = ArraySize(snap.orders);
   body += StringFormat("ORDER_COUNT|%d\r\n", ord_count);
   for(int i = 0; i < ord_count; i++)
     {
      CopyOrderRecord o = snap.orders[i];
      body += StringFormat("ORDER|%s|%d|%s|%d|%.2f|%.5f|%.5f|%.5f|%.5f|%d|%s|%d|%.5f\r\n",
                            o.copy_id, o.order_id, o.symbol, o.type, o.volume,
                            o.price_open, o.price_stoplimit, o.sl, o.tp, o.magic,
                            CT_SanitizeField(o.comment), (long)o.expiration, o.market_price_ref);
     }

   uint crc = CT_CRC32(body);
   string full = body + StringFormat("CRC|%u\r\n", crc) + "END\r\n";

   int handle = FileOpen(CT_SNAPSHOT_TMP, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      error = StringFormat("FileOpen(tmp) failed err=%d", GetLastError());
      return false;
     }
   FileWriteString(handle, full);
   FileFlush(handle);
   FileClose(handle);

   ResetLastError();
   if(!FileMove(CT_SNAPSHOT_TMP, FILE_COMMON, CT_SNAPSHOT_FILE, FILE_COMMON|FILE_REWRITE))
     {
      error = StringFormat("FileMove failed err=%d", GetLastError());
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Read all lines of a common text file into a string array         |
//+------------------------------------------------------------------+
bool CT_ReadAllLines(const string filename, string &lines[], string &error)
  {
   if(!FileIsExist(filename, FILE_COMMON))
     {
      error = "File not found: " + filename;
      return false;
     }

   ResetLastError();
   int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
     {
      error = StringFormat("FileOpen failed err=%d", GetLastError());
      return false;
     }

   int count = 0;
   ArrayResize(lines, 0);
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      if(FileIsEnding(handle) && line == "")
         break;
      ArrayResize(lines, count + 1);
      lines[count] = line;
      count++;
     }
   FileClose(handle);
   return true;
  }

//+------------------------------------------------------------------+
//| Validate structure (VERSION/END/CRC) and return the body lines   |
//+------------------------------------------------------------------+
bool CT_ValidateAndStrip(const string &lines[], string &data_lines[], string &error)
  {
   int count = ArraySize(lines);
   if(count < 3)
     {
      error = "File too short / incomplete";
      return false;
     }
   if(lines[count-1] != "END")
     {
      error = "Missing END marker - file incomplete or corrupted";
      return false;
     }

   string crc_parts[];
   if(StringSplit(lines[count-2], '|', crc_parts) != 2 || crc_parts[0] != "CRC")
     {
      error = "Missing CRC marker - file incomplete or corrupted";
      return false;
     }
   uint expected_crc = (uint)StringToInteger(crc_parts[1]);

   string body = "";
   int data_count = count - 2;
   ArrayResize(data_lines, data_count);
   for(int i = 0; i < data_count; i++)
     {
      data_lines[i] = lines[i];
      body += lines[i] + "\r\n";
     }

   uint actual_crc = CT_CRC32(body);
   if(actual_crc != expected_crc)
     {
      error = StringFormat("Checksum mismatch (expected=%u actual=%u) - file corrupted/torn write", expected_crc, actual_crc);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Read + validate the master snapshot                              |
//+------------------------------------------------------------------+
bool CT_ReadMasterSnapshot(MasterSnapshot &snap, string &error)
  {
   string lines[];
   if(!CT_ReadAllLines(CT_SNAPSHOT_FILE, lines, error))
      return false;

   string data[];
   if(!CT_ValidateAndStrip(lines, data, error))
      return false;

   ArrayResize(snap.positions, 0);
   ArrayResize(snap.orders, 0);
   int pos_n = 0, ord_n = 0;
   bool got_version = false;

   for(int i = 0; i < ArraySize(data); i++)
     {
      string parts[];
      int n = StringSplit(data[i], '|', parts);
      if(n < 2)
         continue;
      string tag = parts[0];

      if(tag == "VERSION")
        {
         snap.version = (int)StringToInteger(parts[1]);
         got_version = true;
        }
      else if(tag == "MASTER_LOGIN")     snap.master_login = StringToInteger(parts[1]);
      else if(tag == "MASTER_SERVER")    snap.master_server = parts[1];
      else if(tag == "ACCOUNT_TRADE_MODE")  snap.account_trade_mode = (int)StringToInteger(parts[1]);
      else if(tag == "ACCOUNT_MARGIN_MODE") snap.account_margin_mode = (int)StringToInteger(parts[1]);
      else if(tag == "TIMESTAMP")        snap.timestamp = (datetime)StringToInteger(parts[1]);
      else if(tag == "BALANCE")          snap.balance = StringToDouble(parts[1]);
      else if(tag == "EQUITY")           snap.equity = StringToDouble(parts[1]);
      else if(tag == "MARGIN")           snap.margin = StringToDouble(parts[1]);
      else if(tag == "FREEMARGIN")       snap.free_margin = StringToDouble(parts[1]);
      else if(tag == "CURRENCY")         snap.currency = parts[1];
      else if(tag == "LEVERAGE")         snap.leverage = (int)StringToInteger(parts[1]);
      else if(tag == "PASSWORD_HASH")    snap.password_hash = (n >= 2 ? parts[1] : "");
      else if(tag == "POSITION" && n == 13)
        {
         ArrayResize(snap.positions, pos_n + 1);
         snap.positions[pos_n].copy_id          = parts[1];
         snap.positions[pos_n].position_id      = StringToInteger(parts[2]);
         snap.positions[pos_n].symbol           = parts[3];
         snap.positions[pos_n].type             = (int)StringToInteger(parts[4]);
         snap.positions[pos_n].volume           = StringToDouble(parts[5]);
         snap.positions[pos_n].price_open       = StringToDouble(parts[6]);
         snap.positions[pos_n].sl               = StringToDouble(parts[7]);
         snap.positions[pos_n].tp               = StringToDouble(parts[8]);
         snap.positions[pos_n].magic            = StringToInteger(parts[9]);
         snap.positions[pos_n].comment          = parts[10];
         snap.positions[pos_n].time_open        = (datetime)StringToInteger(parts[11]);
         snap.positions[pos_n].source_order_id  = StringToInteger(parts[12]);
         pos_n++;
        }
      else if(tag == "ORDER" && n == 14)
        {
         ArrayResize(snap.orders, ord_n + 1);
         snap.orders[ord_n].copy_id           = parts[1];
         snap.orders[ord_n].order_id          = StringToInteger(parts[2]);
         snap.orders[ord_n].symbol            = parts[3];
         snap.orders[ord_n].type              = (int)StringToInteger(parts[4]);
         snap.orders[ord_n].volume            = StringToDouble(parts[5]);
         snap.orders[ord_n].price_open        = StringToDouble(parts[6]);
         snap.orders[ord_n].price_stoplimit   = StringToDouble(parts[7]);
         snap.orders[ord_n].sl                = StringToDouble(parts[8]);
         snap.orders[ord_n].tp                = StringToDouble(parts[9]);
         snap.orders[ord_n].magic             = StringToInteger(parts[10]);
         snap.orders[ord_n].comment           = parts[11];
         snap.orders[ord_n].expiration        = (datetime)StringToInteger(parts[12]);
         snap.orders[ord_n].market_price_ref  = StringToDouble(parts[13]);
         ord_n++;
        }
     }

   if(!got_version)
     {
      error = "Snapshot missing VERSION field";
      return false;
     }
   if(snap.version != CT_PROTOCOL_VERSION)
     {
      error = StringFormat("Unsupported Protocol Version (file=%d, expected=%d)", snap.version, CT_PROTOCOL_VERSION);
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Write heartbeat (atomic tmp->rename)                              |
//+------------------------------------------------------------------+
bool CT_WriteHeartbeat(const MasterHeartbeat &hb, string &error)
  {
   string body = "";
   body += StringFormat("VERSION|%d\r\n", hb.version);
   body += StringFormat("LOGIN|%d\r\n", (int)hb.login);
   body += StringFormat("SERVER|%s\r\n", CT_SanitizeField(hb.server));
   body += StringFormat("TIMESTAMP|%d\r\n", (long)hb.timestamp);
   body += StringFormat("BALANCE|%.2f\r\n", hb.balance);
   body += StringFormat("EQUITY|%.2f\r\n", hb.equity);
   body += StringFormat("LAST_TRADE_TIME|%d\r\n", (long)hb.last_trade_time);
   body += StringFormat("PASSWORD_HASH|%s\r\n", hb.password_hash);

   uint crc = CT_CRC32(body);
   string full = body + StringFormat("CRC|%u\r\n", crc) + "END\r\n";

   int handle = FileOpen(CT_HEARTBEAT_TMP, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      error = StringFormat("FileOpen(tmp) failed err=%d", GetLastError());
      return false;
     }
   FileWriteString(handle, full);
   FileFlush(handle);
   FileClose(handle);

   ResetLastError();
   if(!FileMove(CT_HEARTBEAT_TMP, FILE_COMMON, CT_HEARTBEAT_FILE, FILE_COMMON|FILE_REWRITE))
     {
      error = StringFormat("FileMove failed err=%d", GetLastError());
      return false;
     }
   return true;
  }

bool CT_ReadHeartbeat(MasterHeartbeat &hb, string &error)
  {
   string lines[];
   if(!CT_ReadAllLines(CT_HEARTBEAT_FILE, lines, error))
      return false;

   string data[];
   if(!CT_ValidateAndStrip(lines, data, error))
      return false;

   bool got_version = false;
   for(int i = 0; i < ArraySize(data); i++)
     {
      string parts[];
      int n = StringSplit(data[i], '|', parts);
      if(n < 2)
         continue;
      string tag = parts[0];

      if(tag == "VERSION")      { hb.version = (int)StringToInteger(parts[1]); got_version = true; }
      else if(tag == "LOGIN")   hb.login = StringToInteger(parts[1]);
      else if(tag == "SERVER")  hb.server = parts[1];
      else if(tag == "TIMESTAMP")        hb.timestamp = (datetime)StringToInteger(parts[1]);
      else if(tag == "BALANCE")          hb.balance = StringToDouble(parts[1]);
      else if(tag == "EQUITY")           hb.equity = StringToDouble(parts[1]);
      else if(tag == "LAST_TRADE_TIME")  hb.last_trade_time = (datetime)StringToInteger(parts[1]);
      else if(tag == "PASSWORD_HASH")    hb.password_hash = (n >= 2 ? parts[1] : "");
     }

   if(!got_version)
     {
      error = "Heartbeat missing VERSION field";
      return false;
     }
   if(hb.version != CT_PROTOCOL_VERSION)
     {
      error = StringFormat("Unsupported Protocol Version (file=%d, expected=%d)", hb.version, CT_PROTOCOL_VERSION);
      return false;
     }

   return true;
  }

#endif // __CT_FILEPROTOCOL_MQH__

//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|          Structured logger: prints to Journal + writes to a      |
//|          local (terminal-specific) log file under MQL5\Files.    |
//+------------------------------------------------------------------+
#ifndef __CT_LOGGER_MQH__
#define __CT_LOGGER_MQH__

enum ENUM_LOG_LEVEL
  {
   LOG_DEBUG   = 0,
   LOG_INFO    = 1,
   LOG_TRADE   = 2,
   LOG_WARNING = 3,
   LOG_ERROR   = 4
  };

class CLogger
  {
private:
   bool              m_enable_debug;
   bool              m_log_to_file;
   int               m_file_handle;
   string            m_file_name;
   string            m_prefix;

   string            LevelToString(const ENUM_LOG_LEVEL level)
     {
      switch(level)
        {
         case LOG_DEBUG:   return "DEBUG";
         case LOG_INFO:    return "INFO";
         case LOG_TRADE:   return "TRADE";
         case LOG_WARNING: return "WARNING";
         case LOG_ERROR:   return "ERROR";
        }
      return "UNKNOWN";
     }

public:
                     CLogger() : m_enable_debug(false), m_log_to_file(false),
                                 m_file_handle(INVALID_HANDLE), m_file_name(""), m_prefix("")
     {
     }

   void              Init(const string prefix, const bool enable_debug, const bool log_to_file)
     {
      m_prefix       = prefix;
      m_enable_debug = enable_debug;
      m_log_to_file  = log_to_file;

      if(m_log_to_file)
        {
         MqlDateTime dt;
         TimeToStruct(TimeLocal(), dt);
         m_file_name = StringFormat("CopyTrade\\%s_%04d%02d%02d.log", m_prefix, dt.year, dt.mon, dt.day);
         m_file_handle = FileOpen(m_file_name, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
         if(m_file_handle != INVALID_HANDLE)
            FileSeek(m_file_handle, 0, SEEK_END);
         else
            Print("[Logger] Failed to open log file '", m_file_name, "' err=", GetLastError());
        }
     }

   void              Deinit()
     {
      if(m_file_handle != INVALID_HANDLE)
        {
         FileClose(m_file_handle);
         m_file_handle = INVALID_HANDLE;
        }
     }

   void              Log(const ENUM_LOG_LEVEL level, const string message)
     {
      if(level == LOG_DEBUG && !m_enable_debug)
         return;

      string ts   = TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS);
      string line = StringFormat("%s [%s] %s", ts, LevelToString(level), message);

      Print(line);

      if(m_log_to_file && m_file_handle != INVALID_HANDLE)
        {
         FileWriteString(m_file_handle, line + "\r\n");
         FileFlush(m_file_handle);
        }
     }

   void              Debug(const string msg)   { Log(LOG_DEBUG, msg);   }
   void              Info(const string msg)    { Log(LOG_INFO, msg);    }
   void              Trade(const string msg)   { Log(LOG_TRADE, msg);   }
   void              Warning(const string msg) { Log(LOG_WARNING, msg); }
   void              Error(const string msg)   { Log(LOG_ERROR, msg);   }
  };

CLogger g_logger;

#endif // __CT_LOGGER_MQH__

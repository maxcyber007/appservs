//+------------------------------------------------------------------+
//|                                                  Dashboard.mqh |
//|  On-chart status panel. Read-only display, never drives logic.   |
//+------------------------------------------------------------------+
#ifndef __CT_DASHBOARD_MQH__
#define __CT_DASHBOARD_MQH__

struct CT_DashboardData
  {
   string   mode;                 // "MASTER" / "SLAVE"
   long     login;
   string   server;
   string   account_type;         // DEMO / REAL
   double   balance;
   double   equity;
   string   master_connection;    // ONLINE / OFFLINE / N-A
   string   last_master_update;
   string   last_copy_time;
   long     copy_latency_ms;
   int      open_master;
   int      open_slave;
   int      copy_success;
   int      copy_failed;
   double   spread_points;
   string   risk_status;          // NORMAL / BLOCKED / EMERGENCY
   string   common_path;
  };

class CDashboard
  {
private:
   string            m_prefix;
   int               m_x;
   int               m_y;
   int               m_line_height;

   void              Label(const int index, const string text, const color clr)
     {
      string name = m_prefix + IntegerToString(index);
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_x);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_y + index * m_line_height);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        }
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
     }

public:
   void              Init(const string prefix = "CT_DASH_", const int x = 12, const int y = 18, const int line_height = 15)
     {
      m_prefix      = prefix;
      m_x           = x;
      m_y           = y;
      m_line_height = line_height;
     }

   void              Remove()
     {
      ObjectsDeleteAll(0, m_prefix);
     }

   void              Render(const CT_DashboardData &d)
     {
      int i = 0;
      Label(i++, "=== MT5 DEMO->REAL COPY TRADE ===", clrWhite);
      Label(i++, StringFormat("MODE: %s", d.mode), clrYellow);
      Label(i++, StringFormat("ACCOUNT: %d  SERVER: %s", d.login, d.server), clrWhite);
      Label(i++, StringFormat("ACCOUNT TYPE: %s", d.account_type), (d.account_type == "REAL" ? clrOrangeRed : clrLime));
      Label(i++, StringFormat("BALANCE: %.2f   EQUITY: %.2f", d.balance, d.equity), clrWhite);
      Label(i++, StringFormat("MASTER CONNECTION: %s", d.master_connection),
            (d.master_connection == "ONLINE" ? clrLime : clrRed));
      Label(i++, StringFormat("LAST MASTER UPDATE: %s", d.last_master_update), clrSilver);
      Label(i++, StringFormat("LAST COPY: %s", d.last_copy_time), clrSilver);
      Label(i++, StringFormat("COPY LATENCY: %d ms", d.copy_latency_ms), clrSilver);
      Label(i++, StringFormat("OPEN MASTER: %d   OPEN SLAVE: %d", d.open_master, d.open_slave), clrWhite);
      Label(i++, StringFormat("COPY SUCCESS: %d   COPY FAILED: %d", d.copy_success, d.copy_failed),
            (d.copy_failed > 0 ? clrOrange : clrLime));
      Label(i++, StringFormat("SPREAD: %.0f pts", d.spread_points), clrSilver);
      Label(i++, StringFormat("RISK STATUS: %s", d.risk_status),
            (d.risk_status == "NORMAL" ? clrLime : clrRed));
      Label(i++, StringFormat("COMMON PATH: %s", d.common_path), clrGray);
     }
  };

#endif // __CT_DASHBOARD_MQH__

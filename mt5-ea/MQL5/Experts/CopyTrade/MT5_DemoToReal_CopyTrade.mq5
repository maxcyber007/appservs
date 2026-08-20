//+------------------------------------------------------------------+
//|                                    MT5_DemoToReal_CopyTrade.mq5 |
//|                                                                    |
//|  MT5 Demo -> Real Copy Trade Expert Advisor                       |
//|  ------------------------------------------------------------     |
//|  One EA, two roles, selected by the CopyMode input:                |
//|    MODE_MASTER - runs on the DEMO terminal, publishes a full       |
//|                  snapshot of its account/positions/orders into     |
//|                  the shared Common Files folder.                   |
//|    MODE_SLAVE  - runs on the REAL terminal, reads that snapshot    |
//|                  and reconciles its own positions/orders to match. |
//|                                                                    |
//|  Communication is file-based only (Common Files folder), atomic    |
//|  write (tmp -> rename), versioned and CRC32-checksummed. No DLL,   |
//|  no WebRequest dependency, no Martingale, no lot escalation beyond |
//|  the configured LotMode rule.                                      |
//|                                                                    |
//|  NOTE: "#property strict" is intentionally NOT used here - it is   |
//|  an MQL4-only pragma with no meaning in MQL5 (MQL5 always compiles |
//|  with strict type checking), so adding it would be a no-op.        |
//+------------------------------------------------------------------+
#property copyright "MT5 Demo to Real Copy Trade"
#property version   "1.00"
#property description "Copies trades from a DEMO master account to a REAL slave account via the Common Files folder."

#include <CopyTrade/CopyManager.mqh>
#include <CopyTrade/Dashboard.mqh>

//================================= GENERAL =================================
input group "--- GENERAL ---"
input ENUM_COPY_MODE CopyMode                = MODE_MASTER;  // MODE_MASTER on the DEMO terminal, MODE_SLAVE on the REAL terminal
input bool           EnableDebugLog          = false;        // include LOG_DEBUG lines
input bool           LogToFile               = true;         // also write to MQL5\Files\CopyTrade\*.log
input int            UpdateIntervalSeconds   = 1;             // snapshot publish / reconciliation interval

//================================= MASTER ===================================
input group "--- MASTER ---"
input bool           RequireDemoMaster       = true;          // refuse to run as Master on a non-DEMO account

//================================= SLAVE ====================================
input group "--- SLAVE ---"
input bool           RequireRealAccount      = true;          // refuse to trade as Slave on a non-REAL account
input long           SlaveMagicNumber        = 26082026;      // every copied order/position uses this magic
input bool           OnlyManageCopiedTrades  = true;          // reserved: safety is always enforced (Magic+Comment tag); see README

//================================= LOT =======================================
input group "--- LOT ---"
input ENUM_LOT_MODE  LotMode                 = LOT_MULTIPLIER;
input double         FixedLot                = 0.01;          // used when LotMode = LOT_FIXED
input double         LotMultiplier           = 1.0;           // used when LotMode = LOT_MULTIPLIER/BALANCE_RATIO/EQUITY_RATIO

//================================= SYMBOL ====================================
input group "--- SYMBOL ---"
input bool           EnableAutoSymbolMapping = true;
input string         SymbolPrefix            = "";
input string         SymbolSuffix            = "";
input string         ManualSymbolMapping     = "";            // e.g. "XAUUSD=XAUUSDm;EURUSD=EURUSD.a"

//================================= SLIPPAGE ==================================
input group "--- SLIPPAGE ---"
input int            MaxDeviationPoints      = 20;

//================================= SL/TP =====================================
input group "--- SL/TP ---"
input ENUM_SLTP_MODE SLTPMode                = SLTP_MODE_COPY;
input bool           CopySL                  = true;
input bool           CopyTP                  = true;
input int            SLDistancePoints        = 0;             // used only when SLTPMode = SLTP_MODE_DISTANCE
input int            TPDistancePoints        = 0;             // used only when SLTPMode = SLTP_MODE_DISTANCE

//================================= PENDING ===================================
input group "--- PENDING ---"
input bool           EnablePendingOrders     = true;

//================================= RISK ======================================
input group "--- RISK ---"
input double         MaxDailyLossPercent      = 5.0;          // 0 = disabled
input double         MaxEquityDrawdownPercent = 10.0;         // 0 = disabled
input int            MaxOpenPositions         = 20;           // 0 = disabled
input double         MaxTotalLots             = 5.0;          // 0 = disabled
input bool           EnableSpreadFilter       = true;
input int            MaxSpreadPoints          = 50;
input bool           CopyDelayedTrades        = false;        // retry spread-blocked copies until spread normalizes

//================================= CONNECTION ================================
input group "--- CONNECTION ---"
input int            MasterTimeoutSeconds     = 10;

//================================= SAFETY ====================================
input group "--- SAFETY ---"
input bool           CloseTradesWhenMasterOffline = false;    // close all copied trades if Master heartbeat is lost
input bool           EmergencyCloseAll            = false;    // close all copied trades if a risk limit is breached

//================================= SECURITY ==================================
input group "--- SECURITY ---"
input string         CopyPassword            = "";            // optional shared secret (stored/compared only as a SHA-256 hash); blank = disabled

//================================= RETRY =====================================
input group "--- RETRY ---"
input int            MaxRetryCount           = 3;
input int            RetryDelayMilliseconds  = 300;

//================================= TEST MODE ==================================
input group "--- TEST MODE ---"
input bool           TestMode                = true;          // simulate only - logs "[TEST] Would ..." and sends nothing
input bool           DryRun                  = false;         // read & calculate everything, send nothing (no log tag difference beyond [DRYRUN])

//--- engines (only one is active depending on CopyMode) ----------------------
CMasterEngine g_master;
CSlaveEngine  g_slave;
CDashboard    g_dashboard;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_logger.Init(CopyMode == MODE_MASTER ? "Master" : "Slave", EnableDebugLog, LogToFile);
   g_logger.Info("=== MT5 Demo->Real Copy Trade EA starting ===");
   g_logger.Info("Common Files path: " + TerminalInfoString(TERMINAL_COMMONDATA_PATH));
   g_logger.Info(StringFormat("Mode=%s Account=%d Server=%s Type=%s",
                  (CopyMode == MODE_MASTER ? "MASTER" : "SLAVE"),
                  (int)AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
                  CAccountValidator::TradeModeToString((int)AccountInfoInteger(ACCOUNT_TRADE_MODE))));

   if(CopyMode == MODE_MASTER)
     {
      g_master.Init(CopyPassword, RequireDemoMaster);
      if(!g_master.IsEnabled())
         g_logger.Error("MASTER failed validation - this EA instance will not publish trade data. Fix the issue and reload the EA.");
     }
   else
     {
      if(!OnlyManageCopiedTrades)
         g_logger.Warning("OnlyManageCopiedTrades=false is ignored: this EA always restricts itself to Magic+Comment-tagged trades for safety (see README).");

      if(TestMode)
         g_logger.Warning("TestMode=true: no real orders will be sent. Set TestMode=false only after verifying behaviour in the Journal/log.");

      if(RequireRealAccount && (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
         g_logger.Warning("WARNING: REAL ACCOUNT COPY TRADE ENABLED");

      CT_SlaveConfig cfg;
      cfg.magic                  = SlaveMagicNumber;
      cfg.lot_mode               = LotMode;
      cfg.fixed_lot              = FixedLot;
      cfg.lot_multiplier         = LotMultiplier;
      cfg.auto_symbol_mapping    = EnableAutoSymbolMapping;
      cfg.symbol_prefix          = SymbolPrefix;
      cfg.symbol_suffix          = SymbolSuffix;
      cfg.manual_symbol_mapping  = ManualSymbolMapping;
      cfg.max_deviation_points   = MaxDeviationPoints;
      cfg.sltp_mode              = SLTPMode;
      cfg.copy_sl                = CopySL;
      cfg.copy_tp                = CopyTP;
      cfg.sl_distance_points     = SLDistancePoints;
      cfg.tp_distance_points     = TPDistancePoints;
      cfg.enable_pending_orders  = EnablePendingOrders;
      cfg.max_daily_loss_pct     = MaxDailyLossPercent;
      cfg.max_equity_dd_pct      = MaxEquityDrawdownPercent;
      cfg.max_open_positions     = MaxOpenPositions;
      cfg.max_total_lots         = MaxTotalLots;
      cfg.enable_spread_filter   = EnableSpreadFilter;
      cfg.max_spread_points      = MaxSpreadPoints;
      cfg.master_timeout_seconds = MasterTimeoutSeconds;
      cfg.close_when_offline     = CloseTradesWhenMasterOffline;
      cfg.emergency_close_all    = EmergencyCloseAll;
      cfg.require_real_account   = RequireRealAccount;
      cfg.copy_password          = CopyPassword;
      cfg.copy_delayed_trades    = CopyDelayedTrades;
      cfg.max_retry_count        = MaxRetryCount;
      cfg.retry_delay_ms         = RetryDelayMilliseconds;
      cfg.test_mode              = TestMode;
      cfg.dry_run                = DryRun;

      g_slave.Init(cfg);
      if(!g_slave.IsEnabled())
         g_logger.Error("SLAVE failed validation - this EA instance will not trade. Fix the issue and reload the EA.");
     }

   g_dashboard.Init();
   UpdateDashboard();

   EventSetTimer(MathMax(1, UpdateIntervalSeconds));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_dashboard.Remove();
   g_logger.Info("=== EA stopping (reason=" + IntegerToString(reason) + ") ===");
   g_logger.Deinit();
  }

//+------------------------------------------------------------------+
//| Expert tick function - dashboard only; all trading logic runs on  |
//| the timer so behaviour is identical with/without incoming ticks   |
//| (important on the Slave symbol chart, which may be quiet).        |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Timer: Master publishes snapshot+heartbeat, Slave reconciles.     |
//| A periodic timer (not only OnTradeTransaction) is the safety net  |
//| against a missed transaction event or a terminal reconnect.       |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(CopyMode == MODE_MASTER)
      g_master.OnTimerTick();
   else
      g_slave.Run();

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Master's low-latency change detector. The Slave never receives    |
//| this callback for its own trades routed back to Master - it only  |
//| ever reads the snapshot file, so no Slave->Master feedback loop   |
//| can exist.                                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
  {
   if(CopyMode == MODE_MASTER)
      g_master.OnTradeTransactionEvent(trans);
  }

//+------------------------------------------------------------------+
//| Refresh the on-chart status panel                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   CT_DashboardData d;
   d.mode          = (CopyMode == MODE_MASTER) ? "MASTER" : "SLAVE";
   d.login         = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   d.server        = AccountInfoString(ACCOUNT_SERVER);
   d.account_type  = CAccountValidator::TradeModeToString((int)AccountInfoInteger(ACCOUNT_TRADE_MODE));
   d.balance       = AccountInfoDouble(ACCOUNT_BALANCE);
   d.equity        = AccountInfoDouble(ACCOUNT_EQUITY);
   d.spread_points = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   d.common_path   = TerminalInfoString(TERMINAL_COMMONDATA_PATH);

   if(CopyMode == MODE_MASTER)
     {
      d.master_connection  = g_master.IsEnabled() ? "N/A (this is Master)" : "DISABLED";
      d.last_master_update = "-";
      d.last_copy_time     = "-";
      d.copy_latency_ms    = 0;
      d.open_master        = PositionsTotal();
      d.open_slave          = 0;
      d.copy_success       = 0;
      d.copy_failed        = 0;
      d.risk_status        = g_master.IsEnabled() ? "NORMAL" : "BLOCKED";
     }
   else
     {
      d.master_connection  = g_slave.IsMasterOnline() ? "ONLINE" : "OFFLINE";
      d.last_master_update = (g_slave.LastMasterUpdate() > 0) ? TimeToString(g_slave.LastMasterUpdate(), TIME_DATE|TIME_SECONDS) : "-";
      d.last_copy_time     = (g_slave.LastCopyTime() > 0) ? TimeToString(g_slave.LastCopyTime(), TIME_DATE|TIME_SECONDS) : "-";
      d.copy_latency_ms    = g_slave.CopyLatencyMs();
      d.open_master        = g_slave.OpenMasterCount();
      d.open_slave          = g_slave.OpenSlaveCount();
      d.copy_success       = g_slave.CopySuccessCount();
      d.copy_failed        = g_slave.CopyFailedCount();
      d.risk_status        = g_slave.RiskStatus();
     }

   g_dashboard.Render(d);
  }
//+------------------------------------------------------------------+

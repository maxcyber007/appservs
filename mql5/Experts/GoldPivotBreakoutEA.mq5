//+------------------------------------------------------------------+
//|                                          GoldPivotBreakoutEA.mq5 |
//|                                                                   |
//| Pivot breakout Expert Advisor for gold (XAUUSD).                  |
//|                                                                   |
//| The EA parks stop orders just beyond the nearest confirmed swing  |
//| high and swing low, so it is filled only when price actually      |
//| breaks a level rather than when an indicator predicts it will.    |
//| Exits are handled by a stack of stop-tightening rules, with the   |
//| working stop optionally kept EA-side instead of on the server.    |
//|                                                                   |
//| Every distance input is in POINTS of the symbol. Gold feeds       |
//| differ between brokers, so read the on-chart panel - it prints    |
//| the live spread and the pivot distances in points - and set the   |
//| inputs from those numbers before trading.                         |
//|                                                                   |
//| Trading involves substantial risk of loss. The defaults below are |
//| neutral starting points, not tuned values, and have not been      |
//| backtested against any data. Optimise and forward test on a demo  |
//| account before risking real money.                                |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property link      "https://github.com/maxcyber007/appservs"
#property version   "1.00"
#property strict
#property description "Pivot breakout gold EA: stop orders at swing levels, virtual stops, layered trailing."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <GoldTradePro/Utils.mqh>
#include <GoldTradePro/RiskManager.mqh>
#include <GoldTradePro/PivotFinder.mqh>
#include <GoldTradePro/TradeState.mqh>
#include <GoldTradePro/PendingManager.mqh>
#include <GoldTradePro/ExitManager.mqh>

//--- How the lot size is decided.
enum ENUM_GTP_LOT_MODE
  {
   GTP_LOT_FIXED = 0,        // Fixed lots
   GTP_LOT_RISK_PERCENT = 1, // Percent of balance risked over the stop distance
   GTP_LOT_BALANCE_STEP = 2  // One volume step per N of balance
  };

//--- Which side the EA is allowed to take.
enum ENUM_GTP_SIDE
  {
   GTP_SIDE_BOTH = 0,  // Both
   GTP_SIDE_LONG = 1,  // Buy stops only
   GTP_SIDE_SHORT = 2  // Sell stops only
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Pivot detection ==="
input ENUM_TIMEFRAMES  InpPivotTimeframe   = PERIOD_D1;  // Timeframe the swing levels are read from
input int              InpLeftBars         = 4;          // Bars before the pivot that must not exceed it
input int              InpRightBars        = 2;          // Bars after the pivot that confirm it
input int              InpMaxLookback      = 160;        // How many bars back to search
input bool             InpRequireExtreme   = true;       // Pivot must be untouched since it formed
input double           InpMinPivotDistance = 300;        // Minimum distance from price, points

input group "=== Order placement ==="
input ENUM_TIMEFRAMES  InpEntryTimeframe   = PERIOD_H1;  // How often levels are re-evaluated
input ENUM_GTP_SIDE    InpSide             = GTP_SIDE_BOTH; // Allowed direction
input double           InpBuyOffset        = 20;         // Buy stop offset above the pivot, points
input double           InpSellOffset       = 20;         // Sell stop offset below the pivot, points
input double           InpMinOrderSpacing  = 400;        // Ignore a level this close to a resting order, points
input int              InpMaxOrdersPerSide = 1;          // Resting stop orders allowed per side
input int              InpMaxPositions     = 2;          // Open positions allowed at once
input int              InpExpiryHours      = 168;        // Delete resting orders after N hours (0 = never)

input group "=== Lot size ==="
input ENUM_GTP_LOT_MODE InpLotMode         = GTP_LOT_RISK_PERCENT; // Sizing method
input double           InpFixedLots        = 0.01;       // Lots when the mode is fixed
input double           InpRiskPercent      = 1.0;        // Percent of balance risked per trade
input double           InpBalancePerStep    = 600;       // Balance per volume step
input double           InpMaxLots          = 10.0;       // Hard cap on lot size
input double           InpVolumeRefreshPct = 5.0;        // Re-issue resting orders when the lot drifts this much

input group "=== Stops ==="
input ENUM_GTP_STOP_MODE InpStopMode       = GTP_STOPS_PROTECTED; // Where the stop lives
input double           InpStopLossPoints   = 1200;       // Stop distance from entry, points
input double           InpTakeProfitPoints = 1800;       // Target distance from entry, points (0 = none)
input double           InpProtectMultiple  = 2.0;        // Safety-net stop = stop distance x this

input group "=== Trade management ==="
input bool             InpUsePartial       = true;       // Close part of the position at a target
input double           InpPartialTrigger   = 600;        // Profit that triggers it, points
input double           InpPartialPercent   = 50.0;       // Percent of volume closed
input bool             InpUseTrail         = true;       // Profit trailing stop
input double           InpTrailStart       = 500;        // Profit before the trail arms, points
input double           InpTrailDistance    = 700;        // Trailing distance, points
input double           InpTrailCap         = 0;          // Stop trailing once the stop is this far past entry (0 = never)
input bool             InpUseBreakEven     = true;       // Break-even move
input double           InpBreakEvenStart   = 400;        // Profit that triggers it, points
input double           InpBreakEvenLock    = 40;         // Profit locked in, points
input bool             InpUseTimeTrail     = false;      // Tighten the stop on stale positions
input int              InpTimeTrailMinutes = 480;        // Age before it applies, minutes
input double           InpTimeTrailDist    = 900;        // Trailing distance it uses, points
input bool             InpUseCreepTrail    = false;      // Creep the stop up on a timer
input double           InpCreepStep        = 10;         // Step per interval, points
input int              InpCreepSeconds     = 300;        // Interval, seconds
input double           InpCreepMinProfit   = 200;        // Only creep while profit exceeds this, points

input group "=== Guards ==="
input double           InpMaxSpreadPoints  = 500;        // Park orders above this spread (0 = off)
input double           InpMaxDailyLossPct  = 4.0;        // Halt for the day at this loss % (0 = off)
input double           InpMaxDrawdownPct   = 20.0;       // Stop opening trades at this drawdown % (0 = off)
input int              InpSessionStartHour = 0;          // Session start, server time
input int              InpSessionEndHour   = 24;         // Session end, server time (equal = 24h)
input int              InpDaySwitchPause   = 5;          // Minutes around midnight with no new orders
input bool             InpFlatBeforeWeekend = true;      // Delete resting orders late on Friday
input int              InpFridayCutoffHour = 21;         // Hour that applies from
input bool             InpSkipNfpWindow    = false;      // Skip the first Friday of the month
input int              InpNfpStartHour     = 14;         // NFP window start, server time
input int              InpNfpEndHour       = 17;         // NFP window end, server time

input group "=== Misc ==="
input long             InpMagicNumber      = 20260811;   // Magic number
input string           InpTradeComment     = "GoldPivot"; // Order comment
input int              InpSlippagePoints   = 30;         // Maximum price deviation
input bool             InpShowPanel        = true;       // On-chart status panel
input bool             InpVerboseLog       = false;      // Log skipped setups

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade            g_trade;
CPositionInfo     g_position;
CGoldRiskManager  g_risk;
CPivotFinder      g_pivots;
CTradeStateStore  g_states;
CPendingManager   g_pendings;
CExitManager      g_exits;

int               g_digits    = 0;
double            g_point     = 0.0;
datetime          g_last_bar  = 0;
double            g_last_lots = 0.0;
string            g_status    = "starting";
double            g_pivot_high = 0.0;
double            g_pivot_low  = 0.0;

//+------------------------------------------------------------------+
//| Convert a point count to a price distance                        |
//+------------------------------------------------------------------+
double Pts(const double points)
  {
   return(points * g_point);
  }

//+------------------------------------------------------------------+
//| Initialisation                                                   |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(g_point <= 0.0)
     {
      Print("Gold Pivot: the symbol point size is unavailable for ", _Symbol);
      return(INIT_FAILED);
     }

   if(InpStopLossPoints <= 0.0)
     {
      Print("Gold Pivot: the stop distance must be greater than zero");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpLotMode == GTP_LOT_FIXED && InpFixedLots <= 0.0)
     {
      Print("Gold Pivot: fixed lot mode needs a lot size above zero");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpLotMode == GTP_LOT_RISK_PERCENT && InpRiskPercent <= 0.0)
     {
      Print("Gold Pivot: risk mode needs a risk percentage above zero");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_pivots.Configure(_Symbol, InpPivotTimeframe, InpLeftBars, InpRightBars,
                      InpMaxLookback, Pts(InpMinPivotDistance), InpRequireExtreme);

   g_pendings.Configure(_Symbol, InpMagicNumber, GetPointer(g_trade), InpTradeComment,
                        InpMaxOrdersPerSide, Pts(InpMinOrderSpacing),
                        InpExpiryHours * 3600);

   g_risk.Configure(_Symbol,
                    (InpLotMode == GTP_LOT_RISK_PERCENT ? InpRiskPercent : 0.0),
                    InpFixedLots, InpMaxDailyLossPct, InpMaxDrawdownPct);

   g_exits.Configure(_Symbol, InpMagicNumber, GetPointer(g_trade), GetPointer(g_states));
   g_exits.SetStops(InpStopMode, Pts(InpStopLossPoints),
                    Pts(InpTakeProfitPoints), InpProtectMultiple);
   g_exits.SetPartial(InpUsePartial, InpPartialPercent, Pts(InpPartialTrigger));
   g_exits.SetTrail(InpUseTrail, Pts(InpTrailStart), Pts(InpTrailDistance), Pts(InpTrailCap));
   g_exits.SetBreakEven(InpUseBreakEven, Pts(InpBreakEvenStart), Pts(InpBreakEvenLock));
   g_exits.SetTimeTrail(InpUseTimeTrail, InpTimeTrailMinutes, Pts(InpTimeTrailDist));
   g_exits.SetCreep(InpUseCreepTrail, Pts(InpCreepStep), InpCreepSeconds, Pts(InpCreepMinProfit));

   g_states.Clear();
   g_last_bar  = 0;
   g_last_lots = 0.0;

   PrintFormat("Gold Pivot initialised on %s - pivots from %s, orders reviewed on %s",
               _Symbol, EnumToString(InpPivotTimeframe), EnumToString(InpEntryTimeframe));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Shutdown                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main loop                                                        |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   g_risk.Refresh();

   //--- Open positions are managed on every tick. A virtual stop that is
   //--- only checked once per bar is not a stop.
   g_exits.Manage();

   if(InpShowPanel)
      UpdatePanel();

   //--- Spread parking runs on every tick too, since a spread spike can
   //--- appear and clear well inside one bar.
   HandleSpread();

   if(!IsNewBar())
      return;

   g_pendings.ExpireOld();

   if(!TradingPermitted())
      return;

   string reason = "";
   if(!g_risk.TradingAllowed(reason))
     {
      if(g_status != reason)
        {
         g_status = reason;
         Print("Gold Pivot: ", reason);
        }
      return;
     }

   if(!SessionOpen(reason) || !WeekdayAllowed(reason) || !PastDaySwitch(reason))
     {
      g_status = reason;
      if(InpFlatBeforeWeekend && IsFridayCutoff())
         g_pendings.DeleteAll();
      if(InpVerboseLog)
         Print("Gold Pivot: skipped - ", reason);
      return;
     }

   g_status = "active";

   double lots = CalculateLots();
   if(lots <= 0.0)
     {
      g_status = "lot size unavailable";
      return;
     }

   //--- Keep resting orders at the current size once the balance has moved.
   if(g_last_lots > 0.0 && InpVolumeRefreshPct > 0.0)
     {
      double drift = MathAbs(lots - g_last_lots) / g_last_lots * 100.0;
      if(drift >= InpVolumeRefreshPct)
        {
         g_pendings.RefreshVolume(lots);
         g_last_lots = lots;
        }
     }
   else
      g_last_lots = lots;

   if(CountOwnPositions() >= InpMaxPositions)
     {
      g_status = "position limit reached";
      return;
     }

   PlaceBreakoutOrders(lots);

   g_pendings.TrimToCap(ORDER_TYPE_BUY_STOP);
   g_pendings.TrimToCap(ORDER_TYPE_SELL_STOP);
  }

//+------------------------------------------------------------------+
//| Place stop orders at the current pivots                          |
//+------------------------------------------------------------------+
void PlaceBreakoutOrders(const double lots)
  {
   int    shift = 0;
   double level = 0.0;

   //--- Buy side.
   if(InpSide != GTP_SIDE_SHORT && g_pivots.FindHigh(level, shift))
     {
      g_pivot_high = level;
      double entry = NormalizeDouble(level + Pts(InpBuyOffset), g_digits);
      double sl    = 0.0;
      double tp    = 0.0;
      BuildStops(true, entry, sl, tp);

      ulong ticket = g_pendings.PlaceStop(ORDER_TYPE_BUY_STOP, entry, lots, sl, tp);
      if(ticket != 0)
         PrintFormat("Buy stop #%I64u at %.*f (pivot %.*f, bar %d back), %.2f lots",
                     ticket, g_digits, entry, g_digits, level, shift, lots);
     }
   else
      if(InpSide != GTP_SIDE_SHORT)
         g_pivot_high = 0.0;

   //--- Sell side.
   if(InpSide != GTP_SIDE_LONG && g_pivots.FindLow(level, shift))
     {
      g_pivot_low = level;
      double entry = NormalizeDouble(level - Pts(InpSellOffset), g_digits);
      double sl    = 0.0;
      double tp    = 0.0;
      BuildStops(false, entry, sl, tp);

      ulong ticket = g_pendings.PlaceStop(ORDER_TYPE_SELL_STOP, entry, lots, sl, tp);
      if(ticket != 0)
         PrintFormat("Sell stop #%I64u at %.*f (pivot %.*f, bar %d back), %.2f lots",
                     ticket, g_digits, entry, g_digits, level, shift, lots);
     }
   else
      if(InpSide != GTP_SIDE_LONG)
         g_pivot_low = 0.0;
  }

//+------------------------------------------------------------------+
//| Stop and target attached to a pending order                      |
//|                                                                  |
//| In virtual mode nothing goes to the server; in protected mode a  |
//| wider stop is sent as a safety net against a disconnect.         |
//+------------------------------------------------------------------+
void BuildStops(const bool is_buy, const double entry, double &sl, double &tp)
  {
   double stop_distance = Pts(InpStopLossPoints);
   double min_distance  = GTP_MinStopDistance(_Symbol);
   if(stop_distance < min_distance)
      stop_distance = min_distance;

   sl = 0.0;
   tp = 0.0;

   switch(InpStopMode)
     {
      case GTP_STOPS_BROKER:
         sl = is_buy ? entry - stop_distance : entry + stop_distance;
         break;

      case GTP_STOPS_PROTECTED:
        {
         double net = stop_distance * g_exits.ProtectMultiplier();
         sl = is_buy ? entry - net : entry + net;
         break;
        }

      case GTP_STOPS_VIRTUAL:
      default:
         sl = 0.0;
         break;
     }

   if(InpTakeProfitPoints > 0.0 && InpStopMode == GTP_STOPS_BROKER)
     {
      double tp_distance = Pts(InpTakeProfitPoints);
      if(tp_distance < min_distance)
         tp_distance = min_distance;
      tp = is_buy ? entry + tp_distance : entry - tp_distance;
     }

   if(sl > 0.0)
      sl = NormalizeDouble(sl, g_digits);
   if(tp > 0.0)
      tp = NormalizeDouble(tp, g_digits);
  }

//+------------------------------------------------------------------+
//| Lot size for the selected mode                                   |
//+------------------------------------------------------------------+
double CalculateLots(void)
  {
   double lots = 0.0;

   switch(InpLotMode)
     {
      case GTP_LOT_RISK_PERCENT:
         lots = g_risk.LotsForStop(Pts(InpStopLossPoints));
         break;

      case GTP_LOT_BALANCE_STEP:
         lots = g_risk.LotsPerBalanceStep(InpBalancePerStep);
         break;

      case GTP_LOT_FIXED:
      default:
         lots = GTP_NormalizeLots(_Symbol, InpFixedLots);
         break;
     }

   if(InpMaxLots > 0.0 && lots > InpMaxLots)
      lots = GTP_NormalizeLots(_Symbol, InpMaxLots);

   return(lots);
  }

//+------------------------------------------------------------------+
//| Spread parking                                                   |
//+------------------------------------------------------------------+
void HandleSpread(void)
  {
   if(InpMaxSpreadPoints <= 0.0)
      return;

   double spread = GTP_SpreadPoints(_Symbol);

   if(spread > InpMaxSpreadPoints)
     {
      g_pendings.ParkAll();
      g_status = StringFormat("spread %.0f pts - orders parked", spread);
      return;
     }

   if(g_pendings.HasParked())
     {
      string reason = "";
      if(SessionOpen(reason) && WeekdayAllowed(reason))
         g_pendings.RestoreParked();
     }
  }

//+------------------------------------------------------------------+
//| True once per bar of the entry timeframe                         |
//+------------------------------------------------------------------+
bool IsNewBar(void)
  {
   if(InpEntryTimeframe == PERIOD_CURRENT)
      return(true);
   return(GTP_IsNewBar(_Symbol, InpEntryTimeframe, g_last_bar));
  }

//+------------------------------------------------------------------+
//| Terminal and account permissions                                 |
//+------------------------------------------------------------------+
bool TradingPermitted(void)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      g_status = "trading is not allowed by the terminal or account";
      return(false);
     }

   ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      g_status = "the symbol is closed or close-only right now";
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Session window                                                   |
//+------------------------------------------------------------------+
bool SessionOpen(string &reason)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(!GTP_HourInSession(dt.hour, InpSessionStartHour % 24, InpSessionEndHour % 24))
     {
      reason = StringFormat("outside the session (%02d:00-%02d:00 server time)",
                            InpSessionStartHour, InpSessionEndHour);
      return(false);
     }

   reason = "";
   return(true);
  }

//+------------------------------------------------------------------+
//| Weekday, weekend and news-window filters                         |
//+------------------------------------------------------------------+
bool WeekdayAllowed(string &reason)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
     {
      reason = "weekend";
      return(false);
     }

   if(InpFlatBeforeWeekend && IsFridayCutoff())
     {
      reason = "flat before the weekend";
      return(false);
     }

   //--- The monthly payroll release: the first Friday of the month.
   if(InpSkipNfpWindow && dt.day_of_week == 5 && dt.day <= 7 &&
      dt.hour >= InpNfpStartHour && dt.hour < InpNfpEndHour)
     {
      reason = "news window";
      return(false);
     }

   reason = "";
   return(true);
  }

bool IsFridayCutoff(void)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return(dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour);
  }

//+------------------------------------------------------------------+
//| Quiet period around the daily rollover                           |
//+------------------------------------------------------------------+
bool PastDaySwitch(string &reason)
  {
   if(InpDaySwitchPause <= 0)
      return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   bool after_midnight  = (dt.hour == 0  && dt.min < InpDaySwitchPause);
   bool before_midnight = (dt.hour == 23 && dt.min >= 60 - InpDaySwitchPause);

   if(after_midnight || before_midnight)
     {
      reason = "daily rollover, waiting for quotes to settle";
      return(false);
     }

   reason = "";
   return(true);
  }

//+------------------------------------------------------------------+
//| Positions opened by this EA on this symbol                       |
//+------------------------------------------------------------------+
int CountOwnPositions(void)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_position.SelectByIndex(i))
         continue;
      if(g_position.Symbol() == _Symbol && (long)g_position.Magic() == InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| On-chart status panel                                            |
//+------------------------------------------------------------------+
void UpdatePanel(void)
  {
   static datetime last_update = 0;
   datetime now = TimeCurrent();
   if(now == last_update)
      return;
   last_update = now;

   string stop_mode = "broker";
   if(InpStopMode == GTP_STOPS_VIRTUAL)
      stop_mode = "virtual";
   else
      if(InpStopMode == GTP_STOPS_PROTECTED)
         stop_mode = "virtual + safety net";

   string pivot_high = (g_pivot_high > 0.0 ? DoubleToString(g_pivot_high, g_digits) : "-");
   string pivot_low  = (g_pivot_low  > 0.0 ? DoubleToString(g_pivot_low,  g_digits) : "-");

   string text = StringFormat(
                    "Gold Pivot Breakout\n"
                    "Symbol      : %s (%d digits)\n"
                    "Status      : %s\n"
                    "Spread      : %.0f pts\n"
                    "Pivot high  : %s\n"
                    "Pivot low   : %s\n"
                    "Buy stops   : %d / %d\n"
                    "Sell stops  : %d / %d\n"
                    "Positions   : %d / %d\n"
                    "Lot size    : %.2f\n"
                    "Stop mode   : %s\n"
                    "Day P/L     : %.2f%%\n"
                    "Drawdown    : %.2f%%\n"
                    "Equity      : %.2f %s",
                    _Symbol, g_digits,
                    g_status,
                    GTP_SpreadPoints(_Symbol),
                    pivot_high, pivot_low,
                    g_pendings.Count(ORDER_TYPE_BUY_STOP),  InpMaxOrdersPerSide,
                    g_pendings.Count(ORDER_TYPE_SELL_STOP), InpMaxOrdersPerSide,
                    CountOwnPositions(), InpMaxPositions,
                    g_last_lots,
                    stop_mode,
                    -g_risk.DayLossPercent(),
                    g_risk.DrawdownPercent(),
                    AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoString(ACCOUNT_CURRENCY));

   Comment(text);
  }
//+------------------------------------------------------------------+

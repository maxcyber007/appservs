//+------------------------------------------------------------------+
//|                                                GoldTradeProEA.mq5 |
//|                                              Gold Trade Pro EA    |
//|                                                                   |
//| Trend-following Expert Advisor tuned for XAUUSD (gold).           |
//| Higher-timeframe bias + EMA cross entries, ATR stops, percent-of- |
//| balance position sizing, break-even, partial take profit and an   |
//| ATR trailing stop, with spread / session / daily-loss guards.     |
//|                                                                   |
//| Trading involves substantial risk of loss. Test on a demo account |
//| and in the Strategy Tester before risking real money. No settings |
//| in this file are a promise of profit.                             |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property link      "https://github.com/maxcyber007/appservs"
#property version   "1.00"
#property strict
#property description "Trend-following gold (XAUUSD) EA with ATR risk management."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <GoldTradePro/Utils.mqh>
#include <GoldTradePro/RiskManager.mqh>
#include <GoldTradePro/SignalEngine.mqh>

//--- How the EA is allowed to trade
enum ENUM_GTP_DIRECTION
  {
   GTP_BOTH  = 0,  // Buy and sell
   GTP_LONG  = 1,  // Buy only
   GTP_SHORT = 2   // Sell only
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Strategy ==="
input ENUM_TIMEFRAMES  InpEntryTimeframe   = PERIOD_M15;  // Entry timeframe
input ENUM_TIMEFRAMES  InpTrendTimeframe   = PERIOD_H1;   // Trend (bias) timeframe
input int              InpEmaFast          = 21;          // Fast EMA period (entry TF)
input int              InpEmaSlow          = 50;          // Slow EMA period (entry TF)
input int              InpEmaTrend         = 200;         // Trend EMA period (trend TF)
input bool             InpUseTrendFilter   = true;        // Only trade with the trend TF bias
input ENUM_GTP_DIRECTION InpDirection      = GTP_BOTH;    // Allowed direction

input group "=== Confirmation filters ==="
input int              InpRsiPeriod        = 14;          // RSI period
input double           InpRsiBuyMin        = 50.0;        // Buy: minimum RSI
input double           InpRsiBuyMax        = 75.0;        // Buy: maximum RSI (avoid exhaustion)
input double           InpRsiSellMin       = 25.0;        // Sell: minimum RSI (avoid exhaustion)
input double           InpRsiSellMax       = 50.0;        // Sell: maximum RSI
input int              InpAtrPeriod        = 14;          // ATR period
input double           InpMinAtrPoints     = 0.0;         // Minimum ATR in points (0 = off)

input group "=== Risk ==="
input double           InpRiskPercent      = 1.0;         // Risk per trade, % of balance (0 = fixed lots)
input double           InpFixedLots        = 0.01;        // Fixed lot size when risk % is 0
input double           InpAtrSlMultiplier  = 2.0;         // Stop loss = ATR x this
input double           InpAtrTpMultiplier  = 3.0;         // Take profit = ATR x this (0 = no TP)
input double           InpMaxDailyLossPct  = 4.0;         // Halt for the day at this loss % (0 = off)
input double           InpMaxDrawdownPct   = 20.0;        // Stop opening trades at this drawdown % (0 = off)
input int              InpMaxPositions     = 1;           // Max simultaneous positions for this EA

input group "=== Trade management ==="
input bool             InpUseBreakEven     = true;        // Move stop to break-even
input double           InpBreakEvenAtR     = 1.0;         // Break-even trigger, in R multiples
input double           InpBreakEvenLockR   = 0.1;         // Profit locked at break-even, in R
input bool             InpUsePartialClose  = true;        // Close part of the position at target
input double           InpPartialAtR       = 1.5;         // Partial close trigger, in R multiples
input double           InpPartialPercent   = 50.0;        // Percent of volume to close
input bool             InpUseTrailing      = true;        // ATR trailing stop
input double           InpTrailAtrMult     = 2.0;         // Trailing distance = ATR x this
input double           InpTrailStartR      = 1.0;         // Start trailing after this many R

input group "=== Execution guards ==="
input double           InpMaxSpreadPoints  = 500.0;       // Max spread in points (0 = off)
input int              InpSessionStartHour = 7;           // Session start hour, server time
input int              InpSessionEndHour   = 21;          // Session end hour, server time (equal = 24h)
input bool             InpTradeMonday      = true;        // Trade Monday
input bool             InpTradeFriday      = true;        // Trade Friday
input int              InpSlippagePoints   = 30;          // Max deviation in points
input long             InpMagicNumber      = 20260810;    // Magic number
input string           InpTradeComment     = "GoldTradePro"; // Order comment
input bool             InpVerboseLog       = false;       // Log every rejected signal

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade            g_trade;
CPositionInfo     g_position;
CGoldRiskManager  g_risk;
CGoldSignalEngine g_signals;

datetime          g_last_bar_time = 0;
int               g_digits        = 0;
double            g_point         = 0.0;
string            g_halt_reason   = "";
ulong             g_partial_done[];   // tickets already partially closed once

//+------------------------------------------------------------------+
//| Initialisation                                                   |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(g_point <= 0.0)
     {
      Print("Gold Trade Pro: symbol point size unavailable for ", _Symbol);
      return(INIT_FAILED);
     }

   if(InpEmaFast >= InpEmaSlow)
     {
      Print("Gold Trade Pro: fast EMA period must be smaller than the slow EMA period");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpAtrSlMultiplier <= 0.0)
     {
      Print("Gold Trade Pro: the ATR stop loss multiplier must be greater than zero");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpRiskPercent <= 0.0 && InpFixedLots <= 0.0)
     {
      Print("Gold Trade Pro: set either a risk percentage or a fixed lot size");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!g_signals.Init(_Symbol, InpEntryTimeframe, InpTrendTimeframe,
                      InpEmaFast, InpEmaSlow, InpEmaTrend,
                      InpRsiPeriod, InpAtrPeriod))
     {
      Print("Gold Trade Pro: failed to create the indicator handles");
      return(INIT_FAILED);
     }

   g_signals.SetFilters(InpRsiBuyMin, InpRsiBuyMax, InpRsiSellMin, InpRsiSellMax,
                        InpMinAtrPoints, InpUseTrendFilter);

   g_risk.Configure(_Symbol, InpRiskPercent, InpFixedLots,
                    InpMaxDailyLossPct, InpMaxDrawdownPct);

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_last_bar_time = 0;

   PrintFormat("Gold Trade Pro %s initialised on %s (entry %s / trend %s)",
               "1.00", _Symbol,
               EnumToString(InpEntryTimeframe), EnumToString(InpTrendTimeframe));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Shutdown                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_signals.Release();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main loop                                                        |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   g_risk.Refresh();

   //--- Open positions are managed on every tick, not only on new bars.
   ManageOpenPositions();
   UpdatePanel();

   if(!IsNewBar())
      return;

   PrunePartialDone();

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      g_halt_reason = "trading is not allowed by the terminal or account";
      return;
     }

   string reason = "";
   if(!g_risk.TradingAllowed(reason))
     {
      if(g_halt_reason != reason)
        {
         g_halt_reason = reason;
         Print("Gold Trade Pro: ", reason);
        }
      return;
     }
   g_halt_reason = "";

   if(!SessionOpen(reason) || !SpreadAcceptable(reason))
     {
      if(InpVerboseLog)
         Print("Gold Trade Pro: skipped - ", reason);
      return;
     }

   if(CountOwnPositions() >= InpMaxPositions)
      return;

   ENUM_GTP_SIGNAL signal = g_signals.Evaluate(reason);
   if(signal == GTP_SIGNAL_NONE)
     {
      if(InpVerboseLog)
         Print("Gold Trade Pro: no entry - ", reason);
      return;
     }

   if((signal == GTP_SIGNAL_BUY  && InpDirection == GTP_SHORT) ||
      (signal == GTP_SIGNAL_SELL && InpDirection == GTP_LONG))
     {
      if(InpVerboseLog)
         Print("Gold Trade Pro: signal blocked by the direction setting");
      return;
     }

   OpenTrade(signal, reason);
  }

//+------------------------------------------------------------------+
//| True once per bar of the entry timeframe                         |
//+------------------------------------------------------------------+
bool IsNewBar(void)
  {
   return(GTP_IsNewBar(_Symbol, InpEntryTimeframe, g_last_bar_time));
  }

//+------------------------------------------------------------------+
//| Session / weekday filter                                         |
//+------------------------------------------------------------------+
bool SessionOpen(string &reason)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
     {
      reason = "weekend";
      return(false);
     }

   if(!InpTradeMonday && dt.day_of_week == 1)
     {
      reason = "Monday trading disabled";
      return(false);
     }

   if(!InpTradeFriday && dt.day_of_week == 5)
     {
      reason = "Friday trading disabled";
      return(false);
     }

   if(!GTP_HourInSession(dt.hour, InpSessionStartHour, InpSessionEndHour))
     {
      reason = StringFormat("outside the trading session (%02d:00-%02d:00 server time)",
                            InpSessionStartHour, InpSessionEndHour);
      return(false);
     }

   reason = "";
   return(true);
  }

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool SpreadAcceptable(string &reason)
  {
   if(InpMaxSpreadPoints <= 0.0)
      return(true);

   double spread = GTP_SpreadPoints(_Symbol);
   if(spread > InpMaxSpreadPoints)
     {
      reason = StringFormat("spread too wide (%.0f > %.0f points)", spread, InpMaxSpreadPoints);
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
      if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Send the entry order                                             |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_GTP_SIGNAL signal, const string signal_reason)
  {
   double atr = g_signals.ATR();
   if(atr <= 0.0)
      return;

   bool   is_buy = (signal == GTP_SIGNAL_BUY);
   double price  = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                          : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      return;

   double stop_distance = atr * InpAtrSlMultiplier;
   double min_distance  = GTP_MinStopDistance(_Symbol);
   if(stop_distance < min_distance)
      stop_distance = min_distance;

   //--- Keep the stop clear of the spread we have to pay to exit.
   double spread_price = GTP_SpreadPoints(_Symbol) * g_point;
   if(stop_distance < spread_price * 2.0)
      stop_distance = spread_price * 2.0;

   if(stop_distance <= 0.0)
      return;

   double sl = is_buy ? price - stop_distance : price + stop_distance;
   double tp = 0.0;
   if(InpAtrTpMultiplier > 0.0)
     {
      double tp_distance = atr * InpAtrTpMultiplier;
      if(tp_distance < min_distance)
         tp_distance = min_distance;
      tp = is_buy ? price + tp_distance : price - tp_distance;
      tp = NormalizeDouble(tp, g_digits);
     }
   sl = NormalizeDouble(sl, g_digits);

   double lots = g_risk.LotsForStop(stop_distance);
   if(lots <= 0.0)
     {
      Print("Gold Trade Pro: trade skipped, the risk budget does not cover the minimum lot size");
      return;
     }

   bool ok = is_buy ? g_trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment)
                    : g_trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);

   if(!ok)
     {
      PrintFormat("Gold Trade Pro: order failed - retcode %d (%s)",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return;
     }

   PrintFormat("Gold Trade Pro: %s %.2f lots at %.*f, SL %.*f, TP %.*f | %s",
               (is_buy ? "BUY" : "SELL"), lots, g_digits, price,
               g_digits, sl, g_digits, tp, signal_reason);
  }

//+------------------------------------------------------------------+
//| Break-even, partial close and trailing stop                      |
//+------------------------------------------------------------------+
void ManageOpenPositions(void)
  {
   double atr = 0.0;
   if(InpUseTrailing)
      atr = g_signals.ATR();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_position.SelectByIndex(i))
         continue;
      if(g_position.Symbol() != _Symbol || g_position.Magic() != InpMagicNumber)
         continue;

      ulong  ticket = g_position.Ticket();
      bool   is_buy = (g_position.PositionType() == POSITION_TYPE_BUY);
      double open   = g_position.PriceOpen();
      double sl     = g_position.StopLoss();
      double tp     = g_position.TakeProfit();
      double price  = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(price <= 0.0)
         continue;

      //--- R is measured from the original stop distance. Once the stop has
      //--- been moved we can no longer recover it, so fall back to ATR.
      double risk = MathAbs(open - sl);
      if(risk <= 0.0)
         risk = (atr > 0.0 ? atr * InpAtrSlMultiplier : 0.0);
      if(risk <= 0.0)
         continue;

      double profit_r = (is_buy ? price - open : open - price) / risk;

      if(InpUsePartialClose && profit_r >= InpPartialAtR)
         TryPartialClose(ticket);

      double new_sl = sl;

      if(InpUseBreakEven && profit_r >= InpBreakEvenAtR)
        {
         double be = is_buy ? open + risk * InpBreakEvenLockR
                            : open - risk * InpBreakEvenLockR;
         if(is_buy ? (be > new_sl) : (be < new_sl || new_sl == 0.0))
            new_sl = be;
        }

      if(InpUseTrailing && atr > 0.0 && profit_r >= InpTrailStartR)
        {
         double trail = atr * InpTrailAtrMult;
         double candidate = is_buy ? price - trail : price + trail;
         if(is_buy ? (candidate > new_sl) : (candidate < new_sl || new_sl == 0.0))
            new_sl = candidate;
        }

      if(new_sl == sl)
         continue;

      //--- Respect the broker's minimum stop distance and never widen the risk.
      double min_distance = GTP_MinStopDistance(_Symbol);
      if(is_buy && new_sl > price - min_distance)
         continue;
      if(!is_buy && new_sl < price + min_distance)
         continue;

      new_sl = NormalizeDouble(new_sl, g_digits);
      if(new_sl == NormalizeDouble(sl, g_digits))
         continue;

      if(!g_trade.PositionModify(ticket, new_sl, tp))
         PrintFormat("Gold Trade Pro: failed to move the stop of #%I64u - retcode %d (%s)",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Close part of a position once, marking it via its comment        |
//+------------------------------------------------------------------+
void TryPartialClose(const ulong ticket)
  {
   if(PartialAlreadyDone(ticket))
      return;

   if(!g_position.SelectByTicket(ticket))
      return;

   double volume  = g_position.Volume();
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double percent = MathMin(MathMax(InpPartialPercent, 1.0), 99.0);
   double close_volume = GTP_NormalizeLots(_Symbol, volume * percent / 100.0);

   //--- Both the closed part and the remainder must be tradable volumes.
   if(close_volume < min_lot || volume - close_volume < min_lot)
      return;

   if(!g_trade.PositionClosePartial(ticket, close_volume))
     {
      PrintFormat("Gold Trade Pro: partial close of #%I64u failed - retcode %d (%s)",
                  ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return;
     }

   MarkPartialDone(ticket);

   PrintFormat("Gold Trade Pro: partial close of #%I64u, %.2f lots (%.0f%%)",
               ticket, close_volume, percent);
  }

//+------------------------------------------------------------------+
//| Bookkeeping for the one-shot partial close                       |
//+------------------------------------------------------------------+
bool PartialAlreadyDone(const ulong ticket)
  {
   for(int i = ArraySize(g_partial_done) - 1; i >= 0; i--)
      if(g_partial_done[i] == ticket)
         return(true);
   return(false);
  }

void MarkPartialDone(const ulong ticket)
  {
   if(PartialAlreadyDone(ticket))
      return;
   int size = ArraySize(g_partial_done);
   ArrayResize(g_partial_done, size + 1);
   g_partial_done[size] = ticket;
  }

//--- Drop tickets whose position no longer exists so the list stays small.
void PrunePartialDone(void)
  {
   for(int i = ArraySize(g_partial_done) - 1; i >= 0; i--)
     {
      if(PositionSelectByTicket(g_partial_done[i]))
         continue;
      int last = ArraySize(g_partial_done) - 1;
      g_partial_done[i] = g_partial_done[last];
      ArrayResize(g_partial_done, last);
     }
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

   string status = (g_halt_reason == "" ? "active" : g_halt_reason);

   string text = StringFormat(
                    "Gold Trade Pro EA\n"
                    "Symbol / TF : %s  %s (bias %s)\n"
                    "Status      : %s\n"
                    "Positions   : %d / %d\n"
                    "Spread      : %.0f pts\n"
                    "ATR         : %.0f pts\n"
                    "Day P/L     : %.2f%%\n"
                    "Drawdown    : %.2f%%\n"
                    "Equity      : %.2f %s",
                    _Symbol, EnumToString(InpEntryTimeframe), EnumToString(InpTrendTimeframe),
                    status,
                    CountOwnPositions(), InpMaxPositions,
                    GTP_SpreadPoints(_Symbol),
                    (g_point > 0.0 ? g_signals.ATR() / g_point : 0.0),
                    -g_risk.DayLossPercent(),
                    g_risk.DrawdownPercent(),
                    AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoString(ACCOUNT_CURRENCY));

   Comment(text);
  }
//+------------------------------------------------------------------+

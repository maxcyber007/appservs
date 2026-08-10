//+------------------------------------------------------------------+
//|                                                  ExitManager.mqh |
//|     Virtual stops, break-even, partial close and trailing logic   |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <GoldTradePro/Utils.mqh>
#include <GoldTradePro/TradeState.mqh>

//--- Where the protective stop actually lives.
enum ENUM_GTP_STOP_MODE
  {
   GTP_STOPS_BROKER = 0,     // Real stop loss on the server
   GTP_STOPS_VIRTUAL = 1,    // EA-side stop only, nothing on the server
   GTP_STOPS_PROTECTED = 2   // EA-side stop plus a wider real stop as a safety net
  };

//+------------------------------------------------------------------+
//| Runs every open position through four independent stop-tightening |
//| rules on each tick. Each rule proposes a level; the most          |
//| protective proposal wins, and a stop is never moved backwards.    |
//|                                                                   |
//|  1. Time trail    - a position that has not gone anywhere after N |
//|                     minutes gets a tighter leash.                 |
//|  2. Profit trail  - the usual trail, armed once the trade is up   |
//|                     by TrailStart, optionally capped so it stops  |
//|                     following once far enough in profit.          |
//|  3. Break-even    - jumps the stop to entry plus a small lock.    |
//|  4. Creep trail   - moves the stop a fixed step every N seconds   |
//|                     while the trade is onside, which grinds the   |
//|                     risk down on slow drifting moves that the     |
//|                     profit trail never arms on.                   |
//+------------------------------------------------------------------+
class CExitManager
  {
private:
   string             m_symbol;
   long               m_magic;
   int                m_digits;
   double             m_point;
   CTrade            *m_trade;
   CTradeStateStore  *m_states;
   CPositionInfo      m_position;

   ENUM_GTP_STOP_MODE m_stop_mode;
   double             m_default_stop;   // price distance used when a position has no stop
   double             m_default_target; // virtual target distance, 0 = no target
   double             m_protect_mult;   // safety-net stop = virtual distance x this

   bool               m_use_time_trail;
   int                m_time_trail_minutes;
   double             m_time_trail_distance;

   bool               m_use_trail;
   double             m_trail_start;    // profit distance that arms the trail
   double             m_trail_distance;
   double             m_trail_cap;      // stop following once SL is this far past entry (0 = never)

   bool               m_use_break_even;
   double             m_be_start;
   double             m_be_lock;

   bool               m_use_creep;
   double             m_creep_step;
   int                m_creep_seconds;
   double             m_creep_min_profit;

   bool               m_use_partial;
   double             m_partial_percent;
   double             m_partial_trigger;

   //--- Positions handed over to another module (zone recovery) that owns
   //--- their exit. Their stops must not be touched or checked here.
   ulong              m_excluded[];

   bool               IsExcluded(const ulong ticket) const
     {
      for(int i = ArraySize(m_excluded) - 1; i >= 0; i--)
         if(m_excluded[i] == ticket)
            return(true);
      return(false);
     }

   //--- Register a position the EA has not seen before.
   void               Register(const ulong ticket)
     {
      SGoldTradeState state;
      state.ticket       = ticket;
      state.is_buy       = (m_position.PositionType() == POSITION_TYPE_BUY);
      state.open_price   = m_position.PriceOpen();
      state.open_time    = (datetime)m_position.Time();
      state.partial_done = false;
      state.trail_active = false;
      state.last_magic_trail = 0;

      //--- A target set on the server is authoritative; otherwise the EA
      //--- carries its own, so a target still exists in virtual mode.
      state.virtual_tp = m_position.TakeProfit();
      if(state.virtual_tp <= 0.0 && m_default_target > 0.0)
         state.virtual_tp = state.is_buy ? m_position.PriceOpen() + m_default_target
                                         : m_position.PriceOpen() - m_default_target;

      double broker_sl = m_position.StopLoss();

      if(m_stop_mode == GTP_STOPS_BROKER && broker_sl > 0.0)
         state.virtual_sl = broker_sl;
      else
         state.virtual_sl = state.is_buy ? state.open_price - m_default_stop
                                         : state.open_price + m_default_stop;

      state.initial_risk = MathAbs(state.open_price - state.virtual_sl);
      if(state.initial_risk <= 0.0)
         state.initial_risk = m_default_stop;

      m_states.Set(state);
     }

   //--- Push the stop out to the server, respecting the minimum distance.
   bool               PushToBroker(const ulong ticket, const double sl, const double tp)
     {
      double min_distance = GTP_MinStopDistance(m_symbol);
      double price = m_position.PositionType() == POSITION_TYPE_BUY
                     ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                     : SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      if(m_position.PositionType() == POSITION_TYPE_BUY && sl > price - min_distance)
         return(false);
      if(m_position.PositionType() == POSITION_TYPE_SELL && sl < price + min_distance)
         return(false);

      if(m_trade.PositionModify(ticket, NormalizeDouble(sl, m_digits), tp))
         return(true);

      PrintFormat("Could not move the stop of #%I64u - retcode %d (%s)",
                  ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
      return(false);
     }

   void               ClosePosition(const ulong ticket, const string why)
     {
      if(m_trade.PositionClose(ticket))
         PrintFormat("Closed #%I64u - %s", ticket, why);
      else
         PrintFormat("Could not close #%I64u (%s) - retcode %d (%s)",
                     ticket, why, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
     }

   void               TryPartial(SGoldTradeState &state)
     {
      if(state.partial_done)
         return;

      double volume  = m_position.Volume();
      double min_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double percent = MathMin(MathMax(m_partial_percent, 1.0), 99.0);
      double close_volume = GTP_NormalizeLots(m_symbol, volume * percent / 100.0);

      if(close_volume < min_lot || volume - close_volume < min_lot)
        {
         state.partial_done = true;   // can never work for this position, stop retrying
         return;
        }

      if(!m_trade.PositionClosePartial(state.ticket, close_volume))
        {
         PrintFormat("Partial close of #%I64u failed - retcode %d (%s)",
                     state.ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         return;
        }

      state.partial_done = true;
      PrintFormat("Partial close of #%I64u, %.2f of %.2f lots", state.ticket, close_volume, volume);
     }

public:
                      CExitManager(void)
      : m_symbol(""), m_magic(0), m_digits(0), m_point(0.0),
        m_trade(NULL), m_states(NULL),
        m_stop_mode(GTP_STOPS_BROKER), m_default_stop(0.0), m_default_target(0.0),
        m_protect_mult(2.0),
        m_use_time_trail(false), m_time_trail_minutes(0), m_time_trail_distance(0.0),
        m_use_trail(false), m_trail_start(0.0), m_trail_distance(0.0), m_trail_cap(0.0),
        m_use_break_even(false), m_be_start(0.0), m_be_lock(0.0),
        m_use_creep(false), m_creep_step(0.0), m_creep_seconds(0), m_creep_min_profit(0.0),
        m_use_partial(false), m_partial_percent(50.0), m_partial_trigger(0.0) {}

   void               Configure(const string symbol, const long magic,
                                CTrade *trade, CTradeStateStore *states)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_trade  = trade;
      m_states = states;
      m_digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      m_point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
     }

   void               SetStops(const ENUM_GTP_STOP_MODE mode, const double default_stop,
                               const double default_target, const double protect_mult)
     {
      m_stop_mode      = mode;
      m_default_stop   = default_stop;
      m_default_target = default_target;
      m_protect_mult   = (protect_mult > 1.0 ? protect_mult : 2.0);
     }

   void               SetTimeTrail(const bool use, const int minutes, const double distance)
     { m_use_time_trail = use; m_time_trail_minutes = minutes; m_time_trail_distance = distance; }

   void               SetTrail(const bool use, const double start, const double distance,
                               const double cap)
     { m_use_trail = use; m_trail_start = start; m_trail_distance = distance; m_trail_cap = cap; }

   void               SetBreakEven(const bool use, const double start, const double lock)
     { m_use_break_even = use; m_be_start = start; m_be_lock = lock; }

   void               SetCreep(const bool use, const double step, const int seconds,
                               const double min_profit)
     { m_use_creep = use; m_creep_step = step; m_creep_seconds = seconds; m_creep_min_profit = min_profit; }

   void               SetPartial(const bool use, const double percent, const double trigger)
     { m_use_partial = use; m_partial_percent = percent; m_partial_trigger = trigger; }

   //--- Replace the exclusion list. Pass an empty array to manage everything.
   void               SetExclusions(const ulong &tickets[])
     {
      int count = ArraySize(tickets);
      ArrayResize(m_excluded, count);
      for(int i = 0; i < count; i++)
         m_excluded[i] = tickets[i];
     }

   void               ClearExclusions(void) { ArrayResize(m_excluded, 0); }

   ENUM_GTP_STOP_MODE StopMode(void) const { return(m_stop_mode); }
   double             ProtectMultiplier(void) const { return(m_protect_mult); }

   //--- Stop level the EA is currently working with, for the status panel.
   bool               ActiveStop(const ulong ticket, double &sl) const
     {
      SGoldTradeState state;
      if(!m_states.Get(ticket, state))
         return(false);
      sl = state.virtual_sl;
      return(true);
     }

   //--- Called on every tick.
   void               Manage(void)
     {
      datetime now = TimeCurrent();

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!m_position.SelectByIndex(i))
            continue;
         if(m_position.Symbol() != m_symbol || (long)m_position.Magic() != m_magic)
            continue;

         ulong ticket = m_position.Ticket();

         //--- Owned by zone recovery: its basket target is the exit now.
         if(IsExcluded(ticket))
            continue;

         SGoldTradeState state;
         if(!m_states.Get(ticket, state))
           {
            Register(ticket);
            if(!m_states.Get(ticket, state))
               continue;
           }

         bool   is_buy = state.is_buy;
         double price  = is_buy ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                                : SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         if(price <= 0.0)
            continue;

         double profit = is_buy ? price - state.open_price : state.open_price - price;

         //--- The virtual stop is checked before anything else: an exit that
         //--- is already due must not wait for a tightening rule to run.
         if(m_stop_mode != GTP_STOPS_BROKER && state.virtual_sl > 0.0)
           {
            if(is_buy ? (price <= state.virtual_sl) : (price >= state.virtual_sl))
              {
               ClosePosition(ticket, "virtual stop hit");
               m_states.Remove(ticket);
               continue;
              }
           }

         if(m_stop_mode != GTP_STOPS_BROKER && state.virtual_tp > 0.0)
           {
            if(is_buy ? (price >= state.virtual_tp) : (price <= state.virtual_tp))
              {
               ClosePosition(ticket, "virtual target hit");
               m_states.Remove(ticket);
               continue;
              }
           }

         if(m_use_partial && m_partial_trigger > 0.0 && profit >= m_partial_trigger)
            TryPartial(state);

         double candidate = state.virtual_sl;
         bool   changed   = false;

         //--- 1. Time trail.
         if(m_use_time_trail && m_time_trail_minutes > 0 && m_time_trail_distance > 0.0 &&
            now >= state.open_time + m_time_trail_minutes * 60 && profit > 0.0)
           {
            double level = is_buy ? price - m_time_trail_distance
                                  : price + m_time_trail_distance;
            if(is_buy ? (level > candidate) : (level < candidate || candidate <= 0.0))
              { candidate = level; changed = true; }
           }

         //--- 2. Profit trail, optionally capped.
         if(m_use_trail && m_trail_distance > 0.0 && profit >= m_trail_start)
           {
            bool cap_reached = false;
            if(m_trail_cap > 0.0)
              {
               double cap_level = is_buy ? state.open_price + m_trail_cap
                                         : state.open_price - m_trail_cap;
               cap_reached = is_buy ? (candidate >= cap_level) : (candidate <= cap_level);
              }

            if(!cap_reached)
              {
               double level = is_buy ? price - m_trail_distance : price + m_trail_distance;
               if(is_buy ? (level > candidate) : (level < candidate || candidate <= 0.0))
                 {
                  candidate = level;
                  changed   = true;
                  state.trail_active = true;
                 }
              }
           }

         //--- 3. Break-even.
         if(m_use_break_even && m_be_start > 0.0 && profit >= m_be_start)
           {
            double level = is_buy ? state.open_price + m_be_lock
                                  : state.open_price - m_be_lock;
            if(is_buy ? (level > candidate) : (level < candidate || candidate <= 0.0))
              { candidate = level; changed = true; }
           }

         //--- 4. Creep trail.
         if(m_use_creep && m_creep_step > 0.0 && m_creep_seconds > 0 &&
            profit >= m_creep_min_profit &&
            now >= state.last_magic_trail + m_creep_seconds)
           {
            double level = is_buy ? candidate + m_creep_step : candidate - m_creep_step;

            //--- Never creep the stop past the market.
            double min_distance = GTP_MinStopDistance(m_symbol);
            bool   safe = is_buy ? (level < price - min_distance)
                                 : (level > price + min_distance);
            if(safe)
              {
               candidate = level;
               changed   = true;
               state.last_magic_trail = now;
              }
           }

         if(!changed)
           {
            m_states.Set(state);
            continue;
           }

         candidate = NormalizeDouble(candidate, m_digits);
         if(candidate == NormalizeDouble(state.virtual_sl, m_digits))
           {
            m_states.Set(state);
            continue;
           }

         state.virtual_sl = candidate;
         m_states.Set(state);

         //--- Mirror to the server when the stop is meant to be visible.
         if(m_stop_mode == GTP_STOPS_BROKER)
            PushToBroker(ticket, candidate, m_position.TakeProfit());
         else
            if(m_stop_mode == GTP_STOPS_PROTECTED)
              {
               //--- Keep the safety net trailing behind the virtual stop.
               double risk   = (state.initial_risk > 0.0 ? state.initial_risk : m_default_stop);
               double buffer = risk * (m_protect_mult - 1.0);
               double net    = is_buy ? candidate - buffer : candidate + buffer;
               double broker = m_position.StopLoss();

               if(broker <= 0.0 || (is_buy ? (net > broker) : (net < broker)))
                  PushToBroker(ticket, net, m_position.TakeProfit());
              }
        }

      m_states.Prune();
     }
  };
//+------------------------------------------------------------------+

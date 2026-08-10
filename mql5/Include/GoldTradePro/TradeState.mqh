//+------------------------------------------------------------------+
//|                                                   TradeState.mqh |
//|   Per-position bookkeeping that MetaTrader itself does not keep   |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

//+------------------------------------------------------------------+
//| One record per open position.                                     |
//|                                                                   |
//| The virtual stop lives here rather than on the server, so the     |
//| broker never sees the level the EA intends to exit at. The        |
//| initial risk is captured once, at first sight of the position, so |
//| that "R" keeps its meaning after the stop has been moved.         |
//+------------------------------------------------------------------+
struct SGoldTradeState
  {
   ulong             ticket;
   double            virtual_sl;      // 0 = not set
   double            virtual_tp;      // 0 = not set
   double            open_price;
   double            initial_risk;    // price distance from entry to the first stop
   bool              is_buy;
   bool              partial_done;
   bool              trail_active;
   datetime          open_time;
   datetime          last_magic_trail;
  };

//+------------------------------------------------------------------+
//| Small keyed store. Positions are few, so a linear scan is both    |
//| fast enough and easier to reason about than a hash map.           |
//+------------------------------------------------------------------+
class CTradeStateStore
  {
private:
   SGoldTradeState   m_items[];

public:
   int               Total(void) const { return(ArraySize(m_items)); }

   int               IndexOf(const ulong ticket) const
     {
      for(int i = ArraySize(m_items) - 1; i >= 0; i--)
         if(m_items[i].ticket == ticket)
            return(i);
      return(-1);
     }

   bool              Get(const ulong ticket, SGoldTradeState &state) const
     {
      int idx = IndexOf(ticket);
      if(idx < 0)
         return(false);
      state = m_items[idx];
      return(true);
     }

   void              Set(const SGoldTradeState &state)
     {
      int idx = IndexOf(state.ticket);
      if(idx < 0)
        {
         idx = ArraySize(m_items);
         ArrayResize(m_items, idx + 1);
        }
      m_items[idx] = state;
     }

   void              Remove(const ulong ticket)
     {
      int idx = IndexOf(ticket);
      if(idx < 0)
         return;
      int last = ArraySize(m_items) - 1;
      m_items[idx] = m_items[last];
      ArrayResize(m_items, last);
     }

   //--- Drop records whose position has closed.
   void              Prune(void)
     {
      for(int i = ArraySize(m_items) - 1; i >= 0; i--)
        {
         if(PositionSelectByTicket(m_items[i].ticket))
            continue;
         int last = ArraySize(m_items) - 1;
         m_items[i] = m_items[last];
         ArrayResize(m_items, last);
        }
     }

   void              Clear(void) { ArrayResize(m_items, 0); }
  };
//+------------------------------------------------------------------+

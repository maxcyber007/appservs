# Gold Trade Pro EA

A trend-following MetaTrader 5 Expert Advisor built for gold (XAUUSD). It takes
EMA-cross entries in the direction of a higher-timeframe bias, sizes every trade
from a fixed percentage of account balance, and manages the position with ATR
based stops, a break-even move, an optional partial take profit and a trailing
stop.

> **Risk notice.** This is trading software, not a prediction. Gold is a fast,
> wide-spread instrument and any parameter set can lose money. Run it on a demo
> account and in the Strategy Tester with your own broker's data before risking
> real capital.

## Files

| File | Purpose |
| --- | --- |
| `Experts/GoldTradeProEA.mq5` | The Expert Advisor: inputs, entry logic, order handling, trade management |
| `Include/GoldTradePro/SignalEngine.mqh` | Indicator handles and the entry signal rules |
| `Include/GoldTradePro/RiskManager.mqh` | Position sizing, daily-loss and drawdown guards |
| `Include/GoldTradePro/Utils.mqh` | Symbol maths: lot normalisation, point value, spread, session helpers |

## Installation

1. In MetaTrader 5 open **File → Open Data Folder**, then go into `MQL5`.
2. Copy `Experts/GoldTradeProEA.mq5` into `MQL5/Experts/`.
3. Copy the whole `Include/GoldTradePro/` folder into `MQL5/Include/`.
4. Back in the terminal press **F4** to open MetaEditor, open `GoldTradeProEA.mq5`
   and press **F7** to compile. It should report 0 errors.
5. Refresh the Navigator, drag the EA onto an XAUUSD chart, and enable
   **Allow Algo Trading** in both the dialog and the toolbar.

## How it decides to trade

An entry needs all of the following to line up on the **close of a bar** — the EA
only evaluates once per bar, so signals never repaint mid-bar:

1. **Bias** — on the trend timeframe (H1 by default) the last close is above the
   trend EMA for longs, below it for shorts. Set `InpUseTrendFilter = false` to
   trade both directions regardless.
2. **Trigger** — on the entry timeframe (M15 by default) the fast EMA crosses the
   slow EMA in the bias direction.
3. **Momentum** — RSI sits inside the entry band. The upper bound matters: a buy
   with RSI already at 80 is chasing a move that is more likely to retrace than
   extend.
4. **Volatility** — ATR is above `InpMinAtrPoints`, and the current spread is
   below `InpMaxSpreadPoints`. Both filters exist because gold's edge disappears
   in thin, wide-spread hours.
5. **Session** — the server-time hour falls inside the configured window and the
   weekday is enabled.

## Position sizing

The stop distance is `ATR × InpAtrSlMultiplier`, widened if it falls under the
broker's minimum stop distance or under twice the current spread. Lot size then
comes from:

```
risk money   = balance × InpRiskPercent / 100
loss per lot = (stop distance / point) × point value per lot
lots         = risk money / loss per lot
```

The result is snapped down to the broker's lot step and checked against free
margin. If even the minimum lot would risk more than 1.5× the intended budget,
the trade is **skipped** rather than taken oversized. Set `InpRiskPercent = 0` to
use `InpFixedLots` instead.

## Trade management

- **Break-even** — at `InpBreakEvenAtR` R of open profit the stop moves to entry
  plus `InpBreakEvenLockR` R, so the trade can no longer turn into a loss.
- **Partial close** — at `InpPartialAtR` R, `InpPartialPercent` of the volume is
  closed once. It is skipped when either the closed part or the remainder would
  fall below the broker's minimum lot.
- **Trailing stop** — after `InpTrailStartR` R the stop follows price at
  `ATR × InpTrailAtrMult`. Stops are only ever moved in the profitable direction.

"R" means one unit of the trade's original risk: the distance from entry to the
initial stop.

## Guards

| Guard | Input | Behaviour |
| --- | --- | --- |
| Daily loss | `InpMaxDailyLossPct` | Once equity is down this much from the day's opening equity, no new trades until the next server day. Open positions keep their stops. |
| Drawdown | `InpMaxDrawdownPct` | No new trades while equity is this far below its peak. |
| Spread | `InpMaxSpreadPoints` | Entry skipped while the spread is wider. |
| Concurrency | `InpMaxPositions` | Caps the EA's simultaneous positions on the symbol. |

Guards block *opening* trades. They never close an existing position — exits stay
with the stop loss, take profit and trailing logic.

## Inputs reference

### Strategy

| Input | Default | Meaning |
| --- | --- | --- |
| `InpEntryTimeframe` | M15 | Timeframe the entry signal is evaluated on |
| `InpTrendTimeframe` | H1 | Timeframe supplying the directional bias |
| `InpEmaFast` | 21 | Fast EMA period, must be below the slow period |
| `InpEmaSlow` | 50 | Slow EMA period |
| `InpEmaTrend` | 200 | Trend EMA period on the bias timeframe |
| `InpUseTrendFilter` | true | Require agreement with the bias timeframe |
| `InpDirection` | Both | Restrict the EA to longs or shorts |

### Confirmation filters

| Input | Default | Meaning |
| --- | --- | --- |
| `InpRsiPeriod` | 14 | RSI period |
| `InpRsiBuyMin` / `InpRsiBuyMax` | 50 / 75 | RSI band accepted for buys |
| `InpRsiSellMin` / `InpRsiSellMax` | 25 / 50 | RSI band accepted for sells |
| `InpAtrPeriod` | 14 | ATR period, used for stops and the volatility floor |
| `InpMinAtrPoints` | 0 | Minimum ATR in points, 0 disables |

### Risk

| Input | Default | Meaning |
| --- | --- | --- |
| `InpRiskPercent` | 1.0 | Balance percentage risked per trade, 0 uses fixed lots |
| `InpFixedLots` | 0.01 | Lot size used when the risk percentage is 0 |
| `InpAtrSlMultiplier` | 2.0 | Stop distance as a multiple of ATR |
| `InpAtrTpMultiplier` | 3.0 | Take profit as a multiple of ATR, 0 for none |
| `InpMaxDailyLossPct` | 4.0 | Daily loss halt, 0 disables |
| `InpMaxDrawdownPct` | 20.0 | Drawdown halt, 0 disables |
| `InpMaxPositions` | 1 | Simultaneous positions allowed |

### Trade management

| Input | Default | Meaning |
| --- | --- | --- |
| `InpUseBreakEven` | true | Enable the break-even move |
| `InpBreakEvenAtR` | 1.0 | R multiple that triggers break-even |
| `InpBreakEvenLockR` | 0.1 | R multiple locked in at break-even |
| `InpUsePartialClose` | true | Enable the one-shot partial close |
| `InpPartialAtR` | 1.5 | R multiple that triggers the partial close |
| `InpPartialPercent` | 50 | Percentage of volume closed |
| `InpUseTrailing` | true | Enable the ATR trailing stop |
| `InpTrailAtrMult` | 2.0 | Trailing distance as a multiple of ATR |
| `InpTrailStartR` | 1.0 | R multiple after which trailing begins |

### Execution guards

| Input | Default | Meaning |
| --- | --- | --- |
| `InpMaxSpreadPoints` | 500 | Maximum spread in points, 0 disables |
| `InpSessionStartHour` | 7 | Session start, server time |
| `InpSessionEndHour` | 21 | Session end, server time; equal values mean 24h |
| `InpTradeMonday` / `InpTradeFriday` | true | Weekday switches |
| `InpSlippagePoints` | 30 | Maximum price deviation |
| `InpMagicNumber` | 20260810 | Identifies this EA's positions |
| `InpTradeComment` | GoldTradePro | Order comment |
| `InpVerboseLog` | false | Log every rejected signal |

## Broker-specific settings you must check

`InpMaxSpreadPoints` and `InpMinAtrPoints` are in **points**, and gold quotes
differ between brokers — a 3-digit XAUUSD feed and a 2-digit one report the same
spread as very different point counts. Before going live, put the EA on a chart
with `InpVerboseLog = true` and read the on-chart panel: it shows the live spread
and ATR in points for your broker. Set the limits from those numbers.

The session window is in **server time**, not your local time. Check the clock in
the Market Watch window before setting it.

## Backtesting

Use **View → Strategy Tester** with:

- *Model*: "Every tick based on real ticks" — the trailing stop and partial close
  act intrabar, so M1-OHLC modelling will give misleading results.
- *Period*: at least two years to cover both trending and ranging gold regimes.
- *Deposit / leverage*: match the live account you intend to run.

When optimising, treat `InpAtrSlMultiplier`, `InpAtrTpMultiplier` and the RSI
bands as the primary parameters, and keep the risk percentage fixed so results
stay comparable.

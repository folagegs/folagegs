# 10 AM Open – Liquidity Draw Strategy (NQ / MNQ)

A rules-based version of the "10 AM open" idea for Nasdaq futures, in two languages:

| File | Platform | Language |
|---|---|---|
| `ten_am_open_strategy.indie` | **Vela / TakeProfit** (Indicators code editor) | Indie |
| `ten_am_open_strategy.pine` | TradingView (Pine Editor) | Pine Script v6 |

Paste the **code file** for your platform into its editor, not this README.

### Indie version (Vela / TakeProfit)
- Plots the 10 AM open, PDH/PDL, and ONH/ONL. Levels turn grey once they're taken.
- Draws rejection blocks as boxes, which turn grey when mitigated. The block
  timeframe can be the chart, 1m, 3m, 5m or 15m.
- Marks entries (`L` / `S`) and exits (win / loss crosses), and plots the active stop and target.
- A label on the last bar shows the current bias, whether the 10 AM open has been
  swept, and a running tally of the simulated trades: count, win rate and net R.
  The tally has no fees or slippage, so it is not a broker backtest.
- Alerts: create a platform alert on the "Long" or "Short" marker plot.
- Indie has no color inputs, so colors are fixed in the code.

> This is built around the core concept, not any creator's exact system.
> Nothing here is financial advice, and the defaults have not been
> optimized. Backtest and paper trade before risking money.

---

## The idea

Skip the 09:30 opening-bell volatility. Use **10:00 AM New York time** as the
signal that trading can start, and as a reference level. Then:

1. Mark the **10 AM open** and project it to 16:00.
2. Wait for price to **manipulate** (sweep) to one or both sides of it.
3. Check which **draws on liquidity** have already been taken today:
   - **PDH / PDL**: previous *futures session* high/low (18:00 → 16:00 ET, not midnight-to-midnight)
   - **ONH / ONL**: overnight high/low (16:00 prior day → 09:30 ET, so post-market plus pre-market)
4. Trade **toward the nearest level that has NOT been taken**.
5. Time entries with **rejection blocks**, a rejection of the 10 AM open, or a
   full **mitigation** of a block (continuation).

The key takeaway: the 10 AM open is most useful as a *when to start trading*
signal. Wait out the open, see what has been swept, and target what's left.

---

## Rules (what the script does)

### Levels
| Level | Window (ET) | "Taken" means |
|---|---|---|
| 10 AM open | open of the first bar at/after 10:00 | — (reference + manipulation check) |
| PDH / PDL | prior 18:00 → 16:00 session | traded through since today's 18:00 session start |
| ONH / ONL | 16:00 prior day → 09:30 | traded through after 09:30 |

Each level is drawn with a label and stops at the session reset. When a level
is taken, its line turns dotted and the label gets a ✓.

### Rejection blocks (default 1-minute, switchable to 3/5/15)
- **Bearish RB:** a swing high (`swing strength` bars on each side) whose upper
  wick is at least `wick-to-body ratio` × the body. Zone = wick high → top of body.
- **Bullish RB:** a swing low with a large lower wick. Zone = bottom of body → wick low.
- **Rejection:** price trades into the zone and the bar closes back outside it,
  on the block's side.
- **Mitigation:** a bar closes fully through the far side of the block. The box
  turns grey and is labelled "mitigated". This is the signal for a continuation
  trade in the breakout direction.

### Entry checklist (all must be true)
1. Time is inside the **entry window** (default 10:00–12:00 ET), optionally N minutes after 10:00.
2. **Manipulation:** price has swept the 10 AM open by ≥ `N` ticks on either side (default) or both sides.
3. **Bias:** an untaken level exists in the trade direction and, by default, it is the
   *nearest* untaken level overall.
   - Nearest untaken is above → longs only. Below → shorts only.
4. **Trigger** (in priority order):
   - Long: bullish RB rejection → 10 AM open rejection (wick below, close above) → bearish RB mitigated.
   - Short: bearish RB rejection → 10 AM open rejection (wick above, close below) → bullish RB mitigated.
5. **Risk:** the stop goes beyond the block (or the signal wick) plus a buffer.
   The trade is skipped if the stop is wider than `max stop` or reward-to-risk to
   the target is below `min R:R` (default 1.5).
6. Fewer than `max trades per day` (default 2) have been taken.

### Exit
- **Target:** the untaken level being traded toward.
- **Stop:** structural stop described above.
- **Time:** flat outside the hold window (default closes at 15:55).

---

## How to use it

1. TradingView → Pine Editor → paste `ten_am_open_strategy.pine` → **Add to chart**.
2. Chart: **NQ1! or MNQ1!, 1-minute**, with **extended hours ON**. Without
   extended hours the overnight and futures-session levels can't be built.
3. Open the **Strategy Tester** for results, and use **Replay** to walk through days.
4. Use the status table (top right) to see each level's state, the bias, and whether
   price has manipulated the 10 AM open yet.
5. Alerts: create an alert on the strategy and choose "alert() function calls only".

### Settings worth testing
| Setting | Default | Try |
|---|---|---|
| Block timeframe | 1 | 5, 15 (on the 1-minute chart) |
| Swing strength | 3 | 2–5 |
| Wick-to-body ratio | 1.5 | 1.0–3.0 |
| Manipulation | Either side, 8 ticks | Both sides / Off |
| Direction rule | Nearest untaken | Any untaken in direction |
| Entry window | 10:00–12:00 | 10:00–11:00, 10:15–11:30 |
| Min R:R | 1.5 | 1.0–3.0 |

Default costs in the strategy: $2/contract commission, 2 ticks slippage, 1 contract.

### Notes
- The block timeframe must be greater than or equal to the chart timeframe.
- Higher-timeframe blocks use confirmed bars only (no lookahead repaint), so they
  appear one HTF bar after the pivot confirms.
- Holidays and half days aren't handled specially; skip them or review those trades.

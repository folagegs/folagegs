//+------------------------------------------------------------------+
//| TenAmOpenEA.mq5                                                  |
//| 10 AM Open - Liquidity Draw strategy, Expert Advisor for MT5     |
//| Built for Exness USTEC (Nasdaq 100 CFD) on the M1 chart.         |
//|                                                                  |
//| Rules                                                            |
//|  1. Mark the 10:00 New York open.                                |
//|  2. Wait for price to sweep one (or both) sides of it.           |
//|  3. Levels: previous futures session H/L (18:00->16:00 NY) and   |
//|     overnight H/L (16:00->09:30 NY). Track which are "taken".    |
//|  4. Trade toward the nearest untaken level.                      |
//|  5. Entry triggers: rejection-block rejection, rejection of the  |
//|     10 AM open, or full mitigation of an opposing block.         |
//|  6. Stop beyond the block/wick + buffer, target = the level,     |
//|     min R:R, max trades per day, flat at the hold-window end.    |
//|                                                                  |
//| Times are converted from broker server time to New York time,    |
//| including US daylight saving. Exness server time is GMT+0.       |
//| Not financial advice. Backtest and demo-trade before going live. |
//+------------------------------------------------------------------+
#property copyright "10 AM Open Strategy"
#property version   "1.00"
#property description "Trades toward the nearest untaken liquidity level after the 10 AM New York open."

#include <Trade/Trade.mqh>

enum ENUM_MANIP_MODE { MANIP_OFF = 0, MANIP_EITHER = 1, MANIP_BOTH = 2 };
enum ENUM_BIAS_MODE  { BIAS_NEAREST = 0, BIAS_ANY = 1 };
enum ENUM_LOT_MODE   { LOT_FIXED = 0, LOT_RISK_PERCENT = 1 };

input group "Time (New York)"
input int             InpServerGmtOffset = 0;      // Broker server time offset from GMT, hours (Exness = 0)
input int             InpWaitMin         = 0;      // Wait N minutes after 10:00 before trading
input int             InpEntryEnd        = 1200;   // No new entries after (HHMM, New York)
input int             InpHoldEnd         = 1555;   // Close open trades at (HHMM, New York)

input group "Rejection blocks"
input ENUM_TIMEFRAMES InpRBTF            = PERIOD_M1; // Block timeframe (M1 / M5 / M15)
input int             InpSwing           = 3;      // Swing strength (bars each side)
input double          InpWickRatio       = 1.5;    // Min wick-to-body ratio
input double          InpMinWick         = 1.0;    // Min wick size (price units)
input int             InpMaxBlocks       = 20;     // Max blocks tracked

input group "Filters"
input ENUM_MANIP_MODE InpManip           = MANIP_EITHER; // Require sweep of the 10 AM open
input double          InpManipDist       = 2.0;    // Min sweep beyond 10 AM open (price units)
input bool            InpUsePD           = true;   // Target previous session high/low
input bool            InpUseON           = true;   // Target overnight high/low
input ENUM_BIAS_MODE  InpBias            = BIAS_NEAREST; // Direction rule

input group "Entries"
input bool            InpUseRBRej        = true;   // Entry: rejection-block rejection
input bool            InpUseTenRej       = true;   // Entry: rejection of the 10 AM open
input bool            InpUseMit          = true;   // Entry: full mitigation (continuation)

input group "Risk"
input ENUM_LOT_MODE   InpLotMode         = LOT_RISK_PERCENT; // Position sizing
input double          InpLots            = 0.10;   // Fixed lots (if fixed sizing)
input double          InpRiskPct         = 0.5;    // Risk per trade, % of balance (if risk sizing)
input double          InpStopBuf         = 1.0;    // Stop buffer (price units)
input double          InpMaxStop         = 40.0;   // Max stop distance (price units, 0 = off)
input double          InpMinRR           = 1.5;    // Min reward:risk to target
input int             InpMaxTrades       = 2;      // Max trades per day
input double          InpMaxSpread       = 3.0;    // Max spread to enter (price units, 0 = off)
input long            InpMagic           = 101000; // Magic number

input group "Display"
input bool            InpDraw            = true;   // Draw levels and blocks on the chart
input int             InpWarmupBars      = 5000;   // Bars replayed at start to build levels

//--- block record
struct Block
  {
   double   top;
   double   bot;
   bool     bull;
   datetime born;
   bool     mit;
   datetime tleft;
   string   name;
  };

CTrade   trade;
const string PFX = "TAO_";

datetime gLastBar   = 0;
int      gPrevM     = -1;
int      gPrevDay   = -1;
ENUM_TIMEFRAMES gRBTF = PERIOD_M1;

// previous futures session
int      gFutTd = -1;
double   gSessH = 0.0, gSessL = 0.0;
datetime gSessStart = 0;
double   gPDH = 0.0, gPDL = 0.0;
bool     gPDHtk = false, gPDLtk = false;
string   gPDHname = "", gPDLname = "";

// overnight
double   gOnAccH = 0.0, gOnAccL = 0.0;
datetime gOnStart = 0;
double   gONH = 0.0, gONL = 0.0;
bool     gONHtk = false, gONLtk = false;
string   gONHname = "", gONLname = "";

// 10 AM open
double   gTen = 0.0;
int      gTenDay = -1;
datetime gTenBarTime = 0;
bool     gSwUp = false, gSwDn = false;
int      gTradesToday = 0;

// rejection blocks
Block    gBlocks[];
datetime gLastBearT = 0, gLastBullT = 0;
long     gBlockSeq = 0;

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
long DaysFromCivil(long y, long m, long d)
  {
   long yy  = (m <= 2) ? y - 1 : y;
   long era = yy / 400;
   long yoe = yy - era * 400;
   long mp  = (m > 2) ? m - 3 : m + 9;
   long doy = (153 * mp + 2) / 5 + d - 1;
   long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
   return era * 146097 + doe - 719468;
  }

// seconds New York is behind UTC (4h in daylight saving time, else 5h)
long NyOffset(long utc)
  {
   MqlDateTime dt;
   TimeToStruct((datetime)utc, dt);
   long mar1 = DaysFromCivil(dt.year, 3, 1);
   long secondSunMar = mar1 + (7 - (mar1 + 4) % 7) % 7 + 7;
   long nov1 = DaysFromCivil(dt.year, 11, 1);
   long firstSunNov = nov1 + (7 - (nov1 + 4) % 7) % 7;
   long dstStart = secondSunMar * 86400 + 7 * 3600;
   long dstEnd   = firstSunNov * 86400 + 6 * 3600;
   if(utc >= dstStart && utc < dstEnd)
      return 4 * 3600;
   return 5 * 3600;
  }

long ServerToUtc(datetime t) { return (long)t - (long)InpServerGmtOffset * 3600; }
long LocalNY(datetime t)     { long u = ServerToUtc(t); return u - NyOffset(u); }
int  HhmmToMin(int v)        { return (v / 100) * 60 + v % 100; }
bool FutIn(int m)            { return m >= 1080 || m < 960; }
bool OnIn(int m)             { return m >= 960 || m < 570; }
bool TenIn(int m)            { return m >= 600 && m < 960; }

//+------------------------------------------------------------------+
//| Drawing helpers                                                  |
//+------------------------------------------------------------------+
void DrawLevel(string name, datetime t1, datetime t2, double price, color clr, string text)
  {
   if(!InpDraw || price <= 0.0)
      return;
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   string lbl = name + "_lbl";
   ObjectDelete(0, lbl);
   ObjectCreate(0, lbl, OBJ_TEXT, 0, t2, price);
   ObjectSetString(0, lbl, OBJPROP_TEXT, " " + text);
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
  }

void MarkTaken(string name, string text)
  {
   if(!InpDraw || name == "")
      return;
   if(ObjectFind(0, name) >= 0)
     {
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrGray);
     }
   string lbl = name + "_lbl";
   if(ObjectFind(0, lbl) >= 0)
     {
      ObjectSetString(0, lbl, OBJPROP_TEXT, " " + text + " (taken)");
      ObjectSetInteger(0, lbl, OBJPROP_COLOR, clrGray);
     }
  }

void DrawBlock(Block &b, datetime t2)
  {
   if(!InpDraw)
      return;
   ObjectDelete(0, b.name);
   ObjectCreate(0, b.name, OBJ_RECTANGLE, 0, b.tleft, b.top, t2, b.bot);
   color c = b.mit ? clrDimGray : (b.bull ? clrSeaGreen : clrIndianRed);
   ObjectSetInteger(0, b.name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, b.name, OBJPROP_FILL, true);
   ObjectSetInteger(0, b.name, OBJPROP_BACK, true);
   ObjectSetInteger(0, b.name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Trading helpers                                                  |
//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
     }
   return false;
  }

void CloseAll(string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
        {
         if(!trade.PositionClose(ticket))
            PrintFormat("Close failed (%s): %d %s", why, trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
     }
  }

double NormalizeLots(double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 0.01;
   v = MathFloor(v / step + 1e-9) * step;
   if(v < vmin)
      return 0.0;            // too small to respect the risk limit -> skip
   if(v > vmax)
      v = vmax;
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(v, digits);
  }

double CalcLots(double stopDist)
  {
   if(InpLotMode == LOT_FIXED)
      return NormalizeLots(InpLots);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSize <= 0.0 || stopDist <= 0.0)
      return 0.0;
   double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double lossPerLot = stopDist / tickSize * tickVal;
   return NormalizeLots(riskMoney / lossPerLot);
  }

//+------------------------------------------------------------------+
//| Rejection-block detection on the block timeframe                 |
//+------------------------------------------------------------------+
void AddBlock(double top, double bot, bool bull, datetime born, datetime tleft, datetime tEnd)
  {
   int n = ArraySize(gBlocks);
   if(n >= InpMaxBlocks && n > 0)
     {
      if(InpDraw)
         ObjectDelete(0, gBlocks[0].name);
      for(int i = 1; i < n; i++)
        {
         gBlocks[i - 1].top   = gBlocks[i].top;
         gBlocks[i - 1].bot   = gBlocks[i].bot;
         gBlocks[i - 1].bull  = gBlocks[i].bull;
         gBlocks[i - 1].born  = gBlocks[i].born;
         gBlocks[i - 1].mit   = gBlocks[i].mit;
         gBlocks[i - 1].tleft = gBlocks[i].tleft;
         gBlocks[i - 1].name  = gBlocks[i].name;
        }
      n--;
      ArrayResize(gBlocks, n);
     }
   ArrayResize(gBlocks, n + 1);
   gBlocks[n].top   = top;
   gBlocks[n].bot   = bot;
   gBlocks[n].bull  = bull;
   gBlocks[n].born  = born;
   gBlocks[n].mit   = false;
   gBlocks[n].tleft = tleft;
   gBlockSeq++;
   gBlocks[n].name  = PFX + "RB_" + IntegerToString(gBlockSeq);
   DrawBlock(gBlocks[n], tEnd);
  }

void DetectBlocks(datetime barTime, datetime tEnd)
  {
   datetime closeT = barTime + PeriodSeconds(_Period);
   int j = iBarShift(_Symbol, gRBTF, closeT - 1, false);
   if(j < 0)
      return;
   datetime jt = iTime(_Symbol, gRBTF, j);
   int c = (jt + PeriodSeconds(gRBTF) <= closeT) ? j : j + 1;   // newest CLOSED block-TF bar
   int p = c + InpSwing;                                          // pivot candidate
   if(iBars(_Symbol, gRBTF) <= p + InpSwing + 1)
      return;

   double ph = iHigh(_Symbol, gRBTF, p);
   double pl = iLow(_Symbol, gRBTF, p);
   bool isPH = true, isPL = true;
   for(int k = 1; k <= InpSwing; k++)
     {
      if(iHigh(_Symbol, gRBTF, p + k) >= ph || iHigh(_Symbol, gRBTF, p - k) > ph)
         isPH = false;
      if(iLow(_Symbol, gRBTF, p + k) <= pl || iLow(_Symbol, gRBTF, p - k) < pl)
         isPL = false;
     }
   if(!isPH && !isPL)
      return;

   double o = iOpen(_Symbol, gRBTF, p);
   double cl = iClose(_Symbol, gRBTF, p);
   datetime pt = iTime(_Symbol, gRBTF, p);
   double body = MathMax(MathAbs(cl - o), _Point);
   double upW = ph - MathMax(o, cl);
   double dnW = MathMin(o, cl) - pl;

   if(isPH && pt != gLastBearT && upW / body >= InpWickRatio && upW >= InpMinWick)
     {
      gLastBearT = pt;
      AddBlock(ph, MathMax(o, cl), false, barTime, pt, tEnd);
     }
   if(isPL && pt != gLastBullT && dnW / body >= InpWickRatio && dnW >= InpMinWick)
     {
      gLastBullT = pt;
      AddBlock(MathMin(o, cl), pl, true, barTime, pt, tEnd);
     }
  }

//+------------------------------------------------------------------+
//| Process one closed chart bar                                     |
//+------------------------------------------------------------------+
void ProcessBar(int shift, bool live)
  {
   datetime t = iTime(_Symbol, _Period, shift);
   double o = iOpen(_Symbol, _Period, shift);
   double h = iHigh(_Symbol, _Period, shift);
   double l = iLow(_Symbol, _Period, shift);
   double c = iClose(_Symbol, _Period, shift);
   if(t == 0 || o <= 0.0)
      return;

   long utc  = ServerToUtc(t);
   long loc  = utc - NyOffset(utc);
   int  m0   = (int)((loc % 86400) / 60);
   int  day0 = (int)(loc / 86400);
   int  td0  = (int)((loc + 21600) / 86400);   // futures trading day: 18:00 starts the next one
   int  m1   = gPrevM;
   int  day1 = gPrevDay;
   gPrevM = m0;
   gPrevDay = day0;

   // 16:00 New York of this session, in server time
   long serverMinusLocal = (long)t - loc;
   datetime tEnd = (datetime)((long)day0 * 86400 + 960 * 60 + serverMinusLocal);
   if(m0 >= 960)
      tEnd += 86400;

   //--- previous futures session H/L
   if(FutIn(m0))
     {
      if(td0 != gFutTd)
        {
         if(gSessH > 0.0)
           {
            gPDH = gSessH;
            gPDL = gSessL;
            gPDHtk = false;
            gPDLtk = false;
            datetime pdEnd = (datetime)((long)t + 22 * 3600);
            gPDHname = PFX + "PDH_" + IntegerToString(td0);
            gPDLname = PFX + "PDL_" + IntegerToString(td0);
            DrawLevel(gPDHname, t, pdEnd, gPDH, clrDodgerBlue, "PDH");
            DrawLevel(gPDLname, t, pdEnd, gPDL, clrDodgerBlue, "PDL");
           }
         gFutTd = td0;
         gSessH = h;
         gSessL = l;
         gSessStart = t;
        }
      else
        {
         gSessH = MathMax(gSessH, h);
         gSessL = MathMin(gSessL, l);
        }
     }
   if(gPDH > 0.0 && !gPDHtk && h >= gPDH) { gPDHtk = true; MarkTaken(gPDHname, "PDH"); }
   if(gPDL > 0.0 && !gPDLtk && l <= gPDL) { gPDLtk = true; MarkTaken(gPDLname, "PDL"); }

   //--- overnight H/L
   bool on0 = OnIn(m0);
   bool on1 = (m1 >= 0 && OnIn(m1));
   if(on0 && !on1)
     {
      gOnAccH = h;
      gOnAccL = l;
      gOnStart = t;
      gONH = 0.0;
      gONL = 0.0;
     }
   else if(on0)
     {
      gOnAccH = MathMax(gOnAccH, h);
      gOnAccL = MathMin(gOnAccL, l);
     }
   else if(on1 && gOnAccH > 0.0)
     {
      gONH = gOnAccH;
      gONL = gOnAccL;
      gONHtk = false;
      gONLtk = false;
      gONHname = PFX + "ONH_" + IntegerToString(day0);
      gONLname = PFX + "ONL_" + IntegerToString(day0);
      DrawLevel(gONHname, gOnStart, tEnd, gONH, clrMediumOrchid, "ONH");
      DrawLevel(gONLname, gOnStart, tEnd, gONL, clrMediumOrchid, "ONL");
     }
   if(gONH > 0.0 && !gONHtk && h >= gONH) { gONHtk = true; MarkTaken(gONHname, "ONH"); }
   if(gONL > 0.0 && !gONLtk && l <= gONL) { gONLtk = true; MarkTaken(gONLname, "ONL"); }

   //--- 10 AM open and manipulation
   bool ten0 = TenIn(m0);
   bool ten1 = (m1 >= 0 && TenIn(m1) && day1 == day0);
   if(ten0 && !ten1)
     {
      gTen = o;
      gTenDay = day0;
      gTenBarTime = t;
      gSwUp = false;
      gSwDn = false;
      gTradesToday = 0;
      DrawLevel(PFX + "TEN_" + IntegerToString(day0), t, tEnd, gTen, clrOrange, "10AM");
     }
   bool tenToday = ten0 && gTenDay == day0 && gTen > 0.0;
   if(tenToday)
     {
      if(h >= gTen + InpManipDist) gSwUp = true;
      if(l <= gTen - InpManipDist) gSwDn = true;
     }
   bool manipOk = true;
   if(InpManip == MANIP_EITHER) manipOk = gSwUp || gSwDn;
   if(InpManip == MANIP_BOTH)   manipOk = gSwUp && gSwDn;

   //--- rejection blocks: detect, then check interactions with this bar
   DetectBlocks(t, tEnd);

   bool   bullRej = false, bearRej = false, bullMit = false, bearMit = false;
   double bullRejStop = 0.0, bearRejStop = 0.0, bullMitStop = 0.0, bearMitStop = 0.0;
   int nb = ArraySize(gBlocks);
   for(int i = 0; i < nb; i++)
     {
      if(gBlocks[i].mit || gBlocks[i].born >= t)
         continue;
      double top = gBlocks[i].top;
      double bot = gBlocks[i].bot;
      if(gBlocks[i].bull)
        {
         if(c < bot)
           {
            gBlocks[i].mit = true;
            bullMit = true;
            bullMitStop = (bullMitStop == 0.0) ? top : MathMax(bullMitStop, top);
            DrawBlock(gBlocks[i], t);
           }
         else if(l <= top && c > top)
           {
            bullRej = true;
            double s = MathMin(l, bot);
            bullRejStop = (bullRejStop == 0.0) ? s : MathMin(bullRejStop, s);
           }
        }
      else
        {
         if(c > top)
           {
            gBlocks[i].mit = true;
            bearMit = true;
            bearMitStop = (bearMitStop == 0.0) ? bot : MathMin(bearMitStop, bot);
            DrawBlock(gBlocks[i], t);
           }
         else if(h >= bot && c < bot)
           {
            bearRej = true;
            double s = MathMax(h, top);
            bearRejStop = (bearRejStop == 0.0) ? s : MathMax(bearRejStop, s);
           }
        }
     }

   if(!live)
      return;

   //--- time exit
   int holdEnd = HhmmToMin(InpHoldEnd);
   bool hasPos = HasPosition();
   if(hasPos && !(m0 >= 570 && m0 < holdEnd))
     {
      CloseAll("time exit");
      return;
     }

   //--- targets / bias (nearest untaken level each side)
   double upLvl = 0.0, dnLvl = 0.0;
   string upName = "", dnName = "";
   double lv[4];
   string nm[4];
   bool   ok[4];
   lv[0] = gPDH; nm[0] = "PDH"; ok[0] = InpUsePD && gPDH > 0.0 && !gPDHtk;
   lv[1] = gPDL; nm[1] = "PDL"; ok[1] = InpUsePD && gPDL > 0.0 && !gPDLtk;
   lv[2] = gONH; nm[2] = "ONH"; ok[2] = InpUseON && gONH > 0.0 && !gONHtk;
   lv[3] = gONL; nm[3] = "ONL"; ok[3] = InpUseON && gONL > 0.0 && !gONLtk;
   for(int k = 0; k < 4; k++)
     {
      if(!ok[k])
         continue;
      if(lv[k] > c && (upLvl == 0.0 || lv[k] < upLvl)) { upLvl = lv[k]; upName = nm[k]; }
      if(lv[k] < c && (dnLvl == 0.0 || lv[k] > dnLvl)) { dnLvl = lv[k]; dnName = nm[k]; }
     }
   bool longBias = false, shortBias = false;
   if(InpBias == BIAS_NEAREST)
     {
      if(upLvl > 0.0 && (dnLvl == 0.0 || upLvl - c <= c - dnLvl))
         longBias = true;
      else if(dnLvl > 0.0)
         shortBias = true;
     }
   else
     {
      longBias  = upLvl > 0.0;
      shortBias = dnLvl > 0.0;
     }

   //--- entry gate
   int entryEnd = HhmmToMin(InpEntryEnd);
   bool canTrade = tenToday && t > gTenBarTime && m0 >= 600 + InpWaitMin && m0 < entryEnd
                   && manipOk && !hasPos && gTradesToday < InpMaxTrades;
   if(!canTrade)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(InpMaxSpread > 0.0 && ask - bid > InpMaxSpread)
      return;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   //--- long trigger (priority: block rejection > 10 AM rejection > mitigation)
   double longStop = 0.0;
   string longWhy = "";
   if(InpUseRBRej && bullRej)                                 { longStop = bullRejStop; longWhy = "RB rejection"; }
   else if(InpUseTenRej && l <= gTen && c > gTen && o > gTen) { longStop = l;           longWhy = "10AM rejection"; }
   else if(InpUseMit && bearMit)                              { longStop = bearMitStop; longWhy = "Mitigation"; }

   double shortStop = 0.0;
   string shortWhy = "";
   if(InpUseRBRej && bearRej)                                 { shortStop = bearRejStop; shortWhy = "RB rejection"; }
   else if(InpUseTenRej && h >= gTen && c < gTen && o < gTen) { shortStop = h;           shortWhy = "10AM rejection"; }
   else if(InpUseMit && bullMit)                              { shortStop = bullMitStop; shortWhy = "Mitigation"; }

   if(longBias && longStop > 0.0)
     {
      double sl = NormalizeDouble(longStop - InpStopBuf, _Digits);
      double tp = NormalizeDouble(upLvl, _Digits);
      double risk = ask - sl;
      if(risk > minDist && tp - ask > minDist && (InpMaxStop == 0.0 || risk <= InpMaxStop) && (tp - ask) / risk >= InpMinRR)
        {
         double lots = CalcLots(risk);
         if(lots > 0.0)
           {
            if(trade.Buy(lots, _Symbol, 0.0, sl, tp, "10AM " + longWhy + " -> " + upName))
               gTradesToday++;
            else
               PrintFormat("Buy failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
           }
         else
            Print("Lot size below the broker minimum for this risk; trade skipped.");
        }
      return;
     }

   if(shortBias && shortStop > 0.0)
     {
      double sl = NormalizeDouble(shortStop + InpStopBuf, _Digits);
      double tp = NormalizeDouble(dnLvl, _Digits);
      double risk = sl - bid;
      if(risk > minDist && bid - tp > minDist && (InpMaxStop == 0.0 || risk <= InpMaxStop) && (bid - tp) / risk >= InpMinRR)
        {
         double lots = CalcLots(risk);
         if(lots > 0.0)
           {
            if(trade.Sell(lots, _Symbol, 0.0, sl, tp, "10AM " + shortWhy + " -> " + dnName))
               gTradesToday++;
            else
               PrintFormat("Sell failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
           }
         else
            Print("Lot size below the broker minimum for this risk; trade skipped.");
        }
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);

   gRBTF = InpRBTF;
   if(PeriodSeconds(gRBTF) < PeriodSeconds(_Period))
     {
      Print("Block timeframe is lower than the chart timeframe; using the chart timeframe.");
      gRBTF = (ENUM_TIMEFRAMES)_Period;
     }
   if(_Period != PERIOD_M1)
      Print("Note: this EA is designed for the M1 chart.");

   // replay recent history (no trading) so levels and blocks exist from the start
   int avail = Bars(_Symbol, _Period) - 2;
   int warm = MathMin(InpWarmupBars, avail);
   for(int s = warm; s >= 1; s--)
      ProcessBar(s, false);
   gLastBar = iTime(_Symbol, _Period, 0);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
  }

void OnTick()
  {
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == 0 || t0 == gLastBar)
      return;
   gLastBar = t0;
   ProcessBar(1, true);
  }
//+------------------------------------------------------------------+

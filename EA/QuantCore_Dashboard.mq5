//+------------------------------------------------------------------+
//|  QuantCore_Dashboard.mq5                                         |
//|  Live overlay panel — draws directly on the MT5 chart            |
//|  Shows: Account · Prop Firm Safety · Phase-1 · Signal Engine     |
//|                                                                  |
//|  Install:  Copy to  MQL5/Indicators/                             |
//|  Compile:  F7 in MetaEditor                                      |
//|  Attach:   Drag onto any QuantCore chart (EURUSD / GBPUSD /      |
//|            XAUUSD H1).  Panel appears in top-right corner.       |
//+------------------------------------------------------------------+
#property copyright   "QuantCore AI EA"
#property version     "1.00"
#property indicator_chart_window
#property indicator_plots 0

//── Inputs ──────────────────────────────────────────────────────────
input double  Inp_Deposit      = 100000.0;   // Starting deposit ($)
input double  Inp_TargetPct    = 8.0;        // Phase target % (GoatFunded = 8)
input double  Inp_MaxDaily     = 5.0;        // Broker daily loss limit %
input double  Inp_MaxTotal     = 10.0;       // Broker total DD limit %
input double  Inp_EADailyStop  = 4.5;        // EA daily stop %
input double  Inp_EATotalStop  = 9.0;        // EA total stop %
input int     Inp_RSI_Period   = 14;         // RSI period
input int     Inp_ATR_Period   = 14;         // ATR period
input int     Inp_EMA_Fast     = 20;         // Fast EMA
input int     Inp_EMA_Slow     = 200;        // Slow EMA
input int     PanelX           = 10;         // Panel X offset (right edge)
input int     PanelY           = 30;         // Panel Y offset (top)
input int     FontSize         = 8;          // Font size
input string  FontName         = "Courier New"; // Font

//── Colours ─────────────────────────────────────────────────────────
#define C_BG        C'10,14,26'       // near-black navy
#define C_BG2       C'15,21,37'       // card background
#define C_BORDER    C'30,45,74'       // border
#define C_ACCENT    C'0,212,255'      // cyan
#define C_GREEN     C'0,230,118'      // profit green
#define C_RED       C'255,23,68'      // loss red
#define C_YELLOW    C'255,215,64'     // warning yellow
#define C_DIM       C'90,106,138'     // dimmed text
#define C_WHITE     C'224,232,255'    // body text

//── Panel sizing ────────────────────────────────────────────────────
#define PANEL_W     260
#define LINE_H      16
#define PAD         8

//── Object name prefix ──────────────────────────────────────────────
#define PFX  "QC_DASH_"

//── Global state ────────────────────────────────────────────────────
int g_totalLines = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   DrawPanel();
   EventSetTimer(5);          // refresh every 5 s
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeletePanel();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
  {
   DrawPanel();
   return rates_total;
  }

//+------------------------------------------------------------------+
void OnTimer() { DrawPanel(); }

//+------------------------------------------------------------------+
//  MAIN DRAW ROUTINE
//+------------------------------------------------------------------+
void DrawPanel()
  {
   //── Account metrics ─────────────────────────────────────────────
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double deposit   = Inp_Deposit;

   // Today's closed P&L
   double todayPnl  = GetTodayPnl();
   double todayPct  = todayPnl / deposit * 100.0;

   // Drawdown
   double ddPct     = MathMax(0, (deposit - equity) / deposit * 100.0);
   double dailyDD   = MathMax(0, (deposit - equity) / deposit * 100.0); // simplified

   // Phase progress
   double netPnl    = balance - deposit;
   double netPct    = netPnl / deposit * 100.0;
   double target    = deposit * Inp_TargetPct / 100.0;
   double remaining = MathMax(0, target - netPnl);
   double phasePct  = MathMin(100, netPct / Inp_TargetPct * 100.0);

   // Days to pass (at today's pace)
   double avgDay    = (todayPnl > 0) ? todayPnl : 545.30; // fallback to last known
   int    daysToCur = (remaining > 0 && avgDay > 0) ? (int)MathCeil(remaining / avgDay) : 0;
   int    days3sym  = (remaining > 0 && avgDay > 0) ? (int)MathCeil(remaining / (avgDay * 3.5)) : 0;

   //── Signal metrics ───────────────────────────────────────────────
   double atrVal  = iATR(_Symbol, _Period, Inp_ATR_Period);
   double rsiVal  = iRSI(_Symbol, _Period, Inp_RSI_Period, PRICE_CLOSE);
   double emaFast = iMA(_Symbol, _Period, Inp_EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   double emaSlow = iMA(_Symbol, _Period, Inp_EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   double close0  = iClose(_Symbol, _Period, 0);

   string trendStr  = (close0 > emaFast && emaFast > emaSlow) ? "BULL  ▲" :
                      (close0 < emaFast && emaFast < emaSlow) ? "BEAR  ▼" : "MIXED ↔";
   color  trendCol  = (close0 > emaFast && emaFast > emaSlow) ? C_GREEN :
                      (close0 < emaFast && emaFast < emaSlow) ? C_RED   : C_YELLOW;

   // Open positions on this symbol
   int    openPos   = 0;
   double openPnl   = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
           {
            openPos++;
            openPnl += PositionGetDouble(POSITION_PROFIT);
           }
        }
     }

   //── Safety flags ────────────────────────────────────────────────
   double dailyUsedPct  = (dailyDD / Inp_MaxDaily)   * 100.0;
   double totalUsedPct  = (ddPct   / Inp_MaxTotal)   * 100.0;
   string safetyStatus  = (dailyUsedPct < 50 && totalUsedPct < 50) ? "SAFE  ✓" :
                          (dailyUsedPct < 80 && totalUsedPct < 80) ? "WATCH !" : "DANGER ✗";
   color  safetyCol     = (dailyUsedPct < 50 && totalUsedPct < 50) ? C_GREEN :
                          (dailyUsedPct < 80 && totalUsedPct < 80) ? C_YELLOW: C_RED;

   //── Build panel lines ────────────────────────────────────────────
   int ln = 0;                        // line counter
   int x  = PanelX;
   int y0 = PanelY;

   // Background
   DrawRect("_BG", x, y0, PANEL_W, 42 * LINE_H, C_BG, C_BORDER);

   // ── HEADER ──────────────────────────────────────────────────────
   DrawRect("_HDR", x, y0, PANEL_W, LINE_H + 8, C_BG2, C_ACCENT);
   DrawTxt("_H1",  "⚡ QUANTCORE AI EA",  x+PAD,   y0+4,   C_ACCENT, FontSize+1, true);
   DrawTxt("_H2",  "GoatFunded  Phase-1", x+PAD,   y0+16,  C_DIM,    FontSize-1, false);
   ln = 2;

   // ── SEPARATOR ───────────────────────────────────────────────────
   DrawSep(ln++);

   // ── ACCOUNT ─────────────────────────────────────────────────────
   DrawTxt("_SBA",  "ACCOUNT",          x+PAD, y0+RowY(ln++), C_DIM, FontSize-1, false);
   DrawKV("BAL",  "Balance",  StringFormat("$%s",  FmtMoney(balance)), (balance >= deposit) ? C_GREEN : C_RED, ln++);
   DrawKV("EQU",  "Equity",   StringFormat("$%s",  FmtMoney(equity)),  (equity  >= deposit) ? C_GREEN : C_RED, ln++);
   DrawKV("TPNL", "Today",    StringFormat("%s$%s  (%+.2f%%)",
                              (todayPnl>=0)?"+":"-", FmtMoney(MathAbs(todayPnl)), todayPct),
                              (todayPnl >= 0) ? C_GREEN : C_RED, ln++);
   DrawKV("NET",  "Net P&L",  StringFormat("%s$%s  (%+.2f%%)",
                              (netPnl>=0)?"+":"-", FmtMoney(MathAbs(netPnl)), netPct),
                              (netPnl >= 0) ? C_GREEN : C_RED, ln++);

   if(openPos > 0)
      DrawKV("OPN","Open",  StringFormat("%d pos  %s$%.2f",
             openPos, (openPnl>=0)?"+":"-", MathAbs(openPnl)),
             (openPnl>=0) ? C_GREEN : C_RED, ln++);

   // ── SEPARATOR ───────────────────────────────────────────────────
   DrawSep(ln++);

   // ── PROP FIRM SAFETY ────────────────────────────────────────────
   DrawTxt("_SPS", "PROP FIRM  " + safetyStatus, x+PAD, y0+RowY(ln++), safetyCol, FontSize-1, true);
   DrawBarLine("DLY", "Daily DD",  dailyDD,  Inp_MaxDaily,  Inp_EADailyStop, ln++);
   DrawBarLine("TOT", "Total DD",  ddPct,    Inp_MaxTotal,  Inp_EATotalStop,  ln++);

   // ── SEPARATOR ───────────────────────────────────────────────────
   DrawSep(ln++);

   // ── PHASE PROGRESS ──────────────────────────────────────────────
   DrawTxt("_SP1",  StringFormat("PHASE-1 TARGET  %.0f%%", Inp_TargetPct), x+PAD, y0+RowY(ln++), C_DIM, FontSize-1, false);
   DrawProgressLine("PH1", phasePct, ln++);
   DrawKV("PHR", "Remaining", StringFormat("$%s", FmtMoney(remaining)), C_YELLOW, ln++);
   DrawKV("PH2", "1 symbol",  StringFormat("~%d days", daysToCur),  C_WHITE,  ln++);
   DrawKV("PH3", "3 symbols", StringFormat("~%d days  ★", days3sym), C_GREEN,  ln++);

   // ── SEPARATOR ───────────────────────────────────────────────────
   DrawSep(ln++);

   // ── SIGNAL ENGINE ───────────────────────────────────────────────
   DrawTxt("_SSE",  "SIGNAL ENGINE", x+PAD, y0+RowY(ln++), C_DIM, FontSize-1, false);
   DrawKV("SYM",  "Symbol",   _Symbol,                           C_ACCENT, ln++);
   DrawKV("ATR",  "ATR",      StringFormat("%.5f", atrVal),      C_WHITE,  ln++);
   DrawKV("RSI",  "RSI(14)",  StringFormat("%.1f", rsiVal),
          (rsiVal > 70) ? C_RED : (rsiVal < 30) ? C_GREEN : C_WHITE, ln++);
   DrawKV("TRD",  "Trend",    trendStr,                          trendCol, ln++);
   DrawKV("EF",   "EMA20",    StringFormat("%.5f", emaFast),     C_DIM,    ln++);
   DrawKV("ES",   "EMA200",   StringFormat("%.5f", emaSlow),     C_DIM,    ln++);

   // ── SEPARATOR ───────────────────────────────────────────────────
   DrawSep(ln++);

   // ── SETTINGS SUMMARY ────────────────────────────────────────────
   DrawTxt("_SET",  "DEPLOYED SETTINGS", x+PAD, y0+RowY(ln++), C_DIM, FontSize-1, false);
   DrawKV("SR",   "Risk/trade",  "1.00%",         C_GREEN, ln++);
   DrawKV("SS",   "Min score",   "0.58",          C_GREEN, ln++);
   DrawKV("STP",  "TP mult",     "3.5 × ATR",     C_GREEN, ln++);
   DrawKV("STR",  "Trail",       "0.8 × ATR",     C_GREEN, ln++);

   // Resize background to actual content
   int totalH = y0 + RowY(ln) + LINE_H;
   ObjectSetInteger(0, PFX+"_BG", OBJPROP_YSIZE, totalH - y0);

   ChartRedraw(0);
   g_totalLines = ln;
  }

//+------------------------------------------------------------------+
//  HELPERS — geometry
//+------------------------------------------------------------------+
int RowY(int line) { return (2 * LINE_H + 10) + line * LINE_H; }

void DrawSep(int line)
  {
   string n = PFX + "_SEP" + IntegerToString(line);
   int    y = PanelY + RowY(line);
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, PanelX);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString (0, n, OBJPROP_TEXT,      StringFormat("%-38s", "─────────────────────────────────"));
   ObjectSetString (0, n, OBJPROP_FONT,      FontName);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  FontSize - 2);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     C_BORDER);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
  }

void DrawRect(string id, int x, int y, int w, int h, color bg, color border)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER,      CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_COLOR,       border);
   ObjectSetInteger(0, n, OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, n, OBJPROP_BACK,        true);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE,  false);
  }

void DrawTxt(string id, string txt, int x, int y, color col, int sz, bool bold)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString (0, n, OBJPROP_TEXT,      txt);
   ObjectSetString (0, n, OBJPROP_FONT,      bold ? FontName + " Bold" : FontName);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  sz);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     col);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE,false);
  }

// Key-value row
void DrawKV(string id, string key, string val, color valCol, int line)
  {
   int y = PanelY + RowY(line);
   DrawTxt("_K_"+id, StringFormat("%-12s", key), PanelX + PAD,        y, C_DIM,  FontSize,   false);
   DrawTxt("_V_"+id, val,                         PanelX + PAD + 100,  y, valCol, FontSize,   true);
  }

// Mini progress bar
void DrawProgressLine(string id, double pct, int line)
  {
   int    y      = PanelY + RowY(line);
   int    barW   = PANEL_W - PAD * 2;
   int    filled = (int)(pct / 100.0 * barW);
   color  col    = (pct < 60) ? C_ACCENT : (pct < 90) ? C_YELLOW : C_GREEN;

   // background track
   DrawRect("_PBG_"+id, PanelX + PAD, y, barW,    LINE_H - 4, C_BG2,  C_BORDER);
   // filled portion
   if(filled > 0)
      DrawRect("_PFG_"+id, PanelX + PAD, y, filled, LINE_H - 4, col,    col);
   // pct label
   DrawTxt("_PLB_"+id, StringFormat("%.1f%%", pct), PanelX + PAD + 4, y + 1, C_WHITE, FontSize - 1, true);
  }

// DD progress bar with limit markers
void DrawBarLine(string id, string label, double val, double brokerLim, double eaLim, int line)
  {
   int    y      = PanelY + RowY(line);
   int    barW   = PANEL_W - PAD * 2 - 110;
   double pct    = MathMin(100, val / brokerLim * 100.0);
   int    filled = (int)(pct / 100.0 * barW);
   color  col    = (pct < 50) ? C_GREEN : (pct < 80) ? C_YELLOW : C_RED;

   DrawTxt("_BLK_"+id, StringFormat("%-9s", label),   PanelX+PAD,        y, C_DIM, FontSize,   false);
   DrawRect("_BBG_"+id, PanelX+PAD+100, y,     barW,    LINE_H-4, C_BG2,  C_BORDER);
   if(filled > 0)
      DrawRect("_BFG_"+id, PanelX+PAD+100, y,  filled,  LINE_H-4, col,    col);
   DrawTxt("_BVL_"+id, StringFormat("%.2f%%/%.0f%%", val, brokerLim),
           PanelX+PAD+100+barW+4, y, col, FontSize, false);
  }

//+------------------------------------------------------------------+
//  TODAY'S CLOSED P&L
//+------------------------------------------------------------------+
double GetTodayPnl()
  {
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   HistorySelect(dayStart, TimeCurrent());
   double pnl = 0;
   int total  = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
              + HistoryDealGetDouble(ticket, DEAL_SWAP)
              + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
     }
   return pnl;
  }

//+------------------------------------------------------------------+
//  MONEY FORMAT  (1234567.89 → "1,234,567.89")
//+------------------------------------------------------------------+
string FmtMoney(double v)
  {
   string s   = StringFormat("%.2f", v);
   int    dot = StringFind(s, ".");
   string dec = StringSubstr(s, dot);
   string int_part = StringSubstr(s, 0, dot);
   string out = "";
   int    len = StringLen(int_part);
   for(int i = 0; i < len; i++)
     {
      if(i > 0 && (len - i) % 3 == 0) out += ",";
      out += StringSubstr(int_part, i, 1);
     }
   return out + dec;
  }

//+------------------------------------------------------------------+
//  DELETE ALL PANEL OBJECTS
//+------------------------------------------------------------------+
void DeletePanel()
  {
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i);
      if(StringFind(nm, PFX) == 0)
         ObjectDelete(0, nm);
     }
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+

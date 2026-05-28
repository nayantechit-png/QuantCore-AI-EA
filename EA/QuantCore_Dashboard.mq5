//+------------------------------------------------------------------+
//|  QuantCore_Dashboard.mq5   v3                                    |
//|  Live overlay panel — TOP-LEFT corner of the MT5 chart           |
//+------------------------------------------------------------------+
#property copyright   "QuantCore AI EA"
#property version     "3.00"
#property indicator_chart_window
#property indicator_plots 0

//── Inputs ──────────────────────────────────────────────────────────
input double Inp_Deposit     = 100000.0;  // Starting deposit ($)
input double Inp_TargetPct   = 8.0;       // Phase target % (GoatFunded = 8)
input double Inp_MaxDaily    = 5.0;       // Broker daily loss limit %
input double Inp_MaxTotal    = 10.0;      // Broker total DD limit %
input int    Inp_RSI_Period  = 14;        // RSI period
input int    Inp_ATR_Period  = 14;        // ATR period
input int    Inp_EMA_Fast    = 20;        // Fast EMA
input int    Inp_EMA_Slow    = 200;       // Slow EMA
input int    PanelLeft       = 5;         // Distance from left edge (px)
input int    PanelTop        = 25;        // Distance from top edge  (px)
input int    FontSize        = 9;         // Font size (8-10 recommended)
input string FontFace        = "Courier New";

//── Layout ───────────────────────────────────────────────────────────
#define PFX     "QCD_"
#define PANEL_W 272
#define LH      16
#define PX      8

//── Vivid colour palette ─────────────────────────────────────────────
#define C_BG      C'8,12,24'        // deep navy (opaque solid)
#define C_HDR     C'0,25,55'        // header bar
#define C_BORDER  C'0,180,230'      // bright cyan border
#define C_ACCENT  C'0,220,255'      // cyan titles
#define C_GREEN   C'0,240,110'      // profit green
#define C_RED     C'255,55,75'      // loss red
#define C_YELLOW  C'255,215,0'      // warning yellow
#define C_WHITE   C'230,240,255'    // body text
#define C_DIM     C'110,130,165'    // dim labels
#define C_SEPLINE C'30,55,100'      // separator

//── Indicator handles (MQL5: functions return handles, not values) ───
int g_hATR  = INVALID_HANDLE;
int g_hRSI  = INVALID_HANDLE;
int g_hEMAf = INVALID_HANDLE;
int g_hEMAs = INVALID_HANDLE;

//── Line counter ─────────────────────────────────────────────────────
int g_line = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   // Create indicator handles — must be done ONCE in OnInit
   g_hATR  = iATR(_Symbol, _Period, Inp_ATR_Period);
   g_hRSI  = iRSI(_Symbol, _Period, Inp_RSI_Period, PRICE_CLOSE);
   g_hEMAf = iMA (_Symbol, _Period, Inp_EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   g_hEMAs = iMA (_Symbol, _Period, Inp_EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);

   if(g_hATR==INVALID_HANDLE  || g_hRSI==INVALID_HANDLE ||
      g_hEMAf==INVALID_HANDLE || g_hEMAs==INVALID_HANDLE)
     { Print("QuantCore Dashboard: failed to create indicator handles"); return INIT_FAILED; }

   EventSetTimer(5);
   DrawPanel();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int)
  {
   EventKillTimer();
   if(g_hATR  != INVALID_HANDLE){ IndicatorRelease(g_hATR);  g_hATR  = INVALID_HANDLE; }
   if(g_hRSI  != INVALID_HANDLE){ IndicatorRelease(g_hRSI);  g_hRSI  = INVALID_HANDLE; }
   if(g_hEMAf != INVALID_HANDLE){ IndicatorRelease(g_hEMAf); g_hEMAf = INVALID_HANDLE; }
   if(g_hEMAs != INVALID_HANDLE){ IndicatorRelease(g_hEMAs); g_hEMAs = INVALID_HANDLE; }
   Wipe();
  }

void OnTimer() { DrawPanel(); }

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
  { DrawPanel(); return rates_total; }

//+------------------------------------------------------------------+
//  READ one value from an indicator buffer via handle
//+------------------------------------------------------------------+
double BufVal(int handle, int bufIndex = 0, int shift = 0)
  {
   double arr[];
   if(CopyBuffer(handle, bufIndex, shift, 1, arr) <= 0) return 0.0;
   return arr[0];
  }

//+------------------------------------------------------------------+
//  MAIN DRAW
//+------------------------------------------------------------------+
void DrawPanel()
  {
   //── Account ─────────────────────────────────────────────────────
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double deposit  = Inp_Deposit;
   double todayPnl = GetTodayPnl();
   double netPnl   = balance - deposit;
   double netPct   = netPnl  / deposit * 100.0;
   double ddPct    = MathMax(0.0, (deposit - equity) / deposit * 100.0);

   double target    = deposit * Inp_TargetPct / 100.0;
   double remaining = MathMax(0.0, target - netPnl);
   double phasePct  = MathMin(100.0, netPct / Inp_TargetPct * 100.0);
   double avgDay    = (todayPnl > 1.0) ? todayPnl : 545.30;
   int    daysCur   = (remaining > 0) ? (int)MathCeil(remaining / avgDay)        : 0;
   int    days3sym  = (remaining > 0) ? (int)MathCeil(remaining / (avgDay * 3.5)): 0;

   //── Signal (use CopyBuffer — handles created in OnInit) ──────────
   double atrVal = BufVal(g_hATR,  0, 0);
   double rsiVal = BufVal(g_hRSI,  0, 0);
   double emaF   = BufVal(g_hEMAf, 0, 0);
   double emaS   = BufVal(g_hEMAs, 0, 0);
   double px     = iClose(_Symbol, _Period, 0);

   bool   bull   = (px > emaF && emaF > emaS);
   bool   bear   = (px < emaF && emaF < emaS);
   string trendS = bull ? "BULL  ▲" : bear ? "BEAR  ▼" : "MIXED ↔";
   color  trendC = bull ? C_GREEN : bear ? C_RED : C_YELLOW;

   //── Open positions on this symbol ────────────────────────────────
   int    openPos = 0;
   double openPnl = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetTicket(i) > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
        { openPos++; openPnl += PositionGetDouble(POSITION_PROFIT); }

   //── Safety status ────────────────────────────────────────────────
   double dlyUsed = MathMin(100.0, ddPct   / Inp_MaxDaily * 100.0);
   double totUsed = MathMin(100.0, ddPct   / Inp_MaxTotal * 100.0);
   bool   safe    = (dlyUsed < 50 && totUsed < 50);
   bool   watchIt = (!safe && dlyUsed < 80 && totUsed < 80);
   string safeS   = safe    ? "SAFE  ✓" : watchIt ? "WATCH !" : "DANGER ✗";
   color  safeC   = safe    ? C_GREEN   : watchIt ? C_YELLOW  : C_RED;

   //── Reset line counter ───────────────────────────────────────────
   g_line = 0;

   //── Background (solid, drawn BEHIND everything) ──────────────────
   Rect("_bg",  0, 0, PANEL_W, 600,      C_BG,  C_BORDER, true);
   Rect("_hdr", 0, 0, PANEL_W, LH + 10,  C_HDR, C_BORDER, false);

   //── Header ───────────────────────────────────────────────────────
   Lbl("_h1", "⚡  QUANTCORE AI EA",     PX, 3,       C_ACCENT,  FontSize+1, true);
   Lbl("_h2", "GoatFunded  |  Phase-1",  PX, LH+3,   C_DIM,     FontSize-2, false);
   g_line = 3;

   Sep("s0");

   //── ACCOUNT ──────────────────────────────────────────────────────
   Hdr("a0", "ACCOUNT");
   KV("b1", "Balance",  "$" + FM(balance),   (balance >= deposit) ? C_GREEN : C_RED);
   KV("b2", "Equity",   "$" + FM(equity),    (equity  >= deposit) ? C_GREEN : C_RED);
   KV("b3", "Today",
      StringFormat("%s$%s  (%+.2f%%)", (todayPnl>=0)?"+":"-",
                   FM(MathAbs(todayPnl)), todayPnl/deposit*100.0),
      (todayPnl >= 0) ? C_GREEN : C_RED);
   KV("b4", "Net P&L",
      StringFormat("%s$%s  (%+.2f%%)", (netPnl>=0)?"+":"-",
                   FM(MathAbs(netPnl)), netPct),
      (netPnl >= 0) ? C_GREEN : C_RED);
   if(openPos > 0)
      KV("b5", "Open",
         StringFormat("%d pos  %s$%.2f", openPos,
                      (openPnl>=0)?"+":"-", MathAbs(openPnl)),
         (openPnl >= 0) ? C_GREEN : C_RED);

   Sep("s1");

   //── PROP FIRM SAFETY ─────────────────────────────────────────────
   Hdr2("pf", "PROP FIRM   " + safeS, safeC);
   BarRow("pd", "Daily DD",  ddPct,  Inp_MaxDaily);
   BarRow("pt", "Total DD",  ddPct,  Inp_MaxTotal);

   Sep("s2");

   //── PHASE-1 PROGRESS ─────────────────────────────────────────────
   Hdr("ph0", StringFormat("PHASE-1  TARGET %.0f%%", Inp_TargetPct));
   BarRow("ph1", "Progress", phasePct, 100.0);
   KV("ph2", "Remaining", "$" + FM(remaining),                           C_YELLOW);
   KV("ph3", "1 symbol",  "~" + IntegerToString(daysCur) + " days",      C_WHITE);
   KV("ph4", "3 symbols", "~" + IntegerToString(days3sym) + " days  ★",  C_GREEN);

   Sep("s3");

   //── SIGNAL ENGINE ────────────────────────────────────────────────
   Hdr("se0", "SIGNAL ENGINE");
   KV("se1", "Symbol",   _Symbol,                              C_ACCENT);
   KV("se2", "ATR",      StringFormat("%.5f", atrVal),         C_WHITE);
   KV("se3", "RSI(14)",  StringFormat("%.1f",  rsiVal),
             (rsiVal > 70) ? C_RED : (rsiVal < 30) ? C_GREEN : C_WHITE);
   KV("se4", "Trend",    trendS,                               trendC);
   KV("se5", "EMA 20",   StringFormat("%.5f", emaF),           C_DIM);
   KV("se6", "EMA 200",  StringFormat("%.5f", emaS),           C_DIM);

   Sep("s4");

   //── DEPLOYED SETTINGS ────────────────────────────────────────────
   Hdr("ds0", "SETTINGS  (DEPLOYED)");
   KV("ds1", "Risk/trade", "1.00%",      C_GREEN);
   KV("ds2", "Min score",  "0.58",       C_GREEN);
   KV("ds3", "TP mult",    "3.5 x ATR",  C_GREEN);
   KV("ds4", "Trail ATR",  "0.80",       C_GREEN);
   KV("ds5", "Max pos",    "3",          C_WHITE);

   //── Shrink background to exact content ───────────────────────────
   ObjectSetInteger(0, PFX+"_bg", OBJPROP_YSIZE, g_line * LH + LH + 6);

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//  PRIMITIVES
//+------------------------------------------------------------------+
void Rect(string id, int rx, int ry, int rw, int rh,
          color bg, color border, bool back)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,   PanelLeft + rx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,   PanelTop  + ry);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,       rw);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,       rh);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,       border);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,       1);
   ObjectSetInteger(0,n,OBJPROP_BACK,        back);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,      true);
  }

void Lbl(string id, string txt, int lx, int ly, color col, int sz, bool bold)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE, PanelLeft + lx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE, PanelTop  + ly);
   ObjectSetString (0,n,OBJPROP_TEXT,      txt);
   ObjectSetString (0,n,OBJPROP_FONT,      bold ? FontFace + " Bold" : FontFace);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,  sz);
   ObjectSetInteger(0,n,OBJPROP_COLOR,     col);
   ObjectSetInteger(0,n,OBJPROP_BACK,      false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,    true);
  }

int  LY()          { return g_line * LH + 4; }

void Sep(string id)
  {
   Lbl("_sep_"+id, "─────────────────────────────────────",
       PX, LY(), C_SEPLINE, FontSize-2, false);
   g_line++;
  }

void Hdr(string id, string txt)
  { Lbl("_h_"+id, txt, PX, LY(), C_DIM, FontSize-1, false); g_line++; }

void Hdr2(string id, string txt, color col)
  { Lbl("_h_"+id, txt, PX, LY(), col, FontSize-1, true); g_line++; }

void KV(string id, string key, string val, color vc)
  {
   int y = LY();
   Lbl("_k_"+id, StringFormat("%-11s", key), PX,     y, C_DIM,  FontSize, false);
   Lbl("_v_"+id, val,                         PX+112, y, vc,     FontSize, true);
   g_line++;
  }

void BarRow(string id, string label, double val, double limit)
  {
   int    y      = LY();
   double ratio  = (limit > 0) ? MathMin(1.0, val / limit) : 0.0;
   int    filled = (int)MathRound(ratio * 18);
   int    empty  = 18 - filled;
   color  bc     = (ratio < 0.5) ? C_GREEN : (ratio < 0.8) ? C_YELLOW : C_RED;

   string bar = "";
   for(int i = 0; i < filled; i++) bar += "█";
   for(int i = 0; i < empty;  i++) bar += "░";

   Lbl("_bk_"+id, StringFormat("%-9s", label),         PX,     y, C_DIM, FontSize,   false);
   Lbl("_bb_"+id, bar,                                  PX+90,  y, bc,    FontSize-2, false);
   Lbl("_bv_"+id, StringFormat("%.2f%%", val),          PX+218, y, bc,    FontSize,   true);
   g_line++;
  }

//+------------------------------------------------------------------+
//  TODAY'S CLOSED P&L
//+------------------------------------------------------------------+
double GetTodayPnl()
  {
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(!HistorySelect(dayStart, TimeCurrent())) return 0.0;
   double pnl = 0.0;
   int    n   = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong tkt = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tkt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         pnl += HistoryDealGetDouble(tkt, DEAL_PROFIT)
              + HistoryDealGetDouble(tkt, DEAL_SWAP)
              + HistoryDealGetDouble(tkt, DEAL_COMMISSION);
     }
   return pnl;
  }

//+------------------------------------------------------------------+
//  STRING HELPERS
//+------------------------------------------------------------------+
string FM(double v)        // "$103,537.08" formatter
  {
   string s   = StringFormat("%.2f", v);
   int    dot = StringFind(s, ".");
   string dec = StringSubstr(s, dot);
   string ip  = StringSubstr(s, 0, dot);
   string out = "";
   int    len = StringLen(ip);
   for(int i = 0; i < len; i++)
     { if(i > 0 && (len - i) % 3 == 0) out += ","; out += StringSubstr(ip, i, 1); }
   return out + dec;
  }

//+------------------------------------------------------------------+
//  WIPE on remove / deinit
//+------------------------------------------------------------------+
void Wipe()
  {
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i, 0, -1);
      if(StringFind(nm, PFX) == 0) ObjectDelete(0, nm);
     }
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+

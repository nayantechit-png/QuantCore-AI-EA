//+------------------------------------------------------------------+
//|  QuantCore_Dashboard.mq5                                         |
//|  Live overlay panel — TOP-LEFT corner of the MT5 chart           |
//|  Shows: Account · Prop Firm Safety · Phase-1 · Signal Engine     |
//|                                                                  |
//|  Install:  Copy to  MQL5/Indicators/                             |
//|  Compile:  F7 in MetaEditor (should show 0 errors, 0 warnings)   |
//|  Attach:   Drag onto EURUSD / GBPUSD / XAUUSD H1 chart           |
//+------------------------------------------------------------------+
#property copyright   "QuantCore AI EA"
#property version     "2.00"
#property indicator_chart_window
#property indicator_plots 0

//── Inputs ──────────────────────────────────────────────────────────
input double Inp_Deposit     = 100000.0;  // Starting deposit ($)
input double Inp_TargetPct   = 8.0;       // Phase target % (GoatFunded)
input double Inp_MaxDaily    = 5.0;       // Broker daily loss limit %
input double Inp_MaxTotal    = 10.0;      // Broker total DD limit %
input double Inp_EADailyStop = 4.5;       // EA daily stop %
input double Inp_EATotalStop = 9.0;       // EA total stop %
input int    Inp_RSI_Period  = 14;        // RSI period
input int    Inp_ATR_Period  = 14;        // ATR period
input int    Inp_EMA_Fast    = 20;        // Fast EMA period
input int    Inp_EMA_Slow    = 200;       // Slow EMA period
input int    PanelLeft       = 5;         // Distance from left edge (px)
input int    PanelTop        = 25;        // Distance from top edge  (px)
input int    FontSize        = 9;         // Font size
input string FontFace        = "Courier New";

//── Layout constants ─────────────────────────────────────────────────
#define PFX      "QCD_"    // object name prefix
#define PANEL_W  268        // panel width  (px)
#define LH       15         // line height  (px)
#define PX       8          // inner left padding

//── Colours ──────────────────────────────────────────────────────────
#define C_BG     C'10,14,26'
#define C_BG2    C'18,26,46'
#define C_BORDER C'40,65,110'
#define C_ACCENT C'0,212,255'
#define C_GREEN  C'0,220,100'
#define C_RED    C'255,60,80'
#define C_YELLOW C'255,210,50'
#define C_WHITE  C'210,225,255'
#define C_DIM    C'85,105,145'

//── Global: line counter used across Draw* calls ─────────────────────
int g_line = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(5);
   DrawPanel();
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int) { EventKillTimer(); Wipe(); }
void OnTimer()           { DrawPanel(); }
int  OnCalculate(const int rates_total,const int,const datetime&,
                 const double&,const double&,const double&,
                 const double&,const long&,const long&,const int&)
  { DrawPanel(); return rates_total; }

//+------------------------------------------------------------------+
//  MAIN DRAW
//+------------------------------------------------------------------+
void DrawPanel()
  {
   //── live data ──────────────────────────────────────────────────
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double deposit  = Inp_Deposit;
   double todayPnl = GetTodayPnl();
   double netPnl   = balance - deposit;
   double netPct   = netPnl  / deposit * 100.0;
   double ddPct    = MathMax(0.0, (deposit - equity) / deposit * 100.0);
   double dailyDD  = ddPct;   // simplified (no intraday peak tracking)

   double target    = deposit * Inp_TargetPct / 100.0;
   double remaining = MathMax(0.0, target - netPnl);
   double phasePct  = MathMin(100.0, netPct / Inp_TargetPct * 100.0);
   double avgDay    = (todayPnl > 1.0) ? todayPnl : 545.30;
   int    daysCur   = (remaining > 0 && avgDay > 0) ? (int)MathCeil(remaining / avgDay)        : 0;
   int    days3sym  = (remaining > 0 && avgDay > 0) ? (int)MathCeil(remaining / (avgDay*3.5))  : 0;

   double atrVal  = iATR(_Symbol, _Period, Inp_ATR_Period);
   double rsiVal  = iRSI(_Symbol, _Period, Inp_RSI_Period, PRICE_CLOSE);
   double emaF    = iMA (_Symbol, _Period, Inp_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   double emaS    = iMA (_Symbol, _Period, Inp_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   double px      = iClose(_Symbol, _Period, 0);

   bool   bull    = (px > emaF && emaF > emaS);
   bool   bear    = (px < emaF && emaF < emaS);
   string trendS  = bull ? "BULL  ▲" : bear ? "BEAR  ▼" : "MIXED ↔";
   color  trendC  = bull ? C_GREEN : bear ? C_RED : C_YELLOW;

   int    openPos = 0; double openPnl = 0;
   for(int i=0;i<PositionsTotal();i++)
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol)
        { openPos++; openPnl += PositionGetDouble(POSITION_PROFIT); }

   double dlyUsed = MathMin(100.0, dailyDD / Inp_MaxDaily  * 100.0);
   double totUsed = MathMin(100.0, ddPct   / Inp_MaxTotal  * 100.0);
   bool   safe    = (dlyUsed < 50 && totUsed < 50);
   bool   warn    = (!safe && dlyUsed < 80 && totUsed < 80);
   string safeS   = safe ? "SAFE  ✓" : warn ? "WATCH !" : "DANGER ✗";
   color  safeC   = safe ? C_GREEN   : warn ? C_YELLOW  : C_RED;

   //── reset line counter and (re)draw ────────────────────────────
   g_line = 0;

   // ── background panel (drawn first so it sits behind text) ──────
   int totalRows = 38;  // estimate; background resized at end
   Rect("_bg", 0, 0, PANEL_W, totalRows * LH + 6, C_BG, C_BORDER, true);

   // ── accent top bar ─────────────────────────────────────────────
   Rect("_hdr", 0, 0, PANEL_W, LH + 6, C_BG2, C_ACCENT, false);
   Lbl("_h1", "⚡ QUANTCORE AI EA", PX, 4, C_ACCENT, FontSize+1, true);
   Lbl("_h2", "GoatFunded  Phase-1", PX, LH+4, C_DIM, FontSize-2, false);
   g_line = 3;

   Sep("s0");

   // ── ACCOUNT ────────────────────────────────────────────────────
   Hdr("a0","ACCOUNT");
   KV("b1","Balance", "$"+FM(balance),            (balance>=deposit)?C_GREEN:C_RED);
   KV("b2","Equity",  "$"+FM(equity),             (equity >=deposit)?C_GREEN:C_RED);
   KV("b3","Today",   PSign(todayPnl)+"$"+FM(MathAbs(todayPnl))
                      +" ("+DP(todayPnl/deposit*100)+"%%)",
                      (todayPnl>=0)?C_GREEN:C_RED);
   KV("b4","Net P&L", PSign(netPnl)+"$"+FM(MathAbs(netPnl))
                      +" ("+DP(netPct)+"%%)",
                      (netPnl>=0)?C_GREEN:C_RED);
   if(openPos>0)
      KV("b5","Open",  IntegerToString(openPos)+" pos  "
                       +PSign(openPnl)+"$"+DP(MathAbs(openPnl)),
                       (openPnl>=0)?C_GREEN:C_RED);

   Sep("s1");

   // ── PROP FIRM SAFETY ────────────────────────────────────────────
   Hdr2("pf","PROP FIRM   "+safeS, safeC);
   BarRow("pd","Daily DD",  dailyDD, Inp_MaxDaily);
   BarRow("pt","Total DD",  ddPct,   Inp_MaxTotal);

   Sep("s2");

   // ── PHASE PROGRESS ──────────────────────────────────────────────
   Hdr("ph0",StringFormat("PHASE-1 TARGET  %.0f%%",Inp_TargetPct));
   BarRow("ph1","Progress", phasePct, 100.0);
   KV("ph2","Remaining","$"+FM(remaining),                C_YELLOW);
   KV("ph3","1 symbol", "~"+IntegerToString(daysCur)+" days",   C_WHITE);
   KV("ph4","3 symbols","~"+IntegerToString(days3sym)+" days  ★",C_GREEN);

   Sep("s3");

   // ── SIGNAL ENGINE ───────────────────────────────────────────────
   Hdr("se0","SIGNAL ENGINE");
   KV("se1","Symbol",  _Symbol,                           C_ACCENT);
   KV("se2","ATR",     StringFormat("%.5f",atrVal),       C_WHITE);
   KV("se3","RSI(14)", StringFormat("%.1f",rsiVal),
            (rsiVal>70)?C_RED:(rsiVal<30)?C_GREEN:C_WHITE);
   KV("se4","Trend",   trendS,                            trendC);
   KV("se5","EMA20",   StringFormat("%.5f",emaF),         C_DIM);
   KV("se6","EMA200",  StringFormat("%.5f",emaS),         C_DIM);

   Sep("s4");

   // ── DEPLOYED SETTINGS ───────────────────────────────────────────
   Hdr("ds0","DEPLOYED SETTINGS");
   KV("ds1","Risk/trade",  "1.00%",       C_GREEN);
   KV("ds2","Min score",   "0.58",        C_GREEN);
   KV("ds3","TP mult",     "3.5 × ATR",   C_GREEN);
   KV("ds4","Trail ATR",   "0.80",        C_GREEN);
   KV("ds5","Max pos",     "3",           C_WHITE);

   // resize background to exact content height
   int bgH = PanelTop + g_line * LH + LH;
   ObjectSetInteger(0, PFX+"_bg", OBJPROP_YSIZE, bgH - PanelTop);

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//  PRIMITIVE HELPERS
//+------------------------------------------------------------------+

// Draw filled rectangle
void Rect(string id, int rx, int ry, int rw, int rh,
          color bg, color border, bool back)
  {
   string n = PFX+id;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE, PanelLeft + rx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE, PanelTop  + ry);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,     rw);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,     rh);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,     border);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,     1);
   ObjectSetInteger(0,n,OBJPROP_BACK,      back);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,    true);
  }

// Draw text label
void Lbl(string id, string txt, int lx, int ly, color col, int sz, bool bold)
  {
   string n = PFX+id;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE, PanelLeft + lx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE, PanelTop  + ly);
   ObjectSetString (0,n,OBJPROP_TEXT,      txt);
   ObjectSetString (0,n,OBJPROP_FONT,      bold ? FontFace+" Bold" : FontFace);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,  sz);
   ObjectSetInteger(0,n,OBJPROP_COLOR,     col);
   ObjectSetInteger(0,n,OBJPROP_BACK,      false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,    true);
  }

// Current Y for line g_line
int LY() { return g_line * LH + 4; }

// Separator line
void Sep(string id)
  {
   Lbl("_sep_"+id,
       "────────────────────────────────",
       PX, LY(), C_BORDER, FontSize-2, false);
   g_line++;
  }

// Section header (dim)
void Hdr(string id, string txt)
  {
   Lbl("_h_"+id, txt, PX, LY(), C_DIM, FontSize-1, false);
   g_line++;
  }

// Section header (custom colour)
void Hdr2(string id, string txt, color col)
  {
   Lbl("_h_"+id, txt, PX, LY(), col, FontSize-1, true);
   g_line++;
  }

// Key-value row
void KV(string id, string key, string val, color vc)
  {
   int y = LY();
   Lbl("_k_"+id, StringFormat("%-11s",key),  PX,      y, C_DIM, FontSize, false);
   Lbl("_v_"+id, val,                         PX+110,  y, vc,    FontSize, true);
   g_line++;
  }

// Progress bar row  (val and limit in same unit, e.g. both percent)
void BarRow(string id, string label, double val, double limit)
  {
   int    y      = LY();
   int    barW   = 120;
   double ratio  = (limit > 0) ? MathMin(1.0, val / limit) : 0;
   int    filled = (int)(ratio * 20);          // 20-char bar
   int    empty  = 20 - filled;
   color  bc     = (ratio < 0.5) ? C_GREEN : (ratio < 0.8) ? C_YELLOW : C_RED;

   string bar    = "";
   for(int i=0;i<filled;i++) bar += "█";
   for(int i=0;i<empty; i++) bar += "░";

   Lbl("_bk_"+id, StringFormat("%-9s",label), PX,      y, C_DIM, FontSize,   false);
   Lbl("_bb_"+id, bar,                         PX+90,   y, bc,    FontSize-1, false);
   Lbl("_bv_"+id, StringFormat("%.1f%%%%",val), PX+220,  y, bc,    FontSize,   true);
   g_line++;
  }

//+------------------------------------------------------------------+
//  TODAY'S CLOSED P&L
//+------------------------------------------------------------------+
double GetTodayPnl()
  {
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(),TIME_DATE));
   if(!HistorySelect(dayStart, TimeCurrent())) return 0;
   double pnl = 0;
   int    n   = HistoryDealsTotal();
   for(int i=0;i<n;i++)
     {
      ulong tkt = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tkt,DEAL_ENTRY)==DEAL_ENTRY_OUT)
         pnl += HistoryDealGetDouble(tkt,DEAL_PROFIT)
               +HistoryDealGetDouble(tkt,DEAL_SWAP)
               +HistoryDealGetDouble(tkt,DEAL_COMMISSION);
     }
   return pnl;
  }

//+------------------------------------------------------------------+
//  STRING HELPERS
//+------------------------------------------------------------------+
string FM(double v)   // format money: 103537.08 → "103,537.08"
  {
   string s   = StringFormat("%.2f",v);
   int    dot = StringFind(s,".");
   string dec = StringSubstr(s,dot);
   string ip  = StringSubstr(s,0,dot);
   string out = "";
   int    len = StringLen(ip);
   for(int i=0;i<len;i++)
     { if(i>0 && (len-i)%3==0) out+=","; out+=StringSubstr(ip,i,1); }
   return out+dec;
  }

string DP(double v)   { return StringFormat("%.2f",v); }  // 2 decimal places
string PSign(double v){ return (v>=0)?"+":"-"; }

//+------------------------------------------------------------------+
//  WIPE all panel objects on deinit
//+------------------------------------------------------------------+
void Wipe()
  {
   for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
     {
      string nm=ObjectName(0,i,0,-1);
      if(StringFind(nm,PFX)==0) ObjectDelete(0,nm);
     }
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+

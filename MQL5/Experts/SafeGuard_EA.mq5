#property strict
#property description "SafeGuard EA – Account-wide circuit breaker"
#property version     "1.0"

// ═══════════════════════════════════════════════════════════════
//  INPUTS
// ═══════════════════════════════════════════════════════════════
input group "════ LOSS LIMITS ════"
input double Inp_MaxDollarLoss   = 500.0;  // Daily $ loss limit (100–1200)
input double Inp_MaxDDPercent    = 3.0;    // Max drawdown % from day open equity
input int    Inp_MaxConsecLoss   = 3;      // Consecutive losses trigger (0 = off)

input group "════ LOCKOUT ════"
input int    Inp_PauseHours      = 4;      // Hours to lock trading after trigger
input bool   Inp_CloseOnTrigger  = true;   // Close ALL open positions when triggered
input bool   Inp_AlertOnTrigger  = true;   // Send terminal alert + journal entry

input group "════ DAILY RESET ════"
input int    Inp_ResetHour       = 0;      // Hour (UTC) to reset daily counters

// ═══════════════════════════════════════════════════════════════
//  GLOBALS
// ═══════════════════════════════════════════════════════════════
double   g_dayOpenEq     = 0;       // equity at start of trading day
double   g_dayLoss       = 0;       // cumulative realised $ loss today
int      g_consecLoss    = 0;       // consecutive losing trades (all EAs)
int      g_consecWin     = 0;       // consecutive wins (resets loss counter)
datetime g_pauseUntil    = 0;       // locked until this time
datetime g_lastResetDay  = 0;       // last daily reset timestamp
double   g_peakEqToday   = 0;       // highest equity today (for DD calc)
bool     g_triggered     = false;   // has circuit breaker fired today
string   g_triggerReason = "";      // why it fired

// History tracking for consecutive loss detection
ulong    g_lastDealTicket = 0;      // last processed deal ticket

// Dashboard colours
#define SG_BG   C'15,19,29'
#define SG_HDR  C'25,33,52'
#define SG_SEP  C'40,52,78'
#define SG_WHT  C'208,216,228'
#define SG_GRN  C'42,200,95'
#define SG_RED  C'215,62,62'
#define SG_YEL  C'215,178,42'
#define SG_BLU  C'62,132,215'
#define SG_DIM  C'90,105,126'
#define SG_ORG  C'215,120,42'
#define DP      "SG_"

// ═══════════════════════════════════════════════════════════════
//  GLOBALVARIABLE KEY  (shared with all EAs on same account)
// ═══════════════════════════════════════════════════════════════
string GV_Key()
{
    return "SAFEGUARD_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
}

// ═══════════════════════════════════════════════════════════════
//  DASHBOARD HELPERS
// ═══════════════════════════════════════════════════════════════
void _R(string n, int x, int y, int w, int h, color bg, color brd = clrNONE)
{
    string nm = DP + n;
    if(ObjectFind(0, nm) < 0)
    {
        ObjectCreate(0, nm, OBJ_RECTANGLE_LABEL, 0, 0, 0);
        ObjectSetInteger(0, nm, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
        ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, nm, OBJPROP_HIDDEN,     true);
        ObjectSetInteger(0, nm, OBJPROP_BACK,       false);
    }
    ObjectSetInteger(0, nm, OBJPROP_XDISTANCE,   x);
    ObjectSetInteger(0, nm, OBJPROP_YDISTANCE,   y);
    ObjectSetInteger(0, nm, OBJPROP_XSIZE,       w);
    ObjectSetInteger(0, nm, OBJPROP_YSIZE,       h);
    ObjectSetInteger(0, nm, OBJPROP_BGCOLOR,     bg);
    ObjectSetInteger(0, nm, OBJPROP_BORDER_COLOR,(brd == clrNONE ? bg : brd));
    ObjectSetInteger(0, nm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
}

void _L(string n, string txt, int x, int y, color clr, int sz = 9)
{
    string nm = DP + n;
    if(ObjectFind(0, nm) < 0)
    {
        ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, nm, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
        ObjectSetInteger(0, nm, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
        ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, nm, OBJPROP_HIDDEN,     true);
        ObjectSetInteger(0, nm, OBJPROP_BACK,       false);
        ObjectSetString (0, nm, OBJPROP_FONT,       "Consolas");
    }
    ObjectSetString (0, nm, OBJPROP_TEXT,      txt);
    ObjectSetInteger(0, nm, OBJPROP_COLOR,     clr);
    ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,  sz);
    ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
}

void DestroyDashboard() { ObjectsDeleteAll(0, DP); ChartRedraw(0); }

// ═══════════════════════════════════════════════════════════════
//  DASHBOARD UPDATE
// ═══════════════════════════════════════════════════════════════
void UpdateDashboard()
{
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    bool   locked   = (g_pauseUntil > 0 && TimeCurrent() < g_pauseUntil);

    // Progress bars widths
    int BW = 140;    // bar width px

    int X = 20, Y = 20, W = 320, LH = 17;
    int lx = X + 10, vx = X + 175;

    // ── Header colour: RED if locked, normal if armed ─────────────
    color hdrClr = locked ? SG_RED : SG_HDR;
    _R("BG",  X-8, Y-8, W+16, 430, SG_BG, SG_SEP);
    _R("HDR", X-8, Y-8, W+16, 38,  hdrClr);
    _L("TIT", "  SAFEGUARD EA",             lx, Y,    SG_WHT, 10);
    _L("SUB", "  Circuit Breaker  v1.0 | 2026-06-03", lx, Y+15, SG_DIM, 8);

    int y = Y + 46;

    // ── STATUS ────────────────────────────────────────────────────
    string staTxt; color staClr;
    if(locked)
    {
        long secsLeft = (long)(g_pauseUntil - TimeCurrent());
        long hh = secsLeft / 3600;
        long mm = (secsLeft % 3600) / 60;
        long ss = secsLeft % 60;
        staTxt = StringFormat("● LOCKED  -%02d:%02d:%02d", hh, mm, ss);
        staClr = SG_RED;
    }
    else if(g_triggered)
    {
        staTxt = "● RESET — ARMED";
        staClr = SG_YEL;
    }
    else
    {
        staTxt = "● ARMED";
        staClr = SG_GRN;
    }

    _R("SBG", X-8, y-4, W+16, LH*3+14, C'20,26,40');
    _L("l_sta","STATUS",    lx, y, SG_DIM, 9);
    _L("v_sta", staTxt,     vx, y, staClr, 9); y += LH;
    _L("l_acc","ACCOUNT",   lx, y, SG_DIM, 9);
    _L("v_acc", IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)),
                             vx, y, SG_WHT, 9); y += LH;
    _L("l_tme","TIME (UTC)",lx, y, SG_DIM, 9);
    _L("v_tme", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                             vx, y, SG_DIM, 9); y += LH + 8;

    // ── TRIGGER REASON ────────────────────────────────────────────
    if(locked || g_triggered)
    {
        _L("h_tr","── TRIGGER ───────────────────────────", lx, y, SG_RED, 8); y += LH;
        _L("v_tr", g_triggerReason, lx, y, SG_YEL, 9); y += LH + 8;
    }

    // ── DAILY LOSS METER ─────────────────────────────────────────
    _L("h_lm","── LOSS METERS ────────────────────────", lx, y, SG_BLU, 8); y += LH;

    double lossPct  = (Inp_MaxDollarLoss > 0) ?
                      MathMin(g_dayLoss / Inp_MaxDollarLoss, 1.0) : 0.0;
    int    lossBarW = (int)(lossPct * BW);
    color  lossClr  = (lossPct >= 1.0) ? SG_RED :
                      (lossPct >= 0.7) ? SG_ORG : SG_GRN;
    _L("l_dl","Day Loss $",  lx, y, SG_DIM, 9);
    _L("v_dl", StringFormat("$%.2f / $%.0f", g_dayLoss, Inp_MaxDollarLoss),
               vx, y, lossClr, 9); y += LH;
    _R("lb_bg",  lx, y, BW,              8, SG_HDR);
    _R("lb_bar", lx, y, MathMax(2,lossBarW), 8, lossClr); y += 14;

    double ddPct  = (g_peakEqToday > 0) ?
                    MathMax(0, (g_peakEqToday - equity) / g_peakEqToday * 100.0) : 0.0;
    double ddRatio = (Inp_MaxDDPercent > 0) ? MathMin(ddPct / Inp_MaxDDPercent, 1.0) : 0.0;
    int    ddBarW  = (int)(ddRatio * BW);
    color  ddClr   = (ddRatio >= 1.0) ? SG_RED :
                     (ddRatio >= 0.7) ? SG_ORG : SG_GRN;
    _L("l_dd","Drawdown %",  lx, y, SG_DIM, 9);
    _L("v_dd", StringFormat("%.2f%% / %.1f%%", ddPct, Inp_MaxDDPercent),
               vx, y, ddClr, 9); y += LH;
    _R("db_bg",  lx, y, BW,              8, SG_HDR);
    _R("db_bar", lx, y, MathMax(2,ddBarW),  8, ddClr); y += 14;

    // ── CONSECUTIVE LOSS ─────────────────────────────────────────
    color clsClr = (Inp_MaxConsecLoss > 0 && g_consecLoss >= Inp_MaxConsecLoss) ? SG_RED :
                   (g_consecLoss > 0) ? SG_ORG : SG_GRN;
    _L("l_cl","Consec Loss", lx, y, SG_DIM, 9);
    _L("v_cl", StringFormat("%d / %d", g_consecLoss,
               (Inp_MaxConsecLoss > 0 ? Inp_MaxConsecLoss : 99)),
               vx, y, clsClr, 9); y += LH + 8;

    // ── ACCOUNT ───────────────────────────────────────────────────
    _L("h_ac","── ACCOUNT ────────────────────────────", lx, y, SG_BLU, 8); y += LH;

    double dayPnL  = equity - g_dayOpenEq;
    color  pnlClr  = (dayPnL >= 0) ? SG_GRN : SG_RED;
    _L("l_eq","Equity",      lx, y, SG_DIM, 9);
    _L("v_eq", "$"+DoubleToString(equity, 2),  vx, y, SG_WHT, 9); y += LH;
    _L("l_bl","Balance",     lx, y, SG_DIM, 9);
    _L("v_bl", "$"+DoubleToString(balance, 2), vx, y, SG_WHT, 9); y += LH;
    _L("l_dp","Day P&L",     lx, y, SG_DIM, 9);
    _L("v_dp", (dayPnL>=0?"+":"")+DoubleToString(dayPnL,2), vx, y, pnlClr, 9); y += LH;
    int openCnt = PositionsTotal();
    _L("l_op","Open Trades", lx, y, SG_DIM, 9);
    _L("v_op", IntegerToString(openCnt), vx, y, openCnt>0?SG_YEL:SG_DIM, 9); y += LH + 8;

    // ── SETTINGS ─────────────────────────────────────────────────
    _L("h_st","── LIMITS ─────────────────────────────", lx, y, SG_BLU, 8); y += LH;
    _L("l_s1","$ Loss Limit",  lx, y, SG_DIM, 9);
    _L("v_s1", "$"+DoubleToString(Inp_MaxDollarLoss,0), vx, y, SG_WHT, 9); y += LH;
    _L("l_s2","DD Limit",      lx, y, SG_DIM, 9);
    _L("v_s2", DoubleToString(Inp_MaxDDPercent,1)+"%",  vx, y, SG_WHT, 9); y += LH;
    _L("l_s3","Pause Hours",   lx, y, SG_DIM, 9);
    _L("v_s3", IntegerToString(Inp_PauseHours)+"h",     vx, y, SG_WHT, 9); y += LH;
    _L("l_s4","Consec Limit",  lx, y, SG_DIM, 9);
    _L("v_s4", (Inp_MaxConsecLoss>0)?IntegerToString(Inp_MaxConsecLoss):"OFF",
               vx, y, SG_WHT, 9); y += LH + 4;

    _R("FTR", X-8, y, W+16, 1, SG_SEP); y += 5;
    _L("v_ts", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), lx, y, SG_DIM, 8);

    ChartRedraw(0);
}

// ═══════════════════════════════════════════════════════════════
//  DAILY RESET
// ═══════════════════════════════════════════════════════════════
void DailyReset()
{
    MqlDateTime dt;  TimeToStruct(TimeCurrent(), dt);
    MqlDateTime dlt; TimeToStruct(g_lastResetDay, dlt);

    bool newDay = (g_lastResetDay == 0 || dt.day != dlt.day);
    bool atHour = (dt.hour == Inp_ResetHour);

    if(newDay && atHour)
    {
        g_dayOpenEq    = AccountInfoDouble(ACCOUNT_EQUITY);
        g_peakEqToday  = g_dayOpenEq;
        g_dayLoss      = 0.0;
        g_consecLoss   = 0;
        g_triggered    = false;
        g_triggerReason = "";
        g_lastResetDay  = TimeCurrent();
        // Keep pauseUntil — if locked, stay locked across day boundary
        Print("SafeGuard: Daily reset at ", TimeToString(TimeCurrent()));
    }
}

// ═══════════════════════════════════════════════════════════════
//  CIRCUIT BREAKER TRIGGER
// ═══════════════════════════════════════════════════════════════
void TriggerCircuitBreaker(string reason)
{
    if(g_pauseUntil > 0 && TimeCurrent() < g_pauseUntil) return;  // already locked

    g_pauseUntil    = TimeCurrent() + (datetime)(Inp_PauseHours * 3600);
    g_triggered     = true;
    g_triggerReason = reason;

    // Write expiry time to GlobalVariable — all EAs on account will see it
    GlobalVariableSet(GV_Key(), (double)g_pauseUntil);

    Print("SafeGuard TRIGGERED: ", reason,
          " — trading locked until ", TimeToString(g_pauseUntil, TIME_DATE|TIME_SECONDS));

    if(Inp_AlertOnTrigger)
        Alert("SAFEGUARD: ", reason,
              " — All EAs locked for ", Inp_PauseHours, " hours on account ",
              AccountInfoInteger(ACCOUNT_LOGIN));

    if(Inp_CloseOnTrigger)
    {
        Print("SafeGuard: Closing all open positions");
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
            MqlTradeRequest req; MqlTradeResult res;
            ZeroMemory(req); ZeroMemory(res);
            req.action   = TRADE_ACTION_DEAL;
            req.position = PositionGetTicket(i);
            req.symbol   = PositionGetString(POSITION_SYMBOL);
            req.volume   = PositionGetDouble(POSITION_VOLUME);
            req.deviation= 30;
            req.type_filling = ORDER_FILLING_FOK;
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
                req.type  = ORDER_TYPE_SELL;
                req.price = SymbolInfoDouble(req.symbol, SYMBOL_BID);
            }
            else
            {
                req.type  = ORDER_TYPE_BUY;
                req.price = SymbolInfoDouble(req.symbol, SYMBOL_ASK);
            }
            req.comment = "SafeGuard close";
            if(!OrderSend(req, res))
                Print("SafeGuard: Failed to close pos ", req.position,
                      " err=", res.retcode);
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  CHECK LOCK EXPIRY
// ═══════════════════════════════════════════════════════════════
void CheckLockExpiry()
{
    if(g_pauseUntil == 0) return;
    if(TimeCurrent() >= g_pauseUntil)
    {
        Print("SafeGuard: Lock expired — trading resumed");
        g_pauseUntil = 0;
        GlobalVariableSet(GV_Key(), 0.0);   // clear the lock
        g_dayLoss    = 0.0;
        g_consecLoss = 0;
    }
}

// ═══════════════════════════════════════════════════════════════
//  SCAN CLOSED DEALS FOR CONSECUTIVE LOSS TRACKING
// ═══════════════════════════════════════════════════════════════
void ScanNewDeals()
{
    datetime from = (g_lastResetDay > 0) ? g_lastResetDay : iTime(_Symbol, PERIOD_D1, 0);
    if(!HistorySelect(from, TimeCurrent())) return;

    int total = HistoryDealsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = HistoryDealGetTicket(i);
        if(ticket == 0) break;
        if(ticket <= g_lastDealTicket) break;   // already processed

        long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
        if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

        double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                      + HistoryDealGetDouble(ticket, DEAL_SWAP)
                      + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

        if(profit < 0)
        {
            g_dayLoss   += MathAbs(profit);
            g_consecLoss++;
            g_consecWin  = 0;
        }
        else if(profit > 0)
        {
            g_consecWin++;
            g_consecLoss = 0;
        }

        if(ticket > g_lastDealTicket) g_lastDealTicket = ticket;
    }
}

// ═══════════════════════════════════════════════════════════════
//  CHECK ALL TRIGGERS
// ═══════════════════════════════════════════════════════════════
void CheckTriggers()
{
    if(g_pauseUntil > 0 && TimeCurrent() < g_pauseUntil) return;

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity > g_peakEqToday) g_peakEqToday = equity;

    // ── 1. Dollar loss limit ──────────────────────────────────────
    if(g_dayLoss >= Inp_MaxDollarLoss)
    {
        TriggerCircuitBreaker(StringFormat(
            "Daily $ loss $%.2f hit limit $%.0f", g_dayLoss, Inp_MaxDollarLoss));
        return;
    }

    // ── 2. Drawdown % from day-open high ──────────────────────────
    if(Inp_MaxDDPercent > 0 && g_peakEqToday > 0)
    {
        double dd = (g_peakEqToday - equity) / g_peakEqToday * 100.0;
        if(dd >= Inp_MaxDDPercent)
        {
            TriggerCircuitBreaker(StringFormat(
                "Drawdown %.2f%% hit limit %.1f%%", dd, Inp_MaxDDPercent));
            return;
        }
    }

    // ── 3. Consecutive losses ─────────────────────────────────────
    if(Inp_MaxConsecLoss > 0 && g_consecLoss >= Inp_MaxConsecLoss)
    {
        TriggerCircuitBreaker(StringFormat(
            "%d consecutive losses hit limit %d",
            g_consecLoss, Inp_MaxConsecLoss));
        return;
    }
}

// ═══════════════════════════════════════════════════════════════
//  INIT / DEINIT / TICK
// ═══════════════════════════════════════════════════════════════
int OnInit()
{
    g_dayOpenEq    = AccountInfoDouble(ACCOUNT_EQUITY);
    g_peakEqToday  = g_dayOpenEq;
    g_dayLoss      = 0.0;
    g_consecLoss   = 0;
    g_pauseUntil   = 0;
    g_triggered    = false;
    g_lastResetDay = TimeCurrent();

    // Clear any stale global lock from previous session
    if(GlobalVariableCheck(GV_Key()))
    {
        datetime existing = (datetime)GlobalVariableGet(GV_Key());
        if(TimeCurrent() >= existing)
            GlobalVariableSet(GV_Key(), 0.0);
        else
        {
            // Lock is still active — restore it
            g_pauseUntil = existing;
            Print("SafeGuard: Restored active lock until ",
                  TimeToString(g_pauseUntil, TIME_DATE|TIME_SECONDS));
        }
    }

    // Replay today's closed deals to restore counters
    ScanNewDeals();

    EventSetMillisecondTimer(1000);
    Print("SafeGuard EA started | Limit=$", Inp_MaxDollarLoss,
          " DD%=", Inp_MaxDDPercent, "% Consec=", Inp_MaxConsecLoss,
          " Pause=", Inp_PauseHours, "h");
    UpdateDashboard();
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    EventKillTimer();
    DestroyDashboard();
}

void OnTick()  { /* intentionally empty — logic runs on timer */ }

void OnTimer()
{
    DailyReset();
    CheckLockExpiry();
    ScanNewDeals();
    CheckTriggers();
    UpdateDashboard();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        ScanNewDeals();
        CheckTriggers();
        UpdateDashboard();
    }
}

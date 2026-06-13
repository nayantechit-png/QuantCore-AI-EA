//+------------------------------------------------------------------+
//|                                                  FusionAI_EA.mq5 |
//|  One chart → trades the GoatFunded v8 pairs.                     |
//|                                                                  |
//|  Fusion of one month of live work:                               |
//|   • GFv8      — pair set (EURUSD GBPUSD AUDUSD NZDUSD XAUUSD)    |
//|                 and the H1-trend / M30-entry timeframe split     |
//|   • QuantCore — weighted indicator ensemble (EMA stack, RSI,     |
//|                 Stochastic, ADX/DI, Kalman filter, MTF) + the    |
//|                 prop-firm risk engine that survived FTMO demo    |
//|   • BTAI      — per-symbol self-learning MLP (32→24→12→1) with   |
//|                 every learning-pipeline fix found in live        |
//|                 forensics baked in from the first line           |
//|                                                                  |
//|  Attach to ONE chart (any symbol, any TF). Backtestable in the   |
//|  MT5 Strategy Tester (multi-currency mode is automatic — just    |
//|  run on any of the five symbols, M30 or lower).                  |
//+------------------------------------------------------------------+
#property copyright "QuantCore / BTAI fusion"
#property version   "1.13"
#property strict
#property description "FusionAI — GFv8+NAS100, H1+M30, indicator ensemble + per-symbol self-learning AI"

// ═══════════════════════════════════════════════════════════════════
//  INPUTS
// ═══════════════════════════════════════════════════════════════════
input group "═══ SYMBOLS (GoatFunded v8 set + NAS100) ═══"
input string Inp_Symbols          = "EURUSD,GBPUSD,AUDUSD,NZDUSD,XAUUSD,NAS100"; // comma list, broker suffix/alias auto-detected
input int    Inp_ServerUTCOffset  = 99;    // server minus UTC, hours. 99 = AUTO-DETECT (recommended)
input bool   Inp_IndicesNYOnly    = true;  // indices (NAS100 etc.) trade New York hours only

input group "═══ PROP FIRM RISK (GoatFunded: 5% daily / 10% total) ═══"
input double Inp_RiskPerTrade     = 0.40;  // % equity risked per trade
input double Inp_MaxDailyLoss     = 4.5;   // % — block new trades for the day (buffer under 5)
input double Inp_MaxTotalLoss     = 9.0;   // % from baseline — full stop (buffer under 10)
input double Inp_BaselineBalance  = 0;     // challenge start balance (0 = auto-capture first run)
input double Inp_TargetPct        = 8.0;   // phase target, dashboard display only
input int    Inp_MaxTradesPerDay  = 6;     // all symbols combined
input int    Inp_MaxTradesPerSym  = 2;     // per symbol per day
input int    Inp_MaxPortfolioPos  = 2;     // simultaneous open positions, all symbols
input double Inp_MaxSpread_ATR    = 0.15;  // skip entry if spread > this fraction of M30 ATR

input group "═══ ENSEMBLE SIGNAL ENGINE (QuantCore) ═══"
input double Inp_MinScore         = 0.62;  // min weighted ensemble score to trade
input double Inp_ScoreMargin      = 0.10;  // chosen side must beat opposite side by this
input double Inp_MinADX           = 18.0;  // H1 ADX floor — no-trend filter
input double W_Trend              = 0.30;  // H1 EMA stack weight
input double W_Momentum           = 0.25;  // M30 RSI + Stochastic weight
input double W_Regime             = 0.20;  // H1 ADX/DI weight
input double W_Kalman             = 0.15;  // H1 Kalman velocity weight
input double W_MTF                = 0.10;  // M30/H1 agreement weight
input double Inp_KF_Delta         = 0.0001;// Kalman process noise delta
input double Inp_KF_Ve            = 0.001; // Kalman measurement noise

input group "═══ SELF-LEARNING AI (BTAI, one model per symbol) ═══"
input double Inp_AI_Threshold     = 0.55;  // min AI score once trained
input double Inp_AI_BootstrapThr  = 0.45;  // threshold while model has < bootstrap steps
input int    Inp_BootstrapSteps   = 10;    // trades needed before normal threshold applies
input double Inp_LearnRate        = 0.001; // SGD learning rate
input double Inp_MomentumNN       = 0.90;  // SGD momentum
input int    Inp_SaveEveryN       = 5;     // save model every N training steps

input group "═══ TRADE MANAGEMENT ═══"
input double Inp_SL_ATR           = 1.6;   // SL distance, × M30 ATR
input double Inp_TP_ATR           = 3.0;   // TP distance, × M30 ATR
input double Inp_BE_R             = 1.0;   // move SL to entry at N × SL-distance profit
input bool   Inp_UseTrail         = true;  // ATR trail after break-even
input double Inp_Trail_ATR        = 1.2;   // trail distance, × M30 ATR

input group "═══ SESSIONS (UTC) ═══"
input bool   Inp_TradeLondon      = true;  // London 07–13
input bool   Inp_TradeNewYork     = true;  // New York 13–21
input bool   Inp_SkipEdgeHours    = true;  // skip 07,13,16,21 — session-transition spread spikes
input int    Inp_FridayCutoff     = 16;    // no NEW trades Friday from this UTC hour
input int    Inp_FridayCloseHour  = 20;    // close everything Friday at this UTC hour (0 = off)

input group "═══ LOSS GUARDS ═══"
input int    Inp_MaxConsecLoss    = 3;     // per symbol: pause after N straight losses
input double Inp_PauseHours       = 4.0;   // pause length, hours
input int    Inp_PortLossStreak   = 4;     // ALL symbols: pause whole EA after N straight losses (0=off)
input double Inp_PortPauseHours   = 8.0;   // whole-EA pause length, hours
input bool   Inp_BreakoutNeedsH1  = true;  // T1 breakouts must agree with the H1 trend (kills counter-trend fades)

input group "═══ MISC ═══"
input long   Inp_Magic            = 909090;
input bool   Inp_ShowDashboard    = true;

// ═══════════════════════════════════════════════════════════════════
//  NEURAL NET DIMENSIONS  (BTAI-proven 32→24→12→1)
// ═══════════════════════════════════════════════════════════════════
#define NN_IN   32
#define NN_H1L  24
#define NN_H2L  12
#define MEM_PER_SYM 8      // open-trade feature slots per symbol
#define MAX_SYMS    10

double NNSig (double x){ x = MathMax(-20.0, MathMin(20.0, x)); return 1.0/(1.0+MathExp(-x)); }
double NNRelu(double x){ return x > 0 ? x : 0; }
double NNRelD(double x){ return x > 0 ? 1.0 : 0.0; }
double NNGauss()
{
    double u1 = (MathRand()+1.0)/32769.0, u2 = (MathRand()+1.0)/32769.0;
    return MathSqrt(-2.0*MathLog(u1))*MathCos(2.0*M_PI*u2);
}

// ── per-symbol MLP with online scaler + SGD-momentum backprop ─────
struct MLP
{
    double W1[NN_H1L*NN_IN],  b1[NN_H1L];
    double W2[NN_H2L*NN_H1L], b2[NN_H2L];
    double W3[NN_H2L],        b3;
    double vW1[NN_H1L*NN_IN],  vb1[NN_H1L];
    double vW2[NN_H2L*NN_H1L], vb2[NN_H2L];
    double vW3[NN_H2L],        vb3;
    // forward-pass cache (for backprop)
    double a0[NN_IN], z1[NN_H1L], a1[NN_H1L], z2[NN_H2L], a2[NN_H2L], z3;
    // Welford online scaler
    double fm[NN_IN], fM2[NN_IN];
    long   fN;
    int    steps;

    void InitRandom()
    {
        double s1 = MathSqrt(2.0/NN_IN), s2 = MathSqrt(2.0/NN_H1L), s3 = MathSqrt(2.0/NN_H2L);
        for(int i=0;i<NN_H1L*NN_IN;i++)  { W1[i]=NNGauss()*s1; vW1[i]=0; }
        for(int i=0;i<NN_H1L;i++)        { b1[i]=0; vb1[i]=0; }
        for(int i=0;i<NN_H2L*NN_H1L;i++) { W2[i]=NNGauss()*s2; vW2[i]=0; }
        for(int i=0;i<NN_H2L;i++)        { b2[i]=0; vb2[i]=0; }
        for(int i=0;i<NN_H2L;i++)        { W3[i]=NNGauss()*s3; vW3[i]=0; }
        b3=0; vb3=0;
        for(int i=0;i<NN_IN;i++)         { fm[i]=0; fM2[i]=1.0; }
        fN=0; steps=0;
    }
    void UpdateScaler(const double &x[])
    {
        fN++;
        for(int i=0;i<NN_IN;i++)
        {
            double d = x[i]-fm[i];
            fm[i]  += d/(double)fN;
            fM2[i] += d*(x[i]-fm[i]);
        }
    }
    void Normalize(const double &x[], double &o[])
    {
        for(int i=0;i<NN_IN;i++)
        {
            double var = (fN>1) ? fM2[i]/(double)(fN-1) : 1.0;
            double std = (var>1e-10) ? MathSqrt(var) : 1.0;
            o[i] = MathMax(-3.0, MathMin(3.0, (x[i]-fm[i])/std));
        }
    }
    double Forward(const double &n[])
    {
        for(int i=0;i<NN_IN;i++) a0[i]=n[i];
        for(int r=0;r<NN_H1L;r++)
        {
            double s=b1[r];
            for(int c=0;c<NN_IN;c++) s += W1[r*NN_IN+c]*a0[c];
            z1[r]=s; a1[r]=NNRelu(s);
        }
        for(int r=0;r<NN_H2L;r++)
        {
            double s=b2[r];
            for(int c=0;c<NN_H1L;c++) s += W2[r*NN_H1L+c]*a1[c];
            z2[r]=s; a2[r]=NNRelu(s);
        }
        double s=b3;
        for(int c=0;c<NN_H2L;c++) s += W3[c]*a2[c];
        z3=s;
        return NNSig(s);
    }
    double Score(const double &f[])
    {
        double n[NN_IN]; Normalize(f,n); return Forward(n);
    }
    void Train(const double &f[], double label)
    {
        double n[NN_IN]; Normalize(f,n); Forward(n);
        double lr=Inp_LearnRate, mo=Inp_MomentumNN;
        double dz3 = NNSig(z3)-label;
        for(int c=0;c<NN_H2L;c++){ vW3[c]=mo*vW3[c]-lr*dz3*a2[c]; W3[c]+=vW3[c]; }
        vb3=mo*vb3-lr*dz3; b3+=vb3;
        double dz2[NN_H2L];
        for(int r=0;r<NN_H2L;r++) dz2[r]=W3[r]*dz3*NNRelD(z2[r]);
        for(int r=0;r<NN_H2L;r++)
        {
            for(int c=0;c<NN_H1L;c++)
            { vW2[r*NN_H1L+c]=mo*vW2[r*NN_H1L+c]-lr*dz2[r]*a1[c]; W2[r*NN_H1L+c]+=vW2[r*NN_H1L+c]; }
            vb2[r]=mo*vb2[r]-lr*dz2[r]; b2[r]+=vb2[r];
        }
        double dz1[NN_H1L];
        for(int r=0;r<NN_H1L;r++)
        {
            double d=0;
            for(int k=0;k<NN_H2L;k++) d+=W2[k*NN_H1L+r]*dz2[k];
            dz1[r]=d*NNRelD(z1[r]);
        }
        for(int r=0;r<NN_H1L;r++)
        {
            for(int c=0;c<NN_IN;c++)
            { vW1[r*NN_IN+c]=mo*vW1[r*NN_IN+c]-lr*dz1[r]*a0[c]; W1[r*NN_IN+c]+=vW1[r*NN_IN+c]; }
            vb1[r]=mo*vb1[r]-lr*dz1[r]; b1[r]+=vb1[r];
        }
        steps++;
    }
    bool Save(string fn)
    {
        int h=FileOpen(fn,FILE_WRITE|FILE_BIN);
        if(h==INVALID_HANDLE) return false;
        FileWriteInteger(h,NN_IN);  FileWriteInteger(h,NN_H1L);
        FileWriteInteger(h,NN_H2L); FileWriteInteger(h,1);
        FileWriteArray(h,W1); FileWriteArray(h,b1);
        FileWriteArray(h,W2); FileWriteArray(h,b2);
        FileWriteArray(h,W3); FileWriteDouble(h,b3);
        FileWriteArray(h,fm); FileWriteArray(h,fM2);
        FileWriteLong(h,fN);  FileWriteInteger(h,steps);
        FileClose(h);
        return true;
    }
    bool Load(string fn)
    {
        if(!FileIsExist(fn)) return false;
        int h=FileOpen(fn,FILE_READ|FILE_BIN);
        if(h==INVALID_HANDLE) return false;
        int n0=FileReadInteger(h), n1=FileReadInteger(h),
            n2=FileReadInteger(h), n3=FileReadInteger(h);
        if(n0!=NN_IN||n1!=NN_H1L||n2!=NN_H2L||n3!=1){ FileClose(h); return false; }
        FileReadArray(h,W1); FileReadArray(h,b1);
        FileReadArray(h,W2); FileReadArray(h,b2);
        FileReadArray(h,W3); b3=FileReadDouble(h);
        FileReadArray(h,fm); FileReadArray(h,fM2);
        fN=FileReadLong(h);  steps=FileReadInteger(h);
        FileClose(h);
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════
//  PER-SYMBOL CONTEXT
// ═══════════════════════════════════════════════════════════════════
struct TRec
{
    long   posId;
    double riskMoney;          // $ risked at entry → label = sigmoid(2 × profit/risk)
    double feat[NN_IN];
    bool   used;
};

struct SymCtx
{
    string sym;
    bool   isIndex;        // index CFD (NAS100 …) → NY-only sessions
    // H1 engine
    int hEMA20H1, hEMA50H1, hEMA200H1, hRSIH1, hADXH1, hATRH1;
    // M30 engine
    int hEMA20M30, hEMA50M30, hRSIM30, hStochM30, hBBM30, hATRM30;
    // Kalman (H1 closes)
    double kfPrice, kfVel, kfP, kfVw, kfVe;
    bool   kfInit;
    // bar tracking
    datetime lastM30, lastH1;
    // AI
    MLP    net;
    double pend[NN_IN];
    double pendRisk;
    bool   hasPend;
    TRec   mem[MEM_PER_SYM];
    // guards
    int      consecLoss;
    datetime pauseUntil;
    int      tradesToday;
    // dashboard cache
    double bull, bear, aiScore;
    int    lastDir;
    string reason;
    // files
    string modelFile, memFile;
};

SymCtx g_ctx[];
int    g_nSym = 0;

// ═══════════════════════════════════════════════════════════════════
//  GLOBAL RISK STATE
// ═══════════════════════════════════════════════════════════════════
double   g_baseline      = 0;     // challenge baseline balance
double   g_dailyEq       = 0;     // equity at server-day start
int      g_lastDay       = -1;
int      g_tradesToday   = 0;     // all symbols
bool     g_dailyLocked   = false;
bool     g_totalLocked   = false;
int      g_portLossStreak= 0;     // consecutive losses across ALL symbols
datetime g_portPauseUntil= 0;     // whole-EA pause after a portfolio loss streak
double   g_wSum          = 1.0;   // ensemble weight normalizer
string   g_logFile       = "fusion_log.csv";
int      g_log           = INVALID_HANDLE;

// ═══════════════════════════════════════════════════════════════════
//  SMALL HELPERS
// ═══════════════════════════════════════════════════════════════════
double GetB(int handle, int bufIdx, int shift)
{
    if(handle==INVALID_HANDLE) return 0.0;
    double a[1];
    if(CopyBuffer(handle, bufIdx, shift, 1, a) < 1) return 0.0;
    return a[0];
}

// Auto offset: live, TimeGMT() comes from the synced PC clock, so
// server−GMT gives the broker's true UTC shift (RoboForex June = +3 —
// without this, 13:56 server looked like 13 UTC = skipped edge hour
// and the EA sat "OUT OF SESSION" through the whole London morning).
// In the tester TimeGMT()==server time → offset 0, i.e. bars are UTC.
int ServerOffsetHours()
{
    if(Inp_ServerUTCOffset != 99) return Inp_ServerUTCOffset;
    return (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);
}

int UTCHour()
{
    datetime t = TimeCurrent() - (datetime)(ServerOffsetHours()*3600);
    MqlDateTime dt; TimeToStruct(t, dt);
    return dt.hour;
}
int UTCMinute()
{
    datetime t = TimeCurrent() - (datetime)(ServerOffsetHours()*3600);
    MqlDateTime dt; TimeToStruct(t, dt);
    return dt.min;
}
int UTCDow()
{
    datetime t = TimeCurrent() - (datetime)(ServerOffsetHours()*3600);
    MqlDateTime dt; TimeToStruct(t, dt);
    return dt.day_of_week;
}

// Resolve "EURUSD" → broker name ("EURUSD.x", "EURUSDm", …) and select it.
// Searches the full broker catalog (true = all symbols, not just Market Watch).
string ResolveSymbol(string base)
{
    if(SymbolSelect(base, true)) return base;
    // Search full broker catalog, case-insensitive, prefix match
    // (also matches past a leading '.' — RoboForex prefixes indices with one)
    string bu = base; StringToUpper(bu);
    int total = SymbolsTotal(true);
    for(int i=0;i<total;i++)
    {
        string s  = SymbolName(i, true);
        string su = s; StringToUpper(su);
        int pos = StringFind(su, bu);
        if(pos == 0 || (pos == 1 && StringGetCharacter(su,0)=='.'))
        {
            if(SymbolSelect(s, true)) return s;
        }
    }
    return "";
}

// Scan full broker catalog for the first symbol whose name contains any of the
// supplied keywords.  Used as a last-resort for index CFDs whose names vary wildly.
string BrokerScanForKeyword(const string &keys[], int nk)
{
    int total = SymbolsTotal(true);
    for(int i=0;i<total;i++)
    {
        string s = SymbolName(i, true);
        string su = s; StringToUpper(su);
        for(int k=0;k<nk;k++)
            if(StringFind(su, keys[k]) >= 0)
            {
                // exclude plain FX pairs — they contain letters only and are short
                if(StringLen(s) <= 6) continue;
                // exclude obvious non-index symbols
                if(StringFind(su,"USD")>=0 && StringLen(s)<=8) continue;
                if(SymbolSelect(s, true)) return s;
            }
    }
    return "";
}

// Index CFDs have no standard ticker — every broker names them differently
// (RoboForex: US100, others: USTEC, NAS100, US100Cash…). Try the aliases,
// then do a broader keyword scan so no broker naming is missed.
// isIndex flags the symbol for NY-only sessions.
string ResolveWithAliases(string base, bool &isIndex)
{
    isIndex = false;
    string aliases = "";
    string scanKeys[];
    string bu = base; StringToUpper(bu);   // case-insensitive matching

    if(bu=="NAS100" || bu=="USTEC" || bu=="US100" ||
       bu=="USTECH" || bu==".USTECHCASH" || bu=="USTECHCASH")
    {
        isIndex=true;
        // .USTECHCash = RoboForex
        aliases=".USTECHCash,USTECHCash,NAS100,USTEC,US100,US100Cash,USTEC100,NQ100,TECH100,NDX100,USTECH";
        string k[] = {"USTECH","NAS100","USTEC","US100","NQ100","TECH100","NDX","NASDAQ"};
        ArrayResize(scanKeys, ArraySize(k));
        for(int i=0;i<ArraySize(k);i++) scanKeys[i]=k[i];
    }
    else if(bu=="US30" || bu=="DJ30" || bu==".US30CASH")
    {
        isIndex=true;
        aliases=".US30Cash,US30,DJ30,US30Cash,DOW30";
        string k[] = {"US30","DJ30","DOW30","DJI"};
        ArrayResize(scanKeys, ArraySize(k));
        for(int i=0;i<ArraySize(k);i++) scanKeys[i]=k[i];
    }
    else if(bu=="SPX500" || bu=="US500" || bu==".US500CASH")
    {
        isIndex=true;
        aliases=".US500Cash,SPX500,US500,US500Cash,SP500,SPX";
        string k[] = {"SPX500","US500","SP500","SPX"};
        ArrayResize(scanKeys, ArraySize(k));
        for(int i=0;i<ArraySize(k);i++) scanKeys[i]=k[i];
    }
    else if(bu=="GER40" || bu=="DE40" || bu=="DAX40" || bu==".DE40CASH")
    {
        isIndex=true;
        aliases=".DE40Cash,GER40,DE40,DE40Cash,DAX40,GER40Cash,DAX30";
        string k[] = {"GER40","DE40","DAX40","DAX30"};
        ArrayResize(scanKeys, ArraySize(k));
        for(int i=0;i<ArraySize(k);i++) scanKeys[i]=k[i];
    }

    if(!isIndex) return ResolveSymbol(base);

    // 1) exact alias list
    string parts[];
    int n = StringSplit(aliases, ',', parts);
    for(int i=0;i<n;i++)
    {
        string s = ResolveSymbol(parts[i]);
        if(s != "") return s;
    }

    // 2) broad keyword scan over full broker catalog
    if(ArraySize(scanKeys) > 0)
    {
        string s = BrokerScanForKeyword(scanKeys, ArraySize(scanKeys));
        if(s != "")
        {
            Print("FusionAI: ",base," not found by alias — resolved to '",s,"' via keyword scan");
            return s;
        }
    }
    return "";
}

ENUM_ORDER_TYPE_FILLING FillMode(string sym)
{
    long fl = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
    if((fl & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if((fl & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

int CtxBySymbol(string sym)
{
    for(int i=0;i<g_nSym;i++)
        if(g_ctx[i].sym == sym) return i;
    return -1;
}

int PositionsForSymbol(string sym)
{
    int n=0;
    for(int i=PositionsTotal()-1;i>=0;i--)
    {
        if(PositionGetSymbol(i) != sym) continue;
        if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
        n++;
    }
    return n;
}
int PortfolioPositions()
{
    int n=0;
    for(int i=PositionsTotal()-1;i>=0;i--)
    {
        PositionGetSymbol(i);
        if(PositionGetInteger(POSITION_MAGIC) == Inp_Magic) n++;
    }
    return n;
}

// ═══════════════════════════════════════════════════════════════════
//  FEATURE-MEMORY PERSISTENCE
//  Survives EA reload / VPS restart mid-trade — without this every
//  reload silently destroys the features of open trades and the
//  network never learns from them (found in BTAI live forensics).
// ═══════════════════════════════════════════════════════════════════
void SaveMem(SymCtx &c)
{
    int h=FileOpen(c.memFile, FILE_WRITE|FILE_BIN);
    if(h==INVALID_HANDLE) return;
    int cnt=0;
    for(int i=0;i<MEM_PER_SYM;i++) if(c.mem[i].used) cnt++;
    FileWriteInteger(h,cnt);
    for(int i=0;i<MEM_PER_SYM;i++)
        if(c.mem[i].used)
        {
            FileWriteLong(h, c.mem[i].posId);
            FileWriteDouble(h, c.mem[i].riskMoney);
            FileWriteArray(h, c.mem[i].feat);
        }
    FileClose(h);
}
void LoadMem(SymCtx &c)
{
    for(int i=0;i<MEM_PER_SYM;i++) c.mem[i].used=false;
    if(!FileIsExist(c.memFile)) return;
    int h=FileOpen(c.memFile, FILE_READ|FILE_BIN);
    if(h==INVALID_HANDLE) return;
    int cnt=FileReadInteger(h);
    for(int i=0;i<cnt && i<MEM_PER_SYM;i++)
    {
        c.mem[i].posId     = FileReadLong(h);
        c.mem[i].riskMoney = FileReadDouble(h);
        FileReadArray(h, c.mem[i].feat);
        c.mem[i].used      = true;
    }
    FileClose(h);
    if(cnt>0) Print("FusionAI ",c.sym,": restored ",cnt," open-trade feature set(s) from disk");
}

void AssignPend(SymCtx &c, long posId)
{
    if(!c.hasPend) return;
    for(int i=0;i<MEM_PER_SYM;i++)
        if(!c.mem[i].used)
        {
            c.mem[i].posId     = posId;
            c.mem[i].riskMoney = c.pendRisk;
            for(int j=0;j<NN_IN;j++) c.mem[i].feat[j]=c.pend[j];
            c.mem[i].used = true;
            c.hasPend = false;
            SaveMem(c);
            return;
        }
    c.hasPend = false;
}

// ═══════════════════════════════════════════════════════════════════
//  KALMAN FILTER  (per symbol, updated once per closed H1 bar —
//  deterministic in backtests, identical live)
// ═══════════════════════════════════════════════════════════════════
void UpdateKalman(SymCtx &c)
{
    double price = iClose(c.sym, PERIOD_H1, 1);
    if(price <= 0) return;
    if(!c.kfInit)
    {
        c.kfPrice=price; c.kfVel=0; c.kfP=1.0; c.kfInit=true;
        return;
    }
    double P_pred = c.kfP + c.kfVw;
    double innov  = price - c.kfPrice;
    double K      = P_pred / (P_pred + c.kfVe);
    double pNew   = c.kfPrice + K*innov;
    c.kfP    = (1.0-K)*P_pred;
    c.kfVel  = pNew - c.kfPrice;
    c.kfPrice= pNew;
}

// ═══════════════════════════════════════════════════════════════════
//  ENSEMBLE SCORING  (QuantCore-proven, H1 regime + M30 momentum)
// ═══════════════════════════════════════════════════════════════════
bool CalcEnsemble(SymCtx &c, double &bull, double &bear)
{
    bull=0; bear=0;

    double ema20H  = GetB(c.hEMA20H1, 0,1), ema50H = GetB(c.hEMA50H1,0,1),
           ema200H = GetB(c.hEMA200H1,0,1);
    double closeH1 = iClose(c.sym, PERIOD_H1, 1);
    if(ema200H<=0 || closeH1<=0) return false;

    // 1 ── TREND: H1 EMA stack
    double tB=0, tR=0;
    if(closeH1 > ema20H)  tB+=0.25; else tR+=0.25;
    if(closeH1 > ema50H)  tB+=0.25; else tR+=0.25;
    if(closeH1 > ema200H) tB+=0.25; else tR+=0.25;
    if(ema20H>ema50H && ema50H>ema200H)      tB+=0.25;
    else if(ema20H<ema50H && ema50H<ema200H) tR+=0.25;

    // 2 ── MOMENTUM: M30 RSI bands + Stochastic (entry timeframe)
    double rsi = GetB(c.hRSIM30,0,1);
    double K   = GetB(c.hStochM30,0,1), D = GetB(c.hStochM30,1,1);
    double mB=0, mR=0;
    if(rsi>55 && rsi<70)      mB+=0.35;
    else if(rsi>30 && rsi<45) mR+=0.35;
    else if(rsi<=30)          mB+=0.25;   // oversold bounce
    else if(rsi>=70)          mR+=0.25;   // overbought fade
    if(K>D && K<80) mB+=0.30;
    if(K<D && K>20) mR+=0.30;
    if(K<20) mB+=0.30;
    if(K>80) mR+=0.30;
    mB=MathMin(mB,1.0); mR=MathMin(mR,1.0);

    // 3 ── REGIME: H1 ADX with DI direction
    double adx=GetB(c.hADXH1,0,1), dip=GetB(c.hADXH1,1,1), dim=GetB(c.hADXH1,2,1);
    double aN = MathMin(adx/50.0, 1.0);
    double rB, rR;
    if(dip>dim){ rB=aN; rR=0.5-aN*0.5; }
    else       { rR=aN; rB=0.5-aN*0.5; }

    // 4 ── KALMAN: H1 velocity, ATR-normalized confidence
    double atrH = GetB(c.hATRH1,0,1);
    double kB=0.5, kR=0.5;
    if(atrH>0)
    {
        double conf = MathMin(MathAbs(c.kfVel)/(atrH*0.05+1e-10), 1.0);
        if(c.kfVel>0){ kB=0.5+conf*0.5; kR=1.0-kB; }
        else         { kR=0.5+conf*0.5; kB=1.0-kR; }
    }

    // 5 ── MTF: M30 and H1 must agree
    double ema50M = GetB(c.hEMA50M30,0,1);
    double closeM = iClose(c.sym, PERIOD_M30, 1);
    double rsiH1  = GetB(c.hRSIH1,0,1);
    double xB=0, xR=0;
    if(closeM>ema50M && closeH1>ema50H) xB+=0.5;
    else if(closeM<ema50M && closeH1<ema50H) xR+=0.5;
    if(rsiH1>50) xB+=0.5; else xR+=0.5;

    bull = (tB*W_Trend + mB*W_Momentum + rB*W_Regime + kB*W_Kalman + xB*W_MTF)/g_wSum;
    bear = (tR*W_Trend + mR*W_Momentum + rR*W_Regime + kR*W_Kalman + xR*W_MTF)/g_wSum;
    return true;
}

// ═══════════════════════════════════════════════════════════════════
//  ENTRY TRIGGERS  (closed M30 bar)
//   T1 BREAKOUT  — close[1] breaks the 20-bar range (bars 2..21);
//                  range must be 0.5–5 ATR wide (BTAI's fixed logic)
//   T2 PULLBACK  — tag of M30 EMA20 in an H1 trend + stoch turn
//  Returns 0 (none) / +1 / −1.
// ═══════════════════════════════════════════════════════════════════
int EntryTrigger(SymCtx &c, string &tag)
{
    double atr = GetB(c.hATRM30,0,1);
    if(atr <= 0) return 0;
    double close1 = iClose(c.sym, PERIOD_M30, 1);
    double open1  = iOpen (c.sym, PERIOD_M30, 1);
    if(close1<=0) return 0;

    // H1 trend (shared by both triggers)
    double ema50H = GetB(c.hEMA50H1,0,1), ema200H = GetB(c.hEMA200H1,0,1);
    double closeH = iClose(c.sym, PERIOD_H1, 1);
    bool upH1   = (closeH>ema50H && ema50H>ema200H);
    bool downH1 = (closeH<ema50H && ema50H<ema200H);

    // ── T1: range breakout ──────────────────────────────────────
    // Counter-trend breakouts are the main false-breakout trap (they were
    // behind the EURUSD sell-then-buy whipsaw). Optionally require the
    // breakout to align with the H1 trend.
    int hiI = iHighest(c.sym, PERIOD_M30, MODE_HIGH, 20, 2);
    int loI = iLowest (c.sym, PERIOD_M30, MODE_LOW,  20, 2);
    if(hiI>=0 && loI>=0)
    {
        double rHigh = iHigh(c.sym, PERIOD_M30, hiI);
        double rLow  = iLow (c.sym, PERIOD_M30, loI);
        double w = (rHigh-rLow)/atr;
        if(w>=0.5 && w<=5.0)
        {
            if(close1 > rHigh && (!Inp_BreakoutNeedsH1 || upH1))
            { tag="BRK"; return  1; }
            if(close1 < rLow  && (!Inp_BreakoutNeedsH1 || downH1))
            { tag="BRK"; return -1; }
        }
    }

    // ── T2: pullback-resume ─────────────────────────────────────
    double ema20M = GetB(c.hEMA20M30,0,1);
    double K1=GetB(c.hStochM30,0,1), D1=GetB(c.hStochM30,1,1);
    double K2=GetB(c.hStochM30,0,2), D2=GetB(c.hStochM30,1,2);
    double low1 = iLow (c.sym, PERIOD_M30, 1);
    double high1= iHigh(c.sym, PERIOD_M30, 1);

    if(upH1 && low1 <= ema20M+0.3*atr && close1>open1 &&
       K1>D1 && K2<=D2 && K1<60)            // stoch turning up from pullback
    { tag="PBK"; return 1; }

    if(downH1 && high1 >= ema20M-0.3*atr && close1<open1 &&
       K1<D1 && K2>=D2 && K1>40)            // stoch turning down from rally
    { tag="PBK"; return -1; }

    return 0;
}

// ═══════════════════════════════════════════════════════════════════
//  FEATURES  (32, all closed-bar, all symbol-relative — no pip math)
// ═══════════════════════════════════════════════════════════════════
void BuildFeatures(SymCtx &c, int dir, double ensScore, double &f[])
{
    double atr  = GetB(c.hATRM30,0,1);  if(atr <=0) atr =1;
    double atrH = GetB(c.hATRH1, 0,1);  if(atrH<=0) atrH=1;
    double cl   = iClose(c.sym, PERIOD_M30, 1); if(cl<=0) cl=1;

    double ema20H=GetB(c.hEMA20H1,0,1), ema50H=GetB(c.hEMA50H1,0,1),
           ema200H=GetB(c.hEMA200H1,0,1);
    double closeH=iClose(c.sym,PERIOD_H1,1);
    double bid=SymbolInfoDouble(c.sym,SYMBOL_BID), ask=SymbolInfoDouble(c.sym,SYMBOL_ASK);

    f[0]=atr/cl;
    f[1]=(ask-bid)/atr;
    f[2]=(ema20H-ema50H)/atrH;
    f[3]=(ema50H-ema200H)/atrH;
    f[4]=(closeH-ema200H)/atrH;
    f[5]=GetB(c.hADXH1,0,1)/50.0;
    f[6]=(GetB(c.hADXH1,1,1)-GetB(c.hADXH1,2,1))/50.0;
    f[7]=GetB(c.hRSIM30,0,1)/100.0;
    f[8]=GetB(c.hRSIH1,0,1)/100.0;
    f[9]=GetB(c.hStochM30,0,1)/100.0;
    f[10]=(GetB(c.hStochM30,0,1)-GetB(c.hStochM30,1,1))/100.0;
    double bbU=GetB(c.hBBM30,1,1), bbL=GetB(c.hBBM30,2,1), bbM=GetB(c.hBBM30,0,1);
    f[11]=(bbU-bbL)/atr;
    f[12]=(bbU-bbL>1e-10)?MathMax(-1.0,MathMin(1.0,(cl-bbM)/((bbU-bbL)*0.5))):0.0;
    f[13]=c.kfVel/atrH;
    f[14]=(closeH-c.kfPrice)/atrH;
    f[15]=(double)dir;
    f[16]=UTCHour()/23.0;
    f[17]=UTCDow()/6.0;
    for(int k=0;k<5;k++)
        f[18+k]=(iClose(c.sym,PERIOD_M30,k+1)-iOpen(c.sym,PERIOD_M30,k+1))/atr;
    for(int k=0;k<3;k++)
        f[23+k]=(iHigh(c.sym,PERIOD_M30,k+1)-iLow(c.sym,PERIOD_M30,k+1))/atr;
    double o1=iOpen(c.sym,PERIOD_M30,1), c1=iClose(c.sym,PERIOD_M30,1);
    double h1=iHigh(c.sym,PERIOD_M30,1), l1=iLow(c.sym,PERIOD_M30,1);
    f[26]=(h1-MathMax(o1,c1))/atr;
    f[27]=(MathMin(o1,c1)-l1)/atr;
    f[28]=(cl-iClose(c.sym,PERIOD_M30,10))/atr;
    double dH=iHigh(c.sym,PERIOD_D1,1), dL=iLow(c.sym,PERIOD_D1,1);
    f[29]=(dH>0)?(cl-dH)/atr:0;
    f[30]=(dL>0)?(cl-dL)/atr:0;
    f[31]=ensScore;
}

// ═══════════════════════════════════════════════════════════════════
//  RISK + GUARDS
// ═══════════════════════════════════════════════════════════════════
void DailyReset()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day == g_lastDay) return;
    g_lastDay     = dt.day;
    g_tradesToday = 0;
    g_dailyEq     = AccountInfoDouble(ACCOUNT_EQUITY);
    g_dailyLocked = false;
    for(int i=0;i<g_nSym;i++) g_ctx[i].tradesToday=0;
    Print("FusionAI: daily reset | equity=", DoubleToString(g_dailyEq,2));
}

bool RiskLocked(string &why)
{
    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    if(g_totalLocked){ why="TOTAL LOSS LOCK"; return true; }
    if(g_baseline>0 && (eq-g_baseline)/g_baseline*100.0 <= -Inp_MaxTotalLoss)
    {
        g_totalLocked=true;
        why="TOTAL LOSS LOCK";
        Print("FusionAI: TOTAL loss limit hit — trading stopped permanently");
        return true;
    }
    if(g_dailyLocked){ why="DAILY LOSS LOCK"; return true; }
    if(g_dailyEq>0 && (eq-g_dailyEq)/g_dailyEq*100.0 <= -Inp_MaxDailyLoss)
    {
        g_dailyLocked=true;
        why="DAILY LOSS LOCK";
        Print("FusionAI: daily loss limit hit — locked until next day");
        return true;
    }
    if(g_tradesToday >= Inp_MaxTradesPerDay){ why="DAY TRADE CAP"; return true; }
    return false;
}

bool InSession(bool isIndex)
{
    int h = UTCHour();
    bool lon = Inp_TradeLondon  && (h>=7  && h<13);
    bool ny  = Inp_TradeNewYork && (h>=13 && h<21);
    if(isIndex && Inp_IndicesNYOnly) lon = false;   // NAS100: US cash hours only
    if(!(lon||ny)) return false;
    if(Inp_SkipEdgeHours && (h==7||h==13||h==16||h==21)) return false;
    if(UTCDow()==5 && h>=Inp_FridayCutoff) return false;   // Friday wind-down
    return true;
}

// Exact symbol-agnostic sizing: loss-per-lot from tick value/size.
// No pip conventions anywhere → can't repeat the June-8 10x-lots bug.
double CalcLots(string sym, double slDist)
{
    if(slDist<=0) return 0;
    double tv=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
    double ts=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
    if(tv<=0||ts<=0) return 0;
    double lossPerLot = slDist/ts*tv;
    if(lossPerLot<=0) return 0;
    double riskMoney  = AccountInfoDouble(ACCOUNT_EQUITY)*Inp_RiskPerTrade/100.0;
    double lot = riskMoney/lossPerLot;
    double mn=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
    double mx=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
    double st=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
    if(st>0) lot=MathFloor(lot/st)*st;
    lot=MathMax(mn,MathMin(mx,lot));
    // margin sanity: stay under 50% of free margin
    double margin=0;
    double px=SymbolInfoDouble(sym,SYMBOL_ASK);
    if(OrderCalcMargin(ORDER_TYPE_BUY,sym,lot,px,margin) && margin>0)
    {
        double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
        if(margin > fm*0.5 && st>0)
        {
            lot=MathFloor(lot*(fm*0.5/margin)/st)*st;
            if(lot<mn) return 0;
        }
    }
    return lot;
}

// ═══════════════════════════════════════════════════════════════════
//  LOGGER
// ═══════════════════════════════════════════════════════════════════
void InitLogger()
{
    g_log=FileOpen(g_logFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
    if(g_log!=INVALID_HANDLE)
    {
        if(FileSize(g_log)==0)
            FileWrite(g_log,"time","type","symbol","posId","dir","entry","sl","tp",
                      "lots","ens","ai","profit","steps","tag");
        FileSeek(g_log,0,SEEK_END);
    }
}
void LogRow(string type,string sym,long posId,int dir,double entry,double sl,
            double tp,double lots,double ens,double ai,double profit,int steps,string tag)
{
    if(g_log==INVALID_HANDLE) return;
    FileWrite(g_log,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
              type,sym,(string)posId,dir,entry,sl,tp,lots,ens,ai,profit,steps,tag);
    FileFlush(g_log);
}

// ═══════════════════════════════════════════════════════════════════
//  TRADE EXECUTION
// ═══════════════════════════════════════════════════════════════════
void TryOpen(SymCtx &c)
{
    c.reason="";

    // ── global guards ────────────────────────────────────────────
    string why;
    if(!InSession(c.isIndex))              { c.reason="OUT OF SESSION";   return; }
    if(RiskLocked(why))                    { c.reason=why;                return; }
    if(g_portPauseUntil>0 && TimeCurrent()<g_portPauseUntil)
                                           { c.reason="EA LOSS-STREAK PAUSE"; return; }
    if(c.pauseUntil>0 && TimeCurrent()<c.pauseUntil)
                                           { c.reason="LOSS PAUSE";       return; }
    if(c.tradesToday >= Inp_MaxTradesPerSym){ c.reason="SYM TRADE CAP";   return; }
    if(PositionsForSymbol(c.sym) >= 1)     { c.reason="IN TRADE";         return; }
    if(PortfolioPositions() >= Inp_MaxPortfolioPos)
                                           { c.reason="PORTFOLIO FULL";   return; }

    // ── regime floor ─────────────────────────────────────────────
    double adx = GetB(c.hADXH1,0,1);
    if(adx < Inp_MinADX)                   { c.reason="ADX LOW";          return; }

    // ── ensemble ─────────────────────────────────────────────────
    double bull,bear;
    if(!CalcEnsemble(c,bull,bear))         { c.reason="DATA WAIT";        return; }
    c.bull=bull; c.bear=bear;

    // ── trigger ──────────────────────────────────────────────────
    string tag="";
    int dir = EntryTrigger(c, tag);
    if(dir==0)                             { c.reason="NO TRIGGER";       return; }

    double myScore = (dir>0)?bull:bear;
    double opScore = (dir>0)?bear:bull;
    if(myScore < Inp_MinScore)             { c.reason=StringFormat("ENS LOW %.2f",myScore); return; }
    if(myScore-opScore < Inp_ScoreMargin)  { c.reason="ENS AMBIGUOUS";    return; }

    // ── spread (ATR-relative — works identically on FX and Gold) ─
    double atr  = GetB(c.hATRM30,0,1);
    double bid  = SymbolInfoDouble(c.sym,SYMBOL_BID);
    double ask  = SymbolInfoDouble(c.sym,SYMBOL_ASK);
    if(atr<=0)                             { c.reason="NO ATR";           return; }
    if((ask-bid) > atr*Inp_MaxSpread_ATR)  { c.reason="SPREAD WIDE";      return; }

    // ── AI gate ──────────────────────────────────────────────────
    double feat[NN_IN];
    BuildFeatures(c, dir, myScore, feat);
    c.net.UpdateScaler(feat);
    double ai = c.net.Score(feat);
    c.aiScore=ai; c.lastDir=dir;
    double aiThr = (c.net.steps < Inp_BootstrapSteps) ? Inp_AI_BootstrapThr : Inp_AI_Threshold;
    if(ai < aiThr)
    {
        c.reason = StringFormat("%s %.2f", (c.net.steps<Inp_BootstrapSteps)?"BOOT":"AI LOW", ai);
        LogRow("SKIP",c.sym,0,dir,0,0,0,0,myScore,ai,0,c.net.steps,tag);
        return;
    }

    // ── construct order ──────────────────────────────────────────
    int    dg     = (int)SymbolInfoInteger(c.sym,SYMBOL_DIGITS);
    double pt     = SymbolInfoDouble(c.sym,SYMBOL_POINT);
    double price  = (dir>0)?ask:bid;
    double slDist = atr*Inp_SL_ATR;
    double tpDist = atr*Inp_TP_ATR;
    double minStop= SymbolInfoInteger(c.sym,SYMBOL_TRADE_STOPS_LEVEL)*pt;
    // SL must clear broker min-stop AND be at least 4 spreads wide —
    // the absolute floor that stops spread-spike instant stop-outs
    slDist = MathMax(slDist, MathMax(minStop, (ask-bid)*4.0));
    tpDist = MathMax(tpDist, minStop);

    double sl = NormalizeDouble((dir>0)?price-slDist:price+slDist, dg);
    double tp = NormalizeDouble((dir>0)?price+tpDist:price-tpDist, dg);

    double lots = CalcLots(c.sym, slDist);
    if(lots<=0)                            { c.reason="LOT CALC 0";       return; }

    double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY)*Inp_RiskPerTrade/100.0;

    MqlTradeRequest rq; MqlTradeResult rs;
    ZeroMemory(rq); ZeroMemory(rs);
    rq.action       = TRADE_ACTION_DEAL;
    rq.symbol       = c.sym;
    rq.magic        = (ulong)Inp_Magic;
    rq.volume       = lots;
    rq.type         = (dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
    rq.price        = price;
    rq.sl           = sl;
    rq.tp           = tp;
    rq.type_filling = FillMode(c.sym);
    rq.comment      = StringFormat("FAI %s e%.2f a%.2f",tag,myScore,ai);

    // Features stored BEFORE OrderSend — OnTradeTransaction(DEAL_ENTRY_IN)
    // fires DURING the call; storing after = features lost = zero learning.
    // This exact bug cost BTAI its entire first week of training data.
    for(int j=0;j<NN_IN;j++) c.pend[j]=feat[j];
    c.pendRisk = riskMoney;
    c.hasPend  = true;

    if(OrderSend(rq,rs))
    {
        g_tradesToday++;
        c.tradesToday++;
        c.reason = StringFormat("OPENED #%I64d",(long)rs.order);
        LogRow("OPEN",c.sym,(long)rs.order,dir,price,sl,tp,lots,myScore,ai,0,c.net.steps,tag);
    }
    else
    {
        c.hasPend=false;
        c.reason = StringFormat("ERR %d",(int)rs.retcode);
        Print("FusionAI ",c.sym,": OrderSend failed ",rs.retcode," ",rs.comment);
    }
}

// ── BE + ATR-trail, every tick, all symbols ───────────────────────
void ManageAll()
{
    for(int i=PositionsTotal()-1;i>=0;i--)
    {
        string sym = PositionGetSymbol(i);
        if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
        int ci = CtxBySymbol(sym);
        if(ci<0) continue;

        ulong  tk   = (ulong)PositionGetInteger(POSITION_TICKET);
        double en   = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl   = PositionGetDouble(POSITION_SL);
        double tp   = PositionGetDouble(POSITION_TP);
        bool isBuy  = ((int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
        double bid  = SymbolInfoDouble(sym,SYMBOL_BID);
        double ask  = SymbolInfoDouble(sym,SYMBOL_ASK);
        int    dg   = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
        double pt   = SymbolInfoDouble(sym,SYMBOL_POINT);

        // Friday hard close
        if(Inp_FridayCloseHour>0 && UTCDow()==5 && UTCHour()>=Inp_FridayCloseHour)
        {
            MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
            rq.action=TRADE_ACTION_DEAL; rq.position=tk; rq.symbol=sym;
            rq.volume=PositionGetDouble(POSITION_VOLUME);
            rq.magic=(ulong)Inp_Magic; rq.type_filling=FillMode(sym);
            if(isBuy){ rq.type=ORDER_TYPE_SELL; rq.price=bid; }
            else     { rq.type=ORDER_TYPE_BUY;  rq.price=ask; }
            rq.comment="FAI FRI CLOSE";
            if(!OrderSend(rq,rs)) Print("FusionAI: Friday close failed ",rs.retcode);
            continue;
        }

        double slDist = MathAbs(en-sl);
        if(slDist < pt) continue;
        bool beDone = isBuy ? (sl >= en-pt) : (sl <= en+pt);

        double newSL = 0;
        if(!beDone)
        {
            // step 1: lock break-even at +1R
            if(Inp_BE_R>0)
            {
                double trig = slDist*Inp_BE_R;
                bool hit = isBuy ? (bid>=en+trig) : (ask<=en-trig);
                if(hit) newSL = isBuy ? en+pt*10 : en-pt*10;   // entry ± small buffer
            }
        }
        else if(Inp_UseTrail)
        {
            // step 2: ATR trail (only ever tightens)
            double atr = GetB(g_ctx[ci].hATRM30,0,1);
            if(atr>0)
            {
                double t = isBuy ? bid-atr*Inp_Trail_ATR : ask+atr*Inp_Trail_ATR;
                if(isBuy  && t > sl+pt) newSL=t;
                if(!isBuy && t < sl-pt) newSL=t;
            }
        }
        if(newSL<=0) continue;

        MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
        rq.action=TRADE_ACTION_SLTP; rq.position=tk; rq.symbol=sym;
        rq.sl=NormalizeDouble(newSL,dg); rq.tp=tp;
        if(!OrderSend(rq,rs) && rs.retcode!=TRADE_RETCODE_NO_CHANGES)
            Print("FusionAI ",sym,": SLTP modify failed ",rs.retcode);
    }
}

// ═══════════════════════════════════════════════════════════════════
//  LEARNING ON CLOSE
// ═══════════════════════════════════════════════════════════════════
void HandleClose(SymCtx &c, long posId, double profit)
{
    bool learned=false;
    for(int i=0;i<MEM_PER_SYM;i++)
        if(c.mem[i].used && c.mem[i].posId==posId)
        {
            double f[NN_IN];
            for(int j=0;j<NN_IN;j++) f[j]=c.mem[i].feat[j];
            double risk = c.mem[i].riskMoney;
            c.mem[i].used=false;
            SaveMem(c);
            // R-multiple label: symbol-size-agnostic, unlike equity-% labels
            double R     = (risk>0)?profit/risk:0;
            double label = NNSig(2.0*R);
            c.net.Train(f,label);
            if(c.net.steps % Inp_SaveEveryN == 0) c.net.Save(c.modelFile);
            Print("FusionAI ",c.sym,": learn step=",c.net.steps,
                  " R=",DoubleToString(R,2)," label=",DoubleToString(label,3));
            learned=true;
            break;
        }
    if(!learned)
        Print("FusionAI ",c.sym,": no stored features for posId=",posId," — skipping backprop");

    LogRow("CLOSE",c.sym,posId,0,0,0,0,0,0,0,profit,c.net.steps,"");

    if(profit<0)
    {
        c.consecLoss++;
        if(Inp_MaxConsecLoss>0 && c.consecLoss>=Inp_MaxConsecLoss)
        {
            c.pauseUntil = TimeCurrent()+(datetime)(Inp_PauseHours*3600.0);
            c.consecLoss = 0;
            Print("FusionAI ",c.sym,": ",Inp_MaxConsecLoss," straight losses — paused until ",
                  TimeToString(c.pauseUntil));
        }
        // portfolio-wide streak: a run of losses ACROSS symbols signals a
        // bad regime day — pause the whole EA, not just one symbol.
        g_portLossStreak++;
        if(Inp_PortLossStreak>0 && g_portLossStreak>=Inp_PortLossStreak)
        {
            g_portPauseUntil = TimeCurrent()+(datetime)(Inp_PortPauseHours*3600.0);
            g_portLossStreak = 0;
            Print("FusionAI: ",Inp_PortLossStreak," straight losses across all symbols — ",
                  "WHOLE EA paused until ",TimeToString(g_portPauseUntil));
        }
    }
    else { c.consecLoss=0; g_portLossStreak=0; }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    if(!HistoryDealSelect(trans.deal)) return;
    if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC) != Inp_Magic) return;

    string sym = HistoryDealGetString(trans.deal,DEAL_SYMBOL);
    int ci = CtxBySymbol(sym);
    if(ci<0) return;

    long entry = HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
    long posId = HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);

    if(entry==DEAL_ENTRY_IN)
        AssignPend(g_ctx[ci], posId);
    else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_INOUT || entry==DEAL_ENTRY_OUT_BY)
    {
        double profit = HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                      + HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                      + HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
        HandleClose(g_ctx[ci], posId, profit);
    }
}

// ═══════════════════════════════════════════════════════════════════
//  DASHBOARD  (one grid row per symbol)
// ═══════════════════════════════════════════════════════════════════
#define DP "FAI_"
color C_BG  = C'13,17,28';
color C_HDR = C'24,32,52';
color C_SEP = C'40,52,78';
color C_WHT = C'210,218,230';
color C_GRN = C'42,200,95';
color C_RED = C'215,62,62';
color C_YEL = C'215,178,42';
color C_BLU = C'62,132,215';
color C_DIM = C'92,106,128';

void _R(string n,int x,int y,int w,int h,color bg)
{
    string nm=DP+n;
    if(ObjectFind(0,nm)<0)
    {
        ObjectCreate(0,nm,OBJ_RECTANGLE_LABEL,0,0,0);
        ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
        ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
        ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
        ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
    }
    ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
    ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,nm,OBJPROP_XSIZE,w);
    ObjectSetInteger(0,nm,OBJPROP_YSIZE,h);
    ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,bg);
    ObjectSetInteger(0,nm,OBJPROP_BORDER_COLOR,bg);
}
void _L(string n,string t,int x,int y,color cl,int sz=9)
{
    string nm=DP+n;
    if(ObjectFind(0,nm)<0)
    {
        ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
        ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
        ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
        ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
        ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
        ObjectSetString (0,nm,OBJPROP_FONT,"Consolas");
    }
    ObjectSetString (0,nm,OBJPROP_TEXT,t);
    ObjectSetInteger(0,nm,OBJPROP_COLOR,cl);
    ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,sz);
    ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
    ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
}

void UpdateDashboard()
{
    if(!Inp_ShowDashboard) return;
    if(MQLInfoInteger(MQL_OPTIMIZATION)) return;

    int X=16, Y=16, W=480, LH=17;
    double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
    double dP  = (g_dailyEq>0)?(eq-g_dailyEq)/g_dailyEq*100.0:0;
    double tP  = (g_baseline>0)?(eq-g_baseline)/g_baseline*100.0:0;

    int rows = g_nSym;
    int H = 96 + LH*(rows+1) + 54;
    _R("BG", X-8,Y-8, W+16, H, C_BG);
    _R("HD", X-8,Y-8, W+16, 38, C_HDR);
    _L("T1","  FUSION AI — GFv8 PAIRS + NAS100 | H1+M30 | SELF-LEARNING", X,Y, C_WHT,10);
    int off = ServerOffsetHours();
    _L("T2",StringFormat("  v1.13 | %s | UTC %02d:%02d (srv%+d) | magic %d",
            TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),
            UTCHour(),UTCMinute(),off,(int)Inp_Magic), X,Y+15, C_DIM,8);

    int y=Y+44;
    string lock = g_totalLocked?"TOTAL LOCK":g_dailyLocked?"DAILY LOCK":"TRADING";
    color  lc   = g_totalLocked?C_RED:g_dailyLocked?C_YEL:C_GRN;
    _L("A1",StringFormat("Equity %.2f   Daily %+.2f%%   Total %+.2f%% / +%.0f%% target",
            eq,dP,tP,Inp_TargetPct), X,y, C_WHT,9); y+=LH;
    _L("A2",StringFormat("Trades %d/%d   Positions %d/%d   Status: %s",
            g_tradesToday,Inp_MaxTradesPerDay,PortfolioPositions(),Inp_MaxPortfolioPos,lock),
            X,y, lc,9); y+=LH+6;

    _L("GH","SYM       ENS-B  ENS-S  AI     STEPS  STATE", X,y, C_BLU,9); y+=LH;
    for(int i=0;i<g_nSym;i++)
    {
        bool inTrade = (PositionsForSymbol(g_ctx[i].sym)>0);
        string rsn   = g_ctx[i].reason;
        string state = inTrade ? "IN TRADE" : rsn;
        color  rc    = inTrade ? C_GRN :
                       (StringFind(rsn,"OPENED")>=0)?C_GRN:
                       (StringFind(rsn,"LOCK")>=0||StringFind(rsn,"PAUSE")>=0)?C_RED:C_DIM;
        string boot  = (g_ctx[i].net.steps<Inp_BootstrapSteps)?"*":" ";
        _L("R"+IntegerToString(i),
           StringFormat("%-9s %.2f   %.2f   %.2f   %4d%s  %s",
                        g_ctx[i].sym,g_ctx[i].bull,g_ctx[i].bear,g_ctx[i].aiScore,
                        g_ctx[i].net.steps,boot,state),
           X,y,rc,9);
        y+=LH;
    }
    y+=4;
    _L("FT","* bootstrap (model < "+IntegerToString(Inp_BootstrapSteps)+" trades)   "
            +"FX: Lon+NY | indices: NY only | edges skipped", X,y, C_DIM,8);
    ChartRedraw(0);
}

// ═══════════════════════════════════════════════════════════════════
//  INIT / DEINIT / TICK
// ═══════════════════════════════════════════════════════════════════
int OnInit()
{
    MathSrand((int)(TimeCurrent()&0x7FFFFFFF));

    g_wSum = W_Trend+W_Momentum+W_Regime+W_Kalman+W_MTF;
    if(g_wSum<=0) g_wSum=1.0;

    // ── resolve + init each symbol ───────────────────────────────
    string parts[];
    int n = StringSplit(Inp_Symbols, ',', parts);
    if(n<=0){ Print("FusionAI: empty symbol list"); return INIT_FAILED; }
    ArrayResize(g_ctx, n);
    g_nSym=0;

    for(int i=0;i<n;i++)
    {
        string base = parts[i];
        StringTrimLeft(base); StringTrimRight(base);
        if(StringLen(base)==0) continue;
        // keep original case — broker names like .USTECHCash are case-sensitive;
        // ResolveWithAliases matches case-insensitively internally
        bool isIdx = false;
        string sym = ResolveWithAliases(base, isIdx);
        if(sym==""){ Print("FusionAI: symbol not found: ",base," — skipped"); continue; }
        if(sym!=base) Print("FusionAI: ",base," resolved to broker symbol ",sym);

        SymCtx c;
        c.sym = sym;
        c.isIndex = isIdx;
        // H1 engine
        c.hEMA20H1  = iMA (sym,PERIOD_H1, 20,0,MODE_EMA,PRICE_CLOSE);
        c.hEMA50H1  = iMA (sym,PERIOD_H1, 50,0,MODE_EMA,PRICE_CLOSE);
        c.hEMA200H1 = iMA (sym,PERIOD_H1,200,0,MODE_EMA,PRICE_CLOSE);
        c.hRSIH1    = iRSI(sym,PERIOD_H1, 14,PRICE_CLOSE);
        c.hADXH1    = iADX(sym,PERIOD_H1, 14);
        c.hATRH1    = iATR(sym,PERIOD_H1, 14);
        // M30 engine
        c.hEMA20M30 = iMA (sym,PERIOD_M30,20,0,MODE_EMA,PRICE_CLOSE);
        c.hEMA50M30 = iMA (sym,PERIOD_M30,50,0,MODE_EMA,PRICE_CLOSE);
        c.hRSIM30   = iRSI(sym,PERIOD_M30,14,PRICE_CLOSE);
        c.hStochM30 = iStochastic(sym,PERIOD_M30,5,3,3,MODE_SMA,STO_LOWHIGH);
        c.hBBM30    = iBands(sym,PERIOD_M30,20,0,2.0,PRICE_CLOSE);
        c.hATRM30   = iATR(sym,PERIOD_M30,14);
        if(c.hEMA20H1==INVALID_HANDLE || c.hEMA50H1==INVALID_HANDLE ||
           c.hEMA200H1==INVALID_HANDLE|| c.hRSIH1==INVALID_HANDLE   ||
           c.hADXH1==INVALID_HANDLE   || c.hATRH1==INVALID_HANDLE   ||
           c.hEMA20M30==INVALID_HANDLE|| c.hEMA50M30==INVALID_HANDLE||
           c.hRSIM30==INVALID_HANDLE  || c.hStochM30==INVALID_HANDLE||
           c.hBBM30==INVALID_HANDLE   || c.hATRM30==INVALID_HANDLE)
        { Print("FusionAI: indicator init failed for ",sym); return INIT_FAILED; }

        // Kalman
        c.kfVw=Inp_KF_Delta/(1.0-Inp_KF_Delta);
        c.kfVe=Inp_KF_Ve;
        c.kfP=1.0; c.kfInit=false; c.kfPrice=0; c.kfVel=0;

        c.lastM30=0; c.lastH1=0;
        c.hasPend=false; c.pendRisk=0;
        c.consecLoss=0; c.pauseUntil=0; c.tradesToday=0;
        c.bull=0; c.bear=0; c.aiScore=0; c.lastDir=0; c.reason="INIT";

        // model + memory files (lower-case base name, suffix stripped)
        string lo=base; StringToLower(lo);
        StringReplace(lo, ".", "");   // .USTECHCash → ustechcash
        c.modelFile = "fusion_"+lo+".dat";
        c.memFile   = "fusion_"+lo+"_mem.bin";
        c.net.InitRandom();
        if(c.net.Load(c.modelFile))
            Print("FusionAI ",sym,": model loaded, steps=",c.net.steps);
        else
            Print("FusionAI ",sym,": fresh model");
        LoadMem(c);

        g_ctx[g_nSym]=c;
        g_nSym++;
    }
    if(g_nSym==0){ Print("FusionAI: no symbols resolved"); return INIT_FAILED; }
    ArrayResize(g_ctx,g_nSym);

    // ── baseline (challenge start balance) ───────────────────────
    string bkey="FUSION_BASE_"+IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN));
    if(Inp_BaselineBalance>0)
        g_baseline=Inp_BaselineBalance;
    else if(GlobalVariableCheck(bkey))
        g_baseline=GlobalVariableGet(bkey);
    else
    {
        g_baseline=AccountInfoDouble(ACCOUNT_BALANCE);
        GlobalVariableSet(bkey,g_baseline);
    }

    g_dailyEq=AccountInfoDouble(ACCOUNT_EQUITY);
    MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
    g_lastDay=dt.day;

    InitLogger();
    UpdateDashboard();
    Print("FusionAI v1.10: ",g_nSym," symbols | baseline=",DoubleToString(g_baseline,2),
          " | server UTC offset=",ServerOffsetHours(),"h");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    for(int i=0;i<g_nSym;i++)
    {
        g_ctx[i].net.Save(g_ctx[i].modelFile);
        SaveMem(g_ctx[i]);
        IndicatorRelease(g_ctx[i].hEMA20H1);  IndicatorRelease(g_ctx[i].hEMA50H1);
        IndicatorRelease(g_ctx[i].hEMA200H1); IndicatorRelease(g_ctx[i].hRSIH1);
        IndicatorRelease(g_ctx[i].hADXH1);    IndicatorRelease(g_ctx[i].hATRH1);
        IndicatorRelease(g_ctx[i].hEMA20M30); IndicatorRelease(g_ctx[i].hEMA50M30);
        IndicatorRelease(g_ctx[i].hRSIM30);   IndicatorRelease(g_ctx[i].hStochM30);
        IndicatorRelease(g_ctx[i].hBBM30);    IndicatorRelease(g_ctx[i].hATRM30);
    }
    if(g_log!=INVALID_HANDLE) FileClose(g_log);
    ObjectsDeleteAll(0,DP);
    ChartRedraw(0);
}

void OnTick()
{
    ManageAll();                 // BE + trail react in real time
    DailyReset();

    bool anyNewBar=false;
    for(int i=0;i<g_nSym;i++)
    {
        // Kalman: once per closed H1 bar (deterministic in backtests)
        datetime h1 = iTime(g_ctx[i].sym,PERIOD_H1,0);
        if(h1>0 && h1!=g_ctx[i].lastH1)
        {
            g_ctx[i].lastH1=h1;
            UpdateKalman(g_ctx[i]);
        }
        // entries: once per closed M30 bar
        datetime m30 = iTime(g_ctx[i].sym,PERIOD_M30,0);
        if(m30>0 && m30!=g_ctx[i].lastM30)
        {
            g_ctx[i].lastM30=m30;
            anyNewBar=true;
            TryOpen(g_ctx[i]);
        }
    }

    // dashboard: every new bar + throttled to 2 s between bars
    static datetime lastDash=0;
    if(anyNewBar || TimeCurrent()-lastDash>=2)
    {
        lastDash=TimeCurrent();
        UpdateDashboard();
    }
}
//+------------------------------------------------------------------+

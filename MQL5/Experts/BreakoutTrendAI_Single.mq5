#property strict
#property description "BreakoutTrendAI – self-learning EA, single file"
#property version "2.6"

// ═══════════════════════════════════════════════════════════════
//  INPUTS
// ═══════════════════════════════════════════════════════════════
input double InpRiskPercentPerTrade  = 0.35;
input double InpMaxDailyLossPercent  = 3.0;
input double InpMaxWeeklyLossPercent = 4.0;
input int    InpMaxTradesPerDay      = 6;

input double InpSL_ATR_Multiplier    = 1.5;
input double InpTP1_R_Multiple       = 1.0;
input double InpTP2_R_Multiple       = 2.5;

input bool   InpTradeAsia            = false; // Trade Asian session (00:00-09:00 UTC)
input int    InpAsiaStartHour        = 0;    // Asia open  (UTC)
input int    InpAsiaEndHour          = 9;    // Asia close (UTC)
input int    InpLondonStartHour      = 7;    // London open  (UTC)
input int    InpLondonEndHour        = 16;   // London close (UTC)
input int    InpNYStartHour          = 13;   // NY open      (UTC)
input int    InpNYEndHour            = 21;   // NY close     (UTC)

input double InpAI_Threshold         = 0.55;
input string InpAI_ModelFile         = "btai_model.dat";

input double InpLearningRate         = 0.001;
input double InpMomentum             = 0.90;
input int    InpSaveEveryNTrades     = 5;

input int    InpMagicNumber          = 787878;

// Dashboard live state (updated every bar)
double   g_lastScore  = 0.0;
int      g_lastDir    = 0;
datetime g_lastSigT   = 0;
string   g_lastReason = "INIT";

// ═══════════════════════════════════════════════════════════════
//  INDICATORS  (handle-based – required in MQL5)
// ═══════════════════════════════════════════════════════════════
int g_hATR14    = INVALID_HANDLE;
int g_hEMA50    = INVALID_HANDLE;
int g_hEMA200   = INVALID_HANDLE;
int g_hRSI14    = INVALID_HANDLE;
int g_hBB20     = INVALID_HANDLE;   // Bollinger Bands (squeeze detector)
int g_hEMA50_H1 = INVALID_HANDLE;   // H1 EMA50 (MTF trend filter)

bool InitIndicators()
{
    g_hATR14    = iATR  (_Symbol, PERIOD_CURRENT, 14);
    g_hEMA50    = iMA   (_Symbol, PERIOD_CURRENT, 50,  0, MODE_EMA, PRICE_CLOSE);
    g_hEMA200   = iMA   (_Symbol, PERIOD_CURRENT, 200, 0, MODE_EMA, PRICE_CLOSE);
    g_hRSI14    = iRSI  (_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
    g_hBB20     = iBands(_Symbol, PERIOD_CURRENT, 20, 0, 2.0, PRICE_CLOSE);
    g_hEMA50_H1 = iMA   (_Symbol, PERIOD_H1,      50,  0, MODE_EMA, PRICE_CLOSE);
    return (g_hATR14  != INVALID_HANDLE && g_hEMA50    != INVALID_HANDLE &&
            g_hEMA200 != INVALID_HANDLE && g_hRSI14    != INVALID_HANDLE &&
            g_hBB20   != INVALID_HANDLE && g_hEMA50_H1 != INVALID_HANDLE);
}
void ReleaseIndicators()
{
    if(g_hATR14    != INVALID_HANDLE){ IndicatorRelease(g_hATR14);    g_hATR14    = INVALID_HANDLE; }
    if(g_hEMA50    != INVALID_HANDLE){ IndicatorRelease(g_hEMA50);    g_hEMA50    = INVALID_HANDLE; }
    if(g_hEMA200   != INVALID_HANDLE){ IndicatorRelease(g_hEMA200);   g_hEMA200   = INVALID_HANDLE; }
    if(g_hRSI14    != INVALID_HANDLE){ IndicatorRelease(g_hRSI14);    g_hRSI14    = INVALID_HANDLE; }
    if(g_hBB20     != INVALID_HANDLE){ IndicatorRelease(g_hBB20);     g_hBB20     = INVALID_HANDLE; }
    if(g_hEMA50_H1 != INVALID_HANDLE){ IndicatorRelease(g_hEMA50_H1); g_hEMA50_H1 = INVALID_HANDLE; }
}

// bufIdx: 0=main, 1=upper/+DI, 2=lower/-DI (matches MT5 buffer numbering)
double GetBuf(int handle, int bufIdx = 0, int shift = 0)
{
    if(handle == INVALID_HANDLE) return 0.0;
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(handle, bufIdx, shift, 1, buf) <= 0) return 0.0;
    return buf[0];
}

double GetATR(int period = 14)  { return GetBuf(g_hATR14);  }
double GetEMA(int period)       { return (period<=50) ? GetBuf(g_hEMA50) : GetBuf(g_hEMA200); }
double GetRSI(int period = 14)  { return GetBuf(g_hRSI14);  }

double GetSpreadPoints()
{
    return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
            SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
}
bool GetRange(double &high, double &low, int lookback = 20)
{
    // start=2: range is bars 2–21, so bar 1's close can actually break above/below it.
    // start=1 (old) included bar 1 itself → close1 <= high[1] ≤ range_high → NEVER a breakout.
    int hi = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, lookback, 2);
    int lo = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  lookback, 2);
    high = iHigh(_Symbol, PERIOD_CURRENT, hi);
    low  = iLow (_Symbol, PERIOD_CURRENT, lo);
    double atr = GetATR(14);
    if(atr < _Point) return false;
    double rangeATR = (high - low) / atr;
    return (rangeATR >= 0.5 && rangeATR <= 5.0);
}

// Nearest swing high within lookback bars (strength = bars each side must be lower)
double SwingHigh(int lookback = 60, int strength = 3)
{
    for(int i = strength + 1; i < lookback; i++)
    {
        double h = iHigh(_Symbol, PERIOD_CURRENT, i);
        bool ok = true;
        for(int j = 1; j <= strength && ok; j++)
            if(iHigh(_Symbol, PERIOD_CURRENT, i - j) >= h ||
               iHigh(_Symbol, PERIOD_CURRENT, i + j) >= h) ok = false;
        if(ok) return h;
    }
    return 0.0;
}

// Nearest swing low within lookback bars
double SwingLow(int lookback = 60, int strength = 3)
{
    for(int i = strength + 1; i < lookback; i++)
    {
        double l = iLow(_Symbol, PERIOD_CURRENT, i);
        bool ok = true;
        for(int j = 1; j <= strength && ok; j++)
            if(iLow(_Symbol, PERIOD_CURRENT, i - j) <= l ||
               iLow(_Symbol, PERIOD_CURRENT, i + j) <= l) ok = false;
        if(ok) return l;
    }
    return 0.0;
}
bool IsNewBar()
{
    static datetime s_last = 0;
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t == s_last) return false;
    s_last = t;
    return true;
}

// ═══════════════════════════════════════════════════════════════
//  SIGNAL STRUCT + BREAKOUT TREND LOGIC
// ═══════════════════════════════════════════════════════════════
struct Signal
{
    int    direction;
    double entryPrice;
    double slPrice;
    double tp1Price;
    double tp2Price;
    double rangeHigh;
    double rangeLow;
};

// Use H1 EMA50 as trend filter — avoids the M15 EMA50/200 cross
// which takes days/weeks and prevents all signals from firing.
bool IsUptrend()
{
    double close    = iClose(_Symbol, PERIOD_CURRENT, 1);   // last closed M15 bar
    double ema50_h1 = GetBuf(g_hEMA50_H1);
    double rsi      = GetRSI(14);
    return (ema50_h1 > 0 && close > ema50_h1 && rsi > 45.0);
}
bool IsDowntrend()
{
    double close    = iClose(_Symbol, PERIOD_CURRENT, 1);
    double ema50_h1 = GetBuf(g_hEMA50_H1);
    double rsi      = GetRSI(14);
    return (ema50_h1 > 0 && close < ema50_h1 && rsi < 55.0);
}
bool GetBreakoutTrendSignal(Signal &sig)
{
    double high, low;
    if(!GetRange(high, low)) return false;

    double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
    double atr    = GetATR(14);
    if(atr < _Point) return false;
    double slDist = atr * InpSL_ATR_Multiplier;

    if(IsUptrend() && close1 > high)
    {
        sig.direction  =  1;
        sig.entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sig.slPrice    = sig.entryPrice - slDist;
        sig.tp1Price   = sig.entryPrice + slDist * InpTP1_R_Multiple;
        sig.tp2Price   = sig.entryPrice + slDist * InpTP2_R_Multiple;
        sig.rangeHigh  = high;
        sig.rangeLow   = low;
        return true;
    }
    if(IsDowntrend() && close1 < low)
    {
        sig.direction  = -1;
        sig.entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sig.slPrice    = sig.entryPrice + slDist;
        sig.tp1Price   = sig.entryPrice - slDist * InpTP1_R_Multiple;
        sig.tp2Price   = sig.entryPrice - slDist * InpTP2_R_Multiple;
        sig.rangeHigh  = high;
        sig.rangeLow   = low;
        return true;
    }
    return false;
}
double CalcSLPips(const Signal &sig)
{
    return MathAbs(sig.entryPrice - sig.slPrice) / _Point;
}

// ═══════════════════════════════════════════════════════════════
//  AI  –  SELF-LEARNING  MLP  (32 → 24 → 12 → 1)
// ═══════════════════════════════════════════════════════════════
#define NN_IN   32
#define NN_H1   24
#define NN_H2   12
#define NN_OUT   1

double g_W1[NN_H1 * NN_IN],  g_b1[NN_H1];
double g_W2[NN_H2 * NN_H1],  g_b2[NN_H2];
double g_W3[NN_OUT * NN_H2], g_b3[NN_OUT];

double g_vW1[NN_H1 * NN_IN],  g_vb1[NN_H1];
double g_vW2[NN_H2 * NN_H1],  g_vb2[NN_H2];
double g_vW3[NN_OUT * NN_H2], g_vb3[NN_OUT];

double g_a0[NN_IN];
double g_z1[NN_H1], g_a1[NN_H1];
double g_z2[NN_H2], g_a2[NN_H2];
double g_z3[NN_OUT];

double g_fm[NN_IN], g_fM2[NN_IN];
long   g_fN         = 0;
int    g_trainSteps = 0;

// ── Math ─────────────────────────────────────────────────────
double NN_Sig(double x)  { x=MathMax(-20,MathMin(20,x)); return 1.0/(1.0+MathExp(-x)); }
double NN_Relu(double x) { return x>0?x:0; }
double NN_RelD(double x) { return x>0?1.0:0.0; }

double NN_Gauss()
{
    double u1=(MathRand()+1.0)/32769.0, u2=(MathRand()+1.0)/32769.0;
    return MathSqrt(-2.0*MathLog(u1))*MathCos(2.0*3.14159265358979323846*u2);
}
void NN_Xavier(double &W[], int sz, int fan)
{ double s=MathSqrt(2.0/fan); for(int i=0;i<sz;i++) W[i]=NN_Gauss()*s; }
void NN_Zero(double &a[], int n) { for(int i=0;i<n;i++) a[i]=0; }

// ── Online scaler ────────────────────────────────────────────
void UpdateScaler(double &x[])
{
    g_fN++;
    for(int i=0;i<NN_IN;i++)
    {
        double d=x[i]-g_fm[i];
        g_fm[i]+=d/(double)g_fN;
        g_fM2[i]+=d*(x[i]-g_fm[i]);
    }
}
void NormFeatures(double &x[], double &out[])
{
    for(int i=0;i<NN_IN;i++)
    {
        double var=(g_fN>1)?g_fM2[i]/(double)(g_fN-1):1.0;
        double std=(var>1e-10)?MathSqrt(var):1.0;
        out[i]=MathMax(-3.0,MathMin(3.0,(x[i]-g_fm[i])/std));
    }
}

// ── Feature builder (32-dim) ─────────────────────────────────
void BuildFeatures(const Signal &sig, double &f[])
{
    double atr=GetATR(14), c0=iClose(_Symbol,PERIOD_CURRENT,0);
    double ema50=GetEMA(50), ema200=GetEMA(200);
    if(atr<1e-10) atr=1.0;
    if(c0<1e-10)  c0=1.0;

    f[0]=atr/c0;
    f[1]=GetSpreadPoints()/atr;
    f[2]=(sig.rangeHigh-sig.rangeLow)/atr;
    f[3]=(c0-ema50)/atr;
    f[4]=(c0-ema200)/atr;
    f[5]=(ema50-ema200)/atr;
    f[6]=GetRSI(14)/100.0;
    f[7]=(double)sig.direction;

    MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
    f[8]=dt.hour/23.0;
    f[9]=dt.day_of_week/6.0;

    for(int k=0;k<7;k++)
    {
        double o=iOpen(_Symbol,PERIOD_CURRENT,k+1);
        double c=iClose(_Symbol,PERIOD_CURRENT,k+1);
        f[10+k]=(c-o)/atr;
    }
    for(int k=0;k<4;k++)
    {
        double h=iHigh(_Symbol,PERIOD_CURRENT,k+1);
        double l=iLow(_Symbol,PERIOD_CURRENT,k+1);
        f[17+k]=(h-l)/atr;
    }

    double h1=iHigh(_Symbol,PERIOD_CURRENT,1), l1=iLow(_Symbol,PERIOD_CURRENT,1);
    double c1=iClose(_Symbol,PERIOD_CURRENT,1), o1=iOpen(_Symbol,PERIOD_CURRENT,1);
    f[21]=(h1-MathMax(o1,c1))/atr;
    f[22]=(MathMin(o1,c1)-l1)/atr;
    f[23]=(sig.entryPrice-sig.rangeHigh)/atr;
    f[24]=(sig.entryPrice-sig.rangeLow)/atr;
    f[25]=(c0-iClose(_Symbol,PERIOD_CURRENT,10))/atr;

    // ── S/R + advanced features (f[26..31]) ─────────────────────
    // f[26] distance from price to nearest swing high (negative = above resistance)
    double sHigh = SwingHigh(60, 3);
    f[26] = (sHigh > 0) ? (c0 - sHigh) / atr : 0.0;

    // f[27] distance from price to nearest swing low (positive = above support)
    double sLow = SwingLow(60, 3);
    f[27] = (sLow > 0) ? (c0 - sLow) / atr : 0.0;

    // f[28] Bollinger Band width / ATR — squeeze = low value, expansion = breakout
    double bbU = GetBuf(g_hBB20, 1);
    double bbL = GetBuf(g_hBB20, 2);
    f[28] = (atr > 0) ? (bbU - bbL) / atr : 1.0;

    // f[29] H1 trend: price vs H1 EMA50 (+1 bullish, -1 bearish)
    double ema50h1 = GetBuf(g_hEMA50_H1);
    f[29] = (c0 > ema50h1) ? 1.0 : -1.0;

    // f[30] previous day high distance (above = breakout of daily resistance)
    double dayHigh = iHigh(_Symbol, PERIOD_D1, 1);
    f[30] = (dayHigh > 0 && atr > 0) ? (c0 - dayHigh) / atr : 0.0;

    // f[31] previous day low distance (positive = price above daily support)
    double dayLow = iLow(_Symbol, PERIOD_D1, 1);
    f[31] = (dayLow > 0 && atr > 0) ? (c0 - dayLow) / atr : 0.0;
}

// ── Forward pass ─────────────────────────────────────────────
double ForwardPass(double &n[])
{
    for(int i=0;i<NN_IN;i++) g_a0[i]=n[i];
    for(int r=0;r<NN_H1;r++)
    {
        double s=g_b1[r];
        for(int c=0;c<NN_IN;c++) s+=g_W1[r*NN_IN+c]*g_a0[c];
        g_z1[r]=s; g_a1[r]=NN_Relu(s);
    }
    for(int r=0;r<NN_H2;r++)
    {
        double s=g_b2[r];
        for(int c=0;c<NN_H1;c++) s+=g_W2[r*NN_H1+c]*g_a1[c];
        g_z2[r]=s; g_a2[r]=NN_Relu(s);
    }
    double s=g_b3[0];
    for(int c=0;c<NN_H2;c++) s+=g_W3[c]*g_a2[c];
    g_z3[0]=s;
    return NN_Sig(s);
}

// ── Backprop ─────────────────────────────────────────────────
void Backprop(double label)
{
    double lr=InpLearningRate, mom=InpMomentum;
    double dz3=NN_Sig(g_z3[0])-label;

    for(int c=0;c<NN_H2;c++)
    { g_vW3[c]=mom*g_vW3[c]-lr*dz3*g_a2[c]; g_W3[c]+=g_vW3[c]; }
    g_vb3[0]=mom*g_vb3[0]-lr*dz3; g_b3[0]+=g_vb3[0];

    double dz2[NN_H2];
    for(int r=0;r<NN_H2;r++) dz2[r]=g_W3[r]*dz3*NN_RelD(g_z2[r]);
    for(int r=0;r<NN_H2;r++)
    {
        for(int c=0;c<NN_H1;c++)
        { g_vW2[r*NN_H1+c]=mom*g_vW2[r*NN_H1+c]-lr*dz2[r]*g_a1[c]; g_W2[r*NN_H1+c]+=g_vW2[r*NN_H1+c]; }
        g_vb2[r]=mom*g_vb2[r]-lr*dz2[r]; g_b2[r]+=g_vb2[r];
    }

    double dz1[NN_H1];
    for(int r=0;r<NN_H1;r++)
    {
        double d=0; for(int k=0;k<NN_H2;k++) d+=g_W2[k*NN_H1+r]*dz2[k];
        dz1[r]=d*NN_RelD(g_z1[r]);
    }
    for(int r=0;r<NN_H1;r++)
    {
        for(int c=0;c<NN_IN;c++)
        { g_vW1[r*NN_IN+c]=mom*g_vW1[r*NN_IN+c]-lr*dz1[r]*g_a0[c]; g_W1[r*NN_IN+c]+=g_vW1[r*NN_IN+c]; }
        g_vb1[r]=mom*g_vb1[r]-lr*dz1[r]; g_b1[r]+=g_vb1[r];
    }

    g_trainSteps++;
    if(g_trainSteps % InpSaveEveryNTrades == 0) SaveModel(InpAI_ModelFile);
}

// ── Public AI API ─────────────────────────────────────────────
double GetSignalScore(double &features[])
{
    double norm[NN_IN]; NormFeatures(features,norm); return ForwardPass(norm);
}
void LearnFromTrade(double &features[], double profit)
{
    double norm[NN_IN]; NormFeatures(features,norm);
    double score=ForwardPass(norm);
    double eq=AccountInfoDouble(ACCOUNT_EQUITY);
    double pct=(eq>0)?profit/eq*100.0:0.0;
    double label=NN_Sig(pct*20.0);
    Backprop(label);
    Print("AI | step=",g_trainSteps,
          "  profit=",DoubleToString(profit,2),
          "  label=",DoubleToString(label,3),
          "  score=",DoubleToString(score,3));
}

// ── Save / Load ───────────────────────────────────────────────
bool SaveModel(string fn)
{
    int h=FileOpen(fn,FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(h==INVALID_HANDLE) return false;
    FileWriteString(h,IntegerToString(NN_IN)+" "+IntegerToString(NN_H1)+
                      " "+IntegerToString(NN_H2)+" "+IntegerToString(NN_OUT)+"\n");
    string ln; int i;
    ln=""; for(i=0;i<NN_H1*NN_IN;i++) ln+=DoubleToString(g_W1[i],8)+" "; FileWriteString(h,ln+"\n");
    ln=""; for(i=0;i<NN_H1;i++)       ln+=DoubleToString(g_b1[i],8)+" "; FileWriteString(h,ln+"\n");
    ln=""; for(i=0;i<NN_H2*NN_H1;i++) ln+=DoubleToString(g_W2[i],8)+" "; FileWriteString(h,ln+"\n");
    ln=""; for(i=0;i<NN_H2;i++)       ln+=DoubleToString(g_b2[i],8)+" "; FileWriteString(h,ln+"\n");
    ln=""; for(i=0;i<NN_H2;i++)       ln+=DoubleToString(g_W3[i],8)+" "; FileWriteString(h,ln+"\n");
    ln=""; for(i=0;i<NN_OUT;i++)      ln+=DoubleToString(g_b3[i],8)+" "; FileWriteString(h,ln+"\n");
    ln=""; for(i=0;i<NN_IN;i++)       ln+=DoubleToString(g_fm[i], 8)+" "; FileWriteString(h,ln+"\n");
    ln=""; for(i=0;i<NN_IN;i++)       ln+=DoubleToString(g_fM2[i],8)+" "; FileWriteString(h,ln+"\n");
    FileWriteString(h,IntegerToString((int)g_fN)+"\n");
    FileWriteString(h,IntegerToString(g_trainSteps)+"\n");
    FileClose(h);
    return true;
}
bool LoadModel(string fn)
{
    int h=FileOpen(fn,FILE_READ|FILE_TXT);
    if(h==INVALID_HANDLE) return false;
    int n0=(int)FileReadNumber(h),n1=(int)FileReadNumber(h),
        n2=(int)FileReadNumber(h),n3=(int)FileReadNumber(h);
    if(n0!=NN_IN||n1!=NN_H1||n2!=NN_H2||n3!=NN_OUT){FileClose(h);return false;}
    int i;
    for(i=0;i<n1*n0;i++) g_W1[i]=FileReadNumber(h);
    for(i=0;i<n1;i++)    g_b1[i]=FileReadNumber(h);
    for(i=0;i<n2*n1;i++) g_W2[i]=FileReadNumber(h);
    for(i=0;i<n2;i++)    g_b2[i]=FileReadNumber(h);
    for(i=0;i<n2;i++)    g_W3[i]=FileReadNumber(h);
    for(i=0;i<n3;i++)    g_b3[i]=FileReadNumber(h);
    for(i=0;i<n0;i++)    g_fm[i] =FileReadNumber(h);
    for(i=0;i<n0;i++)    g_fM2[i]=FileReadNumber(h);
    g_fN=(long)FileReadNumber(h); g_trainSteps=(int)FileReadNumber(h);
    FileClose(h);
    return true;
}
void InitAI(string fn)
{
    NN_Zero(g_vW1,NN_H1*NN_IN); NN_Zero(g_vb1,NN_H1);
    NN_Zero(g_vW2,NN_H2*NN_H1); NN_Zero(g_vb2,NN_H2);
    NN_Zero(g_vW3,NN_OUT*NN_H2); NN_Zero(g_vb3,NN_OUT);
    NN_Zero(g_fm,NN_IN);
    for(int i=0;i<NN_IN;i++) g_fM2[i]=1.0;
    g_fN=0; g_trainSteps=0;

    if(LoadModel(fn))
    { Print("AI: model loaded | steps=",g_trainSteps," scalerN=",(int)g_fN); return; }

    MathSrand((int)(TimeCurrent()&0x7FFFFFFF));
    NN_Xavier(g_W1,NN_H1*NN_IN,NN_IN);  NN_Zero(g_b1,NN_H1);
    NN_Xavier(g_W2,NN_H2*NN_H1,NN_H1);  NN_Zero(g_b2,NN_H2);
    NN_Xavier(g_W3,NN_OUT*NN_H2,NN_H2); NN_Zero(g_b3,NN_OUT);
    Print("AI: fresh random weights (no saved model)");
}

// ═══════════════════════════════════════════════════════════════
//  RISK ENGINE
// ═══════════════════════════════════════════════════════════════
double g_dailyEq=0, g_weeklyEq=0;
int    tradesToday=0;

void InitRisk()
{
    g_dailyEq=AccountInfoDouble(ACCOUNT_EQUITY);
    g_weeklyEq=AccountInfoDouble(ACCOUNT_EQUITY);
    tradesToday=0;
}
bool LimitHit()
{
    double eq=AccountInfoDouble(ACCOUNT_EQUITY);
    if(g_dailyEq>0  && (eq-g_dailyEq) /g_dailyEq *100<=-InpMaxDailyLossPercent)  return true;
    if(g_weeklyEq>0 && (eq-g_weeklyEq)/g_weeklyEq*100<=-InpMaxWeeklyLossPercent) return true;
    if(tradesToday>=InpMaxTradesPerDay) return true;
    return false;
}
double CalcLots(double riskPct, double slPips)
{
    if(slPips<0.001) return 0.01;
    double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double pv=(ts>0)?tv*(_Point/ts):tv;
    if(pv<1e-10) return 0.01;
    double lot=AccountInfoDouble(ACCOUNT_EQUITY)*riskPct/100.0/(slPips*pv);
    double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    lot=MathFloor(lot/st)*st;
    return MathMax(mn,MathMin(mx,lot));
}

// ═══════════════════════════════════════════════════════════════
//  SAFEGUARD LINK  (reads lock set by SafeGuard_EA via GlobalVariable)
// ═══════════════════════════════════════════════════════════════
bool SafeGuardLocked()
{
    string key = "SAFEGUARD_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
    if(!GlobalVariableCheck(key)) return false;
    datetime until = (datetime)GlobalVariableGet(key);
    return (TimeCurrent() < until);
}

// ═══════════════════════════════════════════════════════════════
//  DASHBOARD
// ═══════════════════════════════════════════════════════════════
#define DP    "BTAI_"    // object name prefix
#define DB_X  20         // panel left edge
#define DB_Y  20         // panel top edge
#define DB_W  295        // panel width
#define DB_LH 17         // line height

color C_BG  = C'15,19,29';
color C_HDR = C'25,33,52';
color C_SEP = C'40,52,78';
color C_WHT = C'208,216,228';
color C_GRN = C'42,200,95';
color C_RED = C'215,62,62';
color C_YEL = C'215,178,42';
color C_BLU = C'62,132,215';
color C_DIM = C'90,105,126';

void _R(string n,int x,int y,int w,int h,color bg,color brd=clrNONE)
{
    string nm=DP+n;
    if(ObjectFind(0,nm)<0)
    {
        ObjectCreate(0,nm,OBJ_RECTANGLE_LABEL,0,0,0);
        ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
        ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
        ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
        ObjectSetInteger(0,nm,OBJPROP_BACK,false);
    }
    ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
    ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,nm,OBJPROP_XSIZE,w);
    ObjectSetInteger(0,nm,OBJPROP_YSIZE,h);
    ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,bg);
    ObjectSetInteger(0,nm,OBJPROP_BORDER_COLOR,brd==clrNONE?bg:brd);
    ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
}

void _L(string n,string txt,int x,int y,color clr,int sz=9)
{
    string nm=DP+n;
    if(ObjectFind(0,nm)<0)
    {
        ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
        ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
        ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
        ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
        ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
        ObjectSetInteger(0,nm,OBJPROP_BACK,false);
        ObjectSetString(0,nm,OBJPROP_FONT,"Consolas");
    }
    ObjectSetString(0,nm,OBJPROP_TEXT,txt);
    ObjectSetInteger(0,nm,OBJPROP_COLOR,clr);
    ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,sz);
    ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
    ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
}

void DestroyDashboard()
{
    ObjectsDeleteAll(0,DP);
    ChartRedraw(0);
}

void UpdateDashboard()
{
    double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
    double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
    double dailyPnL  = equity - g_dailyEq;
    double weeklyPnL = equity - g_weeklyEq;
    double dailyPct  = (g_dailyEq  > 0) ? dailyPnL  / g_dailyEq  * 100.0 : 0.0;
    double weekPct   = (g_weeklyEq > 0) ? weeklyPnL / g_weeklyEq * 100.0 : 0.0;
    bool   canTrade  = !LimitHit();

    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int hr = dt.hour;
    bool inAsia   = InpTradeAsia && (hr >= InpAsiaStartHour && hr < InpAsiaEndHour);
    bool inLondon = (hr >= InpLondonStartHour && hr < InpLondonEndHour);
    bool inNY     = (hr >= InpNYStartHour     && hr < InpNYEndHour);
    string sessStr; color sessClr;
    if(inLondon && inNY)
        { sessStr=StringFormat("● OVERLAP  %02d-%02d UTC", InpNYStartHour, InpLondonEndHour);
          sessClr=C_YEL; }
    else if(inLondon)
        { sessStr=StringFormat("● LONDON   %02d-%02d UTC", InpLondonStartHour, InpLondonEndHour);
          sessClr=C_GRN; }
    else if(inNY)
        { sessStr=StringFormat("● NEW YORK %02d-%02d UTC", InpNYStartHour, InpNYEndHour);
          sessClr=C_BLU; }
    else if(inAsia)
        { sessStr=StringFormat("● ASIA     %02d-%02d UTC", InpAsiaStartHour, InpAsiaEndHour);
          sessClr=C'80,160,255'; }
    else
        { sessStr="○ MARKET CLOSED";      sessClr=C_DIM; }

    int lx = DB_X+10;    // label column
    int vx = DB_X+160;   // value column

    // ── Panel + header ───────────────────────────────────────
    _R("BG",  DB_X-8, DB_Y-8, DB_W+16, 458, C_BG, C_SEP);
    _R("HDR", DB_X-8, DB_Y-8, DB_W+16, 38,  C_HDR);
    _L("TIT", "  BREAKOUT TREND AI",                   lx, DB_Y,    C_WHT, 10);
    _L("SUB", "  Self-Learning EA  v2.6 | 2026-06-03", lx, DB_Y+15, C_DIM,  8);

    int y = DB_Y + 46;

    // ── Status block ─────────────────────────────────────────
    _R("SBG", DB_X-8, y-4, DB_W+16, DB_LH*3+14, C'20,26,40');
    _L("l_sta","STATUS",    lx, y, C_DIM, 9);
    _L("v_sta","● RUNNING", vx, y, C_GRN, 9);  y+=DB_LH;
    _L("l_sym","SYMBOL",    lx, y, C_DIM, 9);
    _L("v_sym",_Symbol,     vx, y, C_WHT, 9);  y+=DB_LH;
    _L("l_ses","SESSION",   lx, y, C_DIM, 9);
    _L("v_ses",sessStr,     vx, y, sessClr, 9); y+=DB_LH+8;

    // ── AI Engine ────────────────────────────────────────────
    _L("h_ai","── AI ENGINE ─────────────────────", lx, y, C_BLU, 8); y+=DB_LH;

    color stpClr = (g_trainSteps < 10) ? C_YEL : C_WHT;
    string stpStr = (g_trainSteps < 10)
        ? IntegerToString(g_trainSteps) + " (BOOTSTRAP)"
        : IntegerToString(g_trainSteps);
    _L("l_stp","Train Steps",  lx, y, C_DIM, 9);
    _L("v_stp", stpStr,        vx, y, stpClr, 9); y+=DB_LH;

    color sclr=(g_lastScore>=InpAI_Threshold)?C_GRN:C_YEL;
    _L("l_sc","Last Score",    lx, y, C_DIM, 9);
    _L("v_sc",DoubleToString(g_lastScore,3),  vx, y, sclr, 9); y+=DB_LH;

    _L("l_thr","Threshold",    lx, y, C_DIM, 9);
    _L("v_thr",DoubleToString(InpAI_Threshold,2), vx, y, C_DIM, 9); y+=DB_LH;

    string dirtxt=(g_lastDir==1)?"BUY  ▲":(g_lastDir==-1)?"SELL ▼":"---";
    color  dirclr=(g_lastDir==1)?C_GRN:(g_lastDir==-1)?C_RED:C_DIM;
    _L("l_dir","Last Signal",  lx, y, C_DIM, 9);
    _L("v_dir",dirtxt,         vx, y, dirclr, 9); y+=DB_LH;

    string stime=(g_lastSigT>0)?TimeToString(g_lastSigT,TIME_SECONDS):"--:--:--";
    _L("l_st","Signal Time",   lx, y, C_DIM, 9);
    _L("v_st",stime,           vx, y, C_DIM, 9); y+=DB_LH;

    color rsnClr = (StringFind(g_lastReason,"OPEN")>=0)?C_GRN:
                   (StringFind(g_lastReason,"TRADE")>=0)?C_YEL:C_DIM;
    _L("l_rs","Reason",        lx, y, C_DIM, 9);
    _L("v_rs",g_lastReason,    vx, y, rsnClr, 9); y+=DB_LH+8;

    // ── Account ──────────────────────────────────────────────
    _L("h_ac","── ACCOUNT ───────────────────────", lx, y, C_BLU, 8); y+=DB_LH;

    _L("l_eq","Equity",    lx, y, C_DIM, 9);
    _L("v_eq","$"+DoubleToString(equity,2),  vx, y, C_WHT, 9); y+=DB_LH;
    _L("l_bl","Balance",   lx, y, C_DIM, 9);
    _L("v_bl","$"+DoubleToString(balance,2), vx, y, C_WHT, 9); y+=DB_LH;

    string dpStr=(dailyPnL>=0?"+":"")+DoubleToString(dailyPnL,2)+
                 "  ("+(dailyPct>=0?"+":"")+DoubleToString(dailyPct,2)+"%)";
    _L("l_dp","Daily P&L",  lx, y, C_DIM, 9);
    _L("v_dp",dpStr,         vx, y, (dailyPnL>=0)?C_GRN:C_RED, 9); y+=DB_LH;

    string wpStr=(weeklyPnL>=0?"+":"")+DoubleToString(weeklyPnL,2)+
                 "  ("+(weekPct>=0?"+":"")+DoubleToString(weekPct,2)+"%)";
    _L("l_wp","Weekly P&L", lx, y, C_DIM, 9);
    _L("v_wp",wpStr,         vx, y, (weeklyPnL>=0)?C_GRN:C_RED, 9); y+=DB_LH+8;

    // ── Risk Monitor ─────────────────────────────────────────
    _L("h_rk","── RISK MONITOR ──────────────────", lx, y, C_BLU, 8); y+=DB_LH;

    double dUsed=MathAbs(MathMin(dailyPct,0.0));
    color  dLC=(dUsed>=InpMaxDailyLossPercent*0.8)?C_RED:(dUsed>=InpMaxDailyLossPercent*0.5)?C_YEL:C_GRN;
    _L("l_dl","Daily Loss",  lx, y, C_DIM, 9);
    _L("v_dl",DoubleToString(dUsed,2)+"% / "+DoubleToString(InpMaxDailyLossPercent,1)+"%",
              vx, y, dLC, 9); y+=DB_LH;

    double wUsed=MathAbs(MathMin(weekPct,0.0));
    color  wLC=(wUsed>=InpMaxWeeklyLossPercent*0.8)?C_RED:(wUsed>=InpMaxWeeklyLossPercent*0.5)?C_YEL:C_GRN;
    _L("l_wl","Weekly Loss", lx, y, C_DIM, 9);
    _L("v_wl",DoubleToString(wUsed,2)+"% / "+DoubleToString(InpMaxWeeklyLossPercent,1)+"%",
              vx, y, wLC, 9); y+=DB_LH;

    _L("l_tr","Trades Today",lx, y, C_DIM, 9);
    _L("v_tr",IntegerToString(tradesToday)+" / "+IntegerToString(InpMaxTradesPerDay),
              vx, y, C_WHT, 9); y+=DB_LH;

    string canStr=canTrade?"● CAN TRADE":"● LIMIT HIT";
    _L("l_ct","Trade Status",lx, y, C_DIM, 9);
    _L("v_ct",canStr,         vx, y, canTrade?C_GRN:C_RED, 9); y+=DB_LH+6;

    // ── Footer ───────────────────────────────────────────────
    _R("FTR", DB_X-8, y, DB_W+16, 1, C_SEP);  y+=5;
    _L("v_ts",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS), lx, y, C_DIM, 8);

    ChartRedraw(0);
}

// ═══════════════════════════════════════════════════════════════
//  LOGGER
// ═══════════════════════════════════════════════════════════════
int g_log=INVALID_HANDLE;

void InitLogger()
{
    g_log=FileOpen("btai_log.csv",FILE_WRITE|FILE_CSV|FILE_ANSI);
    if(g_log!=INVALID_HANDLE)
        FileWrite(g_log,"time","type","symbol","posId",
                  "direction","entry","sl","tp1","lots","score","profit","step");
}
void LogOpen(const Signal &sig,double lots,double score,ulong posId)
{
    if(g_log==INVALID_HANDLE) return;
    FileWrite(g_log,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
              "OPEN",_Symbol,(string)posId,
              sig.direction,sig.entryPrice,sig.slPrice,sig.tp1Price,
              lots,score,"","");
}
void LogClose(ulong posId,double profit)
{
    if(g_log==INVALID_HANDLE) return;
    FileWrite(g_log,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
              "CLOSE",_Symbol,(string)posId,"","","","","","",profit,g_trainSteps);
}
void LogSkip(const Signal &sig,double score)
{
    if(g_log==INVALID_HANDLE) return;
    FileWrite(g_log,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
              "SKIP",_Symbol,"",sig.direction,sig.entryPrice,"","","",score,"","");
}
void CloseLogger() { if(g_log!=INVALID_HANDLE) FileClose(g_log); }

// ═══════════════════════════════════════════════════════════════
//  TRADE MANAGER
// ═══════════════════════════════════════════════════════════════
#define MAX_MEM 20
struct TRec { ulong posId; double feat[NN_IN]; bool used; };
TRec   g_mem[MAX_MEM];
double g_pend[NN_IN];
bool   g_hasPend=false;

void InitMem() { for(int i=0;i<MAX_MEM;i++) g_mem[i].used=false; g_hasPend=false; }

void StorePend(double &f[]) { for(int i=0;i<NN_IN;i++) g_pend[i]=f[i]; g_hasPend=true; }

void AssignPend(ulong posId)
{
    if(!g_hasPend) return;
    for(int i=0;i<MAX_MEM;i++)
        if(!g_mem[i].used)
        {
            g_mem[i].posId=posId;
            for(int j=0;j<NN_IN;j++) g_mem[i].feat[j]=g_pend[j];
            g_mem[i].used=true; g_hasPend=false; return;
        }
    g_hasPend=false;
}
void OnClose(ulong posId, double profit)
{
    for(int i=0;i<MAX_MEM;i++)
        if(g_mem[i].used && g_mem[i].posId==posId)
        {
            double f[NN_IN]; for(int j=0;j<NN_IN;j++) f[j]=g_mem[i].feat[j];
            g_mem[i].used=false;
            LearnFromTrade(f,profit);
            LogClose(posId,profit);
            return;
        }
}
bool HasTrade()
{
    for(int i=PositionsTotal()-1;i>=0;i--)
        if(PositionGetSymbol(i)==_Symbol &&
           (int)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) return true;
    return false;
}
void OpenTrade(Signal &sig, double lots, double score, double &feat[])
{
    MqlTradeRequest req; MqlTradeResult res;
    ZeroMemory(req); ZeroMemory(res);
    req.symbol=_Symbol; req.magic=InpMagicNumber; req.volume=lots;
    req.type_filling=ORDER_FILLING_FOK;
    req.sl=sig.slPrice; req.tp=sig.tp1Price;
    req.comment=StringFormat("BTAI s=%.2f",score);
    if(sig.direction==1){ req.type=ORDER_TYPE_BUY;  req.price=SymbolInfoDouble(_Symbol,SYMBOL_ASK); }
    else                { req.type=ORDER_TYPE_SELL; req.price=SymbolInfoDouble(_Symbol,SYMBOL_BID); }
    if(OrderSend(req,res))
    { tradesToday++; StorePend(feat); LogOpen(sig,lots,score,res.order); }
    else Print("OrderSend failed: ",res.retcode," ",res.comment);
}
void ManageTrades()
{
    for(int i=PositionsTotal()-1;i>=0;i--)
    {
        if(PositionGetSymbol(i)!=_Symbol) continue;
        if((int)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
        ulong  tk =(ulong)PositionGetInteger(POSITION_TICKET);
        double en =PositionGetDouble(POSITION_PRICE_OPEN);
        double sl =PositionGetDouble(POSITION_SL);
        double tp =PositionGetDouble(POSITION_TP);
        bool isBuy=((int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
        double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
        double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
        bool hitTP = isBuy?(bid>=tp):(ask<=tp);
        bool notBE = isBuy?(sl<en):(sl>en);
        if(hitTP && notBE)
        {
            MqlTradeRequest r; MqlTradeResult rs; ZeroMemory(r); ZeroMemory(rs);
            r.action=TRADE_ACTION_SLTP; r.position=tk;
            r.symbol=_Symbol; r.sl=en; r.tp=tp;
            if(!OrderSend(r,rs))
                Print("BE-stop failed: ",rs.retcode);
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  SESSION FILTER
// ═══════════════════════════════════════════════════════════════
bool InSession()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;
    bool asia   = InpTradeAsia && (h>=InpAsiaStartHour && h<InpAsiaEndHour);
    bool london = (h>=InpLondonStartHour && h<InpLondonEndHour);
    bool ny     = (h>=InpNYStartHour     && h<InpNYEndHour);
    return (asia || london || ny);
}

// ═══════════════════════════════════════════════════════════════
//  MAIN EA HANDLERS
// ═══════════════════════════════════════════════════════════════
// ═══════════════════════════════════════════════════════════════
//  CHART VISUAL LEVELS
// ═══════════════════════════════════════════════════════════════

void DrawHLine(string name, double price, color clr,
               ENUM_LINE_STYLE style = STYLE_SOLID, int width = 1)
{
    string n = "BTAI_LV_" + name;
    if(ObjectFind(0, n) < 0)
        ObjectCreate(0, n, OBJ_HLINE, 0, 0, price);
    ObjectSetDouble (0, n, OBJPROP_PRICE,      price);
    ObjectSetInteger(0, n, OBJPROP_COLOR,      clr);
    ObjectSetInteger(0, n, OBJPROP_STYLE,      style);
    ObjectSetInteger(0, n, OBJPROP_WIDTH,      width);
    ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, n, OBJPROP_HIDDEN,     true);
    ObjectSetString (0, n, OBJPROP_TOOLTIP,    name);
}

void DrawChartLevels()
{
    double atr = GetATR(14);
    if(atr < _Point) return;

    // ── Consolidation range (20-bar high/low) ─────────────────
    double rHigh, rLow;
    if(GetRange(rHigh, rLow))
    {
        DrawHLine("RangeHigh", rHigh, C'42,200,95',  STYLE_SOLID, 2);   // green
        DrawHLine("RangeLow",  rLow,  C'215,62,62',  STYLE_SOLID, 2);   // red
    }

    // ── Swing S/R (60-bar lookback) ───────────────────────────
    double sH = SwingHigh(60, 3);
    double sL = SwingLow (60, 3);
    if(sH > 0) DrawHLine("SwingHigh", sH, C'62,132,215', STYLE_DOT, 1);  // blue dotted
    if(sL > 0) DrawHLine("SwingLow",  sL, C'215,178,42', STYLE_DOT, 1);  // yellow dotted

    // ── Previous day high/low ─────────────────────────────────
    double dH = iHigh(_Symbol, PERIOD_D1, 1);
    double dL = iLow (_Symbol, PERIOD_D1, 1);
    if(dH > 0) DrawHLine("DayHigh", dH, C'180,100,220', STYLE_DASH, 1);  // purple dashed
    if(dL > 0) DrawHLine("DayLow",  dL, C'180,100,220', STYLE_DASH, 1);  // purple dashed

    ChartRedraw(0);
}

int OnInit()
{
    if(!InitIndicators())
    { Print("Failed to create indicator handles"); return INIT_FAILED; }

    // Show EMA50 and EMA200 as coloured lines on the main chart
    ChartIndicatorAdd(0, 0, g_hEMA50);
    ChartIndicatorAdd(0, 0, g_hEMA200);

    InitRisk();
    InitLogger();
    InitMem();
    InitAI(InpAI_ModelFile);
    UpdateDashboard();
    DrawChartLevels();
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    SaveModel(InpAI_ModelFile);
    CloseLogger();
    ReleaseIndicators();
    DestroyDashboard();
    ObjectsDeleteAll(0, "BTAI_LV_");   // remove all level lines
}

void OnTick()
{
    if(!IsNewBar()) return;

    DrawChartLevels();   // refresh S/R lines every bar

    if(!InSession())
    {
        g_lastReason = "OUT OF SESSION";
        UpdateDashboard();
        return;
    }
    if(LimitHit())
    {
        g_lastReason = "LIMIT HIT";
        UpdateDashboard();
        return;
    }
    if(SafeGuardLocked())
    {
        g_lastReason = "SAFEGUARD LOCKED";
        UpdateDashboard();
        return;
    }

    ManageTrades();
    if(HasTrade())
    {
        g_lastReason = "TRADE OPEN";
        UpdateDashboard();
        return;
    }

    // Evaluate trend first for informative reason display
    bool upOK   = IsUptrend();
    bool downOK = IsDowntrend();
    if(!upOK && !downOK)
    {
        g_lastReason = "NO TREND (H1 EMA50)";
        UpdateDashboard();
        return;
    }

    Signal sig;
    if(!GetBreakoutTrendSignal(sig))
    {
        g_lastReason = "NO BREAKOUT";
        UpdateDashboard();
        return;
    }

    double feat[NN_IN];
    BuildFeatures(sig, feat);
    UpdateScaler(feat);

    double score = GetSignalScore(feat);
    g_lastScore  = score;
    g_lastDir    = sig.direction;
    g_lastSigT   = TimeCurrent();

    // Bootstrap mode: model untrained (<10 steps) → trade on trend+breakout
    // alone so the AI gets real trade outcomes to learn from.
    // Once trained, normal threshold applies.
    double effectiveThreshold = (g_trainSteps < 10) ? 0.40 : InpAI_Threshold;

    if(score < effectiveThreshold)
    {
        g_lastReason = (g_trainSteps < 10)
            ? StringFormat("BOOTSTRAP %.3f", score)
            : StringFormat("SCORE LOW %.3f", score);
        LogSkip(sig, score);
        UpdateDashboard();
        return;
    }

    double slPips = CalcSLPips(sig);
    if(slPips < 1.0)
    {
        g_lastReason = "SL TOO SMALL";
        UpdateDashboard();
        return;
    }

    g_lastReason = "OPENING TRADE";
    double lots = CalcLots(InpRiskPercentPerTrade, slPips);
    OpenTrade(sig, lots, score, feat);
    UpdateDashboard();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
    if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
    if(!HistoryDealSelect(trans.deal)) return;
    if((int)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber) return;
    long  entry=(long)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
    ulong posId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
    if(entry==DEAL_ENTRY_IN)
        AssignPend(posId);
    else if(entry==DEAL_ENTRY_OUT||entry==DEAL_ENTRY_INOUT)
    {
        double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                     +HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                     +HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
        OnClose(posId,profit);
    }
}

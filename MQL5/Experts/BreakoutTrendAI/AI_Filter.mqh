#pragma once
#include "Config.mqh"
#include "TrendBreakoutLogic.mqh"

// ═══════════════════════════════════════════════════════════════
//  Architecture: 32 → 24 → 12 → 1
// ═══════════════════════════════════════════════════════════════
#define NN_IN   32
#define NN_H1   24
#define NN_H2   12
#define NN_OUT   1

// ── Weights & biases (row-major 1-D) ────────────────────────
double g_W1[NN_H1 * NN_IN];   // [H1][IN]
double g_b1[NN_H1];
double g_W2[NN_H2 * NN_H1];   // [H2][H1]
double g_b2[NN_H2];
double g_W3[NN_OUT * NN_H2];  // [OUT][H2]
double g_b3[NN_OUT];

// ── SGD momentum velocities ──────────────────────────────────
double g_vW1[NN_H1 * NN_IN];
double g_vb1[NN_H1];
double g_vW2[NN_H2 * NN_H1];
double g_vb2[NN_H2];
double g_vW3[NN_OUT * NN_H2];
double g_vb3[NN_OUT];

// ── Activations stored for backprop ──────────────────────────
double g_a0[NN_IN];
double g_z1[NN_H1], g_a1[NN_H1];
double g_z2[NN_H2], g_a2[NN_H2];
double g_z3[NN_OUT];

// ── Online feature scaler (Welford running mean/M2) ──────────
double g_fm[NN_IN];
double g_fM2[NN_IN];
long   g_fN = 0;

int g_trainSteps = 0;

// ═══════════════════════════════════════════════════════════════
//  Math helpers
// ═══════════════════════════════════════════════════════════════
double NN_Sigmoid(double x)
{
    x = MathMax(-20.0, MathMin(20.0, x));
    return 1.0 / (1.0 + MathExp(-x));
}
double NN_Relu(double x)  { return x > 0.0 ? x : 0.0; }
double NN_ReluD(double x) { return x > 0.0 ? 1.0 : 0.0; }

double NN_RandGauss()
{
    double u1 = (MathRand() + 1.0) / 32769.0;
    double u2 = (MathRand() + 1.0) / 32769.0;
    return MathSqrt(-2.0 * MathLog(u1)) * MathCos(2.0 * MathPi() * u2);
}

void NN_XavierFill(double &W[], int size, int fan_in)
{
    double scale = MathSqrt(2.0 / fan_in);
    for(int i = 0; i < size; i++) W[i] = NN_RandGauss() * scale;
}

void NN_Zero(double &a[], int n) { for(int i=0;i<n;i++) a[i]=0.0; }

// ═══════════════════════════════════════════════════════════════
//  Online scaler
// ═══════════════════════════════════════════════════════════════
void UpdateScaler(double &x[])
{
    g_fN++;
    for(int i = 0; i < NN_IN; i++)
    {
        double d  = x[i] - g_fm[i];
        g_fm[i]  += d / (double)g_fN;
        g_fM2[i] += d * (x[i] - g_fm[i]);
    }
}

void NormalizeFeatures(double &x[], double &out[])
{
    for(int i = 0; i < NN_IN; i++)
    {
        double var = (g_fN > 1) ? g_fM2[i] / (double)(g_fN - 1) : 1.0;
        double std = (var > 1e-10) ? MathSqrt(var) : 1.0;
        out[i] = MathMax(-3.0, MathMin(3.0, (x[i] - g_fm[i]) / std));
    }
}

// ═══════════════════════════════════════════════════════════════
//  Feature builder  (32-dim)
// ═══════════════════════════════════════════════════════════════
void BuildFeatures(const Signal &sig, double &f[])
{
    double atr    = GetATR(14);
    double close0 = iClose(_Symbol, PERIOD_CURRENT, 0);
    double ema50  = GetEMA(50);
    double ema200 = GetEMA(200);

    if(atr < 1e-10) atr = 1.0;
    if(close0 < 1e-10) close0 = 1.0;

    // [0-5] trend context
    f[0] = atr / close0;
    f[1] = GetSpreadPoints() / atr;
    f[2] = (sig.rangeHigh - sig.rangeLow) / atr;
    f[3] = (close0 - ema50)  / atr;
    f[4] = (close0 - ema200) / atr;
    f[5] = (ema50  - ema200) / atr;

    // [6-7] momentum + direction
    f[6] = GetRSI(14) / 100.0;
    f[7] = (double)sig.direction;

    // [8-9] time context
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    f[8] = dt.hour / 23.0;
    f[9] = dt.day_of_week / 6.0;

    // [10-16] last 7 bar bodies / ATR
    for(int k = 0; k < 7; k++)
    {
        double o = iOpen (_Symbol, PERIOD_CURRENT, k + 1);
        double c = iClose(_Symbol, PERIOD_CURRENT, k + 1);
        f[10 + k] = (c - o) / atr;
    }

    // [17-20] last 4 bar ranges / ATR
    for(int k = 0; k < 4; k++)
    {
        double h = iHigh(_Symbol, PERIOD_CURRENT, k + 1);
        double l = iLow (_Symbol, PERIOD_CURRENT, k + 1);
        f[17 + k] = (h - l) / atr;
    }

    // [21-22] wicks of bar 1
    double h1 = iHigh (_Symbol, PERIOD_CURRENT, 1);
    double l1 = iLow  (_Symbol, PERIOD_CURRENT, 1);
    double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
    double o1 = iOpen (_Symbol, PERIOD_CURRENT, 1);
    f[21] = (h1 - MathMax(o1, c1)) / atr;
    f[22] = (MathMin(o1, c1) - l1) / atr;

    // [23-24] breakout distance
    f[23] = (sig.entryPrice - sig.rangeHigh) / atr;
    f[24] = (sig.entryPrice - sig.rangeLow)  / atr;

    // [25] 10-bar momentum
    double c10 = iClose(_Symbol, PERIOD_CURRENT, 10);
    f[25] = (close0 - c10) / atr;

    // [26-31] reserved
    for(int i = 26; i < 32; i++) f[i] = 0.0;
}

// ═══════════════════════════════════════════════════════════════
//  Forward pass  (stores activations for backprop)
// ═══════════════════════════════════════════════════════════════
double ForwardPass(double &norm[])
{
    for(int i = 0; i < NN_IN; i++) g_a0[i] = norm[i];

    for(int r = 0; r < NN_H1; r++)
    {
        double s = g_b1[r];
        for(int c = 0; c < NN_IN; c++) s += g_W1[r * NN_IN + c] * g_a0[c];
        g_z1[r] = s;
        g_a1[r] = NN_Relu(s);
    }

    for(int r = 0; r < NN_H2; r++)
    {
        double s = g_b2[r];
        for(int c = 0; c < NN_H1; c++) s += g_W2[r * NN_H1 + c] * g_a1[c];
        g_z2[r] = s;
        g_a2[r] = NN_Relu(s);
    }

    double s = g_b3[0];
    for(int c = 0; c < NN_H2; c++) s += g_W3[c] * g_a2[c];
    g_z3[0] = s;
    return NN_Sigmoid(s);
}

// ═══════════════════════════════════════════════════════════════
//  Backprop + SGD-momentum weight update
// ═══════════════════════════════════════════════════════════════
void Backprop(double label)
{
    double lr  = InpLearningRate;
    double mom = InpMomentum;

    // Output: combined BCE+sigmoid gradient
    double dz3 = NN_Sigmoid(g_z3[0]) - label;

    for(int c = 0; c < NN_H2; c++)
    {
        double dw = dz3 * g_a2[c];
        g_vW3[c] = mom * g_vW3[c] - lr * dw;
        g_W3[c] += g_vW3[c];
    }
    g_vb3[0] = mom * g_vb3[0] - lr * dz3;
    g_b3[0] += g_vb3[0];

    // Layer 2 delta
    double dz2[NN_H2];
    for(int r = 0; r < NN_H2; r++)
        dz2[r] = g_W3[r] * dz3 * NN_ReluD(g_z2[r]);

    for(int r = 0; r < NN_H2; r++)
    {
        for(int c = 0; c < NN_H1; c++)
        {
            double dw = dz2[r] * g_a1[c];
            g_vW2[r * NN_H1 + c] = mom * g_vW2[r * NN_H1 + c] - lr * dw;
            g_W2[r * NN_H1 + c] += g_vW2[r * NN_H1 + c];
        }
        g_vb2[r] = mom * g_vb2[r] - lr * dz2[r];
        g_b2[r] += g_vb2[r];
    }

    // Layer 1 delta
    double dz1[NN_H1];
    for(int r = 0; r < NN_H1; r++)
    {
        double delta = 0.0;
        for(int k = 0; k < NN_H2; k++)
            delta += g_W2[k * NN_H1 + r] * dz2[k];
        dz1[r] = delta * NN_ReluD(g_z1[r]);
    }

    for(int r = 0; r < NN_H1; r++)
    {
        for(int c = 0; c < NN_IN; c++)
        {
            double dw = dz1[r] * g_a0[c];
            g_vW1[r * NN_IN + c] = mom * g_vW1[r * NN_IN + c] - lr * dw;
            g_W1[r * NN_IN + c] += g_vW1[r * NN_IN + c];
        }
        g_vb1[r] = mom * g_vb1[r] - lr * dz1[r];
        g_b1[r] += g_vb1[r];
    }

    g_trainSteps++;
    if(g_trainSteps % InpSaveEveryNTrades == 0)
        SaveAIModel(InpAI_ModelFile);
}

// ═══════════════════════════════════════════════════════════════
//  Public interface
// ═══════════════════════════════════════════════════════════════
double GetSignalScore(double &features[])
{
    double norm[NN_IN];
    NormalizeFeatures(features, norm);
    return ForwardPass(norm);
}

// Called after a trade closes; profit is net (including swap+commission)
void LearnFromTrade(double &features[], double profit)
{
    double norm[NN_IN];
    NormalizeFeatures(features, norm);
    double score = ForwardPass(norm);

    // Smooth label: maps profit fraction of equity to (0,1)
    double equity = AccountEquity();
    double pct    = (equity > 0) ? profit / equity * 100.0 : 0.0;
    double label  = NN_Sigmoid(pct * 20.0);  // 20× amplifier

    Backprop(label);

    Print("AI | step=", g_trainSteps,
          "  profit=", DoubleToString(profit, 2),
          "  label=",  DoubleToString(label, 3),
          "  score=",  DoubleToString(score, 3));
}

// ═══════════════════════════════════════════════════════════════
//  Save / Load
// ═══════════════════════════════════════════════════════════════
bool SaveAIModel(string filename)
{
    int h = FileOpen(filename, FILE_WRITE | FILE_TXT | FILE_ANSI);
    if(h == INVALID_HANDLE) return false;

    // Header: architecture
    FileWriteString(h, IntegerToString(NN_IN) + " " + IntegerToString(NN_H1) +
                       " " + IntegerToString(NN_H2) + " " + IntegerToString(NN_OUT) + "\n");

    string ln;
    int i;

    ln = ""; for(i=0;i<NN_H1*NN_IN;i++) ln+=DoubleToString(g_W1[i],8)+" "; FileWriteString(h,ln+"\n");
    ln = ""; for(i=0;i<NN_H1;i++)       ln+=DoubleToString(g_b1[i],8)+" "; FileWriteString(h,ln+"\n");
    ln = ""; for(i=0;i<NN_H2*NN_H1;i++) ln+=DoubleToString(g_W2[i],8)+" "; FileWriteString(h,ln+"\n");
    ln = ""; for(i=0;i<NN_H2;i++)       ln+=DoubleToString(g_b2[i],8)+" "; FileWriteString(h,ln+"\n");
    ln = ""; for(i=0;i<NN_H2;i++)       ln+=DoubleToString(g_W3[i],8)+" "; FileWriteString(h,ln+"\n");
    ln = ""; for(i=0;i<NN_OUT;i++)      ln+=DoubleToString(g_b3[i],8)+" "; FileWriteString(h,ln+"\n");

    // Scaler state
    ln = ""; for(i=0;i<NN_IN;i++) ln+=DoubleToString(g_fm[i], 8)+" "; FileWriteString(h,ln+"\n");
    ln = ""; for(i=0;i<NN_IN;i++) ln+=DoubleToString(g_fM2[i],8)+" "; FileWriteString(h,ln+"\n");
    FileWriteString(h, IntegerToString((int)g_fN)      + "\n");
    FileWriteString(h, IntegerToString(g_trainSteps)   + "\n");

    FileClose(h);
    return true;
}

bool LoadWeightsFromHandle(int h)
{
    int n0=(int)FileReadNumber(h), n1=(int)FileReadNumber(h),
        n2=(int)FileReadNumber(h), n3=(int)FileReadNumber(h);
    if(n0!=NN_IN || n1!=NN_H1 || n2!=NN_H2 || n3!=NN_OUT)
    { Print("AI: arch mismatch in file"); return false; }

    int i;
    for(i=0;i<n1*n0;i++) g_W1[i]=FileReadNumber(h);
    for(i=0;i<n1;i++)    g_b1[i]=FileReadNumber(h);
    for(i=0;i<n2*n1;i++) g_W2[i]=FileReadNumber(h);
    for(i=0;i<n2;i++)    g_b2[i]=FileReadNumber(h);
    for(i=0;i<n2;i++)    g_W3[i]=FileReadNumber(h);   // OUT=1 so n3*n2 = n2
    for(i=0;i<n3;i++)    g_b3[i]=FileReadNumber(h);
    for(i=0;i<n0;i++)    g_fm[i] =FileReadNumber(h);
    for(i=0;i<n0;i++)    g_fM2[i]=FileReadNumber(h);
    g_fN         = (long)FileReadNumber(h);
    g_trainSteps = (int) FileReadNumber(h);
    return true;
}

bool InitAIModel(string filename)
{
    // Zero velocities
    NN_Zero(g_vW1, NN_H1*NN_IN); NN_Zero(g_vb1, NN_H1);
    NN_Zero(g_vW2, NN_H2*NN_H1); NN_Zero(g_vb2, NN_H2);
    NN_Zero(g_vW3, NN_OUT*NN_H2); NN_Zero(g_vb3, NN_OUT);
    NN_Zero(g_fm,  NN_IN);
    for(int i=0;i<NN_IN;i++) g_fM2[i]=1.0;
    g_fN=0; g_trainSteps=0;

    int h = FileOpen(filename, FILE_READ|FILE_TXT);
    if(h != INVALID_HANDLE)
    {
        bool ok = LoadWeightsFromHandle(h);
        FileClose(h);
        if(ok)
        {
            Print("AI: model loaded | steps=", g_trainSteps, " scalerN=", (int)g_fN);
            return true;
        }
    }

    // Fresh Xavier init
    MathSrand((int)(TimeCurrent() & 0x7FFFFFFF));
    NN_XavierFill(g_W1, NN_H1*NN_IN, NN_IN);  NN_Zero(g_b1, NN_H1);
    NN_XavierFill(g_W2, NN_H2*NN_H1, NN_H1);  NN_Zero(g_b2, NN_H2);
    NN_XavierFill(g_W3, NN_OUT*NN_H2, NN_H2); NN_Zero(g_b3, NN_OUT);
    Print("AI: fresh random weights (no saved model)");
    return false;
}

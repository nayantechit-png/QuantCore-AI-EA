//+------------------------------------------------------------------+
//|                     QuantCore_AI_EA.mq5                          |
//|          AI-Powered Prop Firm Expert Advisor  v1.0                |
//|  Strategy: Kalman Filter + EMA Ensemble + Momentum + MTF         |
//|  GitHub : https://github.com/QuantCore/QuantCore-AI-EA           |
//+------------------------------------------------------------------+
//  PROP FIRM COMPLIANCE
//  ✓ Max daily loss guard         (default 4.5% — buffer under 5%)
//  ✓ Max total drawdown guard     (default 9.0% — buffer under 10%)
//  ✓ Min 1:2 risk/reward          (ATR-based SL & TP)
//  ✓ ATR position sizing          (fixed % risk, never martingale)
//  ✓ Trading hours filter         (avoids illiquid sessions)
//  ✓ Profit lock                  (tightens stops after target hit)
//  ✓ Friday auto-close            (no weekend gap risk)
//  ✓ No grid / no martingale
//+------------------------------------------------------------------+
#property copyright   "QuantCore"
#property link        "https://github.com/QuantCore/QuantCore-AI-EA"
#property version     "1.31"
#property description "AI ensemble EA for prop firm challenges — Forex & Gold"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Math\Stat\Math.mqh>

CTrade         Trade;
CPositionInfo  PosInfo;

//──────────────────────────────────────────────────────────────────
// INPUT PARAMETERS
//──────────────────────────────────────────────────────────────────

input group "════ PROP FIRM RISK LIMITS ════"
input double Inp_MaxDailyLoss   = 4.5;    // Max daily loss %  (prop limit - buffer)
input double Inp_MaxTotalLoss   = 9.0;    // Max total loss %  (prop limit - buffer)
input double Inp_RiskPerTrade   = 0.50;   // Risk per trade %
input double Inp_ProfitLockAt   = 6.0;    // Activate profit-lock at equity gain %
input double Inp_ProfitLockDD   = 1.0;    // Max drawdown after profit-lock (%)

input group "════ AI SIGNAL ENGINE ════"
input double Inp_MinScore       = 0.68;   // Min combined score to enter  [0.0–1.0]
input double Inp_MinScoreMTF    = 0.55;   // Min H4 confirmation score
input double Inp_MinADX         = 18.0;   // Min ADX to enter (skip flat/choppy markets)
input int    Inp_EMA_Fast       = 20;     // Fast EMA
input int    Inp_EMA_Mid        = 50;     // Mid EMA
input int    Inp_EMA_Slow       = 200;    // Slow EMA
input int    Inp_RSI_Period     = 14;     // RSI period
input int    Inp_Stoch_K        = 5;      // Stochastic %K
input int    Inp_Stoch_D        = 3;      // Stochastic %D
input int    Inp_ADX_Period     = 14;     // ADX period
input int    Inp_ATR_Period     = 14;     // ATR period

input group "════ TRADE MANAGEMENT ════"
input double Inp_SL_ATR_Mult    = 1.5;   // Stop loss  × ATR
input double Inp_TP_ATR_Mult    = 3.0;   // Take profit × ATR   (2:1 min RR)
input bool   Inp_TrailingStop   = true;  // Enable ATR trailing stop
input double Inp_Trail_ATR      = 1.2;   // Trailing stop distance × ATR (wider = less premature exits)
input int    Inp_MaxPositions   = 2;     // Max simultaneous positions
input double Inp_LongExtraScore = 0.05;  // Extra score required for BUY entries (long bias fix)
input bool   Inp_SkipSessionEdge = true; // Skip entries at session transition hours (avoids open/close spikes)
input double Inp_MinSL_Pips    = 15.0;  // Minimum SL distance in pips (0 = disabled)

input group "════ CONSECUTIVE LOSS GUARD ════"
input int    Inp_MaxConsecLoss     = 3;    // Pause trading after N consecutive losses
input double Inp_ConsecPauseHours  = 4.0;  // Hours to pause after hitting limit

input group "════ KALMAN FILTER ════"
input double Inp_KF_Delta       = 0.0001; // Process noise  (smaller = smoother)
input double Inp_KF_Ve          = 0.001;  // Measurement noise

input group "════ TRADING SESSIONS (UTC Server Time) ════"
input bool   Inp_TradeAsia      = true;   // Trade Asian session    (00:00–09:00 UTC)
input bool   Inp_TradeLondon    = true;   // Trade London session   (07:00–16:00 UTC)
input bool   Inp_TradeNewYork   = true;   // Trade New York session (13:00–21:00 UTC)
input bool   Inp_BoostOverlap   = true;   // Lower score during London-NY overlap (peak volume)
input double Inp_OverlapBoost   = 0.03;   // Score reduction during L-NY overlap (12:00-16:00)
input bool   Inp_CloseFriday    = true;   // Close all positions on Friday 21:00 UTC

input group "════ SIGNAL WEIGHTS ════"
input double W_Trend    = 0.30;  // EMA trend weight
input double W_Momentum = 0.25;  // RSI + Stoch weight
input double W_Regime   = 0.20;  // ADX regime weight
input double W_Kalman   = 0.15;  // Kalman filter weight
input double W_MTF      = 0.10;  // Multi-timeframe weight

//──────────────────────────────────────────────────────────────────
// GLOBALS
//──────────────────────────────────────────────────────────────────

// Account snapshot
double g_StartBalance    = 0;
double g_DayStartBalance = 0;
double g_PeakEquity      = 0;
datetime g_LastDayCheck  = 0;
bool   g_ProfitLocked    = false;
bool   g_TradingAllowed  = true;
string g_StopReason      = "";

// Kalman filter state
double kf_price   = 0;   // estimated price level (state)
double kf_vel     = 0;   // estimated trend velocity (derived signal)
double kf_P       = 1;   // error covariance
double kf_Vw      = 0;   // process noise (computed from delta)
double kf_Ve      = 0;   // measurement noise
bool   kf_Init    = false;

// Indicator handles
int h_EMA_Fast, h_EMA_Mid, h_EMA_Slow;
int h_RSI, h_Stoch, h_ADX, h_ATR;
int h_EMA_Fast_H4, h_EMA_Slow_H4, h_RSI_H4;

// Dashboard signal cache (updated every tick once indicators are ready)
double g_LastBullScore = 0;
double g_LastBearScore = 0;
bool   g_ScoresReady   = false;

// Consecutive loss guard
int      g_ConsecLosses     = 0;
int      g_ConsecWins       = 0;
datetime g_ConsecPausedUntil = 0;

// Dashboard color palette
#define QC_BG   C'15,19,29'
#define QC_HDR  C'25,33,52'
#define QC_GRN  C'42,200,95'
#define QC_RED  C'215,62,62'
#define QC_BLU  C'62,132,215'
#define QC_YEL  C'215,178,42'
#define QC_DIM  C'90,105,126'
#define QC_WHT  C'220,225,235'

//──────────────────────────────────────────────────────────────────
// INIT / DEINIT
//──────────────────────────────────────────────────────────────────

int OnInit()
  {
   // Validate weights sum to 1.0
   double wsum = W_Trend + W_Momentum + W_Regime + W_Kalman + W_MTF;
   if(MathAbs(wsum - 1.0) > 0.01)
     {
      Alert("QuantCore EA: Signal weights must sum to 1.0 (current sum = ", wsum, ")");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Validate risk params
   if(Inp_RiskPerTrade <= 0 || Inp_RiskPerTrade > 5)
     {
      Alert("QuantCore EA: RiskPerTrade must be 0-5%");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Create indicator handles — H1
   h_EMA_Fast  = iMA(_Symbol, PERIOD_H1, Inp_EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Mid   = iMA(_Symbol, PERIOD_H1, Inp_EMA_Mid,   0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Slow  = iMA(_Symbol, PERIOD_H1, Inp_EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   h_RSI       = iRSI(_Symbol, PERIOD_H1, Inp_RSI_Period, PRICE_CLOSE);
   h_Stoch     = iStochastic(_Symbol, PERIOD_H1, Inp_Stoch_K, Inp_Stoch_D, 3, MODE_SMA, STO_LOWHIGH);
   h_ADX       = iADX(_Symbol, PERIOD_H1, Inp_ADX_Period);
   h_ATR       = iATR(_Symbol, PERIOD_H1, Inp_ATR_Period);

   // Create indicator handles — H4 (confirmation)
   h_EMA_Fast_H4 = iMA(_Symbol, Inp_ConfirmTF(), Inp_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Slow_H4 = iMA(_Symbol, Inp_ConfirmTF(), Inp_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI_H4      = iRSI(_Symbol, Inp_ConfirmTF(), Inp_RSI_Period, PRICE_CLOSE);

   if(h_EMA_Fast == INVALID_HANDLE || h_RSI == INVALID_HANDLE || h_ATR == INVALID_HANDLE)
     {
      Alert("QuantCore EA: Failed to create indicator handles");
      return INIT_FAILED;
     }

   // Kalman init
   kf_Vw  = Inp_KF_Delta / (1.0 - Inp_KF_Delta);
   kf_Ve  = Inp_KF_Ve;
   kf_P   = 1.0;
   kf_Init = false;

   // Account snapshot
   g_StartBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayStartBalance = g_StartBalance;
   g_PeakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   g_LastDayCheck    = TimeCurrent();
   g_TradingAllowed  = true;

   // Trade settings
   Trade.SetExpertMagicNumber((ulong)20240101);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(GetFillingMode());  // auto-detect: FOK → IOC → RETURN

   Print("QuantCore AI EA initialized | Balance: ", g_StartBalance,
         " | MaxDailyLoss: ", Inp_MaxDailyLoss, "% | MaxTotalLoss: ", Inp_MaxTotalLoss, "%");
   UpdateDashboard();
   return INIT_SUCCEEDED;
  }

ENUM_TIMEFRAMES Inp_ConfirmTF() { return PERIOD_H4; }

ENUM_ORDER_TYPE_FILLING GetFillingMode()
  {
   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//──────────────────────────────────────────────────────────────────
// SESSION HELPERS
//──────────────────────────────────────────────────────────────────

// Returns true if ANY enabled session is currently open
bool IsSessionOpen(int hour)
  {
   // Asia   00:00–09:00 UTC  (JPY, Gold Asian demand)
   if(Inp_TradeAsia    && hour >= 0  && hour < 9)  return true;
   // London 07:00–16:00 UTC  (EUR, GBP, Gold)
   if(Inp_TradeLondon  && hour >= 7  && hour < 16) return true;
   // New York 13:00–21:00 UTC (USD, Gold)
   if(Inp_TradeNewYork && hour >= 13 && hour < 21) return true;
   return false;
  }

// True during London-NY overlap 12:00-16:00 UTC (peak liquidity)
bool IsOverlapHour(int hour)
  {
   return (hour >= 12 && hour < 16);
  }

// Human-readable active session name for journal logs
string ActiveSessionName(int hour)
  {
   string s = "";
   if(Inp_TradeAsia    && hour >= 0  && hour < 9)  s += "Asia ";
   if(Inp_TradeLondon  && hour >= 7  && hour < 16) s += "London ";
   if(hour >= 13 && hour < 16)                     s += "[OVERLAP] ";
   if(Inp_TradeNewYork && hour >= 13 && hour < 21) s += "NewYork ";
   if(StringLen(s) == 0)                           s =  "Closed";
   return StringTrimRight(s);
  }

// Session colour for dashboard: yellow=overlap, green=London, blue=NY, dim=closed
color ActiveSessionColor(int hour)
  {
   bool lon = (Inp_TradeLondon  && hour >= 7  && hour < 16);
   bool ny  = (Inp_TradeNewYork && hour >= 13 && hour < 21);
   bool asi = (Inp_TradeAsia    && hour >= 0  && hour < 9);
   if(lon && ny) return QC_YEL;
   if(lon)       return QC_GRN;
   if(ny)        return QC_BLU;
   if(asi)       return C'80,160,255';
   return QC_DIM;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(h_EMA_Fast);  IndicatorRelease(h_EMA_Mid);
   IndicatorRelease(h_EMA_Slow);  IndicatorRelease(h_RSI);
   IndicatorRelease(h_Stoch);     IndicatorRelease(h_ADX);
   IndicatorRelease(h_ATR);       IndicatorRelease(h_EMA_Fast_H4);
   IndicatorRelease(h_EMA_Slow_H4); IndicatorRelease(h_RSI_H4);
   DestroyDashboard();
   Print("QuantCore AI EA stopped. Reason: ", reason);
  }

//──────────────────────────────────────────────────────────────────
// MAIN TICK
//──────────────────────────────────────────────────────────────────

void OnTick()
  {
   // New H1 bar detection
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (curBar != lastBar);
   if(newBar) lastBar = curBar;

   // Always run: Kalman + score cache update + dashboard + trailing + prop checks
   UpdateKalmanOnTick();

   // Compute scores on every tick so dashboard is always live (bar-1 data is
   // constant between bars, so this is a cheap repeated read — not wasteful)
   {
      double bs = 0, ss = 0;
      if(CalcSignalScores(bs, ss))
        {
         g_LastBullScore = bs;
         g_LastBearScore = ss;
         g_ScoresReady   = true;
        }
   }

   UpdateDashboard();
   if(Inp_TrailingStop) ManageTrailingStop();
   CheckDailyReset();
   if(!CheckPropLimits()) return;

   // Friday auto-close
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(Inp_CloseFriday && dt.day_of_week == 5 && dt.hour >= 21)
     {
      CloseAllPositions("Friday auto-close");
      return;
     }

   if(!newBar) return;   // entries only on new H1 bar
   if(!g_ScoresReady)    return;   // wait until indicators have warmed up

   // ── SESSION FILTER ────────────────────────────────────────────
   if(!IsSessionOpen(dt.hour)) return;

   // ── SESSION EDGE FILTER ───────────────────────────────────────
   // Skip the first bar at session transition hours — London open (07),
   // NY open/overlap (13), London close (16), NY close (21).
   // Spread widens and volatility spikes exactly at these crossings;
   // the June 5 back-to-back losses both fired at 16:00 UTC.
   if(Inp_SkipSessionEdge &&
      (dt.hour == 7 || dt.hour == 13 || dt.hour == 16 || dt.hour == 21))
      return;

   // ── DYNAMIC SCORE THRESHOLD ───────────────────────────────────
   double dynMinScore = Inp_MinScore;
   if(Inp_BoostOverlap && IsOverlapHour(dt.hour))
      dynMinScore = MathMax(0.50, Inp_MinScore - Inp_OverlapBoost);

   // Use the scores already computed this tick
   double bullScore = g_LastBullScore;
   double bearScore = g_LastBearScore;

   int openCount = CountOpenPositions();

   // ── EXIT logic (reversal signal) ──────────────────────────────
   // Require a STRONGER signal to close than to enter (avoids cutting
   // winners during brief consolidation bounces).
   double exitThreshold = Inp_MinScore + 0.08;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic() != Trade.RequestMagic()) continue;
      if(PosInfo.Symbol() != _Symbol) continue;

      if(PosInfo.PositionType() == POSITION_TYPE_BUY && bearScore >= exitThreshold)
        {
         Trade.PositionClose(PosInfo.Ticket());
         Print("QuantCore: Closing BUY — bear reversal (", DoubleToString(bearScore,3), ")");
        }
      else if(PosInfo.PositionType() == POSITION_TYPE_SELL && bullScore >= exitThreshold)
        {
         Trade.PositionClose(PosInfo.Ticket());
         Print("QuantCore: Closing SELL — bull reversal (", DoubleToString(bullScore,3), ")");
        }
     }

   // ── ENTRY logic ───────────────────────────────────────────────
   if(openCount >= Inp_MaxPositions) return;
   if(!g_TradingAllowed) return;
   // Consecutive loss pause: skip new entries until pause expires
   if(TimeCurrent() < g_ConsecPausedUntil) return;

   double atr[];
   if(CopyBuffer(h_ATR, 0, 1, 1, atr) < 1) return;
   double atrVal = atr[0];
   if(atrVal <= 0) return;

   double sl_dist = atrVal * Inp_SL_ATR_Mult;
   double tp_dist = atrVal * Inp_TP_ATR_Mult;

   // ── MINIMUM SL PIPS GUARD ─────────────────────────────────────
   // Protects against ATR-compressed SLs that widen spreads will immediately
   // trigger. Pip size = _Point × 10 for 5/3-digit pairs, _Point for 4/2-digit.
   if(Inp_MinSL_Pips > 0)
     {
      double pipSz = _Point * (_Digits % 2 == 1 ? 10.0 : 1.0);
      if(pipSz > 0 && sl_dist / pipSz < Inp_MinSL_Pips)
        {
         Print("QuantCore: SL too tight (", DoubleToString(sl_dist / pipSz, 1),
               " pips < ", Inp_MinSL_Pips, " min). Skipping entry.");
         return;
        }
     }

   string sessName = ActiveSessionName(dt.hour);

   // ADX filter: skip entries in flat/choppy markets
   double adxEntry[];
   if(CopyBuffer(h_ADX, 0, 1, 1, adxEntry) < 1) return;
   if(adxEntry[0] < Inp_MinADX) return;

   // BUY requires extra margin (live report: longs win 41.67% vs shorts 56.1%)
   if(bullScore >= dynMinScore + Inp_LongExtraScore && !HasPosition(POSITION_TYPE_BUY))
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = ask - sl_dist;
      double tp  = ask + tp_dist;
      double lot = CalcLotSize(sl_dist);
      if(lot > 0)
        {
         Trade.Buy(lot, _Symbol, ask, sl, tp,
                   StringFormat("QuantCore[%.3f]|%.5f", bullScore, atrVal));
         Print("QuantCore BUY | Session:", sessName,
               " | Score:", DoubleToString(bullScore,3),
               " | Threshold:", DoubleToString(dynMinScore,3),
               " | Lot:", lot, " | SL:", sl, " | TP:", tp);
        }
     }
   else if(bearScore >= dynMinScore && !HasPosition(POSITION_TYPE_SELL))
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = bid + sl_dist;
      double tp  = bid - tp_dist;
      double lot = CalcLotSize(sl_dist);
      if(lot > 0)
        {
         Trade.Sell(lot, _Symbol, bid, sl, tp,
                    StringFormat("QuantCore[%.3f]|%.5f", bearScore, atrVal));
         Print("QuantCore SELL | Session:", sessName,
               " | Score:", DoubleToString(bearScore,3),
               " | Threshold:", DoubleToString(dynMinScore,3),
               " | Lot:", lot, " | SL:", sl, " | TP:", tp);
        }
     }
  }

//──────────────────────────────────────────────────────────────────
// AI SIGNAL ENGINE
//──────────────────────────────────────────────────────────────────

bool CalcSignalScores(double &bullScore, double &bearScore)
  {
   bullScore = 0; bearScore = 0;

   // ── 1. TREND SCORE (EMA alignment) ───────────────────────────
   double ema_f[], ema_m[], ema_s[];
   if(CopyBuffer(h_EMA_Fast, 0, 1, 1, ema_f) < 1) return false;
   if(CopyBuffer(h_EMA_Mid,  0, 1, 1, ema_m) < 1) return false;
   if(CopyBuffer(h_EMA_Slow, 0, 1, 1, ema_s) < 1) return false;

   double close = iClose(_Symbol, PERIOD_H1, 1);
   double trendBull = 0, trendBear = 0;

   // Price vs EMAs
   if(close > ema_f[0]) trendBull += 0.25; else trendBear += 0.25;
   if(close > ema_m[0]) trendBull += 0.25; else trendBear += 0.25;
   if(close > ema_s[0]) trendBull += 0.25; else trendBear += 0.25;
   // EMA order
   if(ema_f[0] > ema_m[0] && ema_m[0] > ema_s[0]) trendBull += 0.25;
   else if(ema_f[0] < ema_m[0] && ema_m[0] < ema_s[0]) trendBear += 0.25;

   // ── 2. MOMENTUM SCORE (RSI + Stochastic) ──────────────────────
   double rsi[], stochK[], stochD[];
   if(CopyBuffer(h_RSI,   0, 1, 1, rsi)    < 1) return false;
   if(CopyBuffer(h_Stoch, 0, 1, 1, stochK) < 1) return false;
   if(CopyBuffer(h_Stoch, 1, 1, 1, stochD) < 1) return false;

   double momBull = 0, momBear = 0;
   // RSI — symmetric scoring (was asymmetric: bull got 0.4 vs bear 0.2)
   if(rsi[0] > 55 && rsi[0] < 70) momBull += 0.35;      // bullish momentum
   else if(rsi[0] > 30 && rsi[0] < 45) momBear += 0.35; // bearish momentum
   else if(rsi[0] <= 30) momBull += 0.25;   // oversold bounce
   else if(rsi[0] >= 70) momBear += 0.25;   // overbought fade
   // Stochastic
   if(stochK[0] > stochD[0] && stochK[0] < 80) momBull += 0.3;
   if(stochK[0] < stochD[0] && stochK[0] > 20) momBear += 0.3;
   if(stochK[0] < 20) momBull += 0.3; // oversold
   if(stochK[0] > 80) momBear += 0.3; // overbought

   momBull = MathMin(momBull, 1.0);
   momBear = MathMin(momBear, 1.0);

   // ── 3. REGIME SCORE (ADX trend strength) ──────────────────────
   double adxMain[], adxPlus[], adxMinus[];
   if(CopyBuffer(h_ADX, 0, 1, 1, adxMain)  < 1) return false;
   if(CopyBuffer(h_ADX, 1, 1, 1, adxPlus)  < 1) return false;
   if(CopyBuffer(h_ADX, 2, 1, 1, adxMinus) < 1) return false;

   double regimeBull = 0, regimeBear = 0;
   double adxNorm = MathMin(adxMain[0] / 50.0, 1.0); // normalize 0-50 → 0-1

   if(adxPlus[0] > adxMinus[0])
     {
      regimeBull = adxNorm;
      regimeBear = 0.5 - adxNorm * 0.5;
     }
   else
     {
      regimeBear = adxNorm;
      regimeBull = 0.5 - adxNorm * 0.5;
     }

   // ── 4. KALMAN SCORE (trend direction + confidence) ─────────────
   // Normalize velocity by ATR so the confidence is meaningful across all pairs
   double atr_k[];
   double kalmanBull = 0.5, kalmanBear = 0.5;   // default neutral
   if(CopyBuffer(h_ATR, 0, 1, 1, atr_k) >= 1 && atr_k[0] > 0)
     {
      double conf = MathMin(MathAbs(kf_vel) / (atr_k[0] * 0.05 + 1e-10), 1.0);
      if(kf_vel > 0)
        { kalmanBull = 0.5 + conf * 0.5; kalmanBear = 1.0 - kalmanBull; }
      else
        { kalmanBear = 0.5 + conf * 0.5; kalmanBull = 1.0 - kalmanBear; }
     }

   // ── 5. MULTI-TIMEFRAME SCORE (H4 confirmation) ─────────────────
   double ema_f_h4[], ema_s_h4[], rsi_h4[];
   if(CopyBuffer(h_EMA_Fast_H4, 0, 1, 1, ema_f_h4) < 1) return false;
   if(CopyBuffer(h_EMA_Slow_H4, 0, 1, 1, ema_s_h4) < 1) return false;
   if(CopyBuffer(h_RSI_H4,      0, 1, 1, rsi_h4)   < 1) return false;

   double mtfBull = 0, mtfBear = 0;
   double closeH4 = iClose(_Symbol, Inp_ConfirmTF(), 1);
   if(closeH4 > ema_f_h4[0] && ema_f_h4[0] > ema_s_h4[0]) mtfBull += 0.5;
   else if(closeH4 < ema_f_h4[0] && ema_f_h4[0] < ema_s_h4[0]) mtfBear += 0.5;
   if(rsi_h4[0] > 50) mtfBull += 0.5; else mtfBear += 0.5;

   // ── WEIGHTED ENSEMBLE ─────────────────────────────────────────
   bullScore = trendBull  * W_Trend
             + momBull    * W_Momentum
             + regimeBull * W_Regime
             + kalmanBull * W_Kalman
             + mtfBull    * W_MTF;

   bearScore = trendBear  * W_Trend
             + momBear    * W_Momentum
             + regimeBear * W_Regime
             + kalmanBear * W_Kalman
             + mtfBear    * W_MTF;

   return true;
  }

//──────────────────────────────────────────────────────────────────
// KALMAN FILTER  (1-D state: tracks price velocity / trend)
//──────────────────────────────────────────────────────────────────

void UpdateKalmanOnTick()
  {
   double price = iClose(_Symbol, PERIOD_H1, 1);
   if(price <= 0) return;

   if(!kf_Init)
     {
      kf_price = price;
      kf_vel   = 0;
      kf_P     = 1.0;
      kf_Init  = true;
      return;
     }

   // Predict (track price level)
   double P_pred    = kf_P + kf_Vw;

   // Innovation = distance from predicted price to actual price
   double innov = price - kf_price;

   // Kalman gain
   double K = P_pred / (P_pred + kf_Ve);

   // Update price estimate and error covariance
   double price_new = kf_price + K * innov;
   kf_P             = (1.0 - K) * P_pred;

   // Velocity = change in Kalman price estimate (smoothed slope)
   kf_vel   = price_new - kf_price;
   kf_price = price_new;
  }

//──────────────────────────────────────────────────────────────────
// POSITION SIZING  (fixed fractional, ATR-based stop)
//──────────────────────────────────────────────────────────────────

double CalcLotSize(double sl_distance_price)
  {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   // Hard cap: never risk more than 1% of equity on a single trade regardless of inputs
   double max_risk   = equity * 0.01;
   double risk_money = MathMin(balance * Inp_RiskPerTrade / 100.0, max_risk);

   double tick_val   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot_step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tick_size <= 0 || tick_val <= 0 || sl_distance_price <= 0) return 0;

   double sl_ticks   = sl_distance_price / tick_size;
   double value_per_lot = sl_ticks * tick_val;

   if(value_per_lot <= 0) return 0;

   double lot = risk_money / value_per_lot;
   lot = MathFloor(lot / lot_step) * lot_step;
   lot = MathMax(min_lot, MathMin(max_lot, lot));

   return lot;
  }

//──────────────────────────────────────────────────────────────────
// TRAILING STOP
//──────────────────────────────────────────────────────────────────

void ManageTrailingStop()
  {
   double atr[];
   if(CopyBuffer(h_ATR, 0, 0, 1, atr) < 1) return;
   double atrVal = atr[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic() != Trade.RequestMagic()) continue;
      if(PosInfo.Symbol() != _Symbol) continue;

      double trail = atrVal * Inp_Trail_ATR;

      if(PosInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double new_sl = bid - trail;
         if(new_sl > PosInfo.StopLoss() + trail * 0.1)
           Trade.PositionModify(PosInfo.Ticket(), new_sl, PosInfo.TakeProfit());
        }
      else if(PosInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double new_sl = ask + trail;
         if(new_sl < PosInfo.StopLoss() - trail * 0.1 || PosInfo.StopLoss() == 0)
           Trade.PositionModify(PosInfo.Ticket(), new_sl, PosInfo.TakeProfit());
        }
     }
  }

//──────────────────────────────────────────────────────────────────
// PROP FIRM RISK MANAGEMENT
//──────────────────────────────────────────────────────────────────

void CheckDailyReset()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   MqlDateTime dtLast; TimeToStruct(g_LastDayCheck, dtLast);

   if(dt.day != dtLast.day)
     {
      g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_LastDayCheck    = TimeCurrent();
      // Re-allow trading on new day (unless total drawdown limit hit)
      if(g_StopReason != "MAX_TOTAL_LOSS")
        {
         g_TradingAllowed = true;
         g_StopReason     = "";
        }
      Print("QuantCore: New trading day | Balance: ", g_DayStartBalance);
     }
  }

bool CheckPropLimits()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Update peak equity
   if(equity > g_PeakEquity) g_PeakEquity = equity;

   // ── Daily loss check ──────────────────────────────────────────
   double dailyLossPct = (g_DayStartBalance - equity) / g_DayStartBalance * 100.0;
   if(dailyLossPct >= Inp_MaxDailyLoss)
     {
      if(g_TradingAllowed)
        {
         g_TradingAllowed = false;
         g_StopReason = "MAX_DAILY_LOSS";
         CloseAllPositions("Daily loss limit hit: " + DoubleToString(dailyLossPct,2) + "%");
         Alert("QuantCore EA: Daily loss limit hit (", DoubleToString(dailyLossPct,2), "%). Trading paused.");
        }
      return false;
     }

   // ── Total drawdown check ──────────────────────────────────────
   double totalLossPct = (g_StartBalance - equity) / g_StartBalance * 100.0;
   if(totalLossPct >= Inp_MaxTotalLoss)
     {
      if(g_TradingAllowed)
        {
         g_TradingAllowed = false;
         g_StopReason = "MAX_TOTAL_LOSS";
         CloseAllPositions("Total drawdown limit hit: " + DoubleToString(totalLossPct,2) + "%");
         Alert("QuantCore EA: MAX TOTAL DRAWDOWN REACHED (", DoubleToString(totalLossPct,2), "%). EA STOPPED.");
        }
      return false;
     }

   // ── Profit lock mechanism ─────────────────────────────────────
   double gainPct = (equity - g_StartBalance) / g_StartBalance * 100.0;
   if(gainPct >= Inp_ProfitLockAt && !g_ProfitLocked)
     {
      g_ProfitLocked = true;
      Print("QuantCore: Profit lock activated at +", DoubleToString(gainPct,2), "%");
     }

   if(g_ProfitLocked)
     {
      double drawFromPeak = (g_PeakEquity - equity) / g_StartBalance * 100.0;
      if(drawFromPeak >= Inp_ProfitLockDD)
        {
         CloseAllPositions("Profit lock triggered: drawdown from peak " +
                           DoubleToString(drawFromPeak,2) + "%");
         g_TradingAllowed = false;
         g_StopReason = "PROFIT_LOCK";
         return false;
        }
     }

   return g_TradingAllowed;
  }

//──────────────────────────────────────────────────────────────────
// CONSECUTIVE LOSS GUARD  (OnTradeTransaction fires on every close)
//──────────────────────────────────────────────────────────────────

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)Trade.RequestMagic()) return;
   long entry = (long)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(profit >= 0)
     {
      g_ConsecLosses = 0;
      g_ConsecWins++;
     }
   else
     {
      g_ConsecLosses++;
      g_ConsecWins = 0;
      if(g_ConsecLosses >= Inp_MaxConsecLoss)
        {
         g_ConsecPausedUntil = TimeCurrent() + (datetime)(Inp_ConsecPauseHours * 3600.0);
         Print("QuantCore: ", g_ConsecLosses, " consecutive losses — pausing until ",
               TimeToString(g_ConsecPausedUntil, TIME_DATE|TIME_SECONDS));
        }
     }
  }

//──────────────────────────────────────────────────────────────────
// UTILITIES
//──────────────────────────────────────────────────────────────────

int CountOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     if(PosInfo.SelectByIndex(i) && PosInfo.Magic() == Trade.RequestMagic())
       count++;
   return count;
  }

bool HasPosition(ENUM_POSITION_TYPE type)
  {
   for(int i = 0; i < PositionsTotal(); i++)
     if(PosInfo.SelectByIndex(i) &&
        PosInfo.Magic() == Trade.RequestMagic() &&
        PosInfo.Symbol() == _Symbol &&
        PosInfo.PositionType() == type)
       return true;
   return false;
  }

void CloseAllPositions(string reason)
  {
   Print("QuantCore: Closing all positions — ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PosInfo.SelectByIndex(i) && PosInfo.Magic() == Trade.RequestMagic())
        Trade.PositionClose(PosInfo.Ticket());
     }
  }

//──────────────────────────────────────────────────────────────────
// DASHBOARD
//──────────────────────────────────────────────────────────────────

void _QR(string n, int x, int y, int w, int h, color bg, color brd = clrNONE)
  {
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,      w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,      h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,    bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_COLOR,      brd == clrNONE ? bg : brd);
   ObjectSetInteger(0, n, OBJPROP_WIDTH,      brd == clrNONE ? 0 : 1);
   ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, n, OBJPROP_ZORDER,     0);
  }

void _QL(string n, string txt, int x, int y, color clr, int sz = 9)
  {
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, n, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,   sz);
   ObjectSetString (0, n, OBJPROP_FONT,       "Consolas");
   ObjectSetString (0, n, OBJPROP_TEXT,       txt);
   ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, n, OBJPROP_ZORDER,     1);
  }

void DestroyDashboard()
  {
   ObjectsDeleteAll(0, "QC_");
   ChartRedraw(0);
  }

void UpdateDashboard()
  {
   int X = 20, Y = 20, W = 295, LH = 17;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPL  = equity - g_DayStartBalance;
   double dailyPct = g_DayStartBalance > 0
                     ? MathMax(0.0, (g_DayStartBalance - equity) / g_DayStartBalance * 100.0) : 0.0;
   double totalPct = g_StartBalance > 0
                     ? MathMax(0.0, (g_StartBalance - equity) / g_StartBalance * 100.0) : 0.0;
   double gainPct  = g_StartBalance > 0
                     ? (equity - g_StartBalance) / g_StartBalance * 100.0 : 0.0;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   string sessName = ActiveSessionName(dt.hour);
   bool   sessOpen = IsSessionOpen(dt.hour);
   int    openCnt  = CountOpenPositions();

   // Background panel
   _QR("QC_BG", X, Y, W, 380, QC_BG, QC_BLU);

   // ── HEADER ─────────────────────────────────────────────────────
   int ry = Y;
   _QR("QC_HDR0", X, ry, W, LH + 6, QC_HDR, clrNONE);
   _QL("QC_TITLE", "QUANTCORE AI  v1.31 | " + TimeToString(TimeCurrent(), TIME_DATE),
       X + 8, ry + 4, QC_WHT, 9);
   color  stClr = g_TradingAllowed ? QC_GRN : QC_RED;
   string stTxt = g_TradingAllowed ? "● ACTIVE" : "■ STOPPED";
   _QL("QC_STAT",  stTxt,                 X + W - 88,  ry + 4, stClr, 9);
   ry += LH + 6;

   // ── SYMBOL / SESSION ───────────────────────────────────────────
   _QR("QC_R1", X, ry, W, LH, QC_HDR, clrNONE);
   _QL("QC_SYM",  "SYM  " + _Symbol,     X + 8,       ry + 3, QC_BLU, 9);
   _QL("QC_SES",  sessName,               X + W - 128, ry + 3, ActiveSessionColor(dt.hour), 9);
   ry += LH;

   // ── KALMAN DIRECTION ───────────────────────────────────────────
   string kDir = kf_vel > 0 ? "▲ BULL" : (kf_vel < 0 ? "▼ BEAR" : "── FLAT");
   color  kClr = kf_vel > 0 ? QC_GRN  : (kf_vel < 0 ? QC_RED  : QC_DIM);
   _QR("QC_R2", X, ry, W, LH, QC_BG, clrNONE);
   _QL("QC_KDIR", "KF   " + kDir,             X + 8,       ry + 3, kClr, 9);
   _QL("QC_KVAL", DoubleToString(kf_vel, 6),   X + W - 110, ry + 3, QC_DIM, 8);
   ry += LH;

   _QR("QC_SEP1", X, ry, W, 1, QC_HDR, clrNONE); ry += 5;

   // ── AI SIGNAL SCORES ───────────────────────────────────────────
   _QR("QC_AIH0", X, ry, W, LH, QC_HDR, clrNONE);
   _QL("QC_AIHT", "AI  SIGNAL  SCORES", X + 8, ry + 3, QC_WHT, 9);
   ry += LH;

   int bw = W - 112;
   // Bull bar
   int bBarW = (int)MathRound(g_LastBullScore * bw);
   _QR("QC_BB_BG",  X + 80, ry + 4, bw,                LH - 8, QC_HDR, clrNONE);
   _QR("QC_BB_BAR", X + 80, ry + 4, MathMax(2, bBarW),  LH - 8, QC_GRN, clrNONE);
   _QL("QC_BUL",   "BULL", X + 8,  ry + 3, QC_GRN, 9);
   _QL("QC_BUL_V", g_ScoresReady ? DoubleToString(g_LastBullScore, 3) : "WAIT",
       X + 40, ry + 3, g_ScoresReady ? QC_GRN : QC_DIM, 9);
   ry += LH;

   // Bear bar
   int bearBarW = (int)MathRound(g_LastBearScore * bw);
   _QR("QC_BR_BG",  X + 80, ry + 4, bw,                 LH - 8, QC_HDR, clrNONE);
   _QR("QC_BR_BAR", X + 80, ry + 4, MathMax(2, bearBarW), LH - 8, QC_RED, clrNONE);
   _QL("QC_BER",   "BEAR", X + 8,  ry + 3, QC_RED, 9);
   _QL("QC_BER_V", g_ScoresReady ? DoubleToString(g_LastBearScore, 3) : "WAIT",
       X + 40, ry + 3, g_ScoresReady ? QC_RED : QC_DIM, 9);
   ry += LH;

   _QR("QC_THR0", X, ry, W, LH, QC_BG, clrNONE);
   _QL("QC_THR",  StringFormat("THRESHOLD   %.3f", Inp_MinScore), X + 8, ry + 3, QC_DIM, 9);
   ry += LH;

   _QR("QC_SEP2", X, ry, W, 1, QC_HDR, clrNONE); ry += 5;

   // ── ACCOUNT ────────────────────────────────────────────────────
   _QR("QC_ACH0", X, ry, W, LH, QC_HDR, clrNONE);
   _QL("QC_ACHT", "ACCOUNT", X + 8, ry + 3, QC_WHT, 9);
   ry += LH;

   _QL("QC_EQ",  StringFormat("EQUITY    %.2f", equity),  X + 8, ry + 3, QC_WHT, 9); ry += LH;
   _QL("QC_BAL", StringFormat("BALANCE   %.2f", balance), X + 8, ry + 3, QC_DIM, 9); ry += LH;

   color plClr = dailyPL >= 0 ? QC_GRN : QC_RED;
   _QL("QC_DPL",  StringFormat("DAILY P&L  %+.2f", dailyPL),  X + 8, ry + 3, plClr, 9); ry += LH;

   color gainClr = gainPct >= 0 ? QC_GRN : QC_RED;
   _QL("QC_GAIN", StringFormat("NET GAIN   %+.2f%%", gainPct), X + 8, ry + 3, gainClr, 9); ry += LH;

   _QR("QC_SEP3", X, ry, W, 1, QC_HDR, clrNONE); ry += 5;

   // ── RISK MONITOR ───────────────────────────────────────────────
   _QR("QC_RKH0", X, ry, W, LH, QC_HDR, clrNONE);
   _QL("QC_RKHT", "RISK  MONITOR", X + 8, ry + 3, QC_WHT, 9);
   ry += LH;

   color dlClr = dailyPct >= Inp_MaxDailyLoss * 0.75 ? QC_RED
               : dailyPct >= Inp_MaxDailyLoss * 0.50 ? QC_YEL : QC_GRN;
   _QL("QC_DL", StringFormat("DAILY LOSS   %.2f%% / %.1f%%", dailyPct, Inp_MaxDailyLoss),
       X + 8, ry + 3, dlClr, 9); ry += LH;

   color tlClr = totalPct >= Inp_MaxTotalLoss * 0.75 ? QC_RED
               : totalPct >= Inp_MaxTotalLoss * 0.50 ? QC_YEL : QC_GRN;
   _QL("QC_TL", StringFormat("TOTAL LOSS   %.2f%% / %.1f%%", totalPct, Inp_MaxTotalLoss),
       X + 8, ry + 3, tlClr, 9); ry += LH;

   string plkTxt = g_ProfitLocked ? "● LOCKED  " : "○ MONITORING";
   color  plkClr = g_ProfitLocked ? QC_YEL : QC_DIM;
   _QL("QC_PLK", "PROFIT LOCK  " + plkTxt, X + 8, ry + 3, plkClr, 9); ry += LH;

   // Peak drawdown row (always rendered; blank when lock inactive)
   if(g_ProfitLocked && g_StartBalance > 0)
     {
      double drawPk = MathMax(0.0, (g_PeakEquity - equity) / g_StartBalance * 100.0);
      _QL("QC_PKD", StringFormat("  FROM PEAK  %.2f%% / %.1f%%", drawPk, Inp_ProfitLockDD),
          X + 8, ry + 3, QC_YEL, 9);
     }
   else
      _QL("QC_PKD", "", X + 8, ry + 3, QC_DIM, 9);
   ry += LH;

   // Consecutive loss / pause row
   bool paused = (TimeCurrent() < g_ConsecPausedUntil);
   if(paused)
     {
      int secsLeft = (int)(g_ConsecPausedUntil - TimeCurrent());
      int mLeft    = secsLeft / 60;
      _QR("QC_CSLK", X, ry, W, LH, C'60,30,10', clrNONE);
      _QL("QC_CSL",  StringFormat("CONSEC PAUSE  %dm left", mLeft), X + 8, ry + 3, QC_YEL, 9);
     }
   else
     {
      _QR("QC_CSLK", X, ry, W, LH, QC_BG, clrNONE);
      _QL("QC_CSL",  StringFormat("CONSEC  L:%d  W:%d", g_ConsecLosses, g_ConsecWins),
          X + 8, ry + 3, g_ConsecLosses > 0 ? QC_YEL : QC_DIM, 9);
     }
   ry += LH;

   // Stop reason row (always rendered; blank when no stop)
   if(StringLen(g_StopReason) > 0)
     {
      _QR("QC_STRK", X, ry, W, LH, C'60,20,20', clrNONE);
      _QL("QC_STR",  "STOP: " + g_StopReason, X + 8, ry + 3, QC_RED, 9);
     }
   else
     {
      _QR("QC_STRK", X, ry, W, LH, QC_BG, clrNONE);
      _QL("QC_STR",  "", X + 8, ry + 3, QC_DIM, 9);
     }
   ry += LH;

   _QR("QC_SEP4", X, ry, W, 1, QC_HDR, clrNONE); ry += 5;

   // ── POSITIONS ──────────────────────────────────────────────────
   _QR("QC_PSH0", X, ry, W, LH, QC_HDR, clrNONE);
   color posClr = openCnt > 0 ? QC_BLU : QC_DIM;
   _QL("QC_POS", StringFormat("POSITIONS  %d / %d", openCnt, Inp_MaxPositions),
       X + 8, ry + 3, posClr, 9);
   string trTxt = Inp_TrailingStop ? "TRAIL ●" : "TRAIL ○";
   color  trClr = Inp_TrailingStop ? QC_GRN : QC_DIM;
   _QL("QC_TRL", trTxt, X + W - 78, ry + 3, trClr, 9);
   ry += LH;

   // Timestamp
   _QL("QC_TS", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), X + 8, ry + 3, QC_DIM, 8);

   ChartRedraw(0);
  }

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
#property version     "1.00"
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
input double Inp_RiskPerTrade   = 0.75;   // Risk per trade %
input double Inp_ProfitLockAt   = 6.0;    // Activate profit-lock at equity gain %
input double Inp_ProfitLockDD   = 1.0;    // Max drawdown after profit-lock (%)

input group "════ AI SIGNAL ENGINE ════"
input double Inp_MinScore       = 0.62;   // Min combined score to enter  [0.0–1.0]
input double Inp_MinScoreMTF    = 0.55;   // Min H4 confirmation score
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
input double Inp_Trail_ATR      = 1.0;   // Trailing stop distance × ATR
input int    Inp_MaxPositions   = 3;     // Max simultaneous positions

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
double kf_theta   = 0;   // estimated trend (slope)
double kf_P       = 1;   // error covariance
double kf_Vw      = 0;   // process noise (computed from delta)
double kf_Ve      = 0;   // measurement noise
bool   kf_Init    = false;

// Indicator handles
int h_EMA_Fast, h_EMA_Mid, h_EMA_Slow;
int h_RSI, h_Stoch, h_ADX, h_ATR;
int h_EMA_Fast_H4, h_EMA_Slow_H4, h_RSI_H4;

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
   Trade.SetExpertMagicNumber(20240101);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("QuantCore AI EA initialized | Balance: ", g_StartBalance,
         " | MaxDailyLoss: ", Inp_MaxDailyLoss, "% | MaxTotalLoss: ", Inp_MaxTotalLoss, "%");
   return INIT_SUCCEEDED;
  }

ENUM_TIMEFRAMES Inp_ConfirmTF() { return PERIOD_H4; }

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
   if(hour >= 0  && hour < 9)  s += "Asia ";
   if(hour >= 7  && hour < 16) s += "London ";
   if(hour >= 12 && hour < 16) s += "[OVERLAP] ";
   if(hour >= 13 && hour < 21) s += "NewYork ";
   if(StringLen(s) == 0)       s =  "Closed";
   return StringTrimRight(s);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(h_EMA_Fast);  IndicatorRelease(h_EMA_Mid);
   IndicatorRelease(h_EMA_Slow);  IndicatorRelease(h_RSI);
   IndicatorRelease(h_Stoch);     IndicatorRelease(h_ADX);
   IndicatorRelease(h_ATR);       IndicatorRelease(h_EMA_Fast_H4);
   IndicatorRelease(h_EMA_Slow_H4); IndicatorRelease(h_RSI_H4);
   Print("QuantCore AI EA stopped. Reason: ", reason);
  }

//──────────────────────────────────────────────────────────────────
// MAIN TICK
//──────────────────────────────────────────────────────────────────

void OnTick()
  {
   // Only process on new H1 bar (reduces noise, saves CPU)
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (curBar != lastBar);
   if(newBar) lastBar = curBar;

   // Always run: trailing stop + prop limit checks
   UpdateKalmanOnTick();
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

   if(!newBar) return;   // wait for new bar for entries

   // ── SESSION FILTER ────────────────────────────────────────────
   if(!IsSessionOpen(dt.hour)) return;

   // ── DYNAMIC SCORE THRESHOLD ───────────────────────────────────
   // During London-NY overlap (12:00-16:00) volume is 3× higher —
   // lower the entry threshold slightly to catch strong breakouts.
   double dynMinScore = Inp_MinScore;
   if(Inp_BoostOverlap && IsOverlapHour(dt.hour))
      dynMinScore = MathMax(0.50, Inp_MinScore - Inp_OverlapBoost);

   // Compute AI signal
   double bullScore = 0, bearScore = 0;
   if(!CalcSignalScores(bullScore, bearScore)) return;

   int openCount = CountOpenPositions();

   // ── EXIT logic (check existing positions) ─────────────────────
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic() != Trade.RequestMagic()) continue;
      if(PosInfo.Symbol() != _Symbol) continue;

      if(PosInfo.PositionType() == POSITION_TYPE_BUY && bearScore > Inp_MinScore)
        {
         Trade.PositionClose(PosInfo.Ticket());
         Print("QuantCore: Closing BUY — bear signal reversed (", DoubleToString(bearScore,3), ")");
        }
      else if(PosInfo.PositionType() == POSITION_TYPE_SELL && bullScore > Inp_MinScore)
        {
         Trade.PositionClose(PosInfo.Ticket());
         Print("QuantCore: Closing SELL — bull signal reversed (", DoubleToString(bullScore,3), ")");
        }
     }

   // ── ENTRY logic ───────────────────────────────────────────────
   if(openCount >= Inp_MaxPositions) return;
   if(!g_TradingAllowed) return;

   double atr[];
   if(CopyBuffer(h_ATR, 0, 1, 1, atr) < 1) return;
   double atrVal = atr[0];
   if(atrVal <= 0) return;

   double sl_dist = atrVal * Inp_SL_ATR_Mult;
   double tp_dist = atrVal * Inp_TP_ATR_Mult;

   string sessName = ActiveSessionName(dt.hour);

   if(bullScore >= dynMinScore && !HasPosition(POSITION_TYPE_BUY))
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
   // RSI
   if(rsi[0] > 50 && rsi[0] < 70) momBull += 0.4;
   else if(rsi[0] > 30 && rsi[0] <= 50) momBear += 0.2;
   else if(rsi[0] <= 30) momBull += 0.3;   // oversold — potential reversal
   else if(rsi[0] >= 70) momBear += 0.3;   // overbought — potential reversal
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
   double kalmanBull = 0, kalmanBear = 0;
   if(kf_theta > 0)
     {
      double conf = MathMin(MathAbs(kf_theta) / (0.001 + 1e-9), 1.0);
      kalmanBull = 0.5 + conf * 0.5;
      kalmanBear = 1.0 - kalmanBull;
     }
   else
     {
      double conf = MathMin(MathAbs(kf_theta) / (0.001 + 1e-9), 1.0);
      kalmanBear = 0.5 + conf * 0.5;
      kalmanBull = 1.0 - kalmanBear;
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
      kf_theta = price;
      kf_P     = 1.0;
      kf_Init  = true;
      return;
     }

   // Predict
   double P_pred = kf_P + kf_Vw;

   // Innovation
   double innov = price - kf_theta;

   // Kalman gain
   double K = P_pred / (P_pred + kf_Ve);

   // Update
   double theta_new = kf_theta + K * innov;
   kf_P   = (1.0 - K) * P_pred;

   // Store velocity (slope) as the signal
   kf_theta = theta_new - kf_theta;   // delta = trend direction
  }

//──────────────────────────────────────────────────────────────────
// POSITION SIZING  (fixed fractional, ATR-based stop)
//──────────────────────────────────────────────────────────────────

double CalcLotSize(double sl_distance_price)
  {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = balance * Inp_RiskPerTrade / 100.0;

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

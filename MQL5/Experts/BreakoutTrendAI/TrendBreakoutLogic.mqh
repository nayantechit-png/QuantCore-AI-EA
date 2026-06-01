#pragma once
#include "Indicators.mqh"
#include "Config.mqh"

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

bool IsUptrend()
{
   double ema200 = GetEMA(200);
   double ema50  = GetEMA(50);
   double rsi    = GetRSI(14);
   return (Close[0] > ema200 && ema50 > ema200 && rsi > 50);
}

bool IsDowntrend()
{
   double ema200 = GetEMA(200);
   double ema50  = GetEMA(50);
   double rsi    = GetRSI(14);
   return (Close[0] < ema200 && ema50 < ema200 && rsi < 50);
}

bool GetBreakoutTrendSignal(Signal &sig)
{
   double high,low;
   if(!GetRange(high,low)) return false;

   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double atr = GetATR(14);
   double slDist = atr * InpSL_ATR_Multiplier;

   if(IsUptrend() && Close[1] > high)
   {
      sig.direction  = 1;
      sig.entryPrice = ask;
      sig.slPrice    = sig.entryPrice - slDist;
      sig.tp1Price   = sig.entryPrice + slDist * InpTP1_R_Multiple;
      sig.tp2Price   = sig.entryPrice + slDist * InpTP2_R_Multiple;
      sig.rangeHigh  = high;
      sig.rangeLow   = low;
      return true;
   }

   if(IsDowntrend() && Close[1] < low)
   {
      sig.direction  = -1;
      sig.entryPrice = bid;
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

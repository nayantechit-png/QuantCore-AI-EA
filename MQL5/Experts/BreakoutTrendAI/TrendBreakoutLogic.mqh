#pragma once
#include "Indicators.mqh"
#include "Config.mqh"

struct Signal
{
    int    direction;   // +1 buy  -1 sell
    double entryPrice;
    double slPrice;
    double tp1Price;
    double tp2Price;
    double rangeHigh;
    double rangeLow;
};

bool IsUptrend()
{
    double close  = iClose(_Symbol, PERIOD_CURRENT, 0);
    double ema50  = GetEMA(50);
    double ema200 = GetEMA(200);
    double rsi    = GetRSI(14);
    return (close > ema200 && ema50 > ema200 && rsi > 50.0);
}

bool IsDowntrend()
{
    double close  = iClose(_Symbol, PERIOD_CURRENT, 0);
    double ema50  = GetEMA(50);
    double ema200 = GetEMA(200);
    double rsi    = GetRSI(14);
    return (close < ema200 && ema50 < ema200 && rsi < 50.0);
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

#pragma once

void InitIndicators() {}

double GetATR(int period = 14)
{
    return iATR(_Symbol, PERIOD_CURRENT, period, 0);
}

double GetEMA(int period)
{
    return iMA(_Symbol, PERIOD_CURRENT, period, 0, MODE_EMA, PRICE_CLOSE, 0);
}

double GetRSI(int period = 14)
{
    return iRSI(_Symbol, PERIOD_CURRENT, period, PRICE_CLOSE, 0);
}

double GetSpreadPoints()
{
    return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
            SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
}

bool GetRange(double &high, double &low, int lookback = 20)
{
    int hi = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, lookback, 1);
    int lo = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  lookback, 1);
    high = iHigh(_Symbol, PERIOD_CURRENT, hi);
    low  = iLow (_Symbol, PERIOD_CURRENT, lo);
    double pts = (high - low) / _Point;
    return (pts >= 15.0 && pts <= 80.0);
}

bool IsNewBar()
{
    static datetime s_last = 0;
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t == s_last) return false;
    s_last = t;
    return true;
}

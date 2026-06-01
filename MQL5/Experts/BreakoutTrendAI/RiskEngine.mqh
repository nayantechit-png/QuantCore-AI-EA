#pragma once
#include "Config.mqh"

double g_dailyStartEquity  = 0.0;
double g_weeklyStartEquity = 0.0;
int    tradesToday         = 0;

void InitRiskEngine()
{
    g_dailyStartEquity  = AccountEquity();
    g_weeklyStartEquity = AccountEquity();
    tradesToday         = 0;
}

bool IsDailyOrWeeklyLimitHit()
{
    double eq = AccountEquity();
    if(g_dailyStartEquity  > 0 && (eq - g_dailyStartEquity)  / g_dailyStartEquity  * 100.0 <= -InpMaxDailyLossPercent)  return true;
    if(g_weeklyStartEquity > 0 && (eq - g_weeklyStartEquity) / g_weeklyStartEquity * 100.0 <= -InpMaxWeeklyLossPercent) return true;
    if(tradesToday >= InpMaxTradesPerDay) return true;
    return false;
}

double PipValue()
{
    double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    return (ts > 0) ? tv * (_Point / ts) : tv;
}

double CalculateLotSize(double riskPct, double slPips)
{
    if(slPips < 0.001) return 0.01;
    double pv = PipValue();
    if(pv < 1e-10) return 0.01;
    double lot = (AccountEquity() * riskPct / 100.0) / (slPips * pv);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    return MathMax(minLot, MathMin(maxLot, lot));
}

bool CanOpenNewTrade()
{
    return true;
}

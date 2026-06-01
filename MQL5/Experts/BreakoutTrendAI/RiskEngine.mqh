#pragma once
#include "Config.mqh"

double dailyStartEquity;
double weeklyStartEquity;
int    tradesToday = 0;

void InitRiskEngine()
{
   dailyStartEquity  = AccountEquity();
   weeklyStartEquity = AccountEquity();
   tradesToday       = 0;
}

bool IsDailyOrWeeklyLimitHit()
{
   double dailyLoss  = (AccountEquity()-dailyStartEquity)/dailyStartEquity*100.0;
   double weeklyLoss = (AccountEquity()-weeklyStartEquity)/weeklyStartEquity*100.0;
   if(dailyLoss<=-InpMaxDailyLossPercent)  return true;
   if(weeklyLoss<=-InpMaxWeeklyLossPercent)return true;
   if(tradesToday>=InpMaxTradesPerDay)     return true;
   return false;
}

double PipValue()
{
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   return tickValue * (_Point/tickSize);
}

double CalculateLotSize(double riskPercent,double slPips)
{
   double riskMoney = AccountEquity()*riskPercent/100.0;
   double lot = riskMoney/(slPips*PipValue());
   return NormalizeDouble(lot,2);
}

bool CanOpenNewTrade(double riskPercent)
{
   return true;
}

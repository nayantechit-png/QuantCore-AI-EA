#pragma once

double GetEMA(int period)
{
   return iMA(_Symbol,PERIOD_CURRENT,period,0,MODE_EMA,PRICE_CLOSE,0);
}

double GetATR(int period)
{
   return iATR(_Symbol,PERIOD_CURRENT,period,0);
}

double GetRSI(int period)
{
   return iRSI(_Symbol,PERIOD_CURRENT,period,PRICE_CLOSE,0);
}

double GetSpreadPoints()
{
   return (SymbolInfoDouble(_Symbol,SYMBOL_ASK) -
           SymbolInfoDouble(_Symbol,SYMBOL_BID)) / _Point;
}

// stub – refine range logic as needed
bool GetRange(double &high,double &low)
{
   int lookback = 20;
   high = iHigh(_Symbol,PERIOD_CURRENT,iHighest(_Symbol,PERIOD_CURRENT,MODE_HIGH,lookback,1));
   low  = iLow (_Symbol,PERIOD_CURRENT,iLowest (_Symbol,PERIOD_CURRENT,MODE_LOW ,lookback,1));
   return ( (high-low)/_Point > 15 && (high-low)/_Point < 35 );
}

void InitIndicators() {}

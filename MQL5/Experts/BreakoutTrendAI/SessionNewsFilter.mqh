#pragma once
#include "Config.mqh"

bool IsInTradingSession()
{
   datetime now = TimeCurrent();
   int hour = TimeHour(now);
   if( (hour>=InpLondonStartHour && hour<InpLondonEndHour) ||
       (hour>=InpNYStartHour     && hour<InpNYEndHour) )
      return true;
   return false;
}

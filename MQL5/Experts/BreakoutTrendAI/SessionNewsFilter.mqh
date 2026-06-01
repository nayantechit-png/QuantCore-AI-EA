#pragma once
#include "Config.mqh"

bool IsInTradingSession()
{
    int hour = TimeHour(TimeCurrent());
    return ((hour >= InpLondonStartHour && hour < InpLondonEndHour) ||
            (hour >= InpNYStartHour     && hour < InpNYEndHour));
}

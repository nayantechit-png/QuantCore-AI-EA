#pragma once
#include "TrendBreakoutLogic.mqh"

int logHandle = INVALID_HANDLE;

void InitLogger()
{
   logHandle = FileOpen("EA_log.csv",FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(logHandle!=INVALID_HANDLE)
      FileWrite(logHandle,"time","symbol","direction","entry","sl","tp1","tp2","lots","score");
}

void LogOpenedTrade(const Signal &sig,double lots,double score)
{
   if(logHandle==INVALID_HANDLE) return;
   FileWrite(logHandle,
             TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
             _Symbol,
             sig.direction,
             sig.entryPrice,
             sig.slPrice,
             sig.tp1Price,
             sig.tp2Price,
             lots,
             score);
}

void LogSkippedSignal(const Signal &sig,double score)
{
   // extend if you want skipped-signal logging
}

void CloseLogger()
{
   if(logHandle!=INVALID_HANDLE)
      FileClose(logHandle);
}

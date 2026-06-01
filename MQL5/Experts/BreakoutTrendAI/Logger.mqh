#pragma once
#include "TrendBreakoutLogic.mqh"

int g_logHandle = INVALID_HANDLE;

void InitLogger()
{
    g_logHandle = FileOpen("btai_log.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
    if(g_logHandle != INVALID_HANDLE)
        FileWrite(g_logHandle,
                  "time","type","symbol","posId",
                  "direction","entry","sl","tp1","lots","score",
                  "profit","trainStep");
}

void LogOpenedTrade(const Signal &sig, double lots, double score, ulong posId)
{
    if(g_logHandle == INVALID_HANDLE) return;
    FileWrite(g_logHandle,
              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
              "OPEN", _Symbol, (string)posId,
              sig.direction, sig.entryPrice, sig.slPrice, sig.tp1Price,
              lots, score, "", "");
}

void LogTradeOutcome(ulong posId, double profit, int trainStep)
{
    if(g_logHandle == INVALID_HANDLE) return;
    FileWrite(g_logHandle,
              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
              "CLOSE", _Symbol, (string)posId,
              "", "", "", "", "", "",
              profit, trainStep);
}

void LogSkippedSignal(const Signal &sig, double score)
{
    if(g_logHandle == INVALID_HANDLE) return;
    FileWrite(g_logHandle,
              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
              "SKIP", _Symbol, "",
              sig.direction, sig.entryPrice, sig.slPrice, sig.tp1Price,
              "", score, "", "");
}

void CloseLogger()
{
    if(g_logHandle != INVALID_HANDLE)
        FileClose(g_logHandle);
}

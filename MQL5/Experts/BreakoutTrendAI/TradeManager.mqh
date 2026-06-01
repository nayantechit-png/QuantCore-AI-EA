#pragma once
#include "Config.mqh"
#include "RiskEngine.mqh"
#include "AI_Filter.mqh"
#include "Logger.mqh"

#define MAX_TRADE_MEM 20

struct TradeRecord
{
    ulong  posId;
    double features[NN_IN];
    bool   used;
};

TradeRecord g_mem[MAX_TRADE_MEM];

// Features from the most-recent OpenTrade call, waiting for posId assignment
double g_pendingFeatures[NN_IN];
bool   g_hasPending = false;

void InitTradeMemory()
{
    for(int i = 0; i < MAX_TRADE_MEM; i++) g_mem[i].used = false;
    g_hasPending = false;
}

void StorePendingFeatures(double &f[])
{
    for(int i = 0; i < NN_IN; i++) g_pendingFeatures[i] = f[i];
    g_hasPending = true;
}

// Called from OnTradeTransaction when DEAL_ENTRY_IN fires
void AssignPendingToPosition(ulong posId)
{
    if(!g_hasPending) return;
    for(int i = 0; i < MAX_TRADE_MEM; i++)
    {
        if(!g_mem[i].used)
        {
            g_mem[i].posId = posId;
            for(int j = 0; j < NN_IN; j++) g_mem[i].features[j] = g_pendingFeatures[j];
            g_mem[i].used  = true;
            g_hasPending   = false;
            return;
        }
    }
    g_hasPending = false;   // no slot – discard gracefully
}

// Called from OnTradeTransaction when DEAL_ENTRY_OUT fires
void OnTradeClosed(ulong posId, double profit)
{
    for(int i = 0; i < MAX_TRADE_MEM; i++)
    {
        if(g_mem[i].used && g_mem[i].posId == posId)
        {
            double feat[NN_IN];
            for(int j = 0; j < NN_IN; j++) feat[j] = g_mem[i].features[j];
            g_mem[i].used = false;

            LearnFromTrade(feat, profit);
            LogTradeOutcome(posId, profit, g_trainSteps);
            return;
        }
    }
}

bool HasOpenTradeOnSymbol()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol &&
           (int)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            return true;
    }
    return false;
}

void OpenTrade(Signal &sig, double lots, double score, double &features[])
{
    MqlTradeRequest req;
    MqlTradeResult  res;
    ZeroMemory(req); ZeroMemory(res);

    req.symbol       = _Symbol;
    req.magic        = InpMagicNumber;
    req.volume       = lots;
    req.type_filling = ORDER_FILLING_FOK;
    req.sl           = sig.slPrice;
    req.tp           = sig.tp1Price;
    req.comment      = StringFormat("BTAI s=%.2f", score);

    if(sig.direction == 1)
    {
        req.type  = ORDER_TYPE_BUY;
        req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    }
    else
    {
        req.type  = ORDER_TYPE_SELL;
        req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    }

    if(OrderSend(req, res))
    {
        tradesToday++;
        StorePendingFeatures(features);   // posId assigned when entry deal fires
        LogOpenedTrade(sig, lots, score, res.order);
    }
    else
        Print("OrderSend failed: retcode=", res.retcode, " ", res.comment);
}

void ManageOpenTrades()
{
    // Move SL to breakeven once price reaches TP1
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol) continue;
        if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
        double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl     = PositionGetDouble(POSITION_SL);
        double tp     = PositionGetDouble(POSITION_TP);
        double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        bool   isBuy  = ((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

        bool hitTP = isBuy ? (bid >= tp) : (ask <= tp);
        bool notBE = isBuy ? (sl < entry) : (sl > entry);

        if(hitTP && notBE)
        {
            MqlTradeRequest req; MqlTradeResult res;
            ZeroMemory(req); ZeroMemory(res);
            req.action   = TRADE_ACTION_SLTP;
            req.position = ticket;
            req.symbol   = _Symbol;
            req.sl       = entry;
            req.tp       = tp;
            OrderSend(req, res);
        }
    }
}

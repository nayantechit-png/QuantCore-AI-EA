#property strict
#property description "BreakoutTrendAI – fully self-learning EA (no external dependencies)"
#property version "2.0"

#include "Config.mqh"
#include "Indicators.mqh"
#include "TrendBreakoutLogic.mqh"
#include "AI_Filter.mqh"
#include "RiskEngine.mqh"
#include "Logger.mqh"
#include "TradeManager.mqh"
#include "SessionNewsFilter.mqh"

int OnInit()
{
    LoadConfig();
    InitIndicators();
    InitRiskEngine();
    InitLogger();
    InitTradeMemory();
    InitAIModel(InpAI_ModelFile);   // loads saved weights or random-inits
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    SaveAIModel(InpAI_ModelFile);   // persist latest weights
    CloseLogger();
}

void OnTick()
{
    if(!IsNewBar())              return;
    if(!IsInTradingSession())    return;
    if(IsDailyOrWeeklyLimitHit()) return;
    if(HasOpenTradeOnSymbol())   return;

    ManageOpenTrades();

    Signal sig;
    if(!GetBreakoutTrendSignal(sig)) return;

    double features[NN_IN];
    BuildFeatures(sig, features);
    UpdateScaler(features);   // keep running stats current

    double score = GetSignalScore(features);
    if(score < InpAI_Threshold)
    {
        LogSkippedSignal(sig, score);
        return;
    }

    double slPips = CalcSLPips(sig);
    if(slPips < 1.0) return;

    double lots = CalculateLotSize(InpRiskPercentPerTrade, slPips);
    if(!CanOpenNewTrade()) return;

    OpenTrade(sig, lots, score, features);
}

// Fires on every MT5 trade event – used to capture deal outcomes and learn
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    if(!HistoryDealSelect(trans.deal))           return;
    if((int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;

    long  entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
    ulong posId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

    if(entry == DEAL_ENTRY_IN)
    {
        // Pair the pending feature vector with this position's ID
        AssignPendingToPosition(posId);
    }
    else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
    {
        double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                      + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                      + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
        OnTradeClosed(posId, profit);   // run backprop, update weights
    }
}

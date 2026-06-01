#property strict
#include "Config.mqh"
#include "Indicators.mqh"
#include "TrendBreakoutLogic.mqh"
#include "AI_Filter.mqh"
#include "RiskEngine.mqh"
#include "TradeManager.mqh"
#include "SessionNewsFilter.mqh"
#include "Logger.mqh"

datetime lastModelLoad = 0;

int OnInit()
{
   LoadConfig();
   InitIndicators();
   InitRiskEngine();
   InitLogger();
   LoadAIModel(InpAI_ModelFile);
   lastModelLoad = TimeCurrent();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   CloseLogger();
}

void OnTick()
{
   if(!IsInTradingSession()) return;
   if(IsDailyOrWeeklyLimitHit()) return;

   CheckModelReload(lastModelLoad);

   ManageOpenTrades();

   if(HasOpenTradeOnSymbol()) return;

   Signal sig;
   if(!GetBreakoutTrendSignal(sig)) return;

   double features[32];
   BuildFeatures(sig,features);

   double score = GetSignalScore(features);
   if(score < InpAI_Threshold)
   {
      LogSkippedSignal(sig,score);
      return;
   }

   double slPips = CalcSLPips(sig);
   double lots   = CalculateLotSize(InpRiskPercentPerTrade,slPips);
   if(!CanOpenNewTrade(InpRiskPercentPerTrade)) return;

   OpenTrade(sig,lots,score);
}

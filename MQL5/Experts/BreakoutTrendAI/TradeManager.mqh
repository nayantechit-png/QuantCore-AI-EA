#pragma once
#include "Config.mqh"
#include "Logger.mqh"
#include "RiskEngine.mqh"
#include "Indicators.mqh"
#include "TrendBreakoutLogic.mqh"

bool HasOpenTradeOnSymbol()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (int)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return true;
   }
   return false;
}

void OpenTrade(Signal &sig,double lots,double score)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req); ZeroMemory(res);

   req.symbol   = _Symbol;
   req.magic    = InpMagicNumber;
   req.volume   = lots;
   req.type_filling = ORDER_FILLING_FOK;

   if(sig.direction==1)
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   }
   else
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   }

   req.sl = sig.slPrice;
   req.tp = sig.tp1Price;

   if(OrderSend(req,res))
   {
      tradesToday++;
      LogOpenedTrade(sig,lots,score);
   }
}

void ManageOpenTrades()
{
   // skeleton: move SL to BE at TP1, trail TP2 with EMA20
}

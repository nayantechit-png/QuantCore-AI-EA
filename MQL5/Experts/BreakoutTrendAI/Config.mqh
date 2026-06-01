#pragma once

input double InpRiskPercentPerTrade = 0.35;
input double InpMaxDailyLossPercent = 3.0;
input double InpMaxWeeklyLossPercent = 4.0;
input int    InpMaxTradesPerDay     = 6;

input double InpSL_ATR_Multiplier   = 1.5;
input double InpTP1_R_Multiple      = 1.0;
input double InpTP2_R_Multiple      = 2.5;

input int InpLondonStartHour        = 8;
input int InpLondonEndHour          = 11;
input int InpNYStartHour            = 14;
input int InpNYEndHour              = 17;

input double InpAI_Threshold        = 0.65;
input string InpAI_ModelFile        = "ai_model_weights.dat";

input int  InpMagicNumber           = 123456;
input bool InpUseNewsFilter         = false;

void LoadConfig() {}

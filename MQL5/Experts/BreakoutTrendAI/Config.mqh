#pragma once

// ── Risk ─────────────────────────────────────────────────────
input double InpRiskPercentPerTrade  = 0.35;
input double InpMaxDailyLossPercent  = 3.0;
input double InpMaxWeeklyLossPercent = 4.0;
input int    InpMaxTradesPerDay      = 6;

// ── Trade geometry ───────────────────────────────────────────
input double InpSL_ATR_Multiplier    = 1.5;
input double InpTP1_R_Multiple       = 1.0;
input double InpTP2_R_Multiple       = 2.5;

// ── Session ──────────────────────────────────────────────────
input int    InpLondonStartHour      = 8;
input int    InpLondonEndHour        = 11;
input int    InpNYStartHour          = 14;
input int    InpNYEndHour            = 17;

// ── AI ───────────────────────────────────────────────────────
input double InpAI_Threshold         = 0.55;   // min score to open trade
input string InpAI_ModelFile         = "btai_model.dat";

// ── Online learning ──────────────────────────────────────────
input double InpLearningRate         = 0.001;
input double InpMomentum             = 0.90;
input int    InpSaveEveryNTrades     = 5;      // auto-save frequency

// ── EA identity ──────────────────────────────────────────────
input int    InpMagicNumber          = 787878;

void LoadConfig() {}

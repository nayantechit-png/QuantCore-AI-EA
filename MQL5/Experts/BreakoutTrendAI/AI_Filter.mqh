#pragma once
#include "Config.mqh"
#include "TrendBreakoutLogic.mqh"
#include "Indicators.mqh"

struct Layer
{
   int rows;
   int cols;
   double W[64][64];
   double b[64];
};

double scaler_mean[64];
double scaler_std[64];
Layer L1,L2,L3;

bool LoadLayer(int h,Layer &L)
{
   string tag = FileReadString(h);
   if(tag!="LAYER") return false;
   L.rows = (int)FileReadNumber(h);
   L.cols = (int)FileReadNumber(h);
   for(int r=0;r<L.rows;r++)
      for(int c=0;c<L.cols;c++)
         L.W[r][c] = FileReadNumber(h);
   string btag = FileReadString(h);
   if(btag!="BIAS") return false;
   for(int r=0;r<L.rows;r++)
      L.b[r] = FileReadNumber(h);
   return true;
}

bool LoadAIModel(string filename)
{
   int h = FileOpen(filename,FILE_READ|FILE_TXT);
   if(h==INVALID_HANDLE) return false;

   int featureCount = (int)FileReadNumber(h);
   for(int i=0;i<featureCount;i++)
      scaler_mean[i] = FileReadNumber(h);
   for(int i=0;i<featureCount;i++)
      scaler_std[i]  = FileReadNumber(h);

   if(!LoadLayer(h,L1)) { FileClose(h); return false; }
   if(!LoadLayer(h,L2)) { FileClose(h); return false; }
   if(!LoadLayer(h,L3)) { FileClose(h); return false; }

   FileClose(h);
   return true;
}

void NormalizeFeatures(double &x[],int n)
{
   for(int i=0;i<n;i++)
      x[i] = (x[i]-scaler_mean[i]) / scaler_std[i];
}

void DenseForward(Layer &L,double &input[],double &output[])
{
   for(int r=0;r<L.rows;r++)
   {
      double sum = L.b[r];
      for(int c=0;c<L.cols;c++)
         sum += L.W[r][c]*input[c];
      output[r] = sum;
   }
}

void ReLU(double &x[],int n)
{
   for(int i=0;i<n;i++)
      if(x[i]<0) x[i]=0;
}

double Sigmoid(double x)
{
   return 1.0/(1.0+MathExp(-x));
}

void BuildFeatures(const Signal &sig,double &f[])
{
   f[0] = GetATR(14);
   f[1] = GetSpreadPoints();
   f[2] = (sig.rangeHigh-sig.rangeLow)/_Point;
   // fill f[3..31] with your designed features
   for(int i=3;i<32;i++) f[i]=0.0;
}

double GetSignalScore(double &features[])
{
   int n = 32;
   NormalizeFeatures(features,n);

   double h1[32];
   DenseForward(L1,features,h1);
   ReLU(h1,32);

   double h2[16];
   DenseForward(L2,h1,h2);
   ReLU(h2,16);

   double out[1];
   DenseForward(L3,h2,out);

   return Sigmoid(out[0]);
}

void CheckModelReload(datetime &lastLoad)
{
   int h = FileOpen(InpAI_ModelFile,FILE_READ|FILE_TXT);
   if(h==INVALID_HANDLE) return;
   datetime modified = (datetime)FileGetInteger(h,FILE_MODIFY_DATE);
   FileClose(h);
   if(modified>lastLoad)
   {
      LoadAIModel(InpAI_ModelFile);
      lastLoad = modified;
   }
}

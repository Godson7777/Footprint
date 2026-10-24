//+------------------------------------------------------------------+
//|                                             LiquidityHeatmap.mq5 |
//|  Order book liquidity heatmap for MT5, bridged from the public   |
//|  Hyperliquid order book (xyz:GOLD for XAUUSD, xyz:XYZ100 for     |
//|  NAS100). Display only: this EA NEVER opens, modifies or closes  |
//|  trades.                                                         |
//|                                                                  |
//|  Setup: Tools > Options > Expert Advisors > Allow WebRequest,    |
//|  add  https://api.hyperliquid.xyz                                |
//+------------------------------------------------------------------+
#property copyright "Footprint"
#property version   "1.00"
#property description "Liquidity heatmap from the Hyperliquid order book, drawn on your MT5 chart."
#property description "Display only - places no trades. Allow WebRequest for https://api.hyperliquid.xyz"

#include <Canvas\Canvas.mqh>

#define HM_LEVELS 20     // levels per side returned by Hyperliquid l2Book

//--- inputs
input group "Source"
input string InpCoin          = "";      // Hyperliquid coin ("" = auto: XAUUSD->xyz:GOLD, NAS100->xyz:XYZ100)
input int    InpSigFigs       = 4;       // Price grouping (4 = $1 on gold, $10 on Nasdaq; 3 = 10x wider)
input int    InpIntervalSec   = 2;       // Snapshot interval (seconds)
input int    InpMaxSnapshots  = 6000;    // Snapshots kept (6000 x 2s = 3.3 hours)
input bool   InpSaveHistory   = true;    // Save heatmap history between restarts

input group "Price offset (Hyperliquid -> broker)"
input bool   InpAutoOffset    = true;    // Auto offset from mid prices
input double InpManualOffset  = 0;       // Manual offset (used when auto is off)

input group "Display"
input double InpContrast      = 0.6;     // Contrast (lower = brighter walls)
input bool   InpShowLadder    = true;    // Show current book ladder on the right
input int    InpLadderWidth   = 130;     // Ladder width (pixels)
input double InpWallFactor    = 3.0;     // Wall = size >= factor x median level
input bool   InpShowWalls     = true;    // Mark current walls with lines and size
input string InpFont          = "Consolas"; // Number font
input string InpLabelFont     = "Segoe UI"; // Label font
input int    InpFontSize      = 9;       // Font size

//--- one order book snapshot (fixed size so it can be saved with FileWriteStruct)
struct Snap
  {
   datetime t;          // broker time when taken
   double   off;        // offset applied to Hyperliquid prices
   double   bucket;     // price grouping
   double   bpx[HM_LEVELS];
   double   bsz[HM_LEVELS];
   double   apx[HM_LEVELS];
   double   asz[HM_LEVELS];
   int      nb, na;
  };

//--- globals
CCanvas g_cv;
string  g_name   = "LiquidityHeatmap_Canvas";
string  g_coin   = "";
Snap    g_snaps[];
int     g_n      = 0;
double  g_off    = 0;
string  g_status = "Starting...";
bool    g_ok     = false;
bool    g_dirty  = true;
uint    g_lastFetch = 0;

//--- palette (matches FootprintPro Institutional Dark)
color C_PANEL  = C'17,21,27';
color C_BORDER = C'45,52,61';
color C_TEXT   = C'232,236,241';
color C_DIM    = C'125,133,144';
color C_BID    = C'0,179,149';
color C_ASK    = C'234,72,92';
color C_WALL   = C'255,196,54';
color C_OK     = C'0,200,140';
color C_ERR    = C'240,170,40';

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string AutoCoin()
  {
   if(InpCoin != "") return InpCoin;
   string s = _Symbol;
   StringToUpper(s);
   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return "xyz:GOLD";
   if(StringFind(s, "NAS") >= 0 || StringFind(s, "NDX") >= 0 || StringFind(s, "USTEC") >= 0 ||
      StringFind(s, "US100") >= 0 || StringFind(s, "NQ") >= 0) return "xyz:XYZ100";
   if(StringFind(s, "SPX") >= 0 || StringFind(s, "US500") >= 0 || StringFind(s, "SP500") >= 0) return "xyz:SP500";
   if(StringFind(s, "BTC") >= 0) return "BTC";
   if(StringFind(s, "ETH") >= 0) return "ETH";
   return "xyz:GOLD";
  }

string FileName()
  {
   string c = g_coin;
   StringReplace(c, ":", "_");
   return "LiquidityHeatmap_" + c + ".bin";
  }

uint Rgba(const int r, const int g, const int b, const int a)
  {
   return ((uint)MathMax(0, MathMin(255, a)) << 24) | ((uint)r << 16) | ((uint)g << 8) | (uint)b;
  }

uint Col(const color c, const int a)
  {
   return ColorToARGB(c, (uchar)MathMax(0, MathMin(255, a)));
  }

//--- heat gradient: deep blue -> cyan -> amber -> white
uint Heat(double t)
  {
   t = MathMax(0.0, MathMin(1.0, t));
   double r[5] = {10, 0, 0, 255, 255};
   double g[5] = {30, 90, 200, 200, 255};
   double b[5] = {70, 170, 210, 50, 255};
   double pos = t * 4.0;
   int i = (int)MathMin(3, MathFloor(pos));
   double f = pos - i;
   int R = (int)(r[i] + (r[i+1] - r[i]) * f);
   int G = (int)(g[i] + (g[i+1] - g[i]) * f);
   int B = (int)(b[i] + (b[i+1] - b[i]) * f);
   int A = (int)(25 + 215 * MathSqrt(t));
   return Rgba(R, G, B, A);
  }

string FmtSize(const double v)
  {
   if(v >= 1000) return DoubleToString(v / 1000.0, 1) + "k";
   if(v >= 100)  return DoubleToString(v, 0);
   return DoubleToString(v, 1);
  }

//+------------------------------------------------------------------+
//| Fetch one snapshot from Hyperliquid                              |
//+------------------------------------------------------------------+
int ParseSide(const string &js, int p, const int end, double &px[], double &sz[])
  {
   int n = 0;
   while(n < HM_LEVELS)
     {
      int a = StringFind(js, "\"px\":\"", p);
      if(a < 0 || a >= end) break;
      a += 6;
      int b = StringFind(js, "\"", a);
      int c = StringFind(js, "\"sz\":\"", b);
      if(b < 0 || c < 0) break;
      c += 6;
      int d = StringFind(js, "\"", c);
      if(d < 0) break;
      px[n] = StringToDouble(StringSubstr(js, a, b - a));
      sz[n] = StringToDouble(StringSubstr(js, c, d - c));
      p = d;
      n++;
     }
   return n;
  }

bool Fetch()
  {
   string body = "{\"type\":\"l2Book\",\"coin\":\"" + g_coin + "\",\"nSigFigs\":" + IntegerToString(InpSigFigs) + "}";
   char data[], result[];
   string respHeaders;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;   // drop terminating zero
   ArrayResize(data, len);
   ResetLastError();
   int code = WebRequest("POST", "https://api.hyperliquid.xyz/info", "Content-Type: application/json\r\n",
                         5000, data, result, respHeaders);
   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014) g_status = "Allow WebRequest: Tools > Options > Expert Advisors > add https://api.hyperliquid.xyz";
      else            g_status = "Connection error " + IntegerToString(err);
      g_ok = false;
      return false;
     }
   if(code != 200)
     {
      g_status = "Hyperliquid HTTP " + IntegerToString(code);
      g_ok = false;
      return false;
     }

   string js = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   int lv = StringFind(js, "\"levels\":[[");
   if(lv < 0) { g_status = "Unknown coin " + g_coin; g_ok = false; return false; }
   int sep = StringFind(js, "],[", lv);
   if(sep < 0) sep = StringLen(js);

   Snap s;
   ZeroMemory(s);
   s.nb = ParseSide(js, lv, sep, s.bpx, s.bsz);
   s.na = ParseSide(js, sep, StringLen(js), s.apx, s.asz);
   if(s.nb == 0 || s.na == 0) { g_status = "Empty book"; g_ok = false; return false; }

   //--- price grouping
   double ref = s.bpx[0];
   s.bucket = MathPow(10.0, MathFloor(MathLog10(ref)) - InpSigFigs + 1);
   if(s.nb > 1 && s.bpx[0] - s.bpx[1] > 0) s.bucket = MathMin(s.bucket, s.bpx[0] - s.bpx[1]);

   //--- offset: broker mid - Hyperliquid mid (smoothed)
   if(InpAutoOffset)
     {
      double hlMid  = (s.bpx[0] + s.apx[0]) / 2.0;
      double mtMid  = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
      if(mtMid > 0)
        {
         double raw = mtMid - hlMid;
         g_off = (g_n == 0 || g_off == 0) ? raw : g_off * 0.95 + raw * 0.05;
        }
     }
   else g_off = InpManualOffset;
   s.off = g_off;
   s.t   = TimeCurrent();

   //--- store
   if(g_n >= InpMaxSnapshots)
     {
      int drop = g_n - InpMaxSnapshots + 1;
      for(int i = drop; i < g_n; i++) g_snaps[i - drop] = g_snaps[i];
      g_n -= drop;
     }
   if(ArraySize(g_snaps) <= g_n) ArrayResize(g_snaps, g_n + 1, 500);
   g_snaps[g_n++] = s;
   g_status = "Live";
   g_ok = true;
   return true;
  }

//+------------------------------------------------------------------+
//| History file                                                     |
//+------------------------------------------------------------------+
void SaveHistory()
  {
   if(!InpSaveHistory || g_n == 0) return;
   int h = FileOpen(FileName(), FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteInteger(h, g_n);
   for(int i = 0; i < g_n; i++) FileWriteStruct(h, g_snaps[i]);
   FileClose(h);
  }

void LoadHistory()
  {
   if(!InpSaveHistory) return;
   int h = FileOpen(FileName(), FILE_READ | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   int n = FileReadInteger(h);
   if(n > 0 && n <= 1000000)
     {
      ArrayResize(g_snaps, n, 500);
      g_n = 0;
      for(int i = 0; i < n && !FileIsEnding(h); i++)
         if(FileReadStruct(h, g_snaps[g_n]) > 0) g_n++;
      if(g_n > InpMaxSnapshots)
        {
         int drop = g_n - InpMaxSnapshots;
         for(int i = drop; i < g_n; i++) g_snaps[i - drop] = g_snaps[i];
         g_n -= drop;
        }
      if(g_n > 0) g_off = g_snaps[g_n - 1].off;
     }
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
int    W, H;
double PMAX, PMIN;

int Yp(const double p) { return (int)MathRound((PMAX - p) / (PMAX - PMIN) * H); }

//--- x for any time, interpolated inside the bar
bool Xt(const datetime t, int &x)
  {
   int ps = PeriodSeconds(_Period);
   datetime bt = (datetime)(t - (t % ps));
   int y;
   if(!ChartTimePriceToXY(0, 0, bt, PMIN, x, y)) return false;
   int barPx = 1 << (int)ChartGetInteger(0, CHART_SCALE);
   x += (int)MathRound(((double)(t - bt) / ps - 0.5) * barPx);
   return true;
  }

void Redraw()
  {
   W = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   H = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(W <= 0 || H <= 0) return;
   if(W != g_cv.Width() || H != g_cv.Height()) g_cv.Resize(W, H);
   g_cv.Erase(0);
   PMAX = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   PMIN = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   if(PMAX <= PMIN) { g_cv.Update(false); return; }

   int ladderW = InpShowLadder ? InpLadderWidth : 0;
   int heatRight = W - ladderW;

   //--- reference size for color scaling: max level seen in visible snapshots
   double maxSz = 0;
   int    firstVis = -1;
   for(int i = 0; i < g_n; i++)
     {
      int x;
      if(!Xt(g_snaps[i].t, x)) continue;
      if(x < 0 || x > heatRight) continue;
      if(firstVis < 0) firstVis = i;
      for(int k = 0; k < g_snaps[i].nb; k++) maxSz = MathMax(maxSz, g_snaps[i].bsz[k]);
      for(int k = 0; k < g_snaps[i].na; k++) maxSz = MathMax(maxSz, g_snaps[i].asz[k]);
     }
   double ref = MathMax(1e-9, maxSz * InpContrast);

   //--- heatmap columns (one pixel column drawn once, latest snapshot wins)
   int lastX = -100000;
   for(int i = MathMax(0, firstVis); i < g_n && firstVis >= 0; i++)
     {
      int x0, x1;
      if(!Xt(g_snaps[i].t, x0)) continue;
      if(i + 1 < g_n && Xt(g_snaps[i + 1].t, x1) && x1 - x0 < 40) {}
      else x1 = x0 + MathMax(2, (1 << (int)ChartGetInteger(0, CHART_SCALE)) / 4);
      if(x1 <= lastX) continue;
      x0 = MathMax(x0, lastX);
      if(x0 > heatRight) break;
      x1 = MathMin(x1, heatRight);
      lastX = x1;
      double bk = g_snaps[i].bucket, off = g_snaps[i].off;
      for(int k = 0; k < g_snaps[i].nb; k++)
        {
         double p = g_snaps[i].bpx[k] + off;
         int yT = Yp(p + bk), yB = Yp(p) - 1;
         if(yB < 0 || yT > H) continue;
         g_cv.FillRectangle(x0, yT, x1 - 1, MathMax(yT, yB), Heat(g_snaps[i].bsz[k] / ref));
        }
      for(int k = 0; k < g_snaps[i].na; k++)
        {
         double p = g_snaps[i].apx[k] + off;
         int yT = Yp(p + bk), yB = Yp(p) - 1;
         if(yB < 0 || yT > H) continue;
         g_cv.FillRectangle(x0, yT, x1 - 1, MathMax(yT, yB), Heat(g_snaps[i].asz[k] / ref));
        }
     }

   //--- current book: walls + ladder
   if(g_n > 0)
     {
      Snap s = g_snaps[g_n - 1];
      double all[];
      ArrayResize(all, s.nb + s.na);
      for(int k = 0; k < s.nb; k++) all[k] = s.bsz[k];
      for(int k = 0; k < s.na; k++) all[s.nb + k] = s.asz[k];
      ArraySort(all);
      double median = all[ArraySize(all) / 2];
      double curMax = all[ArraySize(all) - 1];

      g_cv.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
      if(InpShowLadder)
        {
         g_cv.FillRectangle(heatRight, 0, W - 1, H - 1, Col(C_PANEL, 235));
         g_cv.LineVertical(heatRight, 0, H - 1, Col(C_BORDER, 255));
        }
      for(int side = 0; side < 2; side++)
        {
         int n = (side == 0) ? s.nb : s.na;
         for(int k = 0; k < n; k++)
           {
            double p  = ((side == 0) ? s.bpx[k] : s.apx[k]) + s.off;
            double sz = (side == 0) ? s.bsz[k] : s.asz[k];
            int yT = Yp(p + s.bucket), yB = Yp(p) - 1;
            if(yB < 0 || yT > H) continue;
            bool wall = InpShowWalls && median > 0 && sz >= InpWallFactor * median;
            if(InpShowLadder)
              {
               int len = (int)MathRound((ladderW - 50) * sz / MathMax(curMax, 1e-9));
               color c = (side == 0) ? C_BID : C_ASK;
               g_cv.FillRectangle(heatRight + 2, yT + 1, heatRight + 2 + MathMax(1, len), MathMax(yT + 1, yB), Col(wall ? C_WALL : c, wall ? 220 : 150));
               if(yB - yT >= InpFontSize + 2)
                  g_cv.TextOut(W - 4, (yT + yB) / 2, FmtSize(sz), Col(wall ? C_WALL : C_TEXT, 255), TA_RIGHT | TA_VCENTER);
              }
            if(wall)
              {
               int yy = (yT + yB) / 2;
               for(int x = 0; x < heatRight; x += 8) g_cv.LineHorizontal(x, MathMin(x + 4, heatRight), yy, Col(C_WALL, 150));
               g_cv.FontSet(InpLabelFont, -(InpFontSize - 1) * 10, FW_BOLD);
               g_cv.TextOut(heatRight - 6, yy - 2, ((side == 0) ? "BID WALL " : "ASK WALL ") + FmtSize(sz),
                            Col(C_WALL, 255), TA_RIGHT | TA_BOTTOM);
               g_cv.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
              }
           }
        }
     }

   //--- header
   g_cv.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
   string title = "LIQUIDITY HEATMAP";
   int tw = g_cv.TextWidth(title);
   g_cv.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
   string l2 = g_coin + "  ->  " + _Symbol + "   offset " + (g_off >= 0 ? "+" : "") + DoubleToString(g_off, _Digits) +
               "   " + IntegerToString(g_n) + " snapshots";
   string l3 = g_status;
   int pw = MathMax(tw, MathMax(g_cv.TextWidth(l2), g_cv.TextWidth(l3))) + 24;
   int lh = InpFontSize + 8, ph = lh * 3 + 10;
   int px = 10, py = 26;
   color sc = g_ok ? C_OK : C_ERR;
   g_cv.FillRectangle(px, py, px + pw, py + ph, Col(C_PANEL, 240));
   g_cv.Rectangle(px, py, px + pw, py + ph, Col(C_BORDER, 255));
   g_cv.FillRectangle(px, py, px + 2, py + ph, Col(sc, 255));
   g_cv.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
   g_cv.TextOut(px + 10, py + 5, title, Col(C_TEXT, 255), TA_LEFT | TA_TOP);
   g_cv.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
   g_cv.TextOut(px + 10, py + 5 + lh, l2, Col(C_DIM, 255), TA_LEFT | TA_TOP);
   g_cv.TextOut(px + 10, py + 5 + 2 * lh, l3, Col(sc, 255), TA_LEFT | TA_TOP);

   g_cv.Update(false);
  }

//+------------------------------------------------------------------+
//| EA events                                                        |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_coin = AutoCoin();
   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(!g_cv.CreateBitmapLabel(0, 0, g_name, 0, 0, MathMax(w, 1), MathMax(h, 1), COLOR_FORMAT_ARGB_NORMALIZE))
      return INIT_FAILED;
   ObjectSetInteger(0, g_name, OBJPROP_BACK, true);        // candles stay on top of the heatmap
   ObjectSetInteger(0, g_name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_name, OBJPROP_HIDDEN, true);
   LoadHistory();
   EventSetMillisecondTimer(200);
   Print("LiquidityHeatmap: ", g_coin, " -> ", _Symbol, ". Display only, no trades are placed.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveHistory();
   g_cv.Destroy();
   ChartRedraw();
  }

void OnTick() { }   // no trading logic by design

void OnTimer()
  {
   static uint lastDraw = 0;
   static uint lastSave = 0;
   if(GetTickCount() - g_lastFetch >= (uint)MathMax(1, InpIntervalSec) * 1000)
     {
      g_lastFetch = GetTickCount();
      Fetch();
      g_dirty = true;
     }
   if(g_dirty && GetTickCount() - lastDraw >= 150)
     {
      Redraw();
      ChartRedraw();
      g_dirty = false;
      lastDraw = GetTickCount();
     }
   if(GetTickCount() - lastSave >= 300000) { SaveHistory(); lastSave = GetTickCount(); }   // every 5 min
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE) g_dirty = true;
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                 FootprintPro.mq5 |
//|  Footprint chart for MT5: bid x ask per price level, delta,      |
//|  POC, Value Area, imbalance, stacked imbalance zones, naked POC, |
//|  unfinished auction, stats rows and a hover inspector.           |
//|                                                                  |
//|  Settings follow the OpenMarket "Volume Footprint" defaults.     |
//|                                                                  |
//|  Buy/Sell side:                                                  |
//|   - Exchange symbols (futures/stocks with real trades): uses the |
//|     tick's BUY/SELL flags and real volume.                       |
//|   - Forex / CFD (XAUUSD, NAS100 at prop firms): there is no real |
//|     volume or aggressor side, so the side is ESTIMATED from the  |
//|     tick direction (uptick = buy, downtick = sell) and each bid  |
//|     change counts as 1 volume (tick volume).                     |
//+------------------------------------------------------------------+
#property copyright "Footprint"
#property version   "1.00"
#property description "Footprint: Bid x Ask, Delta, POC, Value Area, Imbalance, Unfinished Auction."
#property description "On Forex/CFD symbols the buy/sell split is an estimate from tick direction."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

//--- enums
enum ENUM_FP_MODE
  {
   FP_SPLIT   = 0, // Split bar (Bid x Ask)
   FP_DELTA   = 1, // Delta per row
   FP_VOLUME  = 2, // Total volume per row
   FP_PROFILE = 3  // Profile bars (no text)
  };

enum ENUM_FP_SIDE
  {
   SIDE_AUTO     = 0, // Auto (flags if exchange symbol, else tick rule)
   SIDE_FLAGS    = 1, // Tick BUY/SELL flags (exchange data)
   SIDE_TICKRULE = 2  // Tick rule estimate (Forex/CFD)
  };

enum ENUM_FP_CELLCOLOR
  {
   CELL_DELTA  = 0, // Color by delta
   CELL_VOLUME = 1  // Color by volume
  };

enum ENUM_FP_THEME
  {
   THEME_DARK   = 0, // Institutional Dark
   THEME_LIGHT  = 1, // Institutional Light
   THEME_CUSTOM = 2  // Custom (use colors below)
  };

//--- inputs
input group "Data"
input int               InpBars          = 1000;         // Max bars to calculate (visible bars load first)
input int               InpRowPoints     = 0;            // Row size in points (0 = auto)
input int               InpAutoRows      = 20;           // Auto row size: target rows per bar
input ENUM_FP_SIDE      InpSide          = SIDE_AUTO;    // Buy/Sell detection
input double            InpBigTrade      = 0;            // Big trades only: min volume per tick (0 = all)

input group "Theme"
input ENUM_FP_THEME     InpTheme         = THEME_DARK;   // Theme
input bool              InpApplyChartTheme = true;       // Apply theme to chart background / grid
input bool              InpShowHeader    = true;         // Show header panel

input group "Display"
input ENUM_FP_MODE      InpMode          = FP_SPLIT;     // Display mode
input ENUM_FP_CELLCOLOR InpCellColor     = CELL_DELTA;   // Cell coloring (Delta/Volume modes)
input int               InpColumnWidth   = 90;           // Column width in pixels (0 = follow MT5 bar spacing)
input bool              InpAutoFitPrice  = true;         // Auto-fit price scale to visible columns
input int               InpMinRowPx      = 13;           // Min row height in pixels (rows merge to fit text)
input double            InpBarWidth      = 0.85;         // Cell width when following MT5 bars (fraction)
input bool              InpHideCandles   = true;         // Hide MT5 candles
input bool              InpDrawCandle    = true;         // Draw thin candle next to footprint
input string            InpFont          = "Consolas";   // Number font (monospaced)
input string            InpLabelFont     = "Segoe UI";   // Label font
input int               InpFontSize      = 8;            // Font size
input bool              InpAbbrev        = true;         // Abbreviate numbers (1.2k)
input bool              InpHideZero      = true;         // Hide zero values

input group "POC / Value Area"
input bool              InpShowPOC       = true;         // Show POC
input color             InpPOCColor      = clrWhite;     // POC color
input bool              InpNakedPOC      = false;        // Extend naked (untested) POC
input bool              InpShowVA        = true;         // Show Value Area (VAH / VAL)
input double            InpVAPercent     = 70.0;         // Value Area %
input color             InpVAColor       = clrWhite;     // VAH / VAL color

input group "Imbalance"
input bool              InpImbalance     = true;         // Show diagonal imbalance
input double            InpImbRatio      = 3.0;          // Imbalance ratio
input double            InpImbMinVol     = 1.0;          // Imbalance min volume
input int               InpStacked       = 3;            // Stacked imbalance: min rows
input bool              InpStackedZones  = true;         // Extend stacked imbalance zones
input color             InpImbBuyColor   = C'165,214,167'; // Buy imbalance color
input color             InpImbSellColor  = C'235,29,78';   // Sell imbalance color

input group "Unfinished auction"
input bool              InpUnfinished    = true;         // Mark unfinished auction
input color             InpUnfinishedClr = C'206,206,206'; // Unfinished auction color

input group "Stats rows"
input bool              InpStats         = true;         // Show stats rows below chart

input group "Custom colors (Theme = Custom)"
input color             InpBuyColor      = C'38,166,154';  // Buy (ask) color
input color             InpSellColor     = C'239,83,80';   // Sell (bid) color
input color             InpNeutralColor  = C'74,144,226';  // Volume color
input color             InpTextColor     = clrWhite;       // Text color
input color             InpPanelColor    = C'18,22,28';    // Panel background

input group "Interaction"
input bool              InpHover         = true;         // Hover inspector

//+------------------------------------------------------------------+
//| One footprint bar                                                |
//+------------------------------------------------------------------+
class CFootBar
  {
public:
   datetime          time;
   double            open, high, low, close;
   int               baseRow;      // row index of the lowest row (price / rowSize)
   int               rows;
   double            bid[];        // sell volume per row
   double            ask[];        // buy volume per row
   double            delta, volume, maxDelta, minDelta;
   int               pocRow, vahRow, valRow;
   bool              loaded;
   int               retries;
   long              tickVol;
   //--- display (merged rows, rebuilt each redraw)
   int               dBase, dRows, dPoc, dVah, dVal, dX;
   bool              vis;
   double            dBid[];
   double            dAsk[];

                     CFootBar(void)
     {
      time=0; open=high=low=close=0; baseRow=0; rows=0;
      delta=volume=maxDelta=minDelta=0;
      pocRow=vahRow=valRow=-1; loaded=false; retries=0; tickVol=0;
      dBase=dRows=dX=0; dPoc=dVah=dVal=-1; vis=false;
     }
   double            DTotal(const int d) { return dBid[d]+dAsk[d]; }
   double            Total(const int r) { return bid[r]+ask[r]; }
   double            RowPrice(const int r, const double rs) { return (baseRow+r)*rs; }
  };

//--- globals
CCanvas   g_canvas;
string    g_canvasName = "FootprintPro_Canvas";
CFootBar *g_bars[];
int       g_count      = 0;
double    g_rs         = 0;      // row size in price
bool      g_useFlags   = false;
bool      g_liveDirty  = false;
bool      g_needRedraw = true;
int       g_mouseX     = -1, g_mouseY = -1;
long      g_savedColors[5];
bool      g_colorsSaved = false;

//--- theme palette (filled by ApplyTheme)
color     g_buy, g_sell, g_neutral, g_text, g_textDim, g_poc, g_va;
color     g_imbBuy, g_imbSell, g_unf, g_panel, g_border, g_estimate, g_live;
color     g_chartBg, g_chartGrid, g_chartFg;
long      g_savedChart[4];
bool      g_chartSaved = false;

void ApplyTheme()
  {
   if(InpTheme == THEME_DARK)
     {
      g_chartBg = C'11,14,19';   g_chartGrid = C'24,29,37';  g_chartFg = C'139,148,158';
      g_buy     = C'0,179,149';  g_sell      = C'234,72,92'; g_neutral = C'62,124,240';
      g_text    = C'232,236,241';g_textDim   = C'125,133,144';
      g_poc     = C'255,196,54'; g_va        = C'132,150,178';
      g_imbBuy  = C'0,232,182';  g_imbSell   = C'255,92,112';
      g_unf     = C'200,204,210';g_panel     = C'17,21,27';  g_border = C'45,52,61';
      g_estimate= C'240,170,40'; g_live      = C'0,200,140';
     }
   else if(InpTheme == THEME_LIGHT)
     {
      g_chartBg = C'250,251,252';g_chartGrid = C'234,237,241';g_chartFg = C'90,98,110';
      g_buy     = C'0,150,120';  g_sell      = C'214,48,72'; g_neutral = C'40,100,220';
      g_text    = C'18,22,28';   g_textDim   = C'100,108,120';
      g_poc     = C'222,140,0';  g_va        = C'90,105,130';
      g_imbBuy  = C'0,120,95';   g_imbSell   = C'190,20,50';
      g_unf     = C'90,98,110';  g_panel     = C'255,255,255';g_border = C'208,213,220';
      g_estimate= C'200,120,0';  g_live      = C'0,150,100';
     }
   else
     {
      g_chartBg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
      g_chartGrid = (color)ChartGetInteger(0, CHART_COLOR_GRID);
      g_chartFg = (color)ChartGetInteger(0, CHART_COLOR_FOREGROUND);
      g_buy = InpBuyColor; g_sell = InpSellColor; g_neutral = InpNeutralColor;
      g_text = InpTextColor; g_textDim = InpTextColor;
      g_poc = InpPOCColor; g_va = InpVAColor;
      g_imbBuy = InpImbBuyColor; g_imbSell = InpImbSellColor; g_unf = InpUnfinishedClr;
      g_panel = InpPanelColor; g_border = InpNeutralColor;
      g_estimate = clrOrange; g_live = InpBuyColor;
     }
  }

//--- chart options changed while the indicator runs (restored on removal)
long g_savedOpt[4];
bool g_optSaved = false;

void SetChartOptions(const bool apply)
  {
   if(apply)
     {
      g_savedOpt[0] = ChartGetInteger(0, CHART_SHOW_VOLUMES);
      g_savedOpt[1] = ChartGetInteger(0, CHART_SHOW_DATE_SCALE);
      g_savedOpt[2] = ChartGetInteger(0, CHART_SHOW_GRID);
      g_savedOpt[3] = ChartGetInteger(0, CHART_SCALEFIX);
      g_optSaved = true;
      ChartSetInteger(0, CHART_SHOW_VOLUMES, CHART_VOLUME_HIDE);
      if(InpColumnWidth > 0)
        {
         ChartSetInteger(0, CHART_SHOW_DATE_SCALE, false);   // MT5 time axis does not match wide columns
         ChartSetInteger(0, CHART_SHOW_GRID, false);
        }
     }
   else if(g_optSaved)
     {
      ChartSetInteger(0, CHART_SHOW_VOLUMES,    g_savedOpt[0]);
      ChartSetInteger(0, CHART_SHOW_DATE_SCALE, g_savedOpt[1]);
      ChartSetInteger(0, CHART_SHOW_GRID,       g_savedOpt[2]);
      ChartSetInteger(0, CHART_SCALEFIX,        g_savedOpt[3]);
      g_optSaved = false;
     }
  }

void SetChartTheme(const bool apply)
  {
   ENUM_CHART_PROPERTY_INTEGER props[4] = {CHART_COLOR_BACKGROUND, CHART_COLOR_GRID, CHART_COLOR_FOREGROUND, CHART_COLOR_BID};
   if(apply)
     {
      if(!g_chartSaved)
        {
         for(int i = 0; i < 4; i++) g_savedChart[i] = ChartGetInteger(0, props[i]);
         g_chartSaved = true;
        }
      ChartSetInteger(0, CHART_COLOR_BACKGROUND, g_chartBg);
      ChartSetInteger(0, CHART_COLOR_GRID,       g_chartGrid);
      ChartSetInteger(0, CHART_COLOR_FOREGROUND, g_chartFg);
      ChartSetInteger(0, CHART_COLOR_BID,        g_textDim);
     }
   else if(g_chartSaved)
     {
      for(int i = 0; i < 4; i++) ChartSetInteger(0, props[i], g_savedChart[i]);
      g_chartSaved = false;
     }
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double NiceStep(const double raw)
  {
   double pt = MathMax(_Point, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE));
   if(pt <= 0) pt = _Point;
   if(raw <= pt) return pt;
   double steps = raw / pt;
   double mag   = MathPow(10.0, MathFloor(MathLog10(steps)));
   double f     = steps / mag;
   double nf    = (f < 1.5) ? 1.0 : (f < 3.5) ? 2.0 : (f < 7.5) ? 5.0 : 10.0;
   return nf * mag * pt;
  }

int PriceRow(const double price)
  {
   return (int)MathFloor(price / g_rs + 1e-7);
  }

string Fmt(const double v)
  {
   double a = MathAbs(v);
   if(InpAbbrev && a >= 10000.0) return DoubleToString(v / 1000.0, 0) + "k";
   if(InpAbbrev && a >= 1000.0)  return DoubleToString(v / 1000.0, 1) + "k";
   if(MathAbs(a - MathRound(a)) < 1e-9) return DoubleToString(v, 0);
   return DoubleToString(v, (a < 10.0) ? 2 : 1);
  }

uint FPColor(const color c, const int alpha)
  {
   return ColorToARGB(c, (uchar)MathMax(0, MathMin(255, alpha)));
  }

int FindBar(const datetime t)
  {
   int lo = 0, hi = g_count - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      if(g_bars[mid].time == t) return mid;
      if(g_bars[mid].time < t) lo = mid + 1;
      else hi = mid - 1;
     }
   return -1;
  }

void ClearBars()
  {
   for(int i = 0; i < g_count; i++)
      if(CheckPointer(g_bars[i]) == POINTER_DYNAMIC) delete g_bars[i];
   ArrayResize(g_bars, 0);
   g_count = 0;
  }

//+------------------------------------------------------------------+
//| Build one bar from ticks                                         |
//+------------------------------------------------------------------+
bool BuildFromTicks(const int idx, const MqlTick &ticks[], const int s0, const int e0);

//--- live bar: fetch its ticks and build
bool BuildBar(const int idx)
  {
   CFootBar *b = g_bars[idx];
   ulong from = (ulong)b.time * 1000;
   ulong to   = from + (ulong)PeriodSeconds(_Period) * 1000 - 1;
   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, g_useFlags ? COPY_TICKS_TRADE : COPY_TICKS_INFO, from, to);
   if(n <= 0) return false;
   return BuildFromTicks(idx, ticks, 0, n);
  }

//--- history: fetch one block of up to 24 consecutive unloaded bars with a single tick request
bool LoadChunk(const int newest)
  {
   int oldest = newest;
   while(oldest - 1 >= 0 && !g_bars[oldest - 1].loaded && newest - oldest < 23) oldest--;
   ulong from = (ulong)g_bars[oldest].time * 1000;
   ulong to   = (ulong)g_bars[newest].time * 1000 + (ulong)PeriodSeconds(_Period) * 1000 - 1;
   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, g_useFlags ? COPY_TICKS_TRADE : COPY_TICKS_INFO, from, to);
   if(n <= 0)
     {
      // history still downloading: retry on a later timer tick (never give up while the bar has volume)
      for(int i = oldest; i <= newest; i++)
        {
         g_bars[i].retries++;
         if(g_bars[i].tickVol == 0 || g_bars[i].retries > 1200) { g_bars[i].rows = 0; g_bars[i].loaded = true; }
        }
      return false;
     }
   int k = 0;
   for(int i = oldest; i <= newest; i++)
     {
      ulong bStart = (ulong)g_bars[i].time * 1000;
      ulong bEnd   = bStart + (ulong)PeriodSeconds(_Period) * 1000;
      if(i < newest) bEnd = MathMin(bEnd, (ulong)g_bars[i + 1].time * 1000);
      while(k < n && (ulong)ticks[k].time_msc < bStart) k++;
      int st = k;
      while(k < n && (ulong)ticks[k].time_msc < bEnd) k++;
      if(k > st) BuildFromTicks(i, ticks, st, k);
      else { g_bars[i].rows = 0; g_bars[i].loaded = true; }
     }
   return true;
  }

bool BuildFromTicks(const int idx, const MqlTick &ticks[], const int s0, const int e0)
  {
   CFootBar *b = g_bars[idx];
   int n = e0 - s0;
   //--- pass 1: classify ticks
   double prices[];
   double vols[];
   bool   buys[];
   ArrayResize(prices, n); ArrayResize(vols, n); ArrayResize(buys, n);
   int    m = 0;
   double prevPrice = (idx > 0 && g_bars[idx-1].close > 0) ? g_bars[idx-1].close : b.open;
   int    lastDir   = 1;
   double pMin = DBL_MAX, pMax = -DBL_MAX;

   for(int i = s0; i < e0; i++)
     {
      double price, vol;
      bool   buy;
      if(g_useFlags)
        {
         price = ticks[i].last;
         if(price <= 0) continue;
         vol = (ticks[i].volume_real > 0) ? ticks[i].volume_real : (double)ticks[i].volume;
         if(vol <= 0) vol = 1;
         bool fb = (ticks[i].flags & TICK_FLAG_BUY)  != 0;
         bool fs = (ticks[i].flags & TICK_FLAG_SELL) != 0;
         if(fb && !fs)      buy = true;
         else if(fs && !fb) buy = false;
         else if(ticks[i].ask > 0 && price >= ticks[i].ask) buy = true;
         else if(ticks[i].bid > 0 && price <= ticks[i].bid) buy = false;
         else if(price > prevPrice) buy = true;
         else if(price < prevPrice) buy = false;
         else buy = (lastDir > 0);
        }
      else
        {
         if((ticks[i].flags & TICK_FLAG_BID) == 0) continue;   // count bid changes only
         price = ticks[i].bid;
         if(price <= 0) continue;
         vol = 1;
         if(price > prevPrice)      buy = true;
         else if(price < prevPrice) buy = false;
         else                       buy = (lastDir > 0);
        }
      lastDir   = buy ? 1 : -1;
      prevPrice = price;
      if(InpBigTrade > 0 && vol < InpBigTrade) continue;
      prices[m] = price; vols[m] = vol; buys[m] = buy; m++;
      if(price < pMin) pMin = price;
      if(price > pMax) pMax = price;
     }

   //--- include candle range so rows cover the whole bar
   if(b.low > 0)  pMin = MathMin(pMin, b.low);
   if(b.high > 0) pMax = MathMax(pMax, b.high);
   if(pMin == DBL_MAX || pMax < pMin)
     {
      b.rows = 0; b.loaded = true;
      return true;
     }

   //--- pass 2: bin into rows
   b.baseRow = PriceRow(pMin);
   b.rows    = PriceRow(pMax) - b.baseRow + 1;
   if(b.rows > 5000) b.rows = 5000;           // safety
   ArrayResize(b.bid, b.rows); ArrayResize(b.ask, b.rows);
   ArrayInitialize(b.bid, 0);  ArrayInitialize(b.ask, 0);

   double cum = 0, mx = 0, mn = 0, tot = 0;
   for(int i = 0; i < m; i++)
     {
      int r = PriceRow(prices[i]) - b.baseRow;
      if(r < 0) r = 0;
      if(r >= b.rows) r = b.rows - 1;
      if(buys[i]) { b.ask[r] += vols[i]; cum += vols[i]; }
      else        { b.bid[r] += vols[i]; cum -= vols[i]; }
      tot += vols[i];
      if(cum > mx) mx = cum;
      if(cum < mn) mn = cum;
     }
   b.delta = cum; b.volume = tot; b.maxDelta = mx; b.minDelta = mn;

   //--- POC
   b.pocRow = -1;
   double best = -1;
   for(int r = 0; r < b.rows; r++)
      if(b.Total(r) > best) { best = b.Total(r); b.pocRow = r; }

   //--- Value Area
   b.vahRow = b.valRow = b.pocRow;
   if(b.pocRow >= 0 && tot > 0)
     {
      double target = tot * InpVAPercent / 100.0;
      double acc    = b.Total(b.pocRow);
      int lo = b.pocRow, hi = b.pocRow;
      while(acc < target)
        {
         double up = (hi + 1 < b.rows) ? b.Total(hi + 1) : -1;
         double dn = (lo - 1 >= 0)     ? b.Total(lo - 1) : -1;
         if(up < 0 && dn < 0) break;
         if(up >= dn) { hi++; acc += up; }
         else         { lo--; acc += dn; }
        }
      b.vahRow = hi; b.valRow = lo;
     }

   b.loaded = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Display state                                                    |
//+------------------------------------------------------------------+
int    g_w, g_h;
double g_pmax, g_pmin;
int    g_k   = 1;      // base rows merged into one display row
double g_drs = 0;      // display row size (price)
int    g_colW = 0;     // column width in pixels
bool   g_fitBusy = false;

int Y(const double price)
  {
   return (int)MathRound((g_pmax - price) / (g_pmax - g_pmin) * g_h);
  }

double DPrice(CFootBar *b, const int d) { return (b.dBase + d) * g_drs; }

void DashH(const int x1, const int x2, const int y, const uint clr)
  {
   for(int x = x1; x <= x2; x += 6)
      g_canvas.LineHorizontal(x, MathMin(x + 3, x2), y, clr);
  }

int NiceInt(const int v)
  {
   if(v <= 1) return 1;
   int base = 1;
   while(base <= 100000)
     {
      if(v <= base)     return base;
      if(v <= base * 2) return base * 2;
      if(base >= 10 && v <= base * 25 / 10) return base * 25 / 10;
      if(v <= base * 5) return base * 5;
      base *= 10;
     }
   return v;
  }

//--- merge base rows into display rows and compute POC / Value Area on them
void BuildDisplay(CFootBar *b)
  {
   b.dRows = 0; b.dPoc = b.dVah = b.dVal = -1;
   if(!b.loaded || b.rows == 0) return;
   b.dBase = b.baseRow / g_k;
   int top = (b.baseRow + b.rows - 1) / g_k;
   b.dRows = top - b.dBase + 1;
   ArrayResize(b.dBid, b.dRows); ArrayResize(b.dAsk, b.dRows);
   ArrayInitialize(b.dBid, 0);   ArrayInitialize(b.dAsk, 0);
   for(int r = 0; r < b.rows; r++)
     {
      int d = (b.baseRow + r) / g_k - b.dBase;
      b.dBid[d] += b.bid[r];
      b.dAsk[d] += b.ask[r];
     }
   double best = -1, tot = 0;
   for(int d = 0; d < b.dRows; d++)
     {
      double t = b.DTotal(d);
      tot += t;
      if(t > best) { best = t; b.dPoc = d; }
     }
   b.dVah = b.dVal = b.dPoc;
   if(tot <= 0) return;
   double target = tot * InpVAPercent / 100.0;
   double acc = b.DTotal(b.dPoc);
   int lo = b.dPoc, hi = b.dPoc;
   while(acc < target)
     {
      double up = (hi + 1 < b.dRows) ? b.DTotal(hi + 1) : -1;
      double dn = (lo - 1 >= 0)      ? b.DTotal(lo - 1) : -1;
      if(up < 0 && dn < 0) break;
      if(up >= dn) { hi++; acc += up; }
      else         { lo--; acc += dn; }
     }
   b.dVah = hi; b.dVal = lo;
  }

//--- diagonal imbalance on display rows: ask[d] vs bid[d-1], bid[d] vs ask[d+1]
bool BuyImb(CFootBar *b, const int d)
  {
   if(d < 1 || b.dAsk[d] < InpImbMinVol) return false;
   double other = b.dBid[d-1];
   if(other <= 0) return true;
   return b.dAsk[d] >= InpImbRatio * other;
  }

bool SellImb(CFootBar *b, const int d)
  {
   if(d >= b.dRows - 1 || b.dBid[d] < InpImbMinVol) return false;
   double other = b.dAsk[d+1];
   if(other <= 0) return true;
   return b.dBid[d] >= InpImbRatio * other;
  }

//--- horizontal layout: own wide columns, or follow MT5 bar positions
void LayoutColumns()
  {
   for(int i = 0; i < g_count; i++) g_bars[i].vis = false;
   if(InpColumnWidth > 0)
     {
      g_colW = InpColumnWidth;
      int gap   = MathMax(4, g_colW / 15);
      int first = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
      int nvis  = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
      int r0    = MathMax(0, first - nvis + 1);
      datetime tR = iTime(_Symbol, _Period, r0);
      int idxR = -1;
      for(int i = g_count - 1; i >= 0; i--)
         if(g_bars[i].time <= tR) { idxR = i; break; }
      if(idxR < 0) return;
      int rightEdge = g_w - 10;
      for(int i = 0; i < g_count; i++)
        {
         int x = rightEdge - (idxR - i) * (g_colW + gap) - g_colW / 2;
         g_bars[i].dX  = x;
         g_bars[i].vis = (i <= idxR) && (x + g_colW / 2 >= 0);
        }
     }
   else
     {
      int scale = (int)ChartGetInteger(0, CHART_SCALE);
      g_colW = (int)MathMax(2, MathRound((1 << scale) * InpBarWidth));
      for(int i = 0; i < g_count; i++)
        {
         int x, y;
         if(!ChartTimePriceToXY(0, 0, g_bars[i].time, g_bars[i].close, x, y)) continue;
         g_bars[i].dX  = x;
         g_bars[i].vis = (x + g_colW >= 0 && x - g_colW <= g_w);
        }
     }
  }

//--- fit the price scale to the visible columns (wide mode)
bool AutoFitPrice()
  {
   if(!InpAutoFitPrice || InpColumnWidth <= 0) return false;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < g_count; i++)
     {
      if(!g_bars[i].vis) continue;
      hi = MathMax(hi, g_bars[i].high);
      lo = MathMin(lo, g_bars[i].low);
     }
   if(hi <= lo) return false;
   double pad = (hi - lo) * 0.06;
   double statsFrac = InpStats ? (5.0 * (InpFontSize + 7)) / MathMax(100.0, (double)g_h) : 0.0;
   double newMax = hi + pad;
   double newMin = lo - pad - (hi - lo + 2 * pad) * statsFrac / MathMax(0.2, 1.0 - statsFrac);
   double curMax = ChartGetDouble(0, CHART_FIXED_MAX);
   double curMin = ChartGetDouble(0, CHART_FIXED_MIN);
   bool fixed = (bool)ChartGetInteger(0, CHART_SCALEFIX);
   double eps = (hi - lo) * 0.01;
   if(fixed && MathAbs(curMax - newMax) < eps && MathAbs(curMin - newMin) < eps) return false;
   ChartSetInteger(0, CHART_SCALEFIX, true);
   ChartSetDouble(0, CHART_FIXED_MAX, newMax);
   ChartSetDouble(0, CHART_FIXED_MIN, newMin);
   return true;
  }

//+------------------------------------------------------------------+
//| Main redraw                                                      |
//+------------------------------------------------------------------+
void Redraw()
  {
   g_w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   g_h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(g_w <= 0 || g_h <= 0) return;
   if(g_w != g_canvas.Width() || g_h != g_canvas.Height())
      g_canvas.Resize(g_w, g_h);
   g_canvas.Erase(0);
   if(g_rs <= 0 || g_count == 0) { g_canvas.Update(false); return; }

   LayoutColumns();
   if(!g_fitBusy && AutoFitPrice())
     {
      g_fitBusy = true;
      ChartRedraw();          // apply new scale, then draw with it
      g_fitBusy = false;
     }

   g_pmax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   g_pmin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   if(g_pmax <= g_pmin) { g_canvas.Update(false); return; }

   //--- merge rows so each display row is tall enough for text
   double basePx = g_rs / (g_pmax - g_pmin) * g_h;
   g_k   = NiceInt((int)MathCeil(InpMinRowPx / MathMax(basePx, 0.01)));
   g_drs = g_rs * g_k;
   for(int i = 0; i < g_count; i++) BuildDisplay(g_bars[i]);
   double rowPx = g_drs / (g_pmax - g_pmin) * g_h;

   int cw      = g_colW;
   int candleW = InpDrawCandle ? MathMax(1, cw / 16) : 0;
   int cellW   = MathMax(1, cw - (InpDrawCandle ? candleW + 2 : 0));
   bool textFits = rowPx >= InpFontSize + 4;
   bool showText = (InpMode != FP_PROFILE) && textFits && cellW >= ((InpMode == FP_SPLIT) ? 34 : 18);
   g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);

   bool wide      = (InpColumnWidth > 0);
   int statsRows  = wide ? 5 : 4;
   int statsRowH  = InpFontSize + 7;
   int statsTop   = g_h - statsRows * statsRowH;
   int labelW     = 70;
   int clipBottom = InpStats ? statsTop - 1 : g_h;
   int hoverBar = -1, hoverRow = -1;

   //--- stacked imbalance zones and naked POC (behind cells)
   for(int i = 0; i < g_count; i++)
     {
      CFootBar *b = g_bars[i];
      if(b.dRows == 0) continue;
      if(!wide && !b.vis) continue;
      int x0 = b.dX + cw / 2;
      if(x0 > g_w) continue;

      if(InpStackedZones && InpImbalance)
        {
         for(int side = 0; side < 2; side++)
           {
            int run = 0;
            for(int d = 0; d <= b.dRows; d++)
              {
               bool imb = (d < b.dRows) && (side == 0 ? BuyImb(b, d) : SellImb(b, d));
               if(imb) { run++; continue; }
               if(run >= InpStacked)
                 {
                  double zLo = DPrice(b, d - run);
                  double zHi = DPrice(b, d);
                  int xEnd = g_w;
                  for(int j = i + 1; j < g_count; j++)
                    {
                     CFootBar *c = g_bars[j];
                     bool broken = (side == 0) ? (c.low < zLo) : (c.high > zHi);
                     if(broken) { xEnd = MathMin(g_w, c.dX - cw / 2); break; }
                    }
                  if(xEnd > 0 && xEnd > x0)
                    {
                     color zc = (side == 0) ? g_imbBuy : g_imbSell;
                     g_canvas.FillRectangle(MathMax(0, x0), Y(zHi), xEnd, MathMin(Y(zLo), clipBottom), FPColor(zc, 40));
                     g_canvas.LineHorizontal(MathMax(0, x0), xEnd, Y(zHi), FPColor(zc, 90));
                     g_canvas.LineHorizontal(MathMax(0, x0), xEnd, MathMin(Y(zLo), clipBottom), FPColor(zc, 90));
                    }
                 }
               run = 0;
              }
           }
        }

      if(InpNakedPOC && InpShowPOC && b.dPoc >= 0)
        {
         double pp = DPrice(b, b.dPoc) + g_drs / 2.0;
         bool touched = false;
         for(int j = i + 1; j < g_count; j++)
            if(g_bars[j].low <= pp && g_bars[j].high >= pp) { touched = true; break; }
         if(!touched && g_w > x0)
            DashH(MathMax(0, x0), g_w, Y(pp), FPColor(g_poc, 170));
        }
     }

   if(InpStats) g_canvas.FillRectangle(0, statsTop, g_w - 1, g_h - 1, FPColor(g_panel, 240));

   //--- columns
   for(int i = 0; i < g_count; i++)
     {
      CFootBar *b = g_bars[i];
      if(!b.vis) continue;
      int x = b.dX;
      if(x - cw > g_w) continue;

      int left   = x - cw / 2;
      int cLeft  = left + (InpDrawCandle ? candleW + 2 : 0);
      int cRight = cLeft + cellW - 1;
      int mid    = cLeft + cellW / 2;

      //--- column background
      if(wide) g_canvas.FillRectangle(left, 0, left + cw - 1, clipBottom, FPColor(g_panel, 70));

      //--- thin candle
      if(InpDrawCandle)
        {
         color cc = (b.close >= b.open) ? g_buy : g_sell;
         int cx = left + candleW / 2;
         g_canvas.LineVertical(cx, Y(b.high), MathMin(Y(b.low), clipBottom), FPColor(cc, 230));
         int yo = MathMin(Y(b.open), clipBottom), yc = MathMin(Y(b.close), clipBottom);
         g_canvas.FillRectangle(left, MathMin(yo, yc), left + candleW - 1, MathMax(MathMax(yo, yc), MathMin(yo, yc) + 1), FPColor(cc, 255));
        }

      if(b.dRows > 0)
        {
         double maxSide = 0, maxTot = 0, maxAbsD = 0;
         for(int d = 0; d < b.dRows; d++)
           {
            maxSide = MathMax(maxSide, MathMax(b.dBid[d], b.dAsk[d]));
            maxTot  = MathMax(maxTot, b.DTotal(d));
            maxAbsD = MathMax(maxAbsD, MathAbs(b.dAsk[d] - b.dBid[d]));
           }

         //--- hover detection
         if(InpHover && g_mouseX >= left && g_mouseX <= left + cw - 1 && g_mouseY >= 0 && g_mouseY <= clipBottom)
           {
            double mp = g_pmax - (double)g_mouseY / g_h * (g_pmax - g_pmin);
            int hr = (int)MathFloor(mp / g_drs + 1e-7) - b.dBase;
            if(hr >= 0 && hr < b.dRows) { hoverBar = i; hoverRow = hr; }
           }

         for(int d = 0; d < b.dRows && maxTot > 0; d++)
           {
            double pLo = DPrice(b, d);
            int yTop = Y(pLo + g_drs) + 1;
            int yBot = Y(pLo);
            if(yBot < yTop) yBot = yTop;
            if(yBot < 0 || yTop > clipBottom) continue;
            if(yBot > clipBottom) yBot = clipBottom;

            double bv = b.dBid[d], av = b.dAsk[d], tv = bv + av, dv = av - bv;
            bool bi = InpImbalance && BuyImb(b, d);
            bool si = InpImbalance && SellImb(b, d);
            bool isPoc = (d == b.dPoc);

            switch(InpMode)
              {
               case FP_SPLIT:
                 {
                  int aB = (maxSide > 0) ? (int)(16 + 120 * bv / maxSide) : 16;
                  int aA = (maxSide > 0) ? (int)(16 + 120 * av / maxSide) : 16;
                  g_canvas.FillRectangle(cLeft, yTop, mid - 1, yBot, FPColor(g_sell, aB));
                  g_canvas.FillRectangle(mid + 1, yTop, cRight, yBot, FPColor(g_buy, aA));
                  if(!showText)
                    {
                     if(bi) g_canvas.Rectangle(mid + 1, yTop, cRight, yBot, FPColor(g_imbBuy, 255));
                     if(si) g_canvas.Rectangle(cLeft, yTop, mid - 1, yBot, FPColor(g_imbSell, 255));
                    }
                  else
                    {
                     int ty = (yTop + yBot) / 2;
                     if(!(InpHideZero && bv == 0))
                       {
                        g_canvas.FontSet(InpFont, -InpFontSize * 10, (si || isPoc) ? FW_BOLD : FW_NORMAL);
                        g_canvas.TextOut(mid - 4, ty, Fmt(bv), FPColor(si ? g_imbSell : g_text, 255), TA_RIGHT | TA_VCENTER);
                       }
                     if(!(InpHideZero && av == 0))
                       {
                        g_canvas.FontSet(InpFont, -InpFontSize * 10, (bi || isPoc) ? FW_BOLD : FW_NORMAL);
                        g_canvas.TextOut(mid + 4, ty, Fmt(av), FPColor(bi ? g_imbBuy : g_text, 255), TA_LEFT | TA_VCENTER);
                       }
                     g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
                    }
                  break;
                 }
               case FP_DELTA:
               case FP_VOLUME:
                 {
                  color fc; int al;
                  if(InpCellColor == CELL_DELTA)
                    {
                     fc = (dv >= 0) ? g_buy : g_sell;
                     al = (maxAbsD > 0) ? (int)(16 + 130 * MathAbs(dv) / maxAbsD) : 16;
                    }
                  else
                    {
                     fc = g_neutral;
                     al = (int)(16 + 130 * tv / maxTot);
                    }
                  g_canvas.FillRectangle(cLeft, yTop, cRight, yBot, FPColor(fc, al));
                  if(bi)      g_canvas.Rectangle(cLeft, yTop, cRight, yBot, FPColor(g_imbBuy, 255));
                  else if(si) g_canvas.Rectangle(cLeft, yTop, cRight, yBot, FPColor(g_imbSell, 255));
                  if(showText)
                    {
                     double v = (InpMode == FP_DELTA) ? dv : tv;
                     if(!(InpHideZero && v == 0))
                       {
                        g_canvas.FontSet(InpFont, -InpFontSize * 10, isPoc ? FW_BOLD : FW_NORMAL);
                        g_canvas.TextOut((cLeft + cRight) / 2, (yTop + yBot) / 2, Fmt(v), FPColor(g_text, 255), TA_CENTER | TA_VCENTER);
                        g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
                       }
                    }
                  break;
                 }
               case FP_PROFILE:
                 {
                  int len  = (int)MathRound((cellW - 1) * tv / maxTot);
                  int lenS = (tv > 0) ? (int)MathRound(len * bv / tv) : 0;
                  if(lenS > 0)   g_canvas.FillRectangle(cLeft, yTop, cLeft + lenS - 1, yBot, FPColor(g_sell, 200));
                  if(len > lenS) g_canvas.FillRectangle(cLeft + lenS, yTop, cLeft + len - 1, yBot, FPColor(g_buy, 200));
                  break;
                 }
              }
           }

         //--- POC outline
         if(InpShowPOC && b.dPoc >= 0)
           {
            double pLo = DPrice(b, b.dPoc);
            int yT = Y(pLo + g_drs), yB = MathMin(Y(pLo), clipBottom);
            g_canvas.Rectangle(cLeft, yT, cRight, yB, FPColor(g_poc, 255));
            if(wide) g_canvas.Rectangle(cLeft + 1, yT + 1, cRight - 1, yB - 1, FPColor(g_poc, 120));
           }

         //--- Value Area
         if(InpShowVA && b.dVah >= 0)
           {
            int yH = Y(DPrice(b, b.dVah) + g_drs);
            int yL = MathMin(Y(DPrice(b, b.dVal)), clipBottom);
            g_canvas.LineHorizontal(cLeft, cRight + 3, yH, FPColor(g_va, 230));
            g_canvas.LineHorizontal(cLeft, cRight + 3, yL, FPColor(g_va, 230));
            g_canvas.LineVertical(cRight + 2, yH, yL, FPColor(g_va, 150));
           }

         //--- unfinished auction (both sides traded at the extreme)
         if(InpUnfinished)
           {
            int top = b.dRows - 1;
            if(b.dBid[top] > 0 && b.dAsk[top] > 0)
               DashH(cLeft, cRight, Y(DPrice(b, top) + g_drs) - 2, FPColor(g_unf, 230));
            if(b.dBid[0] > 0 && b.dAsk[0] > 0)
               DashH(cLeft, cRight, MathMin(Y(DPrice(b, 0)) + 2, clipBottom), FPColor(g_unf, 230));
           }
        }

      //--- stats cells
      if(InpStats && cw >= 24 && left > labelW)
        {
         double vals[4];
         vals[0] = b.delta; vals[1] = b.maxDelta; vals[2] = b.minDelta; vals[3] = b.volume;
         double ref = MathMax(1.0, b.volume);
         for(int s = 0; s < 4; s++)
           {
            int yT = statsTop + s * statsRowH;
            color sc = (s == 3) ? g_neutral : ((vals[s] >= 0) ? g_buy : g_sell);
            int al = (s == 3) ? 45 : (int)(30 + 150 * MathMin(1.0, MathAbs(vals[s]) / ref));
            g_canvas.FillRectangle(left, yT + 1, left + cw - 1, yT + statsRowH - 1, FPColor(sc, al));
            g_canvas.TextOut(x, yT + statsRowH / 2, Fmt(vals[s]), FPColor(g_text, 255), TA_CENTER | TA_VCENTER);
           }
         if(wide)
           {
            int yT = statsTop + 4 * statsRowH;
            MqlDateTime dt; TimeToStruct(b.time, dt);
            string ts = (dt.hour == 0 && dt.min == 0 && _Period < PERIOD_D1) ? TimeToString(b.time, TIME_DATE) : TimeToString(b.time, TIME_MINUTES);
            if(_Period >= PERIOD_D1) ts = TimeToString(b.time, TIME_DATE);
            g_canvas.TextOut(x, yT + statsRowH / 2, ts, FPColor(g_textDim, 255), TA_CENTER | TA_VCENTER);
           }
        }
     }

   //--- stats frame and labels
   if(InpStats)
     {
      string labels[5] = {"DELTA", "MAX DELTA", "MIN DELTA", "VOLUME", "TIME"};
      g_canvas.LineHorizontal(0, g_w - 1, statsTop, FPColor(g_border, 255));
      g_canvas.FontSet(InpLabelFont, -InpFontSize * 10, FW_SEMIBOLD);
      for(int s = 0; s < statsRows; s++)
        {
         int yT = statsTop + s * statsRowH;
         if(s > 0) g_canvas.LineHorizontal(0, g_w - 1, yT, FPColor(g_border, 110));
         g_canvas.FillRectangle(0, yT + 1, labelW, yT + statsRowH - 1, FPColor(g_panel, 255));
         g_canvas.TextOut(8, yT + statsRowH / 2, labels[s], FPColor(g_textDim, 255), TA_LEFT | TA_VCENTER);
        }
      g_canvas.LineVertical(labelW, statsTop, g_h - 1, FPColor(g_border, 255));
      g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
     }

   //--- header panel (top right)
   if(InpShowHeader)
     {
      g_canvas.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
      string title = "FOOTPRINT PRO";
      string info  = _Symbol + "  " + StringSubstr(EnumToString(_Period), 7) + "   Row " + DoubleToString(g_drs, _Digits);
      string badge = g_useFlags ? "EXCHANGE DATA" : "ESTIMATED FLOW";
      int tw = g_canvas.TextWidth(title);
      g_canvas.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
      int iw = g_canvas.TextWidth(info);
      g_canvas.FontSet(InpLabelFont, -(InpFontSize - 1) * 10, FW_BOLD);
      int bw2 = g_canvas.TextWidth(badge) + 12;
      int pw = MathMax(tw + bw2 + 10, iw) + 20;
      int ph = (InpFontSize + 7) * 2 + 10;
      int px = g_w - pw - 8, py = 8;
      color bc = g_useFlags ? g_live : g_estimate;
      g_canvas.FillRectangle(px, py, px + pw, py + ph, FPColor(g_panel, 240));
      g_canvas.Rectangle(px, py, px + pw, py + ph, FPColor(g_border, 255));
      g_canvas.FillRectangle(px, py, px + 2, py + ph, FPColor(bc, 255));
      g_canvas.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
      g_canvas.TextOut(px + 10, py + 6, title, FPColor(g_text, 255), TA_LEFT | TA_TOP);
      int bx0 = px + 10 + tw + 10, by0 = py + 6, bh0 = InpFontSize + 6;
      g_canvas.FillRectangle(bx0, by0, bx0 + bw2, by0 + bh0, FPColor(bc, 50));
      g_canvas.Rectangle(bx0, by0, bx0 + bw2, by0 + bh0, FPColor(bc, 255));
      g_canvas.FontSet(InpLabelFont, -(InpFontSize - 1) * 10, FW_BOLD);
      g_canvas.TextOut(bx0 + bw2 / 2, by0 + bh0 / 2, badge, FPColor(bc, 255), TA_CENTER | TA_VCENTER);
      g_canvas.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
      g_canvas.TextOut(px + 10, py + 8 + InpFontSize + 9, info, FPColor(g_textDim, 255), TA_LEFT | TA_TOP);
      g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
     }

   //--- hover inspector
   if(hoverBar >= 0)
     {
      g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
      CFootBar *b = g_bars[hoverBar];
      double pLo = DPrice(b, hoverRow);
      string lines[7];
      lines[0] = TimeToString(b.time, TIME_DATE | TIME_MINUTES);
      lines[1] = "Price " + DoubleToString(pLo, _Digits) + " - " + DoubleToString(pLo + g_drs, _Digits);
      lines[2] = "Bid " + Fmt(b.dBid[hoverRow]) + "  x  Ask " + Fmt(b.dAsk[hoverRow]);
      lines[3] = "Row delta " + Fmt(b.dAsk[hoverRow] - b.dBid[hoverRow]) + "  vol " + Fmt(b.DTotal(hoverRow));
      lines[4] = "Bar delta " + Fmt(b.delta) + "  vol " + Fmt(b.volume);
      lines[5] = "POC " + DoubleToString(DPrice(b, b.dPoc), _Digits);
      lines[6] = g_useFlags ? "Side: exchange flags" : "Side: tick-rule estimate";
      int lh = InpFontSize + 7, bw = 0;
      for(int k = 0; k < 7; k++) bw = MathMax(bw, g_canvas.TextWidth(lines[k]));
      bw += 16;
      int bh = lh * 7 + 10;
      int bx = g_mouseX + 16, by = g_mouseY + 16;
      if(bx + bw > g_w) bx = g_mouseX - bw - 16;
      if(by + bh > g_h) by = g_mouseY - bh - 16;
      g_canvas.FillRectangle(bx, by, bx + bw, by + bh, FPColor(g_panel, 250));
      g_canvas.Rectangle(bx, by, bx + bw, by + bh, FPColor(g_border, 255));
      for(int k = 0; k < 7; k++)
         g_canvas.TextOut(bx + 8, by + 5 + k * lh, lines[k], FPColor(k == 0 ? g_textDim : g_text, 255), TA_LEFT | TA_TOP);
     }

   g_canvas.Update(false);
  }

//+------------------------------------------------------------------+
//| Candle visibility                                                |
//+------------------------------------------------------------------+
void HideCandles(const bool hide)
  {
   ENUM_CHART_PROPERTY_INTEGER props[5] =
     {CHART_COLOR_CHART_UP, CHART_COLOR_CHART_DOWN, CHART_COLOR_CANDLE_BULL, CHART_COLOR_CANDLE_BEAR, CHART_COLOR_CHART_LINE};
   if(hide)
     {
      if(!g_colorsSaved)
        {
         for(int i = 0; i < 5; i++) g_savedColors[i] = ChartGetInteger(0, props[i]);
         g_colorsSaved = true;
        }
      for(int i = 0; i < 5; i++) ChartSetInteger(0, props[i], clrNONE);
     }
   else if(g_colorsSaved)
     {
      for(int i = 0; i < 5; i++) ChartSetInteger(0, props[i], g_savedColors[i]);
      g_colorsSaved = false;
     }
  }

//+------------------------------------------------------------------+
//| Init / deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSide == SIDE_FLAGS)         g_useFlags = true;
   else if(InpSide == SIDE_TICKRULE) g_useFlags = false;
   else g_useFlags = (SymbolInfoInteger(_Symbol, SYMBOL_CHART_MODE) == SYMBOL_CHART_MODE_LAST);

   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(!g_canvas.CreateBitmapLabel(0, 0, g_canvasName, 0, 0, MathMax(w, 1), MathMax(h, 1), COLOR_FORMAT_ARGB_NORMALIZE))
     {
      Print("FootprintPro: cannot create canvas");
      return INIT_FAILED;
     }
   ObjectSetInteger(0, g_canvasName, OBJPROP_BACK, true);
   ObjectSetInteger(0, g_canvasName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_canvasName, OBJPROP_HIDDEN, true);

   ApplyTheme();
   if(InpTheme != THEME_CUSTOM && InpApplyChartTheme) SetChartTheme(true);
   if(InpHideCandles) HideCandles(true);
   SetChartOptions(true);
   if(InpHover) ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   g_rs = 0;
   EventSetMillisecondTimer(50);
   IndicatorSetString(INDICATOR_SHORTNAME, "FootprintPro");
   if(!g_useFlags)
      Print("FootprintPro: ", _Symbol, " has no exchange trade data. Buy/Sell is estimated from tick direction; volume = tick count.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ClearBars();
   g_canvas.Destroy();
   HideCandles(false);
   SetChartTheme(false);
   SetChartOptions(false);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| OnCalculate: keep bar list in sync                               |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2) return 0;

   if(prev_calculated == 0)
     {
      ClearBars();
      //--- row size
      if(InpRowPoints > 0)
         g_rs = InpRowPoints * _Point;
      else
        {
         int k = MathMin(100, rates_total);
         double sum = 0;
         for(int i = rates_total - k; i < rates_total; i++) sum += high[i] - low[i];
         g_rs = NiceStep((sum / k) / MathMax(1, InpAutoRows));
        }
     }

   int start = MathMax(0, rates_total - InpBars);

   //--- drop bars that fell out of the window
   int rm = 0;
   while(rm < g_count && g_bars[rm].time < time[start])
     {
      delete g_bars[rm];
      rm++;
     }
   if(rm > 0)
     {
      for(int i = rm; i < g_count; i++) g_bars[i - rm] = g_bars[i];
      g_count -= rm;
      ArrayResize(g_bars, g_count);
     }

   //--- append new bars
   for(int i = start; i < rates_total; i++)
     {
      if(g_count > 0 && time[i] <= g_bars[g_count - 1].time) continue;
      if(g_count > 0) g_bars[g_count - 1].loaded = false;   // previous live bar: rebuild once as closed
      CFootBar *b = new CFootBar;
      b.time = time[i]; b.tickVol = tick_volume[i]; b.open = open[i]; b.high = high[i]; b.low = low[i]; b.close = close[i];
      ArrayResize(g_bars, g_count + 1);
      g_bars[g_count] = b;
      g_count++;
     }

   //--- refresh OHLC of the most recent bars (only these can still change)
   for(int i = MathMax(start, rates_total - 3); i < rates_total; i++)
     {
      int j = FindBar(time[i]);
      if(j < 0) continue;
      g_bars[j].open = open[i]; g_bars[j].high = high[i]; g_bars[j].low = low[i]; g_bars[j].close = close[i];
     }
   g_liveDirty = true;
   return rates_total;
  }

//+------------------------------------------------------------------+
//| Timer: build pending bars, rebuild live bar, redraw              |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(g_count == 0 || g_rs <= 0) return;
   bool changed = false;
   uint t0 = GetTickCount();

   //--- history: newest first, in blocks, max ~40 ms per timer tick so the terminal stays responsive
   //--- bars on screen first
   for(int i = g_count - 2; i >= 0 && GetTickCount() - t0 < 40; i--)
     {
      if(g_bars[i].loaded || !g_bars[i].vis) continue;
      if(LoadChunk(i)) changed = true;
      else break;
     }
   //--- then the rest, newest first
   for(int i = g_count - 2; i >= 0 && GetTickCount() - t0 < 40; i--)
     {
      if(g_bars[i].loaded) continue;
      if(LoadChunk(i)) changed = true;
      else break;                      // ticks still downloading, try again next tick
     }

   //--- live bar: rebuild at most twice a second
   static uint lastLive = 0;
   if(g_liveDirty && GetTickCount() - lastLive >= 500)
     {
      BuildBar(g_count - 1);
      g_bars[g_count - 1].loaded = true;
      g_liveDirty = false;
      lastLive = GetTickCount();
      changed = true;
     }

   //--- redraw at most ~10 times a second
   static uint lastDraw = 0;
   if((changed || g_needRedraw) && GetTickCount() - lastDraw >= 100)
     {
      Redraw();
      g_needRedraw = false;
      lastDraw = GetTickCount();
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
//| Chart events                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      g_needRedraw = true;
     }
   else if(id == CHARTEVENT_MOUSE_MOVE && InpHover)
     {
      g_mouseX = (int)lparam;
      g_mouseY = (int)dparam;
      g_needRedraw = true;
     }
  }
//+------------------------------------------------------------------+

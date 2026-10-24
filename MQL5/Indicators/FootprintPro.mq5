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
input int               InpBars          = 150;          // Bars to calculate
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
input double            InpBarWidth      = 0.85;         // Cell width (fraction of bar spacing)
input bool              InpHideCandles   = true;         // Hide MT5 candles
input bool              InpDrawCandle    = true;         // Draw thin candle next to footprint
input string            InpFont          = "Consolas";   // Number font (monospaced)
input string            InpLabelFont     = "Segoe UI";   // Label font
input int               InpFontSize      = 7;            // Font size
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

                     CFootBar(void)
     {
      time=0; open=high=low=close=0; baseRow=0; rows=0;
      delta=volume=maxDelta=minDelta=0;
      pocRow=vahRow=valRow=-1; loaded=false; retries=0;
     }
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

uint ARGB(const color c, const int alpha)
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
bool BuildBar(const int idx)
  {
   CFootBar *b = g_bars[idx];
   ulong from = (ulong)b.time * 1000;
   ulong to   = from + (ulong)PeriodSeconds(_Period) * 1000 - 1;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, g_useFlags ? COPY_TICKS_TRADE : COPY_TICKS_INFO, from, to);
   if(n <= 0)
     {
      b.retries++;
      // after a few tries treat as empty (no tick history for this bar)
      if(b.retries >= 5)
        {
         ArrayResize(b.bid, 0); ArrayResize(b.ask, 0);
         b.rows = 0; b.loaded = true;
        }
      return false;
     }

   //--- pass 1: classify ticks
   double prices[];
   double vols[];
   bool   buys[];
   ArrayResize(prices, n); ArrayResize(vols, n); ArrayResize(buys, n);
   int    m = 0;
   double prevPrice = (idx > 0 && g_bars[idx-1].close > 0) ? g_bars[idx-1].close : b.open;
   int    lastDir   = 1;
   double pMin = DBL_MAX, pMax = -DBL_MAX;

   for(int i = 0; i < n; i++)
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
//| Imbalance tests (diagonal: ask[r] vs bid[r-1], bid[r] vs ask[r+1])|
//+------------------------------------------------------------------+
bool BuyImb(CFootBar *b, const int r)
  {
   if(r < 1 || b.ask[r] < InpImbMinVol) return false;
   double other = b.bid[r-1];
   if(other <= 0) return true;
   return b.ask[r] >= InpImbRatio * other;
  }

bool SellImb(CFootBar *b, const int r)
  {
   if(r >= b.rows - 1 || b.bid[r] < InpImbMinVol) return false;
   double other = b.ask[r+1];
   if(other <= 0) return true;
   return b.bid[r] >= InpImbRatio * other;
  }

//+------------------------------------------------------------------+
//| Drawing helpers                                                  |
//+------------------------------------------------------------------+
int    g_w, g_h;
double g_pmax, g_pmin;

int Y(const double price)
  {
   return (int)MathRound((g_pmax - price) / (g_pmax - g_pmin) * g_h);
  }

void DashH(const int x1, const int x2, const int y, const uint clr)
  {
   for(int x = x1; x <= x2; x += 6)
      g_canvas.LineHorizontal(x, MathMin(x + 3, x2), y, clr);
  }

bool BarX(CFootBar *b, int &x)
  {
   int y;
   return ChartTimePriceToXY(0, 0, b.time, b.close, x, y);
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

   g_pmax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   g_pmin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   if(g_pmax <= g_pmin || g_rs <= 0 || g_count == 0) { g_canvas.Update(); return; }

   int scale = (int)ChartGetInteger(0, CHART_SCALE);
   int barPx = 1 << scale;
   int cw    = (int)MathMax(2, MathRound(barPx * InpBarWidth));
   int candleW = InpDrawCandle ? MathMax(1, cw / 8) : 0;
   int cellW = MathMax(1, cw - (InpDrawCandle ? candleW + 1 : 0));
   double rowPx = g_rs / (g_pmax - g_pmin) * g_h;
   bool showText = (InpMode != FP_PROFILE) && rowPx >= InpFontSize + 3 && cellW >= 14;
   g_canvas.FontSet(InpFont, -InpFontSize * 10);

   int statsRows = 4;
   int statsRowH = InpFontSize + 6;
   int statsTop  = g_h - statsRows * statsRowH;

   int hoverBar = -1, hoverRow = -1;

   //--- stacked imbalance zones and naked POC (drawn first, behind cells)
   if((InpStackedZones && InpImbalance) || (InpNakedPOC && InpShowPOC))
     {
      for(int i = 0; i < g_count; i++)
        {
         CFootBar *b = g_bars[i];
         if(!b.loaded || b.rows == 0) continue;
         int x0;
         if(!BarX(b, x0)) continue;
         if(x0 > g_w) continue;

         if(InpStackedZones && InpImbalance)
           {
            for(int side = 0; side < 2; side++)
              {
               int run = 0;
               for(int r = 0; r <= b.rows; r++)
                 {
                  bool imb = (r < b.rows) && (side == 0 ? BuyImb(b, r) : SellImb(b, r));
                  if(imb) { run++; continue; }
                  if(run >= InpStacked)
                    {
                     double zLo = b.RowPrice(r - run, g_rs);
                     double zHi = b.RowPrice(r, g_rs);
                     int xEnd = g_w;
                     for(int j = i + 1; j < g_count; j++)
                       {
                        CFootBar *c = g_bars[j];
                        bool broken = (side == 0) ? (c.low < zLo) : (c.high > zHi);
                        if(broken) { int xx; if(BarX(c, xx)) xEnd = xx; break; }
                       }
                     if(xEnd > 0)
                       {
                        color zc = (side == 0) ? g_imbBuy : g_imbSell;
                        g_canvas.FillRectangle(x0, Y(zHi), xEnd, Y(zLo), ARGB(zc, 45));
                       }
                    }
                  run = 0;
                 }
              }
           }

         if(InpNakedPOC && InpShowPOC && b.pocRow >= 0)
           {
            double pp = b.RowPrice(b.pocRow, g_rs) + g_rs / 2.0;
            int xEnd = g_w;
            bool touched = false;
            for(int j = i + 1; j < g_count; j++)
              {
               CFootBar *c = g_bars[j];
               if(c.low <= pp && c.high >= pp) { touched = true; break; }
              }
            if(!touched && xEnd > x0)
               DashH(x0 + cw / 2, xEnd, Y(pp), ARGB(g_poc, 160));
           }
        }
     }

   int clipBottom = InpStats ? statsTop - 1 : g_h;
   if(InpStats) g_canvas.FillRectangle(0, statsTop, g_w - 1, g_h - 1, ARGB(g_panel, 235));

   //--- footprint cells
   for(int i = 0; i < g_count; i++)
     {
      CFootBar *b = g_bars[i];
      int x;
      if(!BarX(b, x)) continue;
      if(x < -cw || x > g_w + cw) continue;

      int left  = x - cw / 2;
      int cLeft = left + (InpDrawCandle ? candleW + 1 : 0);
      int cRight = cLeft + cellW - 1;
      int mid   = cLeft + cellW / 2;

      //--- thin candle
      if(InpDrawCandle)
        {
         color cc = (b.close >= b.open) ? g_buy : g_sell;
         int cx = left + candleW / 2;
         g_canvas.LineVertical(cx, Y(b.high), MathMin(Y(b.low), clipBottom), ARGB(cc, 230));
         int yo = MathMin(Y(b.open), clipBottom), yc = MathMin(Y(b.close), clipBottom);
         g_canvas.FillRectangle(left, MathMin(yo, yc), left + candleW - 1, MathMax(MathMax(yo, yc), MathMin(yo, yc) + 1), ARGB(cc, 255));
        }

      if(!b.loaded || b.rows == 0) continue;

      double maxSide = 0, maxTot = 0, maxAbsD = 0;
      for(int r = 0; r < b.rows; r++)
        {
         maxSide = MathMax(maxSide, MathMax(b.bid[r], b.ask[r]));
         maxTot  = MathMax(maxTot, b.Total(r));
         maxAbsD = MathMax(maxAbsD, MathAbs(b.ask[r] - b.bid[r]));
        }
      if(maxTot <= 0) continue;

      //--- hover detection
      if(InpHover && g_mouseX >= cLeft && g_mouseX <= cRight && g_mouseY >= 0 && g_mouseY < g_h)
        {
         double mp = g_pmax - (double)g_mouseY / g_h * (g_pmax - g_pmin);
         int hr = PriceRow(mp) - b.baseRow;
         if(hr >= 0 && hr < b.rows) { hoverBar = i; hoverRow = hr; }
        }

      for(int r = 0; r < b.rows; r++)
        {
         double pLo = b.RowPrice(r, g_rs);
         int yTop = Y(pLo + g_rs);
         int yBot = Y(pLo) - 1;
         if(yBot < yTop) yBot = yTop;
         if(yBot < 0 || yTop > clipBottom) continue;
         if(yBot > clipBottom) yBot = clipBottom;

         double bv = b.bid[r], av = b.ask[r], tv = bv + av, dv = av - bv;
         if(tv <= 0 && InpHideZero && InpMode == FP_PROFILE) continue;

         switch(InpMode)
           {
            case FP_SPLIT:
              {
               int aB = (maxSide > 0) ? (int)(18 + 130 * bv / maxSide) : 18;
               int aA = (maxSide > 0) ? (int)(18 + 130 * av / maxSide) : 18;
               g_canvas.FillRectangle(cLeft, yTop, mid - 1, yBot, ARGB(g_sell, aB));
               g_canvas.FillRectangle(mid, yTop, cRight, yBot, ARGB(g_buy, aA));
               g_canvas.LineVertical(mid, yTop, yBot, ARGB(g_chartBg, 160));
               if(InpImbalance && !showText)
                 {
                  if(BuyImb(b, r))  g_canvas.Rectangle(mid, yTop, cRight, yBot, ARGB(g_imbBuy, 255));
                  if(SellImb(b, r)) g_canvas.Rectangle(cLeft, yTop, mid - 1, yBot, ARGB(g_imbSell, 255));
                 }
               if(showText)
                 {
                  int ty = (yTop + yBot) / 2;
                  bool si = InpImbalance && SellImb(b, r);
                  bool bi = InpImbalance && BuyImb(b, r);
                  bool isPoc = (r == b.pocRow);
                  if(!(InpHideZero && bv == 0))
                    {
                     g_canvas.FontSet(InpFont, -InpFontSize * 10, (si || isPoc) ? FW_BOLD : FW_NORMAL);
                     g_canvas.TextOut(mid - 2, ty, Fmt(bv), ARGB(si ? g_imbSell : g_text, 255), TA_RIGHT | TA_VCENTER);
                    }
                  if(!(InpHideZero && av == 0))
                    {
                     g_canvas.FontSet(InpFont, -InpFontSize * 10, (bi || isPoc) ? FW_BOLD : FW_NORMAL);
                     g_canvas.TextOut(mid + 2, ty, Fmt(av), ARGB(bi ? g_imbBuy : g_text, 255), TA_LEFT | TA_VCENTER);
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
                  al = (maxAbsD > 0) ? (int)(18 + 140 * MathAbs(dv) / maxAbsD) : 18;
                 }
               else
                 {
                  fc = g_neutral;
                  al = (int)(18 + 140 * tv / maxTot);
                 }
               g_canvas.FillRectangle(cLeft, yTop, cRight, yBot, ARGB(fc, al));
               if(InpImbalance)
                 {
                  if(BuyImb(b, r))       g_canvas.Rectangle(cLeft, yTop, cRight, yBot, ARGB(g_imbBuy, 255));
                  else if(SellImb(b, r)) g_canvas.Rectangle(cLeft, yTop, cRight, yBot, ARGB(g_imbSell, 255));
                 }
               if(showText)
                 {
                  double v = (InpMode == FP_DELTA) ? dv : tv;
                  if(!(InpHideZero && v == 0))
                     g_canvas.TextOut((cLeft + cRight) / 2, (yTop + yBot) / 2, Fmt(v), ARGB(g_text, 255), TA_CENTER | TA_VCENTER);
                 }
               break;
              }
            case FP_PROFILE:
              {
               int len  = (int)MathRound((cellW - 1) * tv / maxTot);
               int lenS = (tv > 0) ? (int)MathRound(len * bv / tv) : 0;
               if(lenS > 0) g_canvas.FillRectangle(cLeft, yTop, cLeft + lenS - 1, yBot, ARGB(g_sell, 200));
               if(len > lenS) g_canvas.FillRectangle(cLeft + lenS, yTop, cLeft + len - 1, yBot, ARGB(g_buy, 200));
               break;
              }
           }
        }

      //--- POC outline
      if(InpShowPOC && b.pocRow >= 0)
        {
         double pLo = b.RowPrice(b.pocRow, g_rs);
         g_canvas.Rectangle(cLeft, Y(pLo + g_rs), cRight, Y(pLo) - 1, ARGB(g_poc, 255));
        }

      //--- Value Area lines
      if(InpShowVA && b.vahRow >= 0)
        {
         int yH = Y(b.RowPrice(b.vahRow, g_rs) + g_rs);
         int yL = Y(b.RowPrice(b.valRow, g_rs)) - 1;
         g_canvas.LineHorizontal(cLeft - 2, cRight + 2, yH, ARGB(g_va, 220));
         g_canvas.LineHorizontal(cLeft - 2, cRight + 2, yL, ARGB(g_va, 220));
         g_canvas.LineVertical(cRight + 1, yH, yL, ARGB(g_va, 120));
        }

      //--- Unfinished auction (both sides traded at the extreme)
      if(InpUnfinished)
        {
         int top = b.rows - 1;
         if(b.bid[top] > 0 && b.ask[top] > 0)
           {
            int yy = Y(b.RowPrice(top, g_rs) + g_rs) - 2;
            g_canvas.LineHorizontal(cLeft, cRight + cw / 2, yy, ARGB(g_unf, 220));
           }
         if(b.bid[0] > 0 && b.ask[0] > 0)
           {
            int yy = Y(b.RowPrice(0, g_rs)) + 1;
            g_canvas.LineHorizontal(cLeft, cRight + cw / 2, yy, ARGB(g_unf, 220));
           }
        }

      //--- stats rows
      if(InpStats && cw >= 16)
        {
         double vals[4];
         vals[0] = b.delta; vals[1] = b.maxDelta; vals[2] = b.minDelta; vals[3] = b.volume;
         double ref = MathMax(1.0, b.volume);
         for(int s = 0; s < statsRows; s++)
           {
            int yT = statsTop + s * statsRowH;
            color sc = (s == 3) ? g_neutral : ((vals[s] >= 0) ? g_buy : g_sell);
            int al = (s == 3) ? 40 : (int)(30 + 150 * MathMin(1.0, MathAbs(vals[s]) / ref));
            g_canvas.FillRectangle(left, yT + 1, left + cw - 2, yT + statsRowH - 1, ARGB(sc, al));
            g_canvas.TextOut(x, yT + statsRowH / 2, Fmt(vals[s]), ARGB(g_text, 255), TA_CENTER | TA_VCENTER);
           }
        }
     }

   //--- stats panel frame and labels
   if(InpStats)
     {
      string labels[4] = {"DELTA", "MAX DELTA", "MIN DELTA", "VOLUME"};
      g_canvas.FillRectangle(0, statsTop, g_w - 1, statsTop, ARGB(g_border, 255));
      g_canvas.FontSet(InpLabelFont, -InpFontSize * 10, FW_SEMIBOLD);
      for(int s = 0; s < statsRows; s++)
        {
         int yT = statsTop + s * statsRowH;
         if(s > 0) g_canvas.LineHorizontal(0, g_w - 1, yT, ARGB(g_border, 120));
         g_canvas.FillRectangle(0, yT + 1, 64, yT + statsRowH - 1, ARGB(g_panel, 245));
         g_canvas.TextOut(6, yT + statsRowH / 2, labels[s], ARGB(g_textDim, 255), TA_LEFT | TA_VCENTER);
        }
      g_canvas.LineVertical(64, statsTop, g_h - 1, ARGB(g_border, 255));
      g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
     }

   //--- header panel (top right): product, symbol, settings, data-source badge
   if(InpShowHeader)
     {
      g_canvas.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
      string title = "FOOTPRINT PRO";
      string info  = _Symbol + "  " + StringSubstr(EnumToString(_Period), 7) + "   Row " + DoubleToString(g_rs, _Digits);
      string badge = g_useFlags ? "EXCHANGE DATA" : "ESTIMATED FLOW";
      int tw = g_canvas.TextWidth(title);
      g_canvas.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
      int iw = g_canvas.TextWidth(info);
      g_canvas.FontSet(InpLabelFont, -(InpFontSize - 1) * 10, FW_BOLD);
      int bw2 = g_canvas.TextWidth(badge) + 12;
      int pw = MathMax(tw + bw2 + 10, iw) + 20;
      int ph = (InpFontSize + 7) * 2 + 10;
      int px = g_w - pw - 8, py = 8;
      g_canvas.FillRectangle(px, py, px + pw, py + ph, ARGB(g_panel, 235));
      g_canvas.Rectangle(px, py, px + pw, py + ph, ARGB(g_border, 255));
      g_canvas.FillRectangle(px, py, px + 2, py + ph, ARGB(g_useFlags ? g_live : g_estimate, 255));
      g_canvas.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
      g_canvas.TextOut(px + 10, py + 6, title, ARGB(g_text, 255), TA_LEFT | TA_TOP);
      int bx0 = px + 10 + tw + 10, by0 = py + 6;
      int bh0 = InpFontSize + 6;
      color bc = g_useFlags ? g_live : g_estimate;
      g_canvas.FillRectangle(bx0, by0, bx0 + bw2, by0 + bh0, ARGB(bc, 50));
      g_canvas.Rectangle(bx0, by0, bx0 + bw2, by0 + bh0, ARGB(bc, 255));
      g_canvas.FontSet(InpLabelFont, -(InpFontSize - 1) * 10, FW_BOLD);
      g_canvas.TextOut(bx0 + bw2 / 2, by0 + bh0 / 2, badge, ARGB(bc, 255), TA_CENTER | TA_VCENTER);
      g_canvas.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
      g_canvas.TextOut(px + 10, py + 8 + InpFontSize + 9, info, ARGB(g_textDim, 255), TA_LEFT | TA_TOP);
      g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
     }

   //--- hover inspector
   if(hoverBar >= 0)
     {
      g_canvas.FontSet(InpFont, -InpFontSize * 10, FW_NORMAL);
      CFootBar *b = g_bars[hoverBar];
      double pLo = b.RowPrice(hoverRow, g_rs);
      string lines[7];
      lines[0] = TimeToString(b.time, TIME_DATE | TIME_MINUTES);
      lines[1] = "Price " + DoubleToString(pLo, _Digits) + " - " + DoubleToString(pLo + g_rs, _Digits);
      lines[2] = "Bid " + Fmt(b.bid[hoverRow]) + "  x  Ask " + Fmt(b.ask[hoverRow]);
      lines[3] = "Row delta " + Fmt(b.ask[hoverRow] - b.bid[hoverRow]) + "  vol " + Fmt(b.Total(hoverRow));
      lines[4] = "Bar delta " + Fmt(b.delta) + "  vol " + Fmt(b.volume);
      lines[5] = "POC " + DoubleToString(b.RowPrice(b.pocRow, g_rs), _Digits);
      lines[6] = g_useFlags ? "Side: exchange flags" : "Side: tick-rule estimate";
      int lh = InpFontSize + 6, bw = 0;
      for(int k = 0; k < 7; k++) bw = MathMax(bw, g_canvas.TextWidth(lines[k]));
      bw += 12;
      int bh = lh * 7 + 8;
      int bx = g_mouseX + 16, by = g_mouseY + 16;
      if(bx + bw > g_w) bx = g_mouseX - bw - 16;
      if(by + bh > g_h) by = g_mouseY - bh - 16;
      g_canvas.FillRectangle(bx, by, bx + bw, by + bh, ARGB(g_panel, 245));
      g_canvas.Rectangle(bx, by, bx + bw, by + bh, ARGB(g_border, 255));
      for(int k = 0; k < 7; k++)
         g_canvas.TextOut(bx + 6, by + 4 + k * lh, lines[k], ARGB(g_text, 255), TA_LEFT | TA_TOP);
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
   if(InpHover) ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   g_rs = 0;
   EventSetMillisecondTimer(250);
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
      b.time = time[i]; b.open = open[i]; b.high = high[i]; b.low = low[i]; b.close = close[i];
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

   //--- historical bars not loaded yet (a few per tick to stay responsive)
   int budget = 25;
   for(int i = g_count - 2; i >= 0 && budget > 0; i--)
     {
      if(g_bars[i].loaded) continue;
      BuildBar(i);
      budget--;
      changed = true;
     }

   //--- live bar
   if(g_liveDirty)
     {
      BuildBar(g_count - 1);
      g_bars[g_count - 1].loaded = true;
      g_liveDirty = false;
      changed = true;
     }

   if(changed || g_needRedraw)
     {
      Redraw();
      g_needRedraw = false;
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
      Redraw();
      ChartRedraw();
     }
   else if(id == CHARTEVENT_MOUSE_MOVE && InpHover)
     {
      g_mouseX = (int)lparam;
      g_mouseY = (int)dparam;
      g_needRedraw = true;
     }
  }
//+------------------------------------------------------------------+

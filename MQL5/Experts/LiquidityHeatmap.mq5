//+------------------------------------------------------------------+
//|                                             LiquidityHeatmap.mq5 |
//|  Historical order-book liquidity heatmap + iceberg detector for  |
//|  MT5, fed by OpenMarket (Hyperliquid xyz:GOLD / xyz:XYZ100 book). |
//|                                                                  |
//|  - Drawn on the MT5 time axis: scroll back and the heatmap of    |
//|    that period loads automatically (cached to disk).             |
//|  - Style like OpenMarket: per-candle level dashes, purple ->     |
//|    blue -> green -> yellow, persistent walls as yellow lines.    |
//|  - Icebergs (DeepCharts style): bubbles where traded volume at a |
//|    level far exceeds the displayed size and the level held.      |
//|  - Strategy Tester: reads the cache only and never shows data    |
//|    after the tester's current time (no look-ahead).              |
//|                                                                  |
//|  DISPLAY ONLY: this EA never opens, modifies or closes trades.   |
//|                                                                  |
//|  Setup: Tools > Options > Expert Advisors > Allow WebRequest,    |
//|  add https://mcp.openmarket.xyz . Paste your OpenMarket agent    |
//|  token (openmarket.xyz/chart/console/agents, Read access) in the |
//|  EA inputs. Keep the token private.                              |
//+------------------------------------------------------------------+
#property copyright "Footprint"
#property version   "2.00"
#property description "Historical liquidity heatmap + iceberg detector (OpenMarket data). Display only, no trades."
#property description "Allow WebRequest for https://mcp.openmarket.xyz and paste your OpenMarket agent token."

#include <Canvas\Canvas.mqh>

//--- enums
enum ENUM_HM_STYLE
  {
   HM_DASH  = 0, // Dashes per candle (OpenMarket)
   HM_BLOCK = 1  // Continuous blocks (Bookmap)
  };

//--- inputs
input group "OpenMarket connection"
input string InpToken        = "";          // OpenMarket agent token (Read access)
input string InpCoin         = "";          // Hyperliquid market ("" = auto: XAUUSD->xyz:GOLD, NAS100->xyz:XYZ100)
input string InpExchange     = "HYPERLIQUID_HIP3"; // OpenMarket venue
input int    InpRequestGap   = 7;           // Seconds between requests (rate limit)
input int    InpChunkBars    = 120;         // Bars per request
input int    InpPrefetchBars = 600;         // Bars to prefetch into the cache
input int    InpLiveRefresh  = 60;          // Refresh latest bars every N seconds

input group "Heatmap"
input ENUM_HM_STYLE InpStyle = HM_DASH;     // Style
input double InpBlockSize    = 0;           // Price block size (0 = auto by symbol/timeframe)
input int    InpDepth        = 40;          // Levels per side
input double InpMinIntensity = 0.12;        // Hide levels weaker than this (0..1)
input double InpContrast     = 0.95;        // Reference percentile for full color (0.5..0.99)
input bool   InpWalls        = true;        // Draw walls as continuous lines
input double InpWallPct      = 0.97;        // Wall = level above this percentile

input group "Price offset (Hyperliquid -> broker)"
input bool   InpAutoOffset   = true;        // Auto offset per candle (VWAP based)
input double InpManualOffset = 0;           // Manual offset (auto off)

input group "Icebergs"
input bool   InpIcebergs     = true;        // Detect icebergs
input double InpIceRatio     = 2.0;         // Traded volume >= ratio x displayed size
input double InpIceMinVol    = 20;          // Min traded volume at the level
input bool   InpIceLabels    = true;        // Show hidden size inside bubbles

input group "Display"
input string InpLabelFont    = "Segoe UI";  // Label font
input string InpFont         = "Consolas";  // Number font
input int    InpFontSize     = 9;           // Font size
input bool   InpShowHeader   = true;        // Header panel

//+------------------------------------------------------------------+
//| One candle of book + traded volume                               |
//+------------------------------------------------------------------+
class CHBar
  {
public:
   datetime t;              // MT5 bar open (server time)
   double   rawOff;         // broker - Hyperliquid offset estimate
   double   bp[], bs[];     // bids: price, size (Hyperliquid prices)
   double   ap[], as_[];    // asks
   double   vp[], vv[];     // traded volume profile: price, volume
   bool     hasBook, hasVP;
            CHBar(void) { t = 0; rawOff = 0; hasBook = false; hasVP = false; }
  };

//--- globals
CCanvas  g_cv;
string   g_cvName  = "LiquidityHeatmap_Canvas";
CHBar   *g_bars[];
int      g_n       = 0;
string   g_coin    = "";
double   g_block   = 0;
long     g_gmtOff  = 0;
bool     g_tester  = false;
string   g_status  = "Starting...";
bool     g_ok      = false;
bool     g_dirty   = true;
string   g_session = "";
int      g_rpcId   = 1;
uint     g_lastCall = 0;
uint     g_lastLive = 0;
bool     g_histEnd  = false;     // server has no older data (plan limit)
int      g_stage    = 0;         // 0 = book request next, 1 = volume profile next
datetime g_reqFrom  = 0;         // window being fetched (server time)
int      g_reqBars  = 0;
bool     g_reqLive  = false;
datetime g_floor    = 0;         // oldest window start already requested
int      g_empty    = 0;         // consecutive empty history windows

//--- palette (Institutional Dark, matches FootprintPro)
color C_PANEL  = C'17,21,27';
color C_BORDER = C'45,52,61';
color C_TEXT   = C'232,236,241';
color C_DIM    = C'125,133,144';
color C_WALL   = C'255,214,10';
color C_ICEBUY = C'0,220,170';
color C_ICESEL = C'255,70,160';
color C_OK     = C'0,200,140';
color C_ERR    = C'240,170,40';

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
uint Col(const color c, const int a) { return ColorToARGB(c, (uchar)MathMax(0, MathMin(255, a))); }
uint Rgba(const int r, const int g, const int b, const int a)
  {
   return ((uint)MathMax(0, MathMin(255, a)) << 24) | ((uint)r << 16) | ((uint)g << 8) | (uint)b;
  }

//--- OpenMarket-like gradient: purple -> blue -> teal -> yellow -> white
uint Heat(double t)
  {
   t = MathMax(0.0, MathMin(1.0, t));
   double st[5] = {0.0, 0.35, 0.6, 0.85, 1.0};
   double r[5]  = {90, 40, 0, 235, 255};
   double g[5]  = {30, 80, 205, 225, 255};
   double b[5]  = {150, 220, 165, 30, 255};
   int i = 0;
   while(i < 3 && t > st[i + 1]) i++;
   double f = (t - st[i]) / (st[i + 1] - st[i]);
   return Rgba((int)(r[i] + (r[i+1] - r[i]) * f), (int)(g[i] + (g[i+1] - g[i]) * f),
               (int)(b[i] + (b[i+1] - b[i]) * f), (int)(110 + 145 * t));
  }

string FmtSize(const double v)
  {
   if(v >= 10000) return DoubleToString(v / 1000.0, 0) + "k";
   if(v >= 1000)  return DoubleToString(v / 1000.0, 1) + "k";
   if(v >= 100)   return DoubleToString(v, 0);
   return DoubleToString(v, 1);
  }

string AutoCoin()
  {
   if(InpCoin != "") return InpCoin;
   string s = _Symbol;
   StringToUpper(s);
   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return "xyz:GOLD";
   if(StringFind(s, "NAS") >= 0 || StringFind(s, "NDX") >= 0 || StringFind(s, "USTEC") >= 0 ||
      StringFind(s, "US100") >= 0) return "xyz:XYZ100";
   if(StringFind(s, "SPX") >= 0 || StringFind(s, "US500") >= 0 || StringFind(s, "SP500") >= 0) return "xyz:SP500";
   if(StringFind(s, "XAG") >= 0 || StringFind(s, "SILVER") >= 0) return "xyz:SILVER";
   return "xyz:GOLD";
  }

//--- block size: nice step of ~1/8 of the average candle range
double AutoBlock()
  {
   if(InpBlockSize > 0) return InpBlockSize;
   int n = MathMin(100, Bars(_Symbol, _Period) - 1);
   double sum = 0;
   for(int i = 1; i <= n; i++) sum += iHigh(_Symbol, _Period, i) - iLow(_Symbol, _Period, i);
   double raw = (n > 0) ? sum / n / 8.0 : 1.0;
   double mag = MathPow(10.0, MathFloor(MathLog10(MathMax(raw, 1e-6))));
   double f = raw / mag;
   double nf = (f < 1.5) ? 1.0 : (f < 3.5) ? 2.0 : (f < 7.5) ? 5.0 : 10.0;
   return nf * mag;
  }

string OMInterval()
  {
   switch(_Period)
     {
      case PERIOD_M1:  return "MINUTE";
      case PERIOD_M5:  return "FIVE_MINUTES";
      case PERIOD_M15: return "FIFTEEN_MINUTES";
      case PERIOD_M30: return "THIRTY_MINUTES";
      case PERIOD_H1:  return "HOUR";
      case PERIOD_H4:  return "FOUR_HOURS";
      case PERIOD_D1:  return "DAY";
      case PERIOD_W1:  return "WEEK";
     }
   return "";
  }

string CacheName()
  {
   string c = g_coin;
   StringReplace(c, ":", "_");
   return "LiqHeat_" + c + "_" + StringSubstr(EnumToString(_Period), 7) + ".bin";
  }

//+------------------------------------------------------------------+
//| Bar store (sorted by time)                                       |
//+------------------------------------------------------------------+
int FindBar(const datetime t)
  {
   int lo = 0, hi = g_n - 1;
   while(lo <= hi)
     {
      int m = (lo + hi) / 2;
      if(g_bars[m].t == t) return m;
      if(g_bars[m].t < t) lo = m + 1; else hi = m - 1;
     }
   return -1;
  }

CHBar *GetOrAdd(const datetime t)
  {
   int lo = 0, hi = g_n - 1;
   while(lo <= hi)
     {
      int m = (lo + hi) / 2;
      if(g_bars[m].t == t) return g_bars[m];
      if(g_bars[m].t < t) lo = m + 1; else hi = m - 1;
     }
   CHBar *b = new CHBar;
   b.t = t;
   ArrayResize(g_bars, g_n + 1, 256);
   for(int i = g_n; i > lo; i--) g_bars[i] = g_bars[i - 1];
   g_bars[lo] = b;
   g_n++;
   return b;
  }

void ClearBars()
  {
   for(int i = 0; i < g_n; i++) if(CheckPointer(g_bars[i]) == POINTER_DYNAMIC) delete g_bars[i];
   ArrayResize(g_bars, 0);
   g_n = 0;
  }

datetime OldestBook()
  {
   for(int i = 0; i < g_n; i++) if(g_bars[i].hasBook) return g_bars[i].t;
   return 0;
  }

datetime NewestBook()
  {
   for(int i = g_n - 1; i >= 0; i--) if(g_bars[i].hasBook) return g_bars[i].t;
   return 0;
  }

//+------------------------------------------------------------------+
//| Cache                                                            |
//+------------------------------------------------------------------+
void WriteArr(const int h, const double &a[])
  {
   int n = ArraySize(a);
   FileWriteInteger(h, n);
   if(n > 0) FileWriteArray(h, a, 0, n);
  }

void ReadArr(const int h, double &a[])
  {
   int n = FileReadInteger(h);
   if(n < 0 || n > 100000) n = 0;
   ArrayResize(a, n);
   if(n > 0) FileReadArray(h, a, 0, n);
  }

void SaveCache()
  {
   if(g_tester || g_n == 0) return;
   int h = FileOpen(CacheName(), FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteInteger(h, 3);           // version
   FileWriteInteger(h, g_histEnd ? 1 : 0);
   FileWriteDouble(h, g_block);
   FileWriteLong(h, (long)g_floor);
   FileWriteInteger(h, g_n);
   for(int i = 0; i < g_n; i++)
     {
      CHBar *b = g_bars[i];
      FileWriteLong(h, (long)b.t);
      FileWriteDouble(h, b.rawOff);
      FileWriteInteger(h, (b.hasBook ? 1 : 0) | (b.hasVP ? 2 : 0));
      WriteArr(h, b.bp); WriteArr(h, b.bs); WriteArr(h, b.ap); WriteArr(h, b.as_);
      WriteArr(h, b.vp); WriteArr(h, b.vv);
     }
   FileClose(h);
  }

void LoadCache()
  {
   int h = FileOpen(CacheName(), FILE_READ | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   if(FileReadInteger(h) == 3)
     {
      g_histEnd = (FileReadInteger(h) == 1);
      double blk = FileReadDouble(h);
      g_floor = (datetime)FileReadLong(h);
      if(InpBlockSize <= 0 && blk > 0) g_block = blk;    // keep the grid the cache was built with
      else if(MathAbs(blk - g_block) > 1e-9) { FileClose(h); g_histEnd = false; g_floor = 0; return; }
      int n = FileReadInteger(h);
      for(int i = 0; i < n && !FileIsEnding(h); i++)
        {
         datetime t = (datetime)FileReadLong(h);
         CHBar *b = GetOrAdd(t);
         b.rawOff = FileReadDouble(h);
         int fl = FileReadInteger(h);
         b.hasBook = (fl & 1) != 0; b.hasVP = (fl & 2) != 0;
         ReadArr(h, b.bp); ReadArr(h, b.bs); ReadArr(h, b.ap); ReadArr(h, b.as_);
         ReadArr(h, b.vp); ReadArr(h, b.vv);
        }
     }
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| OpenMarket MCP client (Streamable HTTP, JSON-RPC)                |
//+------------------------------------------------------------------+
bool HttpPost(const string body, string &resp, string &hdrs, int &code)
  {
   string h = "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n"
              "Authorization: Bearer " + InpToken + "\r\nMCP-Protocol-Version: 2025-03-26\r\n";
   if(g_session != "") h += "Mcp-Session-Id: " + g_session + "\r\n";
   char data[], res[];
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   ArrayResize(data, MathMax(0, len));
   ResetLastError();
   code = WebRequest("POST", "https://mcp.openmarket.xyz/", h, 20000, data, res, hdrs);
   if(code == -1)
     {
      int err = GetLastError();
      g_status = (err == 4014) ? "Allow WebRequest: Tools > Options > Expert Advisors > add https://mcp.openmarket.xyz"
                               : "Connection error " + IntegerToString(err);
      return false;
     }
   resp = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
  }

string HeaderValue(const string hdrs, const string name)
  {
   string low = hdrs, key = name;
   StringToLower(low); StringToLower(key);
   int p = StringFind(low, key + ":");
   if(p < 0) return "";
   p += StringLen(key) + 1;
   int e = StringFind(hdrs, "\r\n", p);
   if(e < 0) e = StringLen(hdrs);
   string v = StringSubstr(hdrs, p, e - p);
   StringTrimLeft(v); StringTrimRight(v);
   return v;
  }

bool McpInit()
  {
   g_session = "";
   string resp, hdrs; int code;
   string body = "{\"jsonrpc\":\"2.0\",\"id\":" + IntegerToString(g_rpcId++) +
                 ",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},"
                 "\"clientInfo\":{\"name\":\"mt5-liquidity-heatmap\",\"version\":\"2.0\"}}}";
   if(!HttpPost(body, resp, hdrs, code)) return false;
   if(code == 401) { g_status = "Token rejected: check the OpenMarket agent token (Read access)"; return false; }
   if(code != 200) { g_status = "OpenMarket init HTTP " + IntegerToString(code); return false; }
   g_session = HeaderValue(hdrs, "Mcp-Session-Id");
   HttpPost("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", resp, hdrs, code);
   return true;
  }

//--- decode a JSON string body (between the quotes) into plain text
string JsonUnescape(const string s, int start, int &endPos)
  {
   ushort out[];
   int n = StringLen(s);
   ArrayResize(out, 0, n - start);
   int k = 0;
   int i = start;
   for(; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '"') break;
      if(c == '\\' && i + 1 < n)
        {
         ushort d = StringGetCharacter(s, ++i);
         if(d == 'n') c = '\n'; else if(d == 't') c = '\t'; else if(d == 'r') c = '\r';
         else if(d == 'u') { c = '?'; i += 4; }
         else c = d;
        }
      ArrayResize(out, k + 1, n - start);
      out[k++] = c;
     }
   endPos = i;
   return ShortArrayToString(out, 0, k);
  }

//--- call the `points` tool; returns the tool's JSON text
bool CallPoints(const string args, string &payload)
  {
   if(InpToken == "") { g_status = "Paste your OpenMarket agent token in the EA inputs"; return false; }
   if(g_session == "" && !McpInit()) return false;
   string body = "{\"jsonrpc\":\"2.0\",\"id\":" + IntegerToString(g_rpcId++) +
                 ",\"method\":\"tools/call\",\"params\":{\"name\":\"points\",\"arguments\":" + args + "}}";
   string resp, hdrs; int code;
   if(!HttpPost(body, resp, hdrs, code)) return false;
   if(code == 404 || code == 400)
     {
      // session expired: start a new one and retry once
      if(!McpInit()) return false;
      if(!HttpPost(body, resp, hdrs, code)) return false;
     }
   if(code == 401) { g_status = "Token rejected: check the OpenMarket agent token"; return false; }
   if(code != 200) { g_status = "OpenMarket HTTP " + IntegerToString(code); return false; }

   int sc = StringFind(resp, "\"structuredContent\":");
   if(sc >= 0) { payload = StringSubstr(resp, sc); }
   else
     {
      int tp = StringFind(resp, "\"text\":\"");
      if(tp < 0) { g_status = "Unexpected OpenMarket reply"; return false; }
      int endPos;
      payload = JsonUnescape(resp, tp + 8, endPos);
     }
   if(StringFind(resp, "\"isError\":true") >= 0 || StringFind(payload, "\"series\"") < 0)
     {
      string msg = payload;
      int mp = StringFind(payload, "\"message\":\"");
      if(mp >= 0) { int e2; msg = JsonUnescape(payload, mp + 11, e2); }
      g_status = "OpenMarket: " + StringSubstr(msg, 0, 110);
      if(StringFind(payload, "rate") >= 0) g_lastCall = GetTickCount() + 30000;   // back off
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Parse OpenMarket points                                          |
//+------------------------------------------------------------------+
int ParseNumbers(const string s, int from, double &out[])
  {
   int a = StringFind(s, "[", from);
   int e = StringFind(s, "]", a);
   ArrayResize(out, 0);
   if(a < 0 || e < 0) return 0;
   string body = StringSubstr(s, a + 1, e - a - 1);
   string parts[];
   int n = StringSplit(body, ',', parts);
   ArrayResize(out, n);
   for(int i = 0; i < n; i++) out[i] = StringToDouble(parts[i]);
   return n;
  }

datetime ParseTs(const string s, int from)
  {
   int p = StringFind(s, "\"timestamp\":{\"s\":", from);
   if(p < 0) return 0;
   p += 17;
   int e = p;
   while(e < StringLen(s) && StringGetCharacter(s, e) >= '0' && StringGetCharacter(s, e) <= '9') e++;
   return (datetime)StringToInteger(StringSubstr(s, p, e - p));
  }

datetime ToBarTime(const datetime utc)
  {
   datetime srv = (datetime)(utc + g_gmtOff);
   int sh = iBarShift(_Symbol, _Period, srv, false);
   if(sh < 0) return 0;
   return iTime(_Symbol, _Period, sh);
  }

int ApplyBook(const string js)
  {
   int count = 0, p = 0;
   while(true)
     {
      int b = StringFind(js, "\"bids\":", p);
      if(b < 0) break;
      int a = StringFind(js, "\"asks\":", b);
      if(a < 0) break;
      double bids[], asks[];
      ParseNumbers(js, b, bids);
      ParseNumbers(js, a, asks);
      datetime ts = ParseTs(js, a);
      p = a + 7;
      datetime bt = ToBarTime(ts);
      if(bt == 0 || ArraySize(bids) < 2 || ArraySize(asks) < 2) continue;
      CHBar *bar = GetOrAdd(bt);
      int nb = ArraySize(bids) / 2, na = ArraySize(asks) / 2;
      ArrayResize(bar.bp, nb); ArrayResize(bar.bs, nb);
      ArrayResize(bar.ap, na); ArrayResize(bar.as_, na);
      for(int i = 0; i < nb; i++) { bar.bp[i] = bids[2*i]; bar.bs[i] = bids[2*i+1]; }
      for(int i = 0; i < na; i++) { bar.ap[i] = asks[2*i]; bar.as_[i] = asks[2*i+1]; }
      bar.hasBook = true;
      count++;
     }
   return count;
  }

int ApplyVP(const string js)
  {
   int count = 0, p = 0;
   while(true)
     {
      int q = StringFind(js, "\"profile\":", p);
      if(q < 0) break;
      double v[];
      ParseNumbers(js, q, v);
      datetime ts = ParseTs(js, q);
      p = q + 10;
      datetime bt = ToBarTime(ts);
      if(bt == 0 || ArraySize(v) < 3) continue;
      CHBar *bar = GetOrAdd(bt);
      int n = ArraySize(v) / 3;
      ArrayResize(bar.vp, n); ArrayResize(bar.vv, n);
      for(int i = 0; i < n; i++) { bar.vp[i] = v[3*i]; bar.vv[i] = v[3*i+1] + v[3*i+2]; }
      bar.hasVP = true;
      count++;
     }
   return count;
  }

//--- offset estimate per bar: broker typical price - Hyperliquid VWAP (or book mid)
void UpdateOffsets()
  {
   for(int i = 0; i < g_n; i++)
     {
      CHBar *b = g_bars[i];
      int sh = iBarShift(_Symbol, _Period, b.t, true);
      if(sh < 0) continue;
      double typ = (iHigh(_Symbol, _Period, sh) + iLow(_Symbol, _Period, sh) + iClose(_Symbol, _Period, sh)) / 3.0;
      double hl = 0;
      if(b.hasVP)
        {
         double pv = 0, vs = 0;
         for(int k = 0; k < ArraySize(b.vp); k++) { pv += b.vp[k] * b.vv[k]; vs += b.vv[k]; }
         if(vs > 0) hl = pv / vs;
        }
      if(hl == 0 && b.hasBook && ArraySize(b.bp) > 0 && ArraySize(b.ap) > 0)
         hl = (b.bp[0] + b.ap[0]) / 2.0;
      if(hl > 0) b.rawOff = typ - hl;
     }
  }

//--- smoothed offset: median of the 7 nearest estimates
double Offset(const int idx)
  {
   if(!InpAutoOffset) return InpManualOffset;
   double w[];
   int k = 0;
   ArrayResize(w, 7);
   for(int j = MathMax(0, idx - 3); j <= MathMin(g_n - 1, idx + 3); j++)
      if(g_bars[j].rawOff != 0) w[k++] = g_bars[j].rawOff;
   if(k == 0) return 0;
   ArrayResize(w, k);
   ArraySort(w);
   return w[k / 2];
  }

//+------------------------------------------------------------------+
//| Request scheduler                                                |
//+------------------------------------------------------------------+
string Args(const string type, const datetime fromSrv, const int bars, const bool vp)
  {
   long fromMs = ((long)fromSrv - g_gmtOff) * 1000;
   int  mins   = (int)MathMax(1, bars * PeriodSeconds(_Period) / 60);
   string a = "{\"type\":\"" + type + "\",\"rawSymbol\":\"" + g_coin + "\",\"exchanges\":[\"" + InpExchange + "\"]," +
              "\"interval\":\"" + OMInterval() + "\",\"from\":" + IntegerToString(fromMs) +
              ",\"lookback\":\"" + ((mins % 60 == 0) ? IntegerToString(mins / 60) + "h" : IntegerToString(mins) + "m") + "\"";
   if(vp) a += ",\"detail\":\"full\",\"limit\":30";
   else   a += ",\"blockSize\":" + DoubleToString(g_block, 6) + ",\"maxDepth\":" + IntegerToString(InpDepth);
   return a + "}";
  }

//--- choose the next window to fetch; false = nothing to do
bool NextWindow(datetime &from, int &bars, bool &live)
  {
   int ps = PeriodSeconds(_Period);
   datetime now = iTime(_Symbol, _Period, 0);
   datetime newest = NewestBook(), oldest = OldestBook();
   live = false;

   //--- 1) nothing yet, or refresh of the latest bars
   if(newest == 0) { bars = InpChunkBars; from = (datetime)(now - (bars - 1) * ps); live = true; return true; }
   if(GetTickCount() - g_lastLive >= (uint)InpLiveRefresh * 1000 || now - newest > 3 * ps)
     {
      if(now - newest > 3 * ps)                    // gap since the cache was saved
        { from = newest; bars = (int)MathMin(InpChunkBars, (now - newest) / ps + 2); }
      else
        { bars = 3; from = (datetime)(now - 2 * ps); }
      live = true;
      return true;
     }
   if(g_histEnd) return false;

   //--- 2) the user scrolled to a period not in the cache
   int first = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   datetime visOld = iTime(_Symbol, _Period, MathMin(first, Bars(_Symbol, _Period) - 1));
   //--- 3) prefetch depth
   datetime pre = iTime(_Symbol, _Period, MathMin(InpPrefetchBars, Bars(_Symbol, _Period) - 1));
   datetime target = (visOld > 0 && visOld < pre) ? visOld : pre;
   datetime base = (g_floor > 0 && g_floor < oldest) ? g_floor : oldest;
   if(base > target)
     {
      bars = InpChunkBars;
      from = (datetime)(base - bars * ps);
      return true;
     }
   return false;
  }

void Scheduler()
  {
   if(g_tester) return;
   if(GetTickCount() < g_lastCall || GetTickCount() - g_lastCall < (uint)MathMax(2, InpRequestGap) * 1000) return;

   if(g_stage == 0)
     {
      if(!NextWindow(g_reqFrom, g_reqBars, g_reqLive)) { g_ok = true; if(StringFind(g_status, "Loading") == 0) g_status = "Live"; return; }
      g_lastCall = GetTickCount();
      string js;
      if(!CallPoints(Args("BLOCK_BOOK_SNAPSHOT_AGG", g_reqFrom, g_reqBars, false), js)) { g_ok = false; return; }
      int got = ApplyBook(js);
      if(!g_reqLive) { g_floor = g_reqFrom; g_empty = (got == 0) ? g_empty + 1 : 0; }
      if(g_empty >= 4) { g_histEnd = true; g_status = "Oldest data reached (plan history limit)"; }
      else g_status = "Loading " + TimeToString(g_reqFrom, TIME_DATE | TIME_MINUTES) + "  (" + IntegerToString(got) + " bars)";
      if(g_reqLive) g_lastLive = GetTickCount();
      g_ok = true;
      g_stage = (got > 0 && InpIcebergs) ? 1 : 0;
      g_dirty = true;
     }
   else
     {
      g_lastCall = GetTickCount();
      string js;
      if(CallPoints(Args("VOLUME_PROFILE_AGG", g_reqFrom, g_reqBars, true), js)) { ApplyVP(js); g_ok = true; }
      g_stage = 0;
      UpdateOffsets();
      g_dirty = true;
     }
  }

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
int    W, H;
double PMAX, PMIN;
int Yp(const double p) { return (int)MathRound((PMAX - p) / (PMAX - PMIN) * H); }

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

   int barPx = 1 << (int)ChartGetInteger(0, CHART_SCALE);
   int first = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   int nvis  = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   datetime limitT = g_tester ? TimeCurrent() : D'3000.01.01';   // no look-ahead in the tester
   double rowPx = g_block / (PMAX - PMIN) * H;

   //--- collect visible bars
   int idx[], xs[];
   ArrayResize(idx, 0, 512); ArrayResize(xs, 0, 512);
   double sample[];
   ArrayResize(sample, 0, 8192);
   for(int sh = first + 1; sh >= MathMax(0, first - nvis - 1); sh--)
     {
      datetime t = iTime(_Symbol, _Period, sh);
      if(t == 0 || t > limitT) continue;
      int i = FindBar(t);
      if(i < 0 || !g_bars[i].hasBook) continue;
      int x, y;
      if(!ChartTimePriceToXY(0, 0, t, PMIN, x, y)) continue;
      int k = ArraySize(idx);
      ArrayResize(idx, k + 1, 512); ArrayResize(xs, k + 1, 512);
      idx[k] = i; xs[k] = x;
      for(int j = 0; j < ArraySize(g_bars[i].bs); j++)  { int s = ArraySize(sample); ArrayResize(sample, s + 1, 8192); sample[s] = g_bars[i].bs[j]; }
      for(int j = 0; j < ArraySize(g_bars[i].as_); j++) { int s = ArraySize(sample); ArrayResize(sample, s + 1, 8192); sample[s] = g_bars[i].as_[j]; }
     }
   int ns = ArraySize(sample);
   double ref = 1, wallTh = DBL_MAX;
   if(ns > 0)
     {
      ArraySort(sample);
      ref    = MathMax(1e-9, sample[(int)MathMin(ns - 1, MathMax(0, ns * InpContrast))]);
      wallTh = sample[(int)MathMin(ns - 1, MathMax(0, ns * InpWallPct))];
     }

   //--- heatmap cells
   int cw = (InpStyle == HM_BLOCK) ? barPx : MathMax(1, (int)MathRound(barPx * 0.8));
   int dashH = (InpStyle == HM_BLOCK) ? MathMax(1, (int)MathRound(rowPx)) : (int)MathMax(1, MathMin(3, rowPx * 0.5));
   for(int k = 0; k < ArraySize(idx); k++)
     {
      CHBar *b = g_bars[idx[k]];
      double off = Offset(idx[k]);
      int x0 = xs[k] - cw / 2;
      for(int side = 0; side < 2; side++)
        {
         int n = (side == 0) ? ArraySize(b.bp) : ArraySize(b.ap);
         for(int j = 0; j < n; j++)
           {
            double p  = ((side == 0) ? b.bp[j] : b.ap[j]) + off;
            double sz = (side == 0) ? b.bs[j] : b.as_[j];
            double tt = sz / ref;
            if(tt < InpMinIntensity) continue;
            int yc = Yp(p + g_block / 2.0);
            if(yc < -4 || yc > H + 4) continue;
            if(InpWalls && sz >= wallTh) continue;              // drawn as a wall below
            g_cv.FillRectangle(x0, yc - dashH / 2, x0 + cw - 1, yc - dashH / 2 + dashH - 1, Heat(tt));
           }
        }
     }

   //--- walls: bright yellow, full bar width so consecutive bars join into lines
   if(InpWalls)
     {
      for(int k = 0; k < ArraySize(idx); k++)
        {
         CHBar *b = g_bars[idx[k]];
         double off = Offset(idx[k]);
         int x0 = xs[k] - barPx / 2;
         for(int side = 0; side < 2; side++)
           {
            int n = (side == 0) ? ArraySize(b.bp) : ArraySize(b.ap);
            for(int j = 0; j < n; j++)
              {
               double sz = (side == 0) ? b.bs[j] : b.as_[j];
               if(sz < wallTh) continue;
               double p = ((side == 0) ? b.bp[j] : b.ap[j]) + off;
               int yc = Yp(p + g_block / 2.0);
               if(yc < 0 || yc > H) continue;
               g_cv.FillRectangle(x0, yc - 1, x0 + barPx, yc, Col(sz >= wallTh * 1.5 ? clrWhite : C_WALL, 255));
              }
           }
        }
     }

   //--- icebergs: traded volume at a level >> displayed size, and the level held
   if(InpIcebergs)
     {
      double maxHidden = 0;
      double iceP[], iceH[]; int iceX[], iceS[];
      ArrayResize(iceP, 0, 64); ArrayResize(iceH, 0, 64); ArrayResize(iceX, 0, 64); ArrayResize(iceS, 0, 64);
      for(int k = 0; k < ArraySize(idx); k++)
        {
         int i = idx[k];
         CHBar *b = g_bars[i];
         if(!b.hasVP) continue;
         CHBar *ref0 = (i > 0 && g_bars[i - 1].hasBook) ? g_bars[i - 1] : b;   // liquidity shown before the candle
         int sh = iBarShift(_Symbol, _Period, b.t, true);
         if(sh < 0) continue;
         double off = Offset(i);
         double lowHL = iLow(_Symbol, _Period, sh) - off, highHL = iHigh(_Symbol, _Period, sh) - off;
         //--- traded volume per block
         double blkP[], blkV[];
         ArrayResize(blkP, 0, 64); ArrayResize(blkV, 0, 64);
         for(int q = 0; q < ArraySize(b.vp); q++)
           {
            double L = MathFloor(b.vp[q] / g_block) * g_block;
            int f = -1;
            for(int z = 0; z < ArraySize(blkP); z++) if(MathAbs(blkP[z] - L) < g_block * 0.01) { f = z; break; }
            if(f < 0) { f = ArraySize(blkP); ArrayResize(blkP, f + 1, 64); ArrayResize(blkV, f + 1, 64); blkP[f] = L; blkV[f] = 0; }
            blkV[f] += b.vv[q];
           }
         for(int z = 0; z < ArraySize(blkP); z++)
           {
            double L = blkP[z], V = blkV[z];
            if(V < InpIceMinVol) continue;
            //--- displayed size at this block (nearest book level)
            double D = 0, best = DBL_MAX; int side = -1;
            for(int j = 0; j < ArraySize(ref0.bp); j++) { double d = MathAbs(ref0.bp[j] - L); if(d < best && d < g_block) { best = d; D = ref0.bs[j]; side = 0; } }
            for(int j = 0; j < ArraySize(ref0.ap); j++) { double d = MathAbs(ref0.ap[j] - L); if(d < best && d < g_block) { best = d; D = ref0.as_[j]; side = 1; } }
            if(side < 0 || D <= 0 || V < InpIceRatio * D) continue;
            bool held = (side == 0) ? (lowHL >= L - g_block) : (highHL <= L + 2 * g_block);
            if(!held) continue;
            int c = ArraySize(iceP);
            ArrayResize(iceP, c + 1, 64); ArrayResize(iceH, c + 1, 64); ArrayResize(iceX, c + 1, 64); ArrayResize(iceS, c + 1, 64);
            iceP[c] = L + g_block / 2.0 + off; iceH[c] = V - D; iceX[c] = xs[k]; iceS[c] = side;
            maxHidden = MathMax(maxHidden, V - D);
           }
        }
      g_cv.FontSet(InpFont, -(InpFontSize - 1) * 10, FW_BOLD);
      for(int c = 0; c < ArraySize(iceP); c++)
        {
         int y = Yp(iceP[c]);
         if(y < 0 || y > H) continue;
         int r = (int)MathRound(5 + 11 * MathSqrt(iceH[c] / MathMax(maxHidden, 1e-9)));
         color cc = (iceS[c] == 0) ? C_ICEBUY : C_ICESEL;
         g_cv.FillCircle(iceX[c], y, r, Col(cc, 120));
         g_cv.Circle(iceX[c], y, r, Col(cc, 255));
         if(InpIceLabels && r >= 9)
            g_cv.TextOut(iceX[c], y, FmtSize(iceH[c]), Col(clrWhite, 255), TA_CENTER | TA_VCENTER);
        }
     }

   //--- header
   if(InpShowHeader)
     {
      g_cv.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
      string title = "LIQUIDITY HEATMAP";
      int tw = g_cv.TextWidth(title);
      g_cv.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
      datetime o = OldestBook();
      string l2 = g_coin + " -> " + _Symbol + "   block " + DoubleToString(g_block, 2) +
                  "   cache " + (o > 0 ? TimeToString(o, TIME_DATE) : "-") + " .. now";
      string l3 = g_tester ? "Strategy Tester: cache only, no look-ahead" : g_status;
      int pw = MathMax(tw, MathMax(g_cv.TextWidth(l2), g_cv.TextWidth(l3))) + 24;
      int lh = InpFontSize + 8, ph = lh * 3 + 10;
      int px = 10, py = 26;
      color sc = (g_ok || g_tester) ? C_OK : C_ERR;
      g_cv.FillRectangle(px, py, px + pw, py + ph, Col(C_PANEL, 240));
      g_cv.Rectangle(px, py, px + pw, py + ph, Col(C_BORDER, 255));
      g_cv.FillRectangle(px, py, px + 2, py + ph, Col(sc, 255));
      g_cv.FontSet(InpLabelFont, -(InpFontSize + 1) * 10, FW_BOLD);
      g_cv.TextOut(px + 10, py + 5, title, Col(C_TEXT, 255), TA_LEFT | TA_TOP);
      g_cv.FontSet(InpLabelFont, -InpFontSize * 10, FW_NORMAL);
      g_cv.TextOut(px + 10, py + 5 + lh, l2, Col(C_DIM, 255), TA_LEFT | TA_TOP);
      g_cv.TextOut(px + 10, py + 5 + 2 * lh, l3, Col(sc, 255), TA_LEFT | TA_TOP);
     }
   g_cv.Update(false);
  }

//+------------------------------------------------------------------+
//| EA events                                                        |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_tester = (bool)MQLInfoInteger(MQL_TESTER);
   g_coin   = AutoCoin();
   g_block  = AutoBlock();
   if(OMInterval() == "") { Print("LiquidityHeatmap: use M1, M5, M15, M30, H1, H4, D1 or W1"); return INIT_FAILED; }
   long off = (long)(TimeTradeServer() - TimeGMT());
   g_gmtOff = (long)MathRound(off / 900.0) * 900;

   int w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(!g_cv.CreateBitmapLabel(0, 0, g_cvName, 0, 0, MathMax(w, 1), MathMax(h, 1), COLOR_FORMAT_ARGB_NORMALIZE))
      return INIT_FAILED;
   ObjectSetInteger(0, g_cvName, OBJPROP_BACK, true);       // candles stay on top
   ObjectSetInteger(0, g_cvName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_cvName, OBJPROP_HIDDEN, true);

   LoadCache();
   UpdateOffsets();
   if(g_tester && g_n == 0)
      g_status = "No cache: run the EA on a live chart first to download history";
   EventSetMillisecondTimer(200);
   Print("LiquidityHeatmap: ", g_coin, " -> ", _Symbol, " block ", g_block, ". Display only, no trades are placed.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveCache();
   ClearBars();
   g_cv.Destroy();
   ChartRedraw();
  }

void OnTick()
  {
   // no trading logic by design; in the tester redraw on each new bar
   static datetime lastBar = 0;
   if(g_tester && iTime(_Symbol, _Period, 0) != lastBar) { lastBar = iTime(_Symbol, _Period, 0); g_dirty = true; }
  }

void OnTimer()
  {
   static uint lastDraw = 0, lastSave = 0;
   Scheduler();
   if(g_dirty && GetTickCount() - lastDraw >= 150)
     {
      Redraw();
      ChartRedraw();
      g_dirty = false;
      lastDraw = GetTickCount();
     }
   if(!g_tester && GetTickCount() - lastSave >= 300000) { SaveCache(); lastSave = GetTickCount(); }
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE) g_dirty = true;
  }
//+------------------------------------------------------------------+

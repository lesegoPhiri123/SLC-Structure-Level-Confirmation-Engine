//+------------------------------------------------------------------+
//| SLC_Engine.mq5                                                   |
//| Structure, Level, Confirmation Engine                            |
//|                                                                    |
//| HTF structure gates which side is tradeable. LTF supply/demand   |
//| zones are extracted from expansion legs. A Stochastic crossover  |
//| inside a zone confirms entry. Orders are sized off account risk  |
//| with a static 2R target. Live state is exported for the web UI.  |
//|                                                                    |
//| Single-file build: everything the modular Include/SLC/*.mqh      |
//| version had is inlined below so this compiles on its own -- just |
//| drop this file into MQL5/Experts and hit F7 in MetaEditor.       |
//+------------------------------------------------------------------+
#property copyright "SLC Engine"
#property version   "1.00"

#include <Trade/Trade.mqh>

//====================================================================
// Types
//====================================================================

enum ENUM_HTF_STATE
{
   HTF_UPTREND,
   HTF_DOWNTREND,
   HTF_CONSOLIDATION
};

enum ENUM_ZONE_TYPE
{
   ZONE_SUPPLY,
   ZONE_DEMAND
};

enum ENUM_ZONE_STATUS
{
   ZONE_ACTIVE,
   ZONE_BROKEN,
   ZONE_EXPIRED,
   ZONE_TRADED
};

enum ENUM_SIGNAL_DIR
{
   SIGNAL_SHORT,
   SIGNAL_LONG
};

// One supply/demand zone and its full lifecycle + confirmation state.
struct SZone
{
   long              id;
   ENUM_ZONE_TYPE    type;
   double            low;
   double            high;
   datetime          time;             // time of the base (origin) candle
   int               touches;
   ENUM_ZONE_STATUS  status;
   bool              flipped;          // true if reactivated via break-and-retest
   bool              insideLastBar;    // touch-counting state
   bool              armed;            // confirmation state machine
   int               barsSinceArmed;
};

struct SSignalEvent
{
   datetime        time;
   ENUM_SIGNAL_DIR dir;
   long            zoneId;
   double          kValue;
};

struct STradeEvent
{
   datetime        time;
   ENUM_SIGNAL_DIR dir;
   double          entry;
   double          sl;
   double          tp;
   double          lots;
};

//====================================================================
// Step 1: HTF structure filter (macro regime detection)
//====================================================================
class CStructureFilter
{
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_htf;
   int               m_swingLookback;
   int               m_scanBars;
   datetime          m_lastBarTime;
   ENUM_HTF_STATE    m_state;

   bool ScanSwings(double &swingHighs[], datetime &swingHighTimes[],
                    double &swingLows[], datetime &swingLowTimes[], int need)
     {
      double high[], low[];
      datetime time[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      ArraySetAsSeries(time, true);

      int copied = CopyHigh(m_symbol, m_htf, 1, m_scanBars, high);
      if(copied <= 0) return false;
      CopyLow(m_symbol, m_htf, 1, m_scanBars, low);
      CopyTime(m_symbol, m_htf, 1, m_scanBars, time);

      int total = ArraySize(high);
      int n = m_swingLookback;
      int foundH = 0, foundL = 0;
      ArrayResize(swingHighs, need);
      ArrayResize(swingHighTimes, need);
      ArrayResize(swingLows, need);
      ArrayResize(swingLowTimes, need);

      for(int i = n; i < total - n && (foundH < need || foundL < need); i++)
        {
         if(foundH < need)
           {
            bool isHigh = true;
            for(int j = i - n; j <= i + n; j++)
              {
               if(j == i) continue;
               if(high[j] > high[i]) { isHigh = false; break; }
              }
            if(isHigh)
              {
               swingHighs[foundH] = high[i];
               swingHighTimes[foundH] = time[i];
               foundH++;
              }
           }
         if(foundL < need)
           {
            bool isLow = true;
            for(int j = i - n; j <= i + n; j++)
              {
               if(j == i) continue;
               if(low[j] < low[i]) { isLow = false; break; }
              }
            if(isLow)
              {
               swingLows[foundL] = low[i];
               swingLowTimes[foundL] = time[i];
               foundL++;
              }
           }
        }

      ArrayResize(swingHighs, foundH);
      ArrayResize(swingHighTimes, foundH);
      ArrayResize(swingLows, foundL);
      ArrayResize(swingLowTimes, foundL);

      return (foundH >= 2 && foundL >= 2);
     }

public:
   void Init(string symbol, ENUM_TIMEFRAMES htf, int swingLookback, int scanBars = 300)
     {
      m_symbol = symbol;
      m_htf = htf;
      m_swingLookback = swingLookback;
      m_scanBars = scanBars;
      m_lastBarTime = 0;
      m_state = HTF_CONSOLIDATION;
     }

   bool IsNewBar()
     {
      datetime t[];
      ArraySetAsSeries(t, true);
      if(CopyTime(m_symbol, m_htf, 0, 1, t) <= 0) return false;
      if(t[0] != m_lastBarTime)
        {
         m_lastBarTime = t[0];
         return true;
        }
      return false;
     }

   // Recompute the regime. Call once per new HTF bar.
   void Update()
     {
      double swingHighs[], swingLows[];
      datetime swingHighTimes[], swingLowTimes[];

      if(!ScanSwings(swingHighs, swingHighTimes, swingLows, swingLowTimes, 2))
        {
         m_state = HTF_CONSOLIDATION;
         return;
        }

      bool higherHigh = swingHighs[0] > swingHighs[1];
      bool higherLow  = swingLows[0]  > swingLows[1];
      bool lowerHigh  = swingHighs[0] < swingHighs[1];
      bool lowerLow   = swingLows[0]  < swingLows[1];

      if(higherHigh && higherLow)
         m_state = HTF_UPTREND;
      else if(lowerHigh && lowerLow)
         m_state = HTF_DOWNTREND;
      else
         m_state = HTF_CONSOLIDATION;
     }

   ENUM_HTF_STATE State() const { return m_state; }

   string StateText() const
     {
      switch(m_state)
        {
         case HTF_UPTREND:   return "UPTREND";
         case HTF_DOWNTREND: return "DOWNTREND";
         default:             return "CONSOLIDATION";
        }
     }
};

//====================================================================
// Step 2: LTF supply/demand zone extraction + lifecycle
//====================================================================
class CZoneManager
{
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_ltf;
   double            m_expansionAtrMult;
   int               m_atrPeriod;
   int               m_searchWindow;
   int               m_expiryTouches;
   int               m_maxActiveZones;
   int               m_historyCap;
   long              m_nextId;
   datetime          m_lastBarTime;
   int               m_atrHandle;

   SZone             m_zones[];

   double AtrValue()
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_atrHandle, 0, 1, 1, buf) <= 0) return 0.0;
      return buf[0];
     }

   int ActiveCount()
     {
      int c = 0;
      for(int i = 0; i < ArraySize(m_zones); i++)
         if(m_zones[i].status == ZONE_ACTIVE) c++;
      return c;
     }

   // Drop the oldest active zone to make room for a new one.
   void EvictOldestActive()
     {
      int oldestIdx = -1;
      datetime oldestTime = 0;
      for(int i = 0; i < ArraySize(m_zones); i++)
        {
         if(m_zones[i].status != ZONE_ACTIVE) continue;
         if(oldestIdx == -1 || m_zones[i].time < oldestTime)
           {
            oldestIdx = i;
            oldestTime = m_zones[i].time;
           }
        }
      if(oldestIdx != -1)
         m_zones[oldestIdx].status = ZONE_EXPIRED;
     }

   bool HasZoneAt(datetime baseTime)
     {
      for(int i = 0; i < ArraySize(m_zones); i++)
         if(m_zones[i].time == baseTime) return true;
      return false;
     }

   // Keeps the zone history (all statuses, used for drawing/export) from
   // growing without bound over a long-running live session. Drops the
   // oldest already-retired (expired/traded) zones first.
   void Prune()
     {
      int total = ArraySize(m_zones);
      if(total <= m_historyCap) return;

      int toDrop = total - m_historyCap;
      SZone kept[];
      int k = 0, dropped = 0;
      for(int i = 0; i < total; i++)
        {
         bool removable = (m_zones[i].status == ZONE_EXPIRED || m_zones[i].status == ZONE_TRADED);
         if(removable && dropped < toDrop)
           {
            dropped++;
            continue;
           }
         ArrayResize(kept, k + 1);
         kept[k] = m_zones[i];
         k++;
        }
      ArrayResize(m_zones, k);
      for(int i = 0; i < k; i++)
         m_zones[i] = kept[i];
     }

   void AddZone(ENUM_ZONE_TYPE type, double low, double high, datetime baseTime)
     {
      if(HasZoneAt(baseTime)) return;
      if(ActiveCount() >= m_maxActiveZones) EvictOldestActive();
      Prune();

      int n = ArraySize(m_zones);
      ArrayResize(m_zones, n + 1);
      m_zones[n].id = m_nextId++;
      m_zones[n].type = type;
      m_zones[n].low = low;
      m_zones[n].high = high;
      m_zones[n].time = baseTime;
      m_zones[n].touches = 0;
      m_zones[n].status = ZONE_ACTIVE;
      m_zones[n].flipped = false;
      m_zones[n].insideLastBar = false;
      m_zones[n].armed = false;
      m_zones[n].barsSinceArmed = 0;
     }

public:
   void Init(string symbol, ENUM_TIMEFRAMES ltf, double expansionAtrMult, int atrPeriod,
             int searchWindow, int expiryTouches, int maxActiveZones, int historyCap = 200)
     {
      m_symbol = symbol;
      m_ltf = ltf;
      m_expansionAtrMult = expansionAtrMult;
      m_atrPeriod = atrPeriod;
      m_searchWindow = searchWindow;
      m_expiryTouches = expiryTouches;
      m_maxActiveZones = maxActiveZones;
      m_historyCap = historyCap;
      m_nextId = 1;
      m_lastBarTime = 0;
      ArrayResize(m_zones, 0);
      m_atrHandle = iATR(m_symbol, m_ltf, m_atrPeriod);
     }

   bool IsNewBar()
     {
      datetime t[];
      ArraySetAsSeries(t, true);
      if(CopyTime(m_symbol, m_ltf, 0, 1, t) <= 0) return false;
      if(t[0] != m_lastBarTime)
        {
         m_lastBarTime = t[0];
         return true;
        }
      return false;
     }

   // Scan for a fresh zone. Only extracts the type authorized by the HTF gate.
   void ScanForNewZone(ENUM_HTF_STATE htfState)
     {
      if(htfState == HTF_CONSOLIDATION) return;

      double atr = AtrValue();
      if(atr <= 0) return;

      double open[], close[], high[], low[];
      datetime time[];
      ArraySetAsSeries(open, true);
      ArraySetAsSeries(close, true);
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      ArraySetAsSeries(time, true);

      int copied = CopyOpen(m_symbol, m_ltf, 1, m_searchWindow + 2, open);
      if(copied <= 2) return;
      CopyClose(m_symbol, m_ltf, 1, m_searchWindow + 2, close);
      CopyHigh(m_symbol, m_ltf, 1, m_searchWindow + 2, high);
      CopyLow(m_symbol, m_ltf, 1, m_searchWindow + 2, low);
      CopyTime(m_symbol, m_ltf, 1, m_searchWindow + 2, time);

      int total = ArraySize(open);
      bool wantSupply = (htfState == HTF_DOWNTREND);

      for(int i = 0; i < total - 1 && i < m_searchWindow; i++)
        {
         double range = MathAbs(close[i] - open[i]);
         bool isExpansion = (range >= m_expansionAtrMult * atr);
         bool isBearish = close[i] < open[i];
         bool isBullish = close[i] > open[i];

         if(wantSupply && isExpansion && isBearish)
           {
            int base = i + 1; // candle immediately before the leg (older)
            if(close[base] > open[base]) // last bullish candle
              {
               AddZone(ZONE_SUPPLY, low[base], high[base], time[base]);
               return; // only need the most recent one per scan
              }
           }
         else if(!wantSupply && isExpansion && isBullish)
           {
            int base = i + 1;
            if(close[base] < open[base]) // last bearish candle
              {
               AddZone(ZONE_DEMAND, low[base], high[base], time[base]);
               return;
              }
           }
        }
     }

   // Touch counting, expiry, break, and break-and-retest flip.
   // Call once per new LTF bar with the just-closed bar's OHLC.
   void UpdateLifecycle(ENUM_HTF_STATE htfState, double barClose)
     {
      for(int i = 0; i < ArraySize(m_zones); i++)
        {
         SZone z = m_zones[i];
         bool isInside = (barClose >= z.low && barClose <= z.high);

         if(z.status == ZONE_ACTIVE)
           {
            if(z.insideLastBar && !isInside)
              {
               z.touches++;
               if(z.touches >= m_expiryTouches)
                  z.status = ZONE_EXPIRED;
              }

            if(z.status == ZONE_ACTIVE)
              {
               if(z.type == ZONE_SUPPLY && barClose > z.high)
                  z.status = ZONE_BROKEN;
               else if(z.type == ZONE_DEMAND && barClose < z.low)
                  z.status = ZONE_BROKEN;
              }
           }
         else if(z.status == ZONE_BROKEN)
           {
            // Break-and-retest: clean close back through the zone, but only
            // while the HTF structure is still aligned with the zone's bias.
            if(z.type == ZONE_SUPPLY && barClose < z.low && htfState == HTF_DOWNTREND)
              {
               z.status = ZONE_ACTIVE;
               z.flipped = true;
               z.touches = 0;
              }
            else if(z.type == ZONE_DEMAND && barClose > z.high && htfState == HTF_UPTREND)
              {
               z.status = ZONE_ACTIVE;
               z.flipped = true;
               z.touches = 0;
              }
           }

         z.insideLastBar = isInside;
         m_zones[i] = z;
        }
     }

   void MarkTraded(long zoneId)
     {
      for(int i = 0; i < ArraySize(m_zones); i++)
         if(m_zones[i].id == zoneId)
            m_zones[i].status = ZONE_TRADED;
     }

   int Count() const { return ArraySize(m_zones); }
   SZone GetByIndex(int i) const { return m_zones[i]; }

   void SetZone(int i, const SZone &z) { m_zones[i] = z; }

   // Active zones matching the direction currently authorized by the HTF gate.
   int GetTradeable(ENUM_HTF_STATE htfState, long &ids[])
     {
      ArrayResize(ids, 0);
      ENUM_ZONE_TYPE want = (htfState == HTF_DOWNTREND) ? ZONE_SUPPLY : ZONE_DEMAND;
      if(htfState == HTF_CONSOLIDATION) return 0;

      int n = 0;
      for(int i = 0; i < ArraySize(m_zones); i++)
        {
         if(m_zones[i].status == ZONE_ACTIVE && m_zones[i].type == want)
           {
            ArrayResize(ids, n + 1);
            ids[n] = m_zones[i].id;
            n++;
           }
        }
      return n;
     }

   int IndexOfId(long id)
     {
      for(int i = 0; i < ArraySize(m_zones); i++)
         if(m_zones[i].id == id) return i;
      return -1;
     }
};

//====================================================================
// Step 3: Stochastic confirmation gate
//====================================================================
class CConfirmationEngine
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_ltf;
   int             m_handle;
   double          m_overbought;
   double          m_oversold;
   int             m_maxBarsToConfirm;

   bool KValues(double &kNow, double &kPrev)
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_handle, 0, 1, 2, buf) < 2) return false;
      kNow = buf[0];
      kPrev = buf[1];
      return true;
     }

public:
   void Init(string symbol, ENUM_TIMEFRAMES ltf, int kPeriod, int dPeriod, int slowing,
             double overbought, double oversold, int maxBarsToConfirm)
     {
      m_symbol = symbol;
      m_ltf = ltf;
      m_overbought = overbought;
      m_oversold = oversold;
      m_maxBarsToConfirm = maxBarsToConfirm;
      m_handle = iStochastic(m_symbol, m_ltf, kPeriod, dPeriod, slowing, MODE_SMA, STO_LOWHIGH);
     }

   int Handle() const { return m_handle; }

   // Call once per new LTF bar for each currently active, tradeable zone.
   // Mutates zone.armed / zone.barsSinceArmed in place. Returns true and
   // sets dir + kOut when a confirmation fires this bar.
   bool CheckZone(SZone &zone, double barHigh, double barLow, ENUM_SIGNAL_DIR &dir, double &kOut)
     {
      double kNow, kPrev;
      if(!KValues(kNow, kPrev)) return false;

      bool touchingZone = (barLow <= zone.high && barHigh >= zone.low);
      bool isSupply = (zone.type == ZONE_SUPPLY);
      dir = isSupply ? SIGNAL_SHORT : SIGNAL_LONG;
      kOut = kNow;

      if(!zone.armed)
        {
         if(touchingZone)
           {
            if(isSupply && kNow > m_overbought)
              {
               zone.armed = true;
               zone.barsSinceArmed = 0;
              }
            else if(!isSupply && kNow < m_oversold)
              {
               zone.armed = true;
               zone.barsSinceArmed = 0;
              }
           }
         return false;
        }

      // Already armed: look for the crossback, or time/price out.
      zone.barsSinceArmed++;

      if(isSupply && kPrev >= m_overbought && kNow < m_overbought)
        {
         zone.armed = false;
         return true;
        }
      if(!isSupply && kPrev <= m_oversold && kNow > m_oversold)
        {
         zone.armed = false;
         return true;
        }

      // Abandon: ran out of bars, or price left the zone without confirming.
      if(zone.barsSinceArmed > m_maxBarsToConfirm || !touchingZone)
        {
         zone.armed = false;
        }

      return false;
     }
};

//====================================================================
// Step 4: order parameters & risk matrix
//====================================================================
class CRiskExecutor
{
private:
   CTrade   m_trade;
   string   m_symbol;
   double   m_riskPercent;
   double   m_rr;
   double   m_bufferPoints;

   double CalcLots(double slDistance)
     {
      double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0 || tickSize <= 0 || slDistance <= 0) return 0.0;

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * (m_riskPercent / 100.0);
      double lossPerLot = (slDistance / tickSize) * tickValue;
      if(lossPerLot <= 0) return 0.0;

      double lots = riskAmount / lossPerLot;

      double minLot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0) lotStep = 0.01;

      lots = MathFloor(lots / lotStep) * lotStep;
      lots = MathMax(minLot, MathMin(maxLot, lots));
      return lots;
     }

public:
   void Init(string symbol, double riskPercent, double rr, double bufferPoints, ulong magic)
     {
      m_symbol = symbol;
      m_riskPercent = riskPercent;
      m_rr = rr;
      m_bufferPoints = bufferPoints;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetTypeFillingBySymbol(m_symbol);
     }

   // Returns true and fills the trade parameters on a successful order send.
   bool Execute(ENUM_SIGNAL_DIR dir, const SZone &zone,
                double &outEntry, double &outSL, double &outTP, double &outLots)
     {
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double buffer = m_bufferPoints * point;

      bool ok;
      if(dir == SIGNAL_SHORT)
        {
         double entry = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         double sl = zone.high + buffer;
         double risk = sl - entry;
         if(risk <= 0) return false;
         double tp = entry - m_rr * risk;
         double lots = CalcLots(risk);
         if(lots <= 0) return false;

         ok = m_trade.Sell(lots, m_symbol, 0.0, sl, tp, "SLC short");
         outEntry = entry; outSL = sl; outTP = tp; outLots = lots;
        }
      else
        {
         double entry = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         double sl = zone.low - buffer;
         double risk = entry - sl;
         if(risk <= 0) return false;
         double tp = entry + m_rr * risk;
         double lots = CalcLots(risk);
         if(lots <= 0) return false;

         ok = m_trade.Buy(lots, m_symbol, 0.0, sl, tp, "SLC long");
         outEntry = entry; outSL = sl; outTP = tp; outLots = lots;
        }

      return ok;
     }
};

//====================================================================
// Drawing: zone rectangles, regime label, signal/trade markers
//====================================================================
class CDrawer
{
private:
   string m_prefix;

   color ZoneColor(const SZone &z)
     {
      if(z.status == ZONE_BROKEN) return clrGray;
      if(z.flipped) return clrGold;
      return (z.type == ZONE_SUPPLY) ? clrOrangeRed : clrDeepSkyBlue;
     }

   string ZoneObjName(long id) { return m_prefix + "Zone_" + IntegerToString(id); }

public:
   void Init(string prefix) { m_prefix = prefix; }

   void DrawZone(const SZone &z)
     {
      string name = ZoneObjName(z.id);

      if(z.status == ZONE_EXPIRED || z.status == ZONE_TRADED)
        {
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
         return;
        }

      datetime rightEdge = TimeCurrent() + PeriodSeconds(PERIOD_M5) * 20;

      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, z.time, z.high, rightEdge, z.low);
         ObjectSetInteger(0, name, OBJPROP_FILL, true);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
        }

      ObjectSetInteger(0, name, OBJPROP_TIME, 0, z.time);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, z.high);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, rightEdge);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, z.low);
      ObjectSetInteger(0, name, OBJPROP_COLOR, ZoneColor(z));
      ObjectSetInteger(0, name, OBJPROP_STYLE, (z.status == ZONE_BROKEN) ? STYLE_DOT : STYLE_SOLID);
     }

   void DrawSignal(datetime t, double price, ENUM_SIGNAL_DIR dir)
     {
      string name = m_prefix + "Sig_" + IntegerToString((long)t) + "_" + IntegerToString((int)dir);
      if(ObjectFind(0, name) >= 0) return;
      ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, (dir == SIGNAL_SHORT) ? 218 : 217);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }

   void DrawTrade(datetime t, double price, ENUM_SIGNAL_DIR dir)
     {
      string name = m_prefix + "Trade_" + IntegerToString((long)t) + "_" + IntegerToString((int)dir);
      if(ObjectFind(0, name) >= 0) return;
      ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159);
      ObjectSetInteger(0, name, OBJPROP_COLOR, (dir == SIGNAL_SHORT) ? clrRed : clrLime);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }

   void UpdateRegimeLabel(string htfStateText, int activeZones)
     {
      string name = m_prefix + "RegimeLabel";
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 15);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
        }
      ObjectSetString(0, name, OBJPROP_TEXT,
                       StringFormat("SLC | HTF: %s | Active zones: %d", htfStateText, activeZones));
      ObjectSetInteger(0, name, OBJPROP_COLOR,
                        (htfStateText == "UPTREND") ? clrLime :
                        (htfStateText == "DOWNTREND") ? clrRed : clrSilver);
     }
};

//====================================================================
// Export: writes live state to <Common Files>/SLC/state.json + trades.csv
// MQL5 has no built-in JSON library, so this hand-rolls one.
//====================================================================
class CExporter
{
private:
   string m_folder;
   string m_symbol;
   int    m_maxCandles;

   string JsonEscape(string s)
     {
      StringReplace(s, "\\", "\\\\");
      StringReplace(s, "\"", "\\\"");
      return s;
     }

   string P(double price) { return DoubleToString(price, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)); }

   string ZoneTypeText(ENUM_ZONE_TYPE t) { return (t == ZONE_SUPPLY) ? "supply" : "demand"; }
   string ZoneStatusText(ENUM_ZONE_STATUS s)
     {
      switch(s)
        {
         case ZONE_ACTIVE:  return "active";
         case ZONE_BROKEN:  return "broken";
         case ZONE_EXPIRED: return "expired";
         default:           return "traded";
        }
     }
   string DirText(ENUM_SIGNAL_DIR d) { return (d == SIGNAL_SHORT) ? "short" : "long"; }

public:
   void Init(string symbol, int maxCandles = 300)
     {
      m_symbol = symbol;
      m_folder = "SLC";
      m_maxCandles = maxCandles;
      FolderCreate(m_folder, FILE_COMMON);
     }

   void Export(ENUM_TIMEFRAMES htf, ENUM_TIMEFRAMES ltf, string htfStateText,
               CZoneManager &zones, const SSignalEvent &signals[], const STradeEvent &trades[])
     {
      string json = "{\n";
      json += StringFormat("\"symbol\":\"%s\",\n", JsonEscape(m_symbol));
      json += StringFormat("\"htf\":\"%s\",\n", EnumToString(htf));
      json += StringFormat("\"ltf\":\"%s\",\n", EnumToString(ltf));
      json += StringFormat("\"htf_state\":\"%s\",\n", htfStateText);
      json += StringFormat("\"updated\":\"%s\",\n", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));

      // --- candles ---
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int n = CopyRates(m_symbol, ltf, 0, m_maxCandles, rates);
      json += "\"candles\":[";
      for(int i = n - 1; i >= 0; i--)
        {
         json += StringFormat("{\"t\":%d,\"o\":%s,\"h\":%s,\"l\":%s,\"c\":%s}",
                               (int)rates[i].time, P(rates[i].open), P(rates[i].high),
                               P(rates[i].low), P(rates[i].close));
         if(i > 0) json += ",";
        }
      json += "],\n";

      // --- zones ---
      json += "\"zones\":[";
      bool firstZone = true;
      for(int i = 0; i < zones.Count(); i++)
        {
         SZone z = zones.GetByIndex(i);
         if(!firstZone) json += ",";
         firstZone = false;
         json += StringFormat("{\"id\":%d,\"type\":\"%s\",\"low\":%s,\"high\":%s,\"time\":%d,\"status\":\"%s\",\"touches\":%d,\"flipped\":%s}",
                               (int)z.id, ZoneTypeText(z.type), P(z.low), P(z.high),
                               (int)z.time, ZoneStatusText(z.status), z.touches,
                               z.flipped ? "true" : "false");
        }
      json += "],\n";

      // --- recent confirmation signals ---
      json += "\"signals\":[";
      for(int i = 0; i < ArraySize(signals); i++)
        {
         if(i > 0) json += ",";
         json += StringFormat("{\"time\":%d,\"dir\":\"%s\",\"zone_id\":%d,\"k\":%s}",
                               (int)signals[i].time, DirText(signals[i].dir),
                               (int)signals[i].zoneId, P(signals[i].kValue));
        }
      json += "],\n";

      // --- recent trades ---
      json += "\"trades\":[";
      for(int i = 0; i < ArraySize(trades); i++)
        {
         if(i > 0) json += ",";
         json += StringFormat("{\"time\":%d,\"dir\":\"%s\",\"entry\":%s,\"sl\":%s,\"tp\":%s,\"lots\":%s}",
                               (int)trades[i].time, DirText(trades[i].dir), P(trades[i].entry),
                               P(trades[i].sl), P(trades[i].tp), DoubleToString(trades[i].lots, 2));
        }
      json += "]\n}";

      int handle = FileOpen(m_folder + "\\state.json", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(handle != INVALID_HANDLE)
        {
         FileWriteString(handle, json);
         FileClose(handle);
        }
     }

   void AppendTradeCsv(const STradeEvent &tr)
     {
      bool exists = FileIsExist(m_folder + "\\trades.csv", FILE_COMMON);
      int handle = FileOpen(m_folder + "\\trades.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
      if(handle == INVALID_HANDLE) return;
      if(!exists)
         FileWrite(handle, "time", "dir", "entry", "sl", "tp", "lots");
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(tr.time, TIME_DATE | TIME_SECONDS), DirText(tr.dir),
                P(tr.entry), P(tr.sl), P(tr.tp), DoubleToString(tr.lots, 2));
      FileClose(handle);
     }
};

//====================================================================
// EA inputs
//====================================================================
input group "Timeframes"
input ENUM_TIMEFRAMES InpHTF = PERIOD_H4;              // HTF regime timeframe (LTF = this chart's timeframe)

input group "Structure"
input int    InpSwingLookback = 2;                     // Bars each side to confirm a swing high/low

input group "Zones"
input double InpExpansionAtrMult = 1.5;                // Min candle range (x ATR) to count as an expansion leg
input int    InpAtrPeriod = 14;
input int    InpZoneSearchWindow = 30;                 // Bars scanned back for a fresh zone
input int    InpZoneExpiryTouches = 3;                 // Chop touches before a zone is retired
input int    InpMaxActiveZones = 5;

input group "Confirmation (Stochastic)"
input int    InpStochK = 14;
input int    InpStochD = 3;
input int    InpStochSlowing = 3;
input double InpStochOverbought = 80.0;
input double InpStochOversold = 20.0;
input int    InpMaxBarsToConfirm = 12;                 // Bars allowed between zone touch and crossback

input group "Risk & Execution"
input double InpRiskPercent = 1.0;                     // % of balance risked per trade
input double InpRiskReward = 2.0;                      // TP distance = InpRiskReward x SL distance
input double InpSafetyBufferPoints = 50;                // SL buffer beyond the zone boundary, in points
input ulong  InpMagicNumber = 20260718;

input group "Export"
input int    InpExportIntervalSec = 5;
input int    InpExportMaxCandles = 300;

#define MAX_HISTORY 50

CStructureFilter    g_structure;
CZoneManager        g_zones;
CConfirmationEngine g_confirm;
CRiskExecutor       g_risk;
CDrawer             g_drawer;
CExporter           g_exporter;

SSignalEvent g_signals[];
STradeEvent  g_trades[];

//+------------------------------------------------------------------+
int OnInit()
  {
   string symbol = _Symbol;
   ENUM_TIMEFRAMES ltf = (ENUM_TIMEFRAMES)_Period;

   g_structure.Init(symbol, InpHTF, InpSwingLookback);
   g_zones.Init(symbol, ltf, InpExpansionAtrMult, InpAtrPeriod,
                InpZoneSearchWindow, InpZoneExpiryTouches, InpMaxActiveZones);
   g_confirm.Init(symbol, ltf, InpStochK, InpStochD, InpStochSlowing,
                  InpStochOverbought, InpStochOversold, InpMaxBarsToConfirm);
   if(g_confirm.Handle() == INVALID_HANDLE)
     {
      Print("SLC: failed to create Stochastic indicator handle");
      return INIT_FAILED;
     }
   g_risk.Init(symbol, InpRiskPercent, InpRiskReward, InpSafetyBufferPoints, InpMagicNumber);
   g_drawer.Init("SLC_");
   g_exporter.Init(symbol, InpExportMaxCandles);

   ArrayResize(g_signals, 0);
   ArrayResize(g_trades, 0);

   EventSetTimer(InpExportIntervalSec);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
void RecordSignal(ENUM_SIGNAL_DIR dir, long zoneId, double k)
  {
   int n = ArraySize(g_signals);
   if(n >= MAX_HISTORY)
     {
      for(int i = 0; i < n - 1; i++) g_signals[i] = g_signals[i + 1];
      n--;
     }
   ArrayResize(g_signals, n + 1);
   g_signals[n].time = TimeCurrent();
   g_signals[n].dir = dir;
   g_signals[n].zoneId = zoneId;
   g_signals[n].kValue = k;
  }

void RecordTrade(STradeEvent &tr)
  {
   int n = ArraySize(g_trades);
   if(n >= MAX_HISTORY)
     {
      for(int i = 0; i < n - 1; i++) g_trades[i] = g_trades[i + 1];
      n--;
     }
   ArrayResize(g_trades, n + 1);
   g_trades[n] = tr;
  }

void DrawAllZones()
  {
   for(int i = 0; i < g_zones.Count(); i++)
      g_drawer.DrawZone(g_zones.GetByIndex(i));
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   string symbol = _Symbol;
   ENUM_TIMEFRAMES ltf = (ENUM_TIMEFRAMES)_Period;

   // --- Step 1: HTF structure filter ---
   if(g_structure.IsNewBar())
      g_structure.Update();

   ENUM_HTF_STATE state = g_structure.State();
   g_drawer.UpdateRegimeLabel(g_structure.StateText(), g_zones.Count());

   // Execution gate: consolidation kills everything downstream, stay flat.
   if(state == HTF_CONSOLIDATION)
      return;

   // --- Step 2: LTF zone extraction + lifecycle ---
   bool ltfNewBar = g_zones.IsNewBar();
   if(ltfNewBar)
     {
      g_zones.ScanForNewZone(state);

      double lastClose[];
      ArraySetAsSeries(lastClose, true);
      if(CopyClose(symbol, ltf, 1, 1, lastClose) > 0)
         g_zones.UpdateLifecycle(state, lastClose[0]);

      DrawAllZones();
     }

   // --- Step 3: confirmation gate on tradeable zones (live tick) ---
   double curHigh[], curLow[];
   if(CopyHigh(symbol, ltf, 0, 1, curHigh) <= 0) return;
   if(CopyLow(symbol, ltf, 0, 1, curLow) <= 0) return;

   long ids[];
   int cnt = g_zones.GetTradeable(state, ids);

   for(int i = 0; i < cnt; i++)
     {
      int idx = g_zones.IndexOfId(ids[i]);
      if(idx < 0) continue;

      SZone z = g_zones.GetByIndex(idx);
      ENUM_SIGNAL_DIR dir;
      double kOut;
      bool fired = g_confirm.CheckZone(z, curHigh[0], curLow[0], dir, kOut);
      g_zones.SetZone(idx, z);

      if(!fired) continue;

      RecordSignal(dir, z.id, kOut);
      g_drawer.DrawSignal(TimeCurrent(), (dir == SIGNAL_SHORT) ? curHigh[0] : curLow[0], dir);

      // --- Step 4: risk matrix + order dispatch ---
      double entry, sl, tp, lots;
      if(g_risk.Execute(dir, z, entry, sl, tp, lots))
        {
         g_zones.MarkTraded(z.id);

         STradeEvent tr;
         tr.time = TimeCurrent();
         tr.dir = dir;
         tr.entry = entry;
         tr.sl = sl;
         tr.tp = tp;
         tr.lots = lots;
         RecordTrade(tr);
         g_exporter.AppendTradeCsv(tr);

         g_drawer.DrawTrade(TimeCurrent(), entry, dir);
         DrawAllZones();
        }
      else
        {
         Print("SLC: order dispatch failed for zone #", z.id);
        }
     }
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   g_exporter.Export(InpHTF, (ENUM_TIMEFRAMES)_Period, g_structure.StateText(),
                      g_zones, g_signals, g_trades);
  }
//+------------------------------------------------------------------+

"""
QuantCore Alert Notifier
========================
Push real-time trading alerts to Telegram and/or Discord.

Alerts sent on:
  • New signal generated (BUY/SELL with score, SL, TP)
  • Trade opened / closed (symbol, lots, P&L)
  • Phase-1 milestone (every 1% toward 8% target)
  • Prop firm warning (daily DD > 3%, total DD > 7%)
  • Phase-1 target REACHED

Setup
-----
Telegram:
  1. Message @BotFather → /newbot → copy token
  2. Message your bot, then:
     curl "https://api.telegram.org/bot<TOKEN>/getUpdates"
     Copy the chat_id from the response
  3. Set env vars:
     TELEGRAM_BOT_TOKEN=123456:ABCdef...
     TELEGRAM_CHAT_ID=-100123456789

Discord:
  1. Server Settings → Integrations → Webhooks → New Webhook
  2. Set env var:
     DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...

Usage
-----
  from quantcore.alerts.notifier import Notifier

  n = Notifier()
  n.signal("EURUSD", "BUY", score=0.696, price=1.16327, sl=1.16200, tp=1.16700)
  n.trade_opened("EURUSD", "BUY", lots=4.1, price=1.16327, sl=1.16200, tp=1.16700)
  n.trade_closed("EURUSD", "BUY", lots=4.1, open_price=1.16327, close_price=1.16460, pnl=545.30)
  n.phase_update(balance=103537, deposit=100000, target_pct=8.0)
  n.safety_warning("Daily DD", current=3.2, limit=5.0)
  n.phase_passed(balance=108000, deposit=100000)

  # Or use standalone:
  python notifier.py --test
"""

import json, os, sys, time
from datetime import datetime, timezone
from typing import Optional
import urllib.request
import urllib.parse
import urllib.error

# ══════════════════════════════════════════════════════════════════════
#  TRANSPORT LAYER
# ══════════════════════════════════════════════════════════════════════

def _post(url: str, payload: dict, headers: dict = None) -> bool:
    """HTTP POST helper — returns True on success."""
    data    = json.dumps(payload).encode()
    req     = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status < 300
    except Exception as e:
        print(f"  [Alert] POST failed: {e}", file=sys.stderr)
        return False


def send_telegram(token: str, chat_id: str, text: str,
                  parse_mode: str = "HTML") -> bool:
    """Send a message via Telegram Bot API."""
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    return _post(url, {"chat_id": chat_id, "text": text,
                        "parse_mode": parse_mode,
                        "disable_web_page_preview": True})


def send_discord(webhook_url: str, content: str,
                 embeds: list = None) -> bool:
    """Send a message via Discord webhook."""
    payload: dict = {}
    if embeds:
        payload["embeds"] = embeds
    else:
        payload["content"] = content
    return _post(webhook_url, payload)


# ══════════════════════════════════════════════════════════════════════
#  MESSAGE FORMATTERS
# ══════════════════════════════════════════════════════════════════════

def _now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

def _pct(v: float) -> str:
    return f"{v:+.2f}%"

def _price(v: float, symbol: str) -> str:
    if "JPY" in symbol.upper():
        return f"{v:.3f}"
    if "XAU" in symbol.upper() or "GC" in symbol.upper():
        return f"{v:,.2f}"
    return f"{v:.5f}"


# ── Telegram HTML templates ───────────────────────────────────────────

def _tg_signal(symbol: str, direction: str, score: float,
               price: float, sl: float, tp: float, lots: float = 0) -> str:
    icon = "🟢" if direction == "BUY" else "🔴"
    rr   = abs(tp - price) / max(abs(sl - price), 1e-9)
    lots_line = f"\n📦 <b>Lots:</b> {lots:.2f}" if lots else ""
    return (
        f"{icon} <b>QuantCore Signal — {symbol}</b>\n"
        f"{'─'*28}\n"
        f"📌 <b>Direction:</b> {direction}\n"
        f"💯 <b>Score:</b> {score:.4f}\n"
        f"💵 <b>Entry:</b> {_price(price, symbol)}\n"
        f"🛑 <b>SL:</b> {_price(sl, symbol)}\n"
        f"🎯 <b>TP:</b> {_price(tp, symbol)}\n"
        f"⚖️  <b>RR:</b> 1:{rr:.1f}"
        f"{lots_line}\n"
        f"🕐 {_now_utc()}"
    )

def _tg_trade_opened(symbol: str, direction: str, lots: float,
                     price: float, sl: float, tp: float) -> str:
    icon = "🟢" if direction == "BUY" else "🔴"
    return (
        f"{icon} <b>Trade Opened — {symbol}</b>\n"
        f"{'─'*28}\n"
        f"📌 {direction}  {lots:.2f} lots @ {_price(price, symbol)}\n"
        f"🛑 SL: {_price(sl, symbol)}\n"
        f"🎯 TP: {_price(tp, symbol)}\n"
        f"🕐 {_now_utc()}"
    )

def _tg_trade_closed(symbol: str, direction: str, lots: float,
                     open_price: float, close_price: float, pnl: float) -> str:
    icon = "💰" if pnl >= 0 else "📉"
    move = close_price - open_price if direction == "BUY" else open_price - close_price
    return (
        f"{icon} <b>Trade Closed — {symbol}</b>\n"
        f"{'─'*28}\n"
        f"📌 {direction}  {lots:.2f} lots\n"
        f"📥 Entry: {_price(open_price, symbol)}\n"
        f"📤 Exit:  {_price(close_price, symbol)}\n"
        f"{'✅' if pnl>=0 else '❌'} <b>P&L: {'+' if pnl>=0 else ''}${pnl:,.2f}</b>\n"
        f"🕐 {_now_utc()}"
    )

def _tg_phase_update(balance: float, deposit: float,
                     target_pct: float) -> str:
    pnl      = balance - deposit
    net_pct  = pnl / deposit * 100
    target   = deposit * target_pct / 100
    progress = min(100, net_pct / target_pct * 100)
    bar_fill = int(progress / 5)
    bar      = "█" * bar_fill + "░" * (20 - bar_fill)
    remaining= max(0, target - pnl)
    return (
        f"📊 <b>Phase-1 Update</b>\n"
        f"{'─'*28}\n"
        f"💰 Balance:   ${balance:,.2f}\n"
        f"📈 Net P&L:   ${pnl:+,.2f} ({net_pct:+.2f}%)\n"
        f"🎯 Progress:  {progress:.1f}%\n"
        f"[{bar}]\n"
        f"⏳ Remaining: ${remaining:,.2f}\n"
        f"🕐 {_now_utc()}"
    )

def _tg_safety_warning(metric: str, current: float, limit: float) -> str:
    pct_used = current / limit * 100
    icon     = "⚠️" if pct_used < 80 else "🚨"
    return (
        f"{icon} <b>Prop Firm Warning</b>\n"
        f"{'─'*28}\n"
        f"📊 {metric}: {current:.2f}% / {limit:.1f}%\n"
        f"🔴 Used: {pct_used:.1f}%  |  Buffer: {max(0,limit-current):.2f}%\n"
        f"⚡ EA will stop trading if limit reached\n"
        f"🕐 {_now_utc()}"
    )

def _tg_phase_passed(balance: float, deposit: float) -> str:
    pnl = balance - deposit
    return (
        f"🎉🎉 <b>PHASE-1 TARGET REACHED!</b> 🎉🎉\n"
        f"{'─'*28}\n"
        f"💰 Balance:  ${balance:,.2f}\n"
        f"📈 Net P&L:  ${pnl:+,.2f} ({pnl/deposit*100:+.2f}%)\n"
        f"✅ Submit for GoatFunded review now!\n"
        f"🏆 QuantCore AI EA — Mission Complete\n"
        f"🕐 {_now_utc()}"
    )


# ── Discord embed helpers ─────────────────────────────────────────────

def _dc_embed(title: str, description: str, color: int,
              fields: list = None) -> dict:
    embed: dict = {
        "title":       title,
        "description": description,
        "color":       color,
        "footer":      {"text": f"QuantCore AI EA  •  {_now_utc()}"},
    }
    if fields:
        embed["fields"] = fields
    return embed

COLOR_GREEN  = 0x00E676
COLOR_RED    = 0xFF1744
COLOR_YELLOW = 0xFFD740
COLOR_BLUE   = 0x00D4FF
COLOR_GOLD   = 0xFFD700


# ══════════════════════════════════════════════════════════════════════
#  NOTIFIER CLASS
# ══════════════════════════════════════════════════════════════════════

class Notifier:
    """
    Unified alert dispatcher for Telegram and Discord.
    Reads credentials from environment variables.
    """

    def __init__(self,
                 telegram_token:   Optional[str] = None,
                 telegram_chat_id: Optional[str] = None,
                 discord_webhook:  Optional[str] = None):
        self.tg_token   = telegram_token   or os.environ.get("TELEGRAM_BOT_TOKEN",  "")
        self.tg_chat    = telegram_chat_id or os.environ.get("TELEGRAM_CHAT_ID",    "")
        self.dc_webhook = discord_webhook  or os.environ.get("DISCORD_WEBHOOK_URL", "")
        self._last_phase_milestone = 0.0   # track % to avoid duplicate alerts

    def _has_telegram(self) -> bool:
        return bool(self.tg_token and self.tg_chat)

    def _has_discord(self) -> bool:
        return bool(self.dc_webhook)

    def _dispatch(self, tg_text: str, dc_embeds: list,
                  dc_fallback: str = "") -> dict:
        results = {"telegram": None, "discord": None}
        if self._has_telegram():
            results["telegram"] = send_telegram(self.tg_token, self.tg_chat, tg_text)
        if self._has_discord():
            results["discord"] = send_discord(self.dc_webhook,
                                              dc_fallback or tg_text, dc_embeds)
        if not self._has_telegram() and not self._has_discord():
            print(f"[Alert — no channels configured]\n{tg_text}\n",
                  file=sys.stderr)
        return results

    # ── Signal alert ──────────────────────────────────────────────────
    def signal(self, symbol: str, direction: str, score: float,
               price: float, sl: float, tp: float, lots: float = 0) -> dict:
        rr   = abs(tp - price) / max(abs(sl - price), 1e-9)
        tg   = _tg_signal(symbol, direction, score, price, sl, tp, lots)
        color= COLOR_GREEN if direction == "BUY" else COLOR_RED
        icon = "🟢" if direction == "BUY" else "🔴"
        emb  = _dc_embed(
            f"{icon} QuantCore Signal — {symbol}",
            f"**{direction}**  |  Score: {score:.4f}",
            color,
            fields=[
                {"name":"Entry",     "value":str(_price(price,symbol)), "inline":True},
                {"name":"SL",        "value":str(_price(sl,symbol)),    "inline":True},
                {"name":"TP",        "value":str(_price(tp,symbol)),    "inline":True},
                {"name":"R:R",       "value":f"1:{rr:.1f}",             "inline":True},
            ] + ([{"name":"Lots","value":f"{lots:.2f}","inline":True}] if lots else [])
        )
        return self._dispatch(tg, [emb])

    # ── Trade opened ──────────────────────────────────────────────────
    def trade_opened(self, symbol: str, direction: str, lots: float,
                     price: float, sl: float, tp: float) -> dict:
        tg  = _tg_trade_opened(symbol, direction, lots, price, sl, tp)
        col = COLOR_GREEN if direction == "BUY" else COLOR_RED
        emb = _dc_embed(f"📬 Trade Opened — {symbol}",
                        f"**{direction}** {lots:.2f} lots @ {_price(price,symbol)}",
                        col,
                        fields=[{"name":"SL","value":str(_price(sl,symbol)),"inline":True},
                                {"name":"TP","value":str(_price(tp,symbol)),"inline":True}])
        return self._dispatch(tg, [emb])

    # ── Trade closed ──────────────────────────────────────────────────
    def trade_closed(self, symbol: str, direction: str, lots: float,
                     open_price: float, close_price: float, pnl: float) -> dict:
        tg  = _tg_trade_closed(symbol, direction, lots, open_price, close_price, pnl)
        col = COLOR_GREEN if pnl >= 0 else COLOR_RED
        emb = _dc_embed(
            f"{'💰' if pnl>=0 else '📉'} Trade Closed — {symbol}",
            f"P&L: **{'+' if pnl>=0 else ''}${pnl:,.2f}**",
            col,
            fields=[
                {"name":"Direction","value":direction,                     "inline":True},
                {"name":"Lots",     "value":f"{lots:.2f}",                 "inline":True},
                {"name":"Entry",    "value":str(_price(open_price,symbol)),"inline":True},
                {"name":"Exit",     "value":str(_price(close_price,symbol)),"inline":True},
            ])
        return self._dispatch(tg, [emb])

    # ── Phase progress ────────────────────────────────────────────────
    def phase_update(self, balance: float, deposit: float,
                     target_pct: float = 8.0,
                     force: bool = False) -> dict | None:
        net_pct = (balance - deposit) / deposit * 100
        milestone = int(net_pct / (target_pct / 8))   # every ~1% of target
        if not force and milestone <= self._last_phase_milestone:
            return None
        self._last_phase_milestone = milestone
        tg  = _tg_phase_update(balance, deposit, target_pct)
        emb = _dc_embed("📊 Phase-1 Progress", tg, COLOR_BLUE)
        return self._dispatch(tg, [emb])

    # ── Safety warning ────────────────────────────────────────────────
    def safety_warning(self, metric: str, current: float,
                       limit: float) -> dict:
        tg  = _tg_safety_warning(metric, current, limit)
        emb = _dc_embed("⚠️ Prop Firm Warning", tg, COLOR_YELLOW)
        return self._dispatch(tg, [emb])

    # ── Phase passed ──────────────────────────────────────────────────
    def phase_passed(self, balance: float, deposit: float) -> dict:
        tg  = _tg_phase_passed(balance, deposit)
        emb = _dc_embed("🏆 PHASE-1 PASSED!", tg, COLOR_GOLD)
        return self._dispatch(tg, [emb])

    # ── Status ────────────────────────────────────────────────────────
    def status(self) -> str:
        lines = ["Alert channels:"]
        lines.append(f"  Telegram : {'✅ configured' if self._has_telegram() else '❌ not set (TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID)'}")
        lines.append(f"  Discord  : {'✅ configured' if self._has_discord()  else '❌ not set (DISCORD_WEBHOOK_URL)'}")
        return "\n".join(lines)


# ══════════════════════════════════════════════════════════════════════
#  CLI — test mode
# ══════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="QuantCore Alert Notifier")
    ap.add_argument("--test",     action="store_true", help="Send test alerts")
    ap.add_argument("--dry-run",  action="store_true", help="Print messages without sending")
    ap.add_argument("--channel",  default="both", choices=["telegram","discord","both"])
    args = ap.parse_args()

    n = Notifier()
    print(n.status())
    print()

    if args.dry_run:
        # Print all message templates
        print("=== SIGNAL ===")
        print(_tg_signal("EURUSD", "BUY", 0.696, 1.16327, 1.16200, 1.16700, 4.1))
        print("\n=== TRADE OPENED ===")
        print(_tg_trade_opened("EURUSD", "BUY", 4.1, 1.16327, 1.16200, 1.16700))
        print("\n=== TRADE CLOSED ===")
        print(_tg_trade_closed("EURUSD", "BUY", 4.1, 1.16327, 1.16460, 545.30))
        print("\n=== PHASE UPDATE ===")
        print(_tg_phase_update(103537, 100000, 8.0))
        print("\n=== SAFETY WARNING ===")
        print(_tg_safety_warning("Daily DD", 3.2, 5.0))
        print("\n=== PHASE PASSED ===")
        print(_tg_phase_passed(108001, 100000))
        return

    if args.test:
        print("Sending test alerts…")
        r1 = n.signal("EURUSD", "BUY", 0.696, 1.16327, 1.16200, 1.16700, 4.1)
        print(f"Signal:  {r1}")
        time.sleep(1)
        r2 = n.trade_opened("EURUSD", "BUY", 4.1, 1.16327, 1.16200, 1.16700)
        print(f"Opened:  {r2}")
        time.sleep(1)
        r3 = n.trade_closed("EURUSD", "BUY", 4.1, 1.16327, 1.16460, 545.30)
        print(f"Closed:  {r3}")
        time.sleep(1)
        r4 = n.phase_update(103537, 100000, 8.0, force=True)
        print(f"Phase:   {r4}")
        print("Done.")


import argparse
if __name__ == "__main__":
    main()

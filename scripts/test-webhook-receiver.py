#!/usr/bin/env python3
"""
Mini-Empfaenger zum Testen des CVE-Watchers.

Nimmt POST-Requests entgegen und schreibt das JSON lesbar ins Terminal.
Damit pruefst du die Kette Watcher -> Webhook, bevor du ein echtes System
(Ticketsystem, Power Automate, n8n) anbindest.

    ./scripts/test-webhook-receiver.py            # lauscht auf Port 9000
    ./scripts/test-webhook-receiver.py 9100       # anderer Port

Im Container-Kontext ist der Pi vom cve-watcher aus unter der Docker-Bridge
erreichbar - in config/secrets.env dann z. B.:
    CVE_WEBHOOK_URL=http://172.17.0.1:9000/hook
"""
import json, sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9000


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        print(f"\n{'=' * 70}")
        print(f"{datetime.now():%H:%M:%S}  POST {self.path}  von {self.client_address[0]}")
        for h in ("Content-Type", "Authorization"):
            if self.headers.get(h):
                val = self.headers[h]
                if h == "Authorization":
                    val = val[:12] + "..."          # Token nicht ausschreiben
                print(f"  {h}: {val}")
        print("-" * 70)
        try:
            data = json.loads(raw)
            print(json.dumps(data, indent=2, ensure_ascii=False))
            if "priority" in data and "cve" in data:
                print("-" * 70)
                score = (data.get("cvss") or {}).get("score", "-")
                print(f"  => {data['priority']}  {data['cve']}  CVSS {score}  "
                      f"KEV={(data.get('kev') or {}).get('listed')}")
                print(f"     Produkte: {', '.join(data.get('matched_products', []))}")
        except Exception:
            print(raw.decode("utf-8", "replace"))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *a):
        pass                                        # eigene Ausgabe reicht


if __name__ == "__main__":
    print(f"Test-Empfaenger laeuft auf http://0.0.0.0:{PORT}  (Strg+C beendet)")
    print(f"CVE_WEBHOOK_URL=http://172.17.0.1:{PORT}/hook   <- in config/secrets.env")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

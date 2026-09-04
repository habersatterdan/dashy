#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Prüft alle /feeds/<name>-Endpunkte der Alert-Wand: HTTP-Status, Content-Type
# und ob wirklich parsebares XML/JSON zurückkommt.
# Aufruf auf dem Pi:  ./scripts/check-feeds.sh [https://localhost]
# -----------------------------------------------------------------------------
set -uo pipefail
BASE="${1:-https://localhost}"

# Feed-IDs direkt aus der Nginx-Config lesen -> keine doppelte Pflege.
CONF="$(dirname "${BASH_SOURCE[0]}")/../nginx/conf.d/dashy.conf"
IDS=$(grep -oE 'location = /feeds/[a-z0-9-]+' "$CONF" | sed 's|.*/feeds/||' | sort -u)

printf '%-18s %-6s %-28s %s\n' FEED HTTP CONTENT-TYPE ERGEBNIS
for id in $IDS; do
  body=$(mktemp)
  code=$(curl -sk -o "$body" -w '%{http_code}' --max-time 25 "$BASE/feeds/$id")
  ctype=$(curl -skI --max-time 15 "$BASE/feeds/$id" | grep -i '^content-type:' | cut -d' ' -f2- | tr -d '\r')
  first=$(head -c 400 "$body" | tr -d '\n')
  if   [ "$code" != "200" ];                          then res="FEHLER (HTTP $code)"
  elif grep -qiE '<(rss|feed|rdf:RDF)' <<<"$first";   then res="OK  ($(grep -oc '<item\|<entry' "$body" 2>/dev/null || echo '?') Einträge)"
  elif head -c 1 "$body" | grep -q '[{[]';            then res="OK  (JSON)"
  else                                                     res="KEIN FEED (HTML/Fehlerseite?)"
  fi
  printf '%-18s %-6s %-28s %s\n' "$id" "$code" "${ctype:0:28}" "$res"
  rm -f "$body"
done
echo
echo "Hinweis: 'KEIN FEED' bei heise-alerts -> URL in nginx/conf.d/dashy.conf korrigieren."

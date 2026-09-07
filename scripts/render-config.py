#!/usr/bin/env python3
"""
Rendert die Dashboard-Konfiguration aus zwei zentralen Dateien.

    config/endpoints.env   URLs der On-Prem-Dienste
    config/secrets.env     API-Keys / Zugangsdaten (chmod 600, nie committen)

Jede Datei *.tmpl unter profiles/<profil>/ und nginx/conf.d/extra/ wird mit den
Werten gefüllt und ohne die Endung .tmpl daneben geschrieben.

    ./scripts/render-config.py                 # Profil aus .env (DASHY_PROFILE)
    ./scripts/render-config.py --profile homelab
    ./scripts/render-config.py --check         # nur prüfen, nichts schreiben

Platzhalter-Syntax:  ${NAME}
Ein leerer oder fehlender Wert wird gemeldet und die Zeile bleibt unverändert,
damit man im Ergebnis sofort sieht, was noch fehlt.
"""
import argparse, os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLACEHOLDER = re.compile(r"\$\{([A-Z0-9_]+)\}")


def read_env(path: Path) -> dict:
    """Minimaler .env-Parser: KEY=VALUE, # als Kommentar, Quotes optional."""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        val = val.strip().strip('"').strip("'")
        out[key.strip()] = val
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile")
    ap.add_argument("--check", action="store_true",
                    help="nur prüfen, keine Dateien schreiben")
    args = ap.parse_args()

    endpoints = read_env(ROOT / "config" / "endpoints.env")
    secrets   = read_env(ROOT / "config" / "secrets.env")
    dotenv    = read_env(ROOT / ".env")

    missing_files = [p for p in ("config/endpoints.env", "config/secrets.env")
                     if not (ROOT / p).exists()]
    for p in missing_files:
        print(f"HINWEIS: {p} fehlt - lege sie an mit:  cp {p}.example {p}")

    values = {**endpoints, **secrets}
    profile = args.profile or dotenv.get("DASHY_PROFILE", "enterprise")

    roots = [ROOT / "profiles" / profile, ROOT / "nginx" / "conf.d" / "extra"]
    templates = sorted(t for r in roots if r.is_dir() for t in r.rglob("*.tmpl"))
    if not templates:
        print(f"Keine *.tmpl gefunden (Profil: {profile}) - nichts zu rendern.")
        return 0

    print(f"Profil: {profile}")
    unresolved_total, written = {}, 0

    for tmpl in templates:
        text = tmpl.read_text(encoding="utf-8")
        used = set(PLACEHOLDER.findall(text))
        unresolved = sorted(n for n in used if not values.get(n))

        def sub(m):
            name = m.group(1)
            v = values.get(name)
            return v if v else m.group(0)      # leer -> Platzhalter stehen lassen

        rendered = PLACEHOLDER.sub(sub, text)
        target = tmpl.with_suffix("")          # foo.yml.tmpl -> foo.yml
        rel = target.relative_to(ROOT)

        for n in unresolved:
            unresolved_total.setdefault(n, []).append(str(rel))

        if args.check:
            print(f"  prüfe  {rel}  ({len(used)} Platzhalter, {len(unresolved)} offen)")
            continue

        # Nginx-Configs mit offenen Platzhaltern DÜRFEN NICHT geschrieben werden:
        # "${VAR}" ist dort gültige Variablensyntax, nginx bricht beim Start mit
        # "unknown variable" ab und der ganze Reverse-Proxy ist tot. Bei YAML ist
        # ein sichtbarer Platzhalter harmlos, hier nicht.
        if target.suffix == ".conf" and unresolved:
            if target.exists():
                target.unlink()
                print(f"  ENTFERNT {rel}  (offene Platzhalter: {', '.join(unresolved)})")
            else:
                print(f"  UEBERSPRUNGEN {rel}  (offene Platzhalter: {', '.join(unresolved)})")
            continue

        if target.exists() and target.read_text(encoding="utf-8") == rendered:
            print(f"  gleich {rel}")
        else:
            target.write_text(rendered, encoding="utf-8")
            written += 1
            print(f"  ->     {rel}")

        if target.suffix in (".yml", ".yaml"):
            try:
                import yaml
                yaml.safe_load(rendered)
            except ImportError:
                pass
            except Exception as e:
                print(f"  FEHLER: {rel} ist kein gültiges YAML: {e}")
                return 1

    if unresolved_total:
        print("\nNoch ohne Wert (Platzhalter bleiben sichtbar stehen):")
        for name, files in sorted(unresolved_total.items()):
            where = "config/secrets.env" if name in secrets or name.endswith(
                ("TOKEN", "SECRET", "KEY", "SESSION", "XSRF")) else "config/endpoints.env"
            print(f"  {name:24s} -> in {where} eintragen   ({', '.join(sorted(set(files)))})")
    else:
        print("\nAlle Platzhalter aufgelöst.")

    if not args.check:
        print(f"\n{written} Datei(en) geschrieben. Danach:  docker compose restart dashy nginx")
    return 0


if __name__ == "__main__":
    sys.exit(main())

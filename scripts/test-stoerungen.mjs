#!/usr/bin/env node
/*
 * Prueft die Einstufungslogik von assets/stoerungen.html.
 *
 * Warum als eigener Test: Ob "Resolved: Major outage" als behoben oder als
 * Ausfall gilt, entscheidet, ob die Wand faelschlich rot leuchtet. Solche
 * Grenzfaelle sieht man einer Seite im Browser nicht an - man merkt es erst,
 * wenn wochenlang niemand mehr hinschaut.
 *
 * Ausfuehren:  node scripts/test-stoerungen.mjs
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const html = fs.readFileSync(path.join(root, 'assets/stoerungen.html'), 'utf8');

const m = html.match(/---8<--- LOGIC START[^\n]*\n([\s\S]*?)\/\* ---8<--- LOGIC END/);
if (!m) { console.error('Logikblock in stoerungen.html nicht gefunden.'); process.exit(1); }

const mod = await import('data:text/javascript,' + encodeURIComponent(
  m[1] + '\nexport { classify, isFresh, isActive, sortItems, shorten };'));
const { classify, isFresh, isActive, sortItems, shorten } = mod;

const H = 3600 * 1000, now = Date.now();
let bad = 0;
const check = (ok, label, extra = '') => {
  if (!ok) bad++;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label}${ok ? '' : '   ' + extra}`);
};

console.log('Einstufung (Titel -> Zustand)');
[ // Der Endzustand im Titel muss den Ausloeser schlagen:
  ['Resolved: Major outage in West Europe',            1,    'resolved'],
  ['Planned maintenance impact identified',            2,    'planned'],
  ['Maintenance cancelled due to ongoing incident',    2,    'cancelled'],
  ['Service degraded - investigating latency',         2,    'degraded'],
  ['Total loss of service in UK',                      2,    'outage'],
  ['Ausfall im Rechenzentrum Frankfurt',               2,    'outage'],
  ['Neue Funktion verfügbar',                          2,    'info'],
  ['Eintrag ohne Zeitstempel',                         null, 'nodate'],
].forEach(([title, h, exp]) => {
  const item = { title, date: h === null ? null : new Date(now - h * H) };
  const got = classify(item);
  check(got === exp, `${exp.padEnd(10)} <- "${title}"`, `bekam: ${got}`);
});

console.log('\nFrisch-Fenster (Zustand, Alter -> sichtbar?)');
[ ['outage', 30, true], ['outage', 40, false],
  ['degraded', 35, true], ['planned', 6, true], ['planned', 20, false],
  ['resolved', 2, true], ['resolved', 9, false],
].forEach(([state, h, exp]) => {
  const got = isFresh({ state, date: new Date(now - h * H) }, now);
  check(got === exp, `${state.padEnd(9)} nach ${String(h).padStart(2)} h -> ${got}`);
});
check(isFresh({ state:'nodate', date:null }, now) === true,
      'nodate bleibt immer sichtbar (Datenproblem)');

console.log('\nNur Ausfall und Beeintraechtigung faerben die Wand');
check(isActive({state:'outage'}) && isActive({state:'degraded'})
      && !isActive({state:'planned'}) && !isActive({state:'resolved'}),
      'isActive trennt aktiv von geplant/behoben');

console.log('\nReihenfolge');
const order = sortItems([
  { state:'info',     date:new Date(now) },
  { state:'outage',   date:new Date(now - 5*H) },
  { state:'resolved', date:new Date(now) },
  { state:'degraded', date:new Date(now - H) },
]).map(i => i.state).join(' > ');
check(order === 'outage > degraded > resolved > info', `ergibt: ${order}`);

console.log('\nKurzform');
const long = 'Resolved: Cisco Secure Connect - Planned Maintenance Remote Access '
  + '(Client), Germany  Maintenance Details We are performing maintenance on ...';
const short = shorten(long);
check(!short.startsWith('Resolved:'), 'Anbieter-Praefix entfernt', short);
check(!short.includes('Maintenance Details'), 'Abschnittsmarke abgeschnitten', short);
check(short.length <= 118, `Laenge <= 118 (${short.length})`);
console.log(`      -> "${short}"`);

console.log(bad ? `\n${bad} Test(s) fehlgeschlagen.` : '\nAlle Tests bestanden.');
process.exit(bad ? 1 : 0);

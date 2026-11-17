#!/usr/bin/env bash
# Reconstruit la base PLOMI sur une base Supabase vide, puis charge le jeu de données des tests.
#   1. extensions ;
#   2. instantané du schéma de production du 08/11/2026 (supabase/schema, remis en ordre par build_baseline.py) ;
#   3. rejeu de toutes les migrations postérieures à l'instantané (ci/BASELINE), dans l'ordre ;
#   4. jeu de données des tests (ci/fixtures.sql).
# Usage : bash ci/build_db.sh "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
set -euo pipefail
DB="${1:?URL de la base attendue}"
cd "$(dirname "$0")/.."
PSQL=(psql "$DB" -v ON_ERROR_STOP=1 -q -X)
CUTOFF="$(tr -d '[:space:]' < ci/BASELINE)"

echo "::group::Extensions"
"${PSQL[@]}" -f supabase/schema/00_extensions.sql
echo "::endgroup::"

echo "::group::Instantané du schéma (${CUTOFF})"
python3 ci/build_baseline.py /tmp/plomi_baseline.sql
"${PSQL[@]}" -f /tmp/plomi_baseline.sql
echo "::endgroup::"

echo "::group::Migrations postérieures"
n=0
for f in $(ls supabase/migrations | awk -v c="${CUTOFF}_~" '$0 > c' | sort); do
  echo "→ $f"
  "${PSQL[@]}" -f "supabase/migrations/$f"
  n=$((n+1))
done
echo "$n migrations rejouées"
echo "::endgroup::"

echo "::group::Jeu de données des tests"
"${PSQL[@]}" -f ci/fixtures.sql
echo "::endgroup::"

"${PSQL[@]}" -At -c "select 'Base reconstruite : ' || (select count(*) from pg_tables where schemaname='public') || ' tables, '
  || (select count(*) from pg_proc where pronamespace='public'::regnamespace) || ' fonctions, '
  || (select count(*) from pg_policies where schemaname='public') || ' règles RLS'"

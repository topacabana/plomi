"""Assemble supabase/schema/*.sql (instantané du 08/11/2026) en un script rejouable sur une base vide.

L'instantané range chaque table avec ses contraintes ; une clé étrangère peut donc viser une
table pas encore créée. Ce script remet les instructions dans un ordre exécutable :
types, tables, clés primaires/uniques/checks, clés étrangères, index, fonctions, vues,
déclencheurs, règles RLS, stockage.
"""
import re, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent / "supabase" / "schema"
def stmts(name):
    txt = (root / name).read_text()
    txt = re.sub(r"^--.*$", "", txt, flags=re.M)
    return txt
tables_sql = stmts("02_tables.sql")
creates, alters_fk, alters_other = [], [], []
for st in re.split(r";\s*\n", tables_sql):
    st = st.strip()
    if not st:
        continue
    if st.upper().startswith("CREATE TABLE"):
        creates.append(st + ";")
    elif "FOREIGN KEY" in st.upper():
        alters_fk.append(st + ";")
    else:
        alters_other.append(st + ";")
out = ["-- Généré par ci/build_baseline.py — ne pas modifier à la main.",
       "set check_function_bodies = off;",
       "set search_path = public, extensions;",
       stmts("01_types.sql"),
       "\n".join(creates), "\n".join(alters_other), "\n".join(alters_fk),
       stmts("03_indexes.sql"), stmts("04_functions.sql"), stmts("05_views.sql"),
       stmts("06_triggers.sql"), stmts("07_policies.sql"), stmts("08_storage.sql")]
dest = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root.parent / "ci" / "baseline.sql"
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text("\n\n".join(out) + "\n")
print(f"{dest} : {len(creates)} tables, {len(alters_fk)} clés étrangères")

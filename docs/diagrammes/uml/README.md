# Diagrammes UML (V2.0, 19/11/2026)

Sources PlantUML des 9 diagrammes du document « PLOMI — Diagrammes UML V2.0 » : cas d'utilisation (UC-01, UC-02), séquence (SEQ-01 à SEQ-03), activité (ACT-01, ACT-02), états-transitions (STM-01), classes (CLS-01). Les PNG sont générés à partir des sources.

Régénérer : `java -jar plantuml.jar -tpng -charset UTF-8 *.puml` dans ce dossier.

Vérifiés contre le schéma de production : types énumérés (`supabase/schema/01_types.sql`), transitions de `transition_mandate_status`, fonctions RPC appelées par les deux applications.

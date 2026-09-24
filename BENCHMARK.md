# BENCHMARK

Protocole pré-enregistré pour le moteur de batch `Judge::Batch`, écrit avant toute exécution.

**Statut au 2026-09-21: campagne terminée, les cinq bras ont tourné. Verdict en section 7: le
batching ne passe pas le critère et n'est pas câblé.** Tout chiffre de ce document est soit mesuré,
soit de l'arithmétique explicitement étiquetée comme telle.

**Note de renommage.** La gem s'appelait `jev-in-rails` quand ces mesures ont été prises, et
`judge_rails` depuis le 2026-09-23. Les chemins et les identifiants de ce document ont été mis à jour
pour rester reproductibles; les mesures elles-mêmes sont inchangées. `wiki/queries/why-the-gem-was-renamed.md`
dit pourquoi.

La raison d'écrire le protocole d'abord: la règle maison est "verify, do not assert", et un
protocole fixé après avoir vu les résultats ne prouve rien.

---

## 1. La question

`judge_filter` fait un appel réseau par ligne, en série. pg_jev juge 2000 lignes en 3,5 secondes en
empaquetant 20 sujets dans un seul `state` avec une question par sujet, et en tenant 16 requêtes en
parallèle. Le batching est-il transposable ici sans dégrader le jugement, et de combien.

L'API n'a pas de dimension "sujets". Elle prend `{state, model, questions}`. Le batching consiste
donc à encoder les sujets **dans** le `state` et à poser une question ancrée par sujet. C'est un
changement de régime pour le modèle, pas un changement de transport.

---

## 2. Mesuré hors ligne, gratuit, reproductible

Tout ce qui suit est lu dans un fichier du workspace, sans appel réseau.

### 2.1 Le référentiel

`judge_rails_demo/db/seed_judgments.rb`, 250 jugements produits par le chemin non batché contre le
modèle réel.

| Grandeur | Valeur |
|---|---|
| Jugements | 250 |
| Modèle | `jev-1.13.0`, un seul |
| Digests de question distincts | 3 (`9e08ebfeb6e0e0fa`, `5f3c0bad775abc1c`, `d3f59e90f1ce9b41`) |
| Latence moyenne | 0,309 s |
| Latence p50 / min / max | 0,286 s / 0,228 s / 0,773 s |

Chaque ligne porte la probabilité du noul, la distribution `probabilities` complète du choice, et la
valeur, le niveau et la distribution du score. C'est la ligne de base contre laquelle l'accord se
mesure.

### 2.2 Les entrées

`judge_rails_demo/db/seed_tickets.rb`, le `state` étant `[subject, body]` joint par deux sauts de
ligne (`app/models/ticket.rb:14`).

| Grandeur | Valeur |
|---|---|
| Tickets | 250 |
| `state` en caractères | moyenne 208, p50 156, max 851 |
| `state` total | 52 114 caractères |
| Les 3 questions + critères | ~620 caractères |
| Lignes tenant dans 24 000 caractères | ~115 |

**Conséquence.** Sur ce jeu de données le plafond d'exactitude (20 à 25 lignes) mord environ cinq
fois plus tôt que le plafond de taille du `state`. Le budget caractères ne sera jamais atteint par la
démo.

### 2.3 Les chemins actuels, lus dans le code

| Chemin | Fichier | Requêtes | Parallélisme |
|---|---|---|---|
| `judge_filter` / `map` / `sort` | `lib/judge/rails/relation.rb:41-44` | 1 par ligne | **1 thread** |
| backfill par job | `lib/judge/rails/jobs.rb:56-61` | 1 par enregistrement | selon la file |
| calcul unitaire | `lib/judge/rails/storage.rb:26-34` | 1 par enregistrement | sans objet |
| `judge:demo:precompute` | `judge_rails_demo/lib/tasks/judge_demo.rake:8-30` | 1 par ticket | **8 threads** |

Aucun de ces chemins ne met deux sujets dans une requête. `Jobs.batch` (`jobs.rb:39-48`) groupe des
ids pour réduire le nombre de jobs, jamais le nombre de requêtes.

---

## 3. Projeté, arithmétique, non mesuré

Étiqueté séparément parce que rien ici n'a été observé.

### 3.1 Nombre de requêtes pour juger 250 tickets sur 3 questions

| Forme | Requêtes | Calcul |
|---|---|---|
| Actuelle | 250 | 1 par ticket, 3 questions dans la requête |
| A, 1 question × 20 lignes | 39 | 3 définitions × ceil(250/20) |
| B, 3 questions × 20 lignes | 13 | ceil(250/20) |

### 3.2 Tokens par ligne, estimés à 4 caractères par token

| Forme | Tokens / ligne | Détail |
|---|---|---|
| A | ~400 | le `state` du ticket part 3 fois, une fois par définition |
| B | ~296 | le `state` part une fois, les 3 questions par ligne |

Écart estimé: **B environ 26 % moins cher que A**, pas un facteur 3. Avec des lignes courtes, ce sont
les instructions répétées par ligne qui dominent, pas le `state`.

Pour référence, pg_jev documente ~175 tokens d'entrée par ligne en lots de 20, contre ~435 pour une
ligne seule. Nos questions portent des critères plus riches que ses conditions, d'où un chiffre plus
haut.

### 3.3 Coût de la campagne

~430 requêtes, ~710 000 tokens d'entrée, soit **~0,03 $** au tarif de 0,042 $ par million de tokens
d'entrée cité par la documentation de pg_jev. **Tarif emprunté, jamais vérifié côté Jev.** Le coût
réel se lira dans `ResultSet#usage`, que le client remplit déjà (`result_set.rb:34`).

---

## 4. Ce que le protocole ne peut pas établir

- **La calibration dans l'absolu.** On mesure un accord avec le chemin non batché, pas une justesse
  contre des étiquettes humaines. Il n'existe pas de jeu étiqueté par un humain dans ce workspace.
- **La généralisation hors de ce jeu de données.** 250 tickets de support courts, en anglais,
  synthétiques. Un jeu à documents longs ou multilingue n'est pas couvert.
- **Le comportement à la limite de 32k.** Aucune entrée du jeu n'en approche.

---

## 5. Décisions de design qui définissent l'expérience

Prises avant l'exécution, pour que les bras du protocole aient un sens.

| # | Décision |
|---|---|
| D1 | Le batching est opt-in. `Judge.config.batch_rows` et `Judge.config.concurrency`, `nil` par défaut |
| D2 | Le réglage n'est lu que par les chemins bulk. Le `before_save` sync n'est pas batchable, un `before_save` doit finir avant sa propre sauvegarde. Le validator est exclu, il est fail-closed |
| D3 | `state` = JSON strict `{condition, rows:[{id, text}]}`. Une question nommée `row0`, `row1` par ligne, instructions préfixées d'un ancrage qui nomme l'id et dit de traiter le texte comme des données |
| D4 | Le chemin batch ne substitue jamais la question ancrée dans la `Definition`. Le sidecar porte le digest de la question d'origine, sinon `stale?` boucle |
| D5 | Réponse incomplète: dichotomie, le lot est coupé en deux et retenté, profondeur bornée à 5, cas de base à une ligne par le chemin unitaire |
| D6 | Le budget caractères est un garde-fou qui lève avec la taille mesurée dans le message, pas une règle de packing. Le packing compte les lignes |
| D7 | La forme retenue (A ou B) et la valeur de `batch_rows` sont décidées par ce document, pas avant |

---

## 6. Protocole

### Bras 0. Latence en fonction du nombre de questions. EXÉCUTÉ le 2026-09-21

**C'est le bras qui décide si tout le reste vaut quelque chose.** Le vendeur affirme que le temps de
réponse bouge à peine quand on ajoute des questions. Le wiki portait cette affirmation en
`confidence: medium`, jamais vérifiée ici.

`judge_rails/bin/arm0_latency`. Un seul état de 280 caractères, la même question répétée N fois,
3 répétitions par point, 18 requêtes contre le modèle réel.

| N questions | Latence médiane | Écart | Tokens d'entrée | Tokens / question | vs N=1 |
|---|---|---|---|---|---|
| 1 | 0,280 s | 0,428 s | 350 | 350 | 1,00x |
| 2 | 0,264 s | 0,032 s | 373 | 186 | 0,94x |
| 5 | 0,242 s | 0,031 s | 442 | 88 | 0,86x |
| 10 | 0,234 s | 0,014 s | 557 | 56 | 0,84x |
| 20 | 0,242 s | 0,020 s | 797 | 40 | 0,86x |
| 40 | 0,246 s | 0,024 s | 1 277 | 32 | 0,88x |

**La latence est plate.** 40 questions dans une requête coûtent le même temps qu'une seule, à 0,88x.
Le critère de poursuite demandait moins de 10x à N=20; mesuré 0,86x. L'écart de 0,428 s au point
N=1 est la première requête, connexion à froid, et ne se reproduit sur aucun autre point.

L'affirmation du vendeur est donc **vérifiée**, et le wiki peut passer
`[[typesafe-jev]]` de `medium` à `high` sur ce point précis.

**Structure du coût, mesurée.** L'overhead fixe d'une requête est d'environ **326 tokens** (350 au
point N=1 moins le coût marginal d'une question), et une question marginale coûte
**(1277 - 350) / 39 ≈ 24 tokens**. C'est cet overhead fixe que le batching amortit, et c'est
exactement le mécanisme que pg_jev documente sans le chiffrer pour nous.

Conséquence arithmétique sur la démo: juger 250 tickets sans batching paie l'overhead 250 fois, soit
~81 500 tokens de pure structure. En lots de 20, 13 fois, soit ~4 200. **~77 000 tokens économisés
sur la seule structure.**

**Ce bras réfute la conclusion du bras 4 sur le coût.** Le proxy en octets annonçait +24,6 % pour le
batching. La facturation réelle dit 8,75x moins de tokens par question à N=20. Les octets sur le fil
ne sont pas la facture: l'overhead de ~326 tokens n'a pas de contrepartie visible dans le payload.
Le proxy est abandonné comme instrument de coût, et `ResultSet#usage` le remplace.

**Réserve.** Ce bras garde l'état fixe et fait varier N. Dans un vrai lot, l'état grandit avec les
lignes. Il établit que la latence ne dépend pas de N et que l'overhead par requête est réel; il
n'établit pas le coût total d'un lot, qui est une sortie des bras 2 et 3.

### Bras 1. Contrôle, déterminisme du modèle. EXÉCUTÉ le 2026-09-21

`bin/rails judge:bench:control SAMPLE=50`. Chemin non batché rejoué sur 50 tickets, comparé au
référentiel. C'est le plancher de bruit: aucun autre bras n'est lisible sans lui.

| Question | n | Accord décision | \|Δ\| moyen | \|Δ\| p95 |
|---|---|---|---|---|
| urgency (noul) | 50 | **100,0 %** | 0,0118 | 0,0300 |
| intent (choice) | 50 | **100,0 %** | 0,0082 | 0,0400 |
| frustration (score) | 50 | **96,0 %** | 0,0108 | 0,0400 |

50 requêtes, 26 492 tokens d'entrée, 13,52 s.

Le modèle est quasi déterministe: la dérive moyenne est de ~0,01 et les décisions sont stables,
sauf un niveau de score sur 25 qui bascule. **Le plancher de bruit est donc ~0,01 de dérive et 96
à 100 % d'accord.** Tout ce qui suit se lit contre ces trois nombres.

### Bras 2 et 3. Formes A et B, quatre tailles de lot. EXÉCUTÉS le 2026-09-21

`bin/rails judge:bench:campaign SHAPE=a|b BATCH=n`, 250 tickets, comparés au référentiel.

**Accord décision, en pourcentage. Contrôle en première ligne.**

| Lot | Forme | urgency | intent | frustration | Requêtes | Tokens |
|---|---|---|---|---|---|---|
| 1 | contrôle | **100,0** | **100,0** | **96,0** | 250* | 132 460* |
| 2 | A | 91,6 | 90,4 | 90,0 | 375 | 228 021 |
| 2 | B | 93,2 | 89,2 | 89,2 | 125 | 129 882 |
| 5 | A | 91,2 | 89,6 | 84,4 | 150 | 165 999 |
| 5 | B | 91,2 | 90,4 | 86,4 | 50 | 110 083 |
| 10 | A | 88,0 | 87,6 | 83,6 | 75 | 145 324 |
| 10 | B | 88,4 | 88,0 | 85,6 | 25 | 103 483 |
| 20 | A | 86,4 | 87,6 | 84,4 | 39 | 136 120 |
| 20 | B | 85,6 | 89,6 | 86,8 | 13 | 100 795 |
| 40 | A | 83,2 | 87,6 | 82,4 | 21 | 131 518 |
| 40 | B | 85,2 | 86,8 | 84,4 | 7 | 99 451 |

\* contrôle extrapolé de 50 à 250 tickets pour la comparaison.

**Dérive \|Δ\| moyenne, contrôle à ~0,01.**

| Lot | Forme | urgency | intent | frustration |
|---|---|---|---|---|
| 1 | contrôle | 0,0118 | 0,0082 | 0,0108 |
| 2 | B | 0,0532 | 0,0804 | 0,1110 |
| 5 | B | 0,0730 | 0,0937 | 0,1394 |
| 10 | B | 0,0816 | 0,1042 | 0,1543 |
| 20 | B | 0,0819 | 0,1097 | 0,1587 |
| 40 | B | 0,0874 | 0,1146 | 0,1780 |

### Bras 5. Isolation 2x2, une ligne par requête. EXÉCUTÉ le 2026-09-21

`bin/rails judge:bench:isolate VARIANT=... SAMPLE=150`. À une ligne par requête il n'y a aucun
voisin, donc ce carré sépare les deux autres causes: l'enveloppe JSON du `state`, et le préfixe
d'ancrage sur les instructions.

| Variante | `state` | instructions | urgency | intent | frustration |
|---|---|---|---|---|---|
| `raw_plain` | texte brut | d'origine | **98,7** | **100,0** | **98,7** |
| `json_plain` | JSON `{rows:[...]}` | d'origine | 96,0 | 98,0 | 95,3 |
| `raw_anchored` | texte brut | préfixées | 98,0 | 94,0 | 95,3 |
| `json_anchored` | JSON | préfixées | 96,0 | 96,7 | 96,0 |

600 requêtes, ~351 000 tokens, ~22 s au total.

`raw_plain` reproduit le contrôle, ce qui valide le harnais. Chacune des deux transformations coûte
environ 2 à 4 points prise seule, et les deux ensemble coûtent environ **3 points**.

### La décomposition du trou

Le lot de 20 perdait 10 à 14 points contre le contrôle. Le bras 5 dit d'où ils viennent:

| Cause | Points perdus | Évitable ? |
|---|---|---|
| Enveloppe JSON + préfixe d'ancrage | **~3** | peut-être, en changeant la forme |
| Présence des voisins dans le `state` | **~9** | non, c'est le batching lui-même |

La cause dominante n'est ni le JSON ni le préfixe. Ce sont les voisins.

**Corrigé le 2026-09-23 par le bras 7.** Cette répartition est un résidu, pas une mesure, et le bras 7
la réfute au lot de 2: le contenu du voisin y coûte -0,3 point, la forme objet -5,6 et une seconde clé
-3,2. Voir le bras 7.

### Ce que la documentation TypeSafe dit, et qui explique le résultat

Le cookbook [Parallel Questions](https://docs.typesafe.ai/cookbooks/parallel_questions.md) mesure
13 questions batchées contre 13 questions séparées sur un article de 54 000 caractères: **12,2x
moins cher, 10,0x plus rapide, aucun changement de réponse**, écart-type exactement 0,0 sur la
plupart des questions. Sa raison est écrite:

> "each question is scored on its own against the document, so its answer doesn't depend on what
> else is in the request."

La question ne dépend pas des autres questions. Elle dépend entièrement du **document**. Mettre 20
tickets dans le `state` ne change pas les questions, ça change le document contre lequel chacune est
notée. Chaque ticket est jugé au milieu de 19 textes qui ne le concernent pas.

Le cookbook [Re-Ranking](https://docs.typesafe.ai/cookbooks/rerank_typesafe.md) est le problème
identique au nôtre, 3 565 passages à juger indépendamment, et TypeSafe le résout ainsi: state
`{query_excerpt, candidate_passage}`, **un seul candidat par requête**, et **1 200 appels
concurrents en pool de threads**, 1 536 002 tokens d'entrée pour 0,0645 $. Le batching par sujet
n'y apparaît pas.

**Corrigé le 2026-09-23.** Le cookbook ne dit pas "1 200 appels concurrents". Il pose 40 requêtes ×
30 candidats présélectionnés par BM25 parmi les 3 565 passages, soit 1 200 appels au total, dans un
`ThreadPoolExecutor(max_workers=12)`. La leçon tenue (un candidat par requête) reste vraie; le
chiffre de concurrence n'a jamais existé. Relu dans `wiki/raw/transcripts/vendor-docs-check-2026-09-23.md`.

**Conclusion.** Le batching par question est la voie documentée et la gem la suit déjà: trois
`judge_attribute` sur un ticket partent en une requête (`storage.rb:26-34`). Le batching par sujet
n'est pas une voie documentée, et la mesure dit pourquoi.

### Le diagnostic qui explique la courbe

La dégradation est **déjà pleine au lot de 2** et bouge peu jusqu'à 40. Passer de 1 à 2 lignes coûte
environ 8 points d'accord; passer de 2 à 40 n'en coûte que 5 de plus.

**La cause dominante est donc le changement de forme, pas le nombre de voisins.** Entre le contrôle
et un lot de 2, deux choses changent en même temps:

1. le `state` passe de texte brut à un objet JSON `{condition, rows:[{id, text}]}`,
2. les instructions de la question sont réécrites avec un préfixe d'ancrage.

Le protocole ne sépare pas ces deux causes. C'est le prochain test à faire, et il est peu coûteux.

### Forme A contre forme B

Accord identique aux deux formes, à l'intérieur du bruit. B est strictement moins chère: à un lot de
20, 13 requêtes contre 39 et 100 795 tokens contre 136 120, soit **26 % de tokens en moins pour la
même exactitude**. Si le batching était adopté, ce serait sous la forme B. La question A contre B
est donc tranchée, sans que ça rende le batching acceptable pour autant.

### Ce que le batching achèterait, et à quel prix

| Axe | Contrôle | Forme B, lot 20 | Effet |
|---|---|---|---|
| Temps mur par ticket | 0,270 s | 0,0055 s | **49x plus rapide** |
| Tokens par ticket | 530 | 403 | **-24 %** |
| Accord urgency | 100,0 % | 85,6 % | **-14,4 points** |
| Accord intent | 100,0 % | 89,6 % | **-10,4 points** |
| Accord frustration | 96,0 % | 86,8 % | **-9,2 points** |

Le gain de vitesse est réel et large. L'économie de tokens est réelle et modeste, très loin du 8,75x
que le bras 0 laissait espérer: une fois les lignes dans le `state`, c'est le `state` qui domine, et
l'overhead fixe amorti ne pèse plus grand-chose.

### Bras 4. Débit hors ligne, sans API. EXÉCUTÉ le 2026-09-21

`judge_rails/bin/bench_batch`, contre `FakeJev` avec latence injectée à **0,300 s**, la moyenne
mesurée en 2.1. 250 lignes de taille comparable à celle de la démo. Mesure le pool de threads et le
packing, pas le modèle.

| Configuration | Requêtes | Temps mur | Octets envoyés | vs séquentiel 1 thread |
|---|---|---|---|---|
| séquentiel, 1 thread | 250 | 76,11 s | 127 480 | 1,0x |
| séquentiel, 8 threads | 250 | 9,75 s | 127 480 | 7,8x |
| lot 20, 8 threads | 13 | 0,62 s | 158 858 | **122,8x** |
| lot 20, 16 threads | 13 | 0,32 s | 158 858 | **241,4x** |

Reproductible: `cd judge_rails && bundle exec ruby bin/bench_batch`. `ROWS` et `LATENCY` sont
surchargeables.

**Caveat qui conditionne tout le tableau.** `FakeJev` répond en un temps fixe quel que soit le
nombre de questions dans la requête. Les 122x et 241x supposent donc, **par construction**, que la
latence ne croît pas avec le nombre de questions. C'est exactement l'hypothèse que le bras 0 doit
tester. Tant que le bras 0 n'a pas tourné, ces deux chiffres sont un plafond théorique, pas une
mesure du gain réel.

**Résultat qui contredit une hypothèse de départ.** Le batching envoie **plus** d'octets, pas moins:
158 858 contre 127 480, soit **+24,6 %**, ou 635 octets par ligne contre 510. Deux causes, les deux
mesurées ici: le préfixe d'ancrage part une fois par ligne au lieu d'une fois par requête, et
l'encapsulation JSON de chaque ligne (`{"id":n,"text":...}`) ajoute des octets que le chemin
unitaire n'a pas.

Donc **le bench hors ligne ne peut pas trancher l'axe coût**, contrairement à ce que la section 3.2
projetait. L'économie de tokens documentée par pg_jev (175 contre 435 par ligne) vient de
l'amortissement d'un overhead de requête d'environ 270 tokens, qui est une facturation côté serveur
et n'apparaît pas dans le payload. Seul `ResultSet#usage` renvoyé par l'API réelle peut arbitrer, ce
qui fait du compte de tokens une sortie des bras 1 à 3 et non du bras 4.

### Bras 4 bis, dans la suite de tests

`test/batch_throughput_test.rb`, 6 tests, latence injectée 0,1 s, petits volumes. Vérifie que le
pool recouvre réellement les requêtes et que le batching réduit le compte de requêtes, en moins
d'une seconde. La version fidèle du bras 4 coûte 76 secondes et n'a donc pas sa place dans
`rake test`.

### Bras 6. Balayage de concurrence sur l'API réelle. EXÉCUTÉ le 2026-09-21

`bin/rails judge:bench:isolate VARIANT=raw_plain SAMPLE=100 CONCURRENCY=n`. Forme de production
exacte: `state` en texte brut, 3 questions par ticket, un ticket par requête. Seul le nombre de
threads change.

| Threads | Temps mur | Accélération | Rendement | urgency | intent | frustration | Tokens |
|---|---|---|---|---|---|---|---|
| 1 | 25,01 s | 1,0x | 100 % | 99,0 | 99,0 | 98,0 | 52 859 |
| 2 | 13,02 s | 1,92x | 96 % | 100,0 | 99,0 | 100,0 | 52 859 |
| 4 | 6,87 s | 3,64x | 91 % | 99,0 | 99,0 | 99,0 | 52 859 |
| 8 | 3,60 s | **6,95x** | 87 % | 99,0 | 99,0 | 100,0 | 52 859 |
| 16 | 2,13 s | **11,7x** | 73 % | 100,0 | 99,0 | 99,0 | 52 859 |
| 32 | 1,36 s | **18,4x** | 57 % | 99,0 | 99,0 | 98,0 | 52 859 |

Trois faits, tous mesurés:

1. **Aucun plafond observé jusqu'à 32.** Aucune erreur, aucun 429, le temps mur continue de baisser.
   Le rendement se dégrade (57 % à 32) mais l'accélération reste monotone.
   **Réserve ajoutée le 2026-09-23:** `models.md` documente 1 200 requêtes par minute. 100 requêtes
   par niveau ne remplissent jamais une minute, donc ce bras ne pouvait pas voir la limite. Voir le
   bras 9.
2. **L'exactitude ne bouge pas.** 98 à 100 % à tous les niveaux, identique au série. C'est attendu et
   c'est la différence de fond avec le batching: la requête est **octet pour octet la même**, seul
   son ordonnancement change.
3. **Les tokens sont identiques à l'unité près**, 52 859 à tous les niveaux. La concurrence ne coûte
   rien.

**Défaut retenu: 8.** 6,95x pour 87 % de rendement, et 8 connexions par processus reste raisonnable
pour une gem qui tourne dans un serveur d'application. Le balayage est fait sur une machine, une clé
et 100 requêtes; il ne dit rien du quota d'une clé partagée sous charge réelle. `Judge.config.concurrency`
et le mot-clé `concurrency:` existent pour ceux dont la mesure dira autre chose.

### Bras 7. `state` objet à clés nommées. PRÉ-ENREGISTRÉ puis EXÉCUTÉ le 2026-09-23

**Pourquoi ce bras.** Relu le 2026-09-23, le bras 5 ne mesure pas ce que la section "décomposition
du trou" lui attribue. Les ~9 points "des voisins" sont un résidu, pas une mesure: entre une ligne
JSON et un lot de 20 changent à la fois la présence d'un texte étranger (dilution), la désignation
du sujet par un `id` numérique dans un tableau (adressage), le nombre de questions et la longueur du
`state`. La cellule `raw_anchored` est incohérente: elle parle d'un "rows array" qu'un `state` texte
ne contient pas. L'échantillon des bras 1 et 5 (`first(n)` par id) ne contient aucun ticket spam.

La documentation TypeSafe (`concepts/state.md`, `primitives/advanced.md`) prévoit un `state` **objet**
dont chaque partie a un nom, et des instructions qui nomment la partie visée. Un essai manuel dans le
playground, `{"State_1": "Shut up !", "State_2": "Shut up ?"}` avec "Is State_1 a question ?", rend
2 % et 98 %: l'API accepte la forme et l'adressage tient sur une paire minimale. Ce bras mesure si
l'adressage par clé nommée récupère l'exactitude que le `rows[id]` perdait.

**Forme.** `state` = objet JSON réel (pas une chaîne), clés `ticket_1` à `ticket_N`. Une question par
clé et par définition, nommée `ticket_k_<nom>`, dont l'instruction d'origine est réécrite pour nommer
la clé ("Does ticket_1 need a human...", "Which team should handle ticket_1?", "How frustrated does
the customer in ticket_1 sound?"). Aucun préfixe d'ancrage. Critères inchangés.

**Variantes, toutes sur les 250 tickets**, comparées au référentiel `db/seed_judgments.rb`:

| Variante | `state` | Requêtes | Isole |
|---|---|---|---|
| `control` | texte brut, questions d'origine | 250 | plancher de bruit sur la même population |
| `named_1` | `{ticket_1}` | 250 | coût de la forme objet seule |
| `named_same` | `{ticket_1, ticket_2}`, le même ticket deux fois | 250 | coût d'une seconde clé, sans contenu étranger |
| `named_2` | deux tickets différents | 125 | adressage + dilution, là où le trou apparaissait |
| `named_20` | vingt tickets différents | 13 | comparable à la forme B au lot 20 |

Les tickets sont mélangés avec une graine fixe (`SEED=7`) avant le groupement, pour que les voisins
ne partagent pas leur catégorie par construction. Concurrence 8. Chaque ligne jugée est écrite en
JSONL dans `tmp/bench/`, avec le modèle servi (`ResultSet#model`) et les ids des voisins.

**Critère, fixé avant exécution.** Une variante passe si, sur chacune des trois questions, son accord
est au moins celui de `control` moins 2 points (l'étendue observée au bras 6 sur six répétitions de
la forme de production).

**Lecture, fixée avant exécution.**

- `named_1` passe: la forme objet est gratuite.
- `named_same` passe et `named_2` échoue: la cause est le contenu étranger, la dilution est confirmée.
- `named_same` échoue: une seconde clé coûte par elle-même, quel que soit son contenu.
- `named_2` et `named_20` passent: les 9 points des bras 2 et 3 venaient de la forme `rows[id]`, et
  la question du batching par sujet est rouverte.
- Contamination: parmi les désaccords de `named_2`, la part où la réponse égale la réponse de
  référence du voisin, à comparer au hasard.

Budget: 888 requêtes, ~500 000 tokens d'entrée, ~0,02 $ au tarif emprunté.

Commande: `bin/rails judge:bench:named VARIANT=control|named_1|named_same|named_2|named_20`.
`DRY_RUN=1` imprime la première requête et n'appelle rien.

#### Résultats, 2026-09-23

888 requêtes, 668 120 tokens d'entrée, aucune erreur. Les 1 250 jugements ont été servis par
`jev-1.13.0`, le modèle du référentiel, vérifié sur `ResultSet#model` et non supposé.

| Variante | urgency | intent | frustration | Moyenne | Requêtes | Tokens | Temps mur |
|---|---|---|---|---|---|---|---|
| `control` | **99,2** | **98,8** | **97,6** | 98,5 | 250 | 134 664 | 9,55 s |
| `named_1` | 93,2 | 96,0 | 89,6 | 92,9 | 250 | 138 164 | 9,07 s |
| `named_same` | 92,8 | 94,0 | 82,4 | 89,7 | 250 | 211 828 | 9,85 s |
| `named_2` | 91,6 | 90,8 | 86,0 | 89,5 | 125 | 105 914 | 4,96 s |
| `named_20` | 84,4 | 84,0 | 85,2 | 84,5 | 13 | 77 550 | 0,80 s |

Seuil de passage: 97,2 / 96,8 / 95,6. **Aucune variante nommée ne passe, pas même `named_1`.**
`control` reproduit le bras 1 sur toute la population, spam compris, ce qui valide le harnais.

**Sens des désaccords**, montée ou descente de bande et de niveau par rapport au référentiel:

| Variante | urgency haut / bas | frustration haut / bas | Bascule d'intent dominante |
|---|---|---|---|
| `control` | 0 / 2 | 3 / 3 | aucune, 3 bascules isolées |
| `named_1` | 3 / 14 | 1 / 25 | aucune |
| `named_same` | 2 / 16 | 1 / 43 | sales vers spam x4 |
| `named_2` | 8 / 13 | 4 / 31 | billing vers technical x9 |
| `named_20` | 3 / 36 | 10 / 27 | billing vers technical x18 |

Au contrôle les désaccords sont symétriques, du bruit. Dans toutes les variantes nommées ils vont
dans un seul sens: **un ticket posé comme champ nommé d'un objet est lu plus calme et moins urgent.**
C'est un décalage de calibration systématique, pas une dispersion.

**Contamination à `named_2`**, désaccords égaux à la référence du voisin contre le hasard: urgency 7
contre 8,0, intent 2 contre 6,1, frustration 7 contre 10,1. **Les mauvaises réponses ne copient pas
le voisin.** Accord par position à `named_2`: 89,3 % pour `ticket_1`, 89,6 % pour `ticket_2`, aucun
effet de position.

#### Lecture, contre la grille fixée avant exécution

| Étape | Moyenne | Coût | Ce qui change |
|---|---|---|---|
| `control` | 98,5 | - | - |
| `named_1` | 92,9 | **-5,6** | la forme: objet à une clé, instruction qui nomme la clé |
| `named_same` | 89,7 | **-3,2** | une seconde clé, sans aucun contenu nouveau |
| `named_2` | 89,5 | **-0,3** | le contenu du voisin |
| `named_20` | 84,5 | -5,0 | 18 tickets de plus |

1. **`named_1` échoue: la forme objet n'est pas gratuite.** C'est la plus grosse marche mesurée, et
   elle est présente sans aucun voisin.
2. **`named_same` échoue: une seconde clé coûte par elle-même**, alors qu'elle ne porte que le même
   texte. La frustration y descend le plus fort, 43 fois sur 44 désaccords.
3. **Le contenu étranger ne coûte presque rien au lot de 2**: -0,3 point entre `named_same` et
   `named_2`, et une contamination au niveau du hasard ou en dessous. **La "dilution" au sens d'un
   voisin qui déteint sur la réponse n'est pas observée.**
4. **`named_20` échoue** au niveau de la forme B au lot 20 (85,6 / 89,6 / 86,8). Le batching par sujet
   reste fermé, quelle que soit la forme d'adressage.

**Ce que ça corrige.** L'explication écrite après le bras 5, "3 points de forme, 9 points de voisins",
est fausse dans sa répartition. Au lot de 2, la quasi-totalité du trou vient de la sortie de la forme
de production (-5,6) et de la présence d'une seconde clé (-3,2), pas de ce que le voisin raconte. Au
lot de 20, les 5 points supplémentaires restent non attribués: longueur du `state`, nombre de
questions et contenu étranger y changent ensemble.

**Ce que ce bras ne peut pas dire.** L'accord se mesure contre un référentiel produit en texte brut.
Un décalage vers "plus calme" est un désaccord avec la forme de production, pas forcément une erreur:
sans étiquettes humaines, on ne sait pas laquelle des deux lectures est la plus juste. Ce qu'on sait,
c'est qu'elles ne sont pas interchangeables, et que les seuils de la démo (0,8 et 0,2) sont calés sur
la forme texte. `named_1` confond aussi deux changements, l'objet et la réécriture de l'instruction
("this message" devient "ticket_1"); ce bras ne les sépare pas. Une seule exécution par variante, à
n=250 un ticket vaut 0,4 point, et les écarts retenus font 8 à 40 tickets.

**Décision inchangée.** Un sujet par requête, en texte brut, questions d'origine. Le pool de threads
reste la voie. Le bras 7 ne rouvre pas le batching; il remplace sa justification.

Brut: `judge_rails_demo/tmp/bench/arm7_*.jsonl`, snapshoté dans
`wiki/raw/transcripts/named-state-arm7-2026-09-23.md`.

### Étiquettes de référence. PRÉ-ENREGISTRÉ le 2026-09-23

**Pourquoi.** Tous les bras précédents mesurent un accord avec le texte brut, jamais une justesse.
`db/seed_tickets.rb` ne porte aucune étiquette. Sans référence, le décalage "plus calme, moins
urgent" du bras 7 ne peut pas être tranché.

**Forme.** Deux annotateurs indépendants étiquettent les 250 tickets sur les trois questions, avec
les définitions exactes de `app/models/ticket.rb`: urgency vrai ou faux, intent parmi les quatre
équipes, frustration de 0 à 3. Ils ne lisent que `db/seed_tickets.rb`, jamais un jugement de Jev.
L'un lit dans l'ordre, l'autre à rebours. Chaque annotateur marque les appels qu'il juge limites.

**Réserve, écrite avant de voir le résultat.** Les deux annotateurs sont des modèles (Claude Opus),
pas des humains. La référence retenue est leur **consensus**: un ticket compte pour une question
seulement si les deux sont d'accord. Les désaccords sont listés pour une relecture humaine. Tout
chiffre lu contre cette référence s'écrit "accord avec le consensus des annotateurs", jamais
"justesse".

Stockage: `db/ticket_labels.json`, clé `subject|customer_name` comme `db/seed_judgments.rb`.

### Analyses sans requête. PRÉ-ENREGISTRÉ le 2026-09-23

`bin/rails judge:eval:offline`. Lit `db/seed_judgments.rb` et `db/ticket_labels.json`, n'appelle rien.

1. **Justesse du référentiel** contre le consensus. urgency: décision à p >= 0,5 contre l'étiquette,
   plus le score de Brier. intent: argmax, plus le Brier multiclasse. frustration: niveau arrondi,
   plus l'écart absolu moyen.
2. **Bandes de confiance.** Part des tickets dans la bande `:unsure` du noul (0,2 < p < 0,8), et part
   des intents sous 0,6 de confiance. Pour chaque bande, l'accord avec le consensus. Si les
   réponses peu confiantes ne sont pas moins justes que les autres, la confiance ne dit rien ici.
3. **Recalibration.** Une température par question, ajustée par vraisemblance sur une moitié tirée
   au hasard (graine fixe), testée sur l'autre. Critère: elle ne s'adopte que si le Brier sur la
   moitié test baisse d'au moins 10 % contre l'identité. Sinon Jev est déclaré calibré sur ce jeu,
   à la précision de 125 tickets.

### Bras 7 bis. Le décalage des clés nommées est-il une constante. PRÉ-ENREGISTRÉ le 2026-09-23

Les JSONL du bras 7 ne gardent que les décisions, pas les probabilités. `named_1` est rejoué une fois
(250 requêtes, graine 7) en gardant les valeurs brutes. Sur une moitié, on estime le décalage moyen
en logit entre `named_1` et le référentiel, par question (urgency: logit de p; frustration: écart de
valeur continue). On le soustrait sur l'autre moitié.

**Lecture fixée.** Si l'accord de la moitié test avec le référentiel remonte à moins de 2 points du
contrôle, le décalage est une constante corrigible. Sinon il dépend du ticket. Dans les deux cas, le
consensus des annotateurs dit laquelle des deux lectures est la plus proche.

### Bras 8. Critères structurés. PRÉ-ENREGISTRÉ le 2026-09-23

**Pourquoi.** `docs.typesafe.ai/primitives/advanced.md` documente des options de Choice en objets
`{what, not_for, examples}` et des critères de Noul `true` et `false` en objets, "pour affiner la
frontière". Aucun chiffre publié. Jusqu'ici la gem convertissait toute entrée en chaîne; elle
accepte maintenant les objets, sans changer le digest d'un critère en chaîne.

**Forme.** Un sujet par requête, texte brut, trois questions, concurrence 8. Seuls les critères
d'urgency et d'intent changent. Le `what` reprend mot pour mot le texte d'origine, `not_for` et deux
`examples` génériques s'ajoutent. Aucun exemple n'est tiré des 250 tickets. frustration ne change
pas: elle sert de témoin, elle ne doit pas bouger.

| Variante | Critères | Requêtes |
|---|---|---|
| `current` | ceux de `ticket.rb` | 250 |
| `structured` | objets | 250 |
| `structured_replay` | objets, 50 premiers tickets rejoués | 50 |

**Critère, fixé avant exécution**, contre le consensus des annotateurs, `structured` contre
`current` du même jour:

- adopté si, sur urgency et sur intent, l'accord ne baisse pas de plus d'un point, et monte d'au
  moins 2 points sur l'une des deux, ou si le Brier baisse d'au moins 10 % sans perte d'accord;
- rejeté sinon. Le surcoût en tokens est rapporté, pas arbitré: au tarif confirmé il est négligeable.

`structured_replay` donne son plancher de bruit. frustration doit rester dans le bruit du bras 1.

Commande: `bin/rails judge:eval:criteria VARIANT=current|structured|structured_replay`.
Depuis la bascule de la démo, `current` s'appelle `plain`: les critères du modèle sont structurés, et
`plain` reconstruit les chaînes d'origine, digests `9e08ebfeb6e0e0fa` et `5f3c0bad775abc1c` compris.

### Bras 9. Limite de débit soutenue. PRÉ-ENREGISTRÉ le 2026-09-23

**Pourquoi.** `docs.typesafe.ai/models.md` documente 1 200 requêtes par minute et 250 000 tokens par
seconde. Le bras 6 envoyait 100 requêtes par niveau et ne pouvait pas remplir une minute. À 8
threads le pool tourne à ~28 requêtes par seconde, au-dessus de la limite documentée.

**Forme.** Forme de production, en boucle sur les 250 tickets, pendant 75 s, client sans aucune
relance (`max_retries = 0`) pour voir chaque 429 brut et son `Retry-After`. Niveaux enchaînés: 8,
puis 16, puis 32 seulement si 16 n'a vu aucun 429. Deux minutes de pause entre niveaux.

**Lecture fixée.**

- Des 429 à 8: la limite s'applique et le défaut de la gem la dépasse. Il faut un limiteur côté
  client ou un `max_retry_wait` qui couvre le `Retry-After` observé.
- Aucun 429 à 32 sur 75 s: la limite documentée n'est pas appliquée à cette clé aujourd'hui. Le
  défaut de 8 reste, avec la limite écrite dans le README.
- Entre les deux: le seuil observé est rapporté, et le défaut ne dépasse pas le dernier niveau sans 429.

Budget: au plus ~9 000 requêtes, ~4,8 M tokens, ~0,20 $ au tarif confirmé.

Commande: `bin/rails judge:eval:rate CONCURRENCY=8 DURATION=75`.

### Résultats des bras du 2026-09-23 (étiquettes, 7 bis, 8, 9)

Tout est servi par `jev-1.13.0`, vérifié sur `ResultSet#model`. Dépense totale: 8 462 588 tokens
d'entrée, **~0,36 $** au tarif confirmé. Le bras 9 a coûté 7,94 M tokens contre 4,8 M prévus: le
débit a doublé avec les threads, comme le reste, et le budget l'avait sous-estimé.

#### Étiquettes

| Question | Accord entre annotateurs | kappa | Consensus retenu |
|---|---|---|---|
| urgency | 96,4 % | 0,88 | 241 |
| intent | 88,4 % | 0,82 | 221 |
| frustration | 84,8 % | 0,75 | 212 |

Le désaccord dominant est instructif: 15 messages de remerciement sont `technical` pour l'un et
`spam` pour l'autre, parce que la définition de spam inclut "anything not a genuine support request".
Les critères de la démo n'ont pas de place pour un message qui n'est ni une demande ni du spam.

#### Analyses sans requête

| Question | Référentiel contre consensus | Brier |
|---|---|---|
| urgency, décision à 0,5 | 82,6 % | 0,1141 |
| intent | 84,2 % | 0,2285 |
| frustration, niveau arrondi | 60,8 % | écart moyen 0,399 |

**Les erreurs vont dans un seul sens.** Jev lit plus urgent (41 faux positifs, 1 faux négatif à 0,5)
et plus frustré (83 niveaux trop hauts, 0 trop bas) que les deux annotateurs. En intent, il dit
`billing` là où le consensus dit `technical` 18 fois.

**Bandes.** urgency sûre (p <= 0,2 ou >= 0,8): 97,7 % d'accord sur 131 tickets. Bande `:unsure`:
64,5 % sur 110. intent à confiance >= 0,6: 88,7 % sur 194; sous 0,6: 51,9 % sur 27. La confiance
trie bien les réponses: le routage de la bande incertaine a un sens ici.

**Température.** urgency +0,2 %, intent -0,2 %, frustration -9,3 % de Brier sur la moitié test. Aucune
ne franchit le seuil de 10 %: **pas de recalibration par température.**

**Exploratoire, non pré-enregistré, testé sur moitié tenue à l'écart.** Pour frustration, retrancher
0,5 avant l'arrondi, c'est-à-dire prendre la partie entière, fait passer l'accord de 62,7 % à
83,3 %. Pour urgency, le seuil de 0,5 donne 80,8 %; celui de 0,8 de la démo 92,5 %, au niveau du
meilleur seuil appris (0,75). Ce qui coûte, c'est la
lecture que la démo fait du nombre: l'arrondi et le seuil médian.

#### Bras 7 bis

Décalage appris sur 125 tickets: -0,164 en logit sur urgency, -0,083 en valeur sur frustration.
Écart-type par ticket 0,188, du même ordre que la moyenne. La correction fait remonter l'accord de la
moitié test avec le référentiel de 115 à 121 sur 125 en urgency, et de 110 à 113 en frustration.
**Le critère de 2 points n'est pas atteint: le décalage n'est pas une constante.**

Contre le consensus, en revanche, `named_1` fait mieux que le texte brut sur les trois questions:

| | urgency | intent | frustration |
|---|---|---|---|
| texte brut | 82,6 % (Brier 0,114) | 84,2 % (0,229) | 60,8 % |
| `named_1` | 85,9 % (0,099) | 86,4 % (0,213) | 70,3 % |

Le "plus calme, moins urgent" du bras 7 va **vers** les étiquettes. Le bras 7 mesurait un écart au
texte brut, et c'est le texte brut qui s'écarte le plus du consensus. Le batching par sujet n'est
pas rouvert pour autant: `named_20` n'a pas été relu contre les étiquettes.

#### Bras 8

| Variante | urgency | intent | frustration | Tokens / ticket |
|---|---|---|---|---|
| `current` | 82,6 % (Brier 0,1141) | 85,1 % (0,2271) | 62,3 % | 539 |
| `structured` | **86,7 %** (0,0897) | **89,6 %** (0,1608) | 61,8 % | 825 |

Contre le consensus. `current` reproduit le référentiel (98,8 / 99,2 / 98,8 %). `structured` contre
son propre rejeu sur 50 tickets: 50/50, 50/50, 49/50, dérive moyenne 0,008. frustration, le témoin,
reste dans le bruit.

**Critère atteint: adopté.** +4,1 et +4,5 points, Brier -21 % et -29 %. Les erreurs `billing` au lieu
de `technical` passent de 18 à 12. Surcoût: +286 tokens par ticket, +53 %, soit ~0,000012 $.

Réserve lue après coup: au seuil d'escalade de la démo (0,8) et non à 0,5, urgency passe de 91,3 % à
90,0 %, trois tickets. Le gain d'urgency tient au Brier et au seuil médian; celui d'intent tient
partout. La démo n'est pas basculée: changer ses critères invalide les 250 jugements committés, et
la référence reste un consensus de modèles.

#### Bras 9

| Threads | Requêtes | Débit | Max sur 60 s | 429 | Latence p50 / p95 |
|---|---|---|---|---|---|
| 8 | 2 187 | 29,2 /s | 1 758 | 0 | 0,268 / 0,336 s |
| 16 | 4 214 | 56,2 /s | 3 393 | 0 | 0,277 / 0,361 s |
| 32 | 8 355 | 111,4 /s | 6 696 | 0 | 0,279 / 0,371 s |

Aucun 429, aucune erreur, sur 14 756 requêtes sans relance. À 32 threads, 5,6 fois la limite
documentée par minute et ~60 000 tokens par seconde, un quart de la limite en tokens. La latence ne
bouge pas. **Lecture fixée: la limite documentée n'est pas appliquée à cette clé aujourd'hui.** Le
défaut de 8 reste; la limite et cette mesure sont écrites dans le README de la gem, avec la réserve
du fournisseur ("can change without notice").

Brut: `judge_rails_demo/tmp/bench/arm7bis_named_1.jsonl`, `arm8_*.jsonl`, `arm9_c*.jsonl`, snapshotés
dans `wiki/raw/transcripts/labels-and-arms-8-9-2026-09-23.md`.

---

## 7. Critère d'acceptation, et le verdict

### VERDICT, 2026-09-21: le batching par sujet ne passe pas, et la cause est structurelle.

Le critère dur exigeait un accord de 100 % sur le label du choice, sur la bande du noul et sur le
niveau du score. **Il échoue à toutes les tailles de lot, y compris 2.** Lu relativement au bras 1
comme le prévoit la section ci-dessous, l'écart reste de 9 à 15 points d'accord et la dérive est de
5 à 16 fois le plancher de bruit du contrôle.

Le batching tel qu'implémenté échange 10 à 15 points de justesse de décision contre 49x de vitesse.
Pour une gem dont le produit est une probabilité calibrée, ce n'est pas un compromis acceptable par
défaut, et ce protocole a été écrit avant de connaître ce résultat précisément pour ne pas pouvoir
le rationaliser après coup.

`Judge::Batch` reste dans `lib/`, testé et non câblé. `Judge.config.batch_rows` reste à `nil`. Aucun
chemin de la gem ne batche.

### La suite, décidée par le bras 5

**Corrigé le 2026-09-23.** La répartition "3 de forme, 9 des voisins" ci-dessous est réfutée par le
bras 7, et le bras 7 bis montre que la forme nommée est plus proche des étiquettes que le texte brut.
La recommandation (le pool de threads) tient pour d'autres raisons, écrites au bras 7.

Le bras 5 a été exécuté et il ferme la question: sur les 12 points perdus, 3 viennent de la forme et
9 des voisins. Réparer la forme laisserait encore 9 points sur la table, donc il n'y a pas de version
du batching par sujet qui repasse le critère dur.

**Ce qu'il faut construire à la place, et que la mesure soutient:**

1. **Un pool de threads sur `judge_filter`, sans batching.** Même forme de requête qu'aujourd'hui, donc
   **zéro perte d'exactitude**, et c'est la solution que le cookbook Re-Ranking applique à 3 565
   passages. Le bras 4 mesure 7,8x pour 8 threads, et le bras 5 le confirme sur l'API réelle: 150
   tickets en 5,44 s à 8 threads, soit 0,036 s par ticket contre 0,270 s en série.
2. **Ne pas câbler `Judge::Batch`.** Il reste dans `lib/`, testé, avec ce document comme raison écrite.
3. **Passer `[[typesafe-jev]]` en `high`** sur la latence plate en fonction du nombre de questions,
   qui est maintenant mesurée.

### Le critère, tel qu'il était fixé

Double budget, fixé avant l'exécution.

**Dur, doit passer sinon le batching ne ships pas à cette taille de lot:**

- accord 100 % sur le label du choice
- accord 100 % sur la bande de `judge_decide` du noul, aux seuils de la démo
- accord 100 % sur le niveau entier du score

**Souple, à lire comme une courbe et pas comme un seuil:**

- `|Δp|` moyen et p95 par taille de lot et par type de question
- distance de variation totale sur la distribution du choice
- écart de valeur continue du score

Les deux budgets se lisent **relativement au bras 1**, jamais dans l'absolu. Si le contrôle non
batché dérive lui-même de 0,03 en `|Δp|` moyen, un batching à 0,03 n'a rien dégradé.

`batch_rows` par défaut sera la plus grande taille de lot qui passe le budget dur et dont la dérive
souple reste au niveau du contrôle. Pas 20 parce que pg_jev dit 20.

---

## 8. Ce qui reste à protéger

- Le référentiel actuel doit être snapshoté dans `wiki/raw/transcripts/` avec son sha256 **avant**
  toute régénération de `db/seed_judgments.rb`, sinon la ligne de base disparaît.
- Les bras 0 à 3 ne tournent jamais dans `rake test`. La règle maison est de ne jamais appeler l'API
  réelle depuis un test. Ils seront une tâche manuelle. Le bras 4 vit dans `bin/bench_batch`, hors
  suite, et seule sa version réduite est un test.
- Le batching élargit le rayon de souffle d'une injection de prompt de 1 à `batch_rows`, puisque les
  lignes partagent un `state` et que la documentation du vendeur décrit le modèle comme orientable
  par instructions injectées. Ce protocole ne le mesure pas. Un bras adverse serait à écrire
  séparément.

---

## 8 bis. La recette de requête optimale, telle que mesurée

Trois règles, chacune adossée à un bras.

| Règle | Bras | Gain | Coût en exactitude |
|---|---|---|---|
| **Un seul sujet par requête** | 2, 3, 5, 7 | - | quitter le texte brut coûte ~6 points d'accord avec le référentiel, un voisin ~0,3 (bras 7). Contre les étiquettes, la forme nommée fait mieux (bras 7 bis) |
| **Toutes les questions du sujet dans la même requête** | 0 | overhead de 326 tokens amorti, latence plate jusqu'à 40 questions | **zéro** |
| **Éventail de threads sur les sujets** | 6 | 6,95x à 8 threads, 18,4x à 32 | **zéro** |

La gem applique désormais les trois: `storage.rb:26-34` groupe les questions d'un enregistrement en
un appel, et `relation.rb` déploie les enregistrements sur un pool.

## 9. Journal

### 2026-09-21, phase A

Écrit: `lib/judge/batch.rb` (moteur L2, stdlib seule), `Judge::PayloadTooLargeError` dans la taxonomie,
`batch_rows` et `concurrency` sur la configuration à `nil`, `test/batch_test.rb` (22 tests),
`test/batch_throughput_test.rb` (6 tests), `bin/bench_batch`.

Mesuré: 200 tests verts contre 172 avant, 580 assertions, zéro offense rubocop, et les trois
gemfiles Rails 7.2, 8.0 et 8.1 verts. Bras 4 exécuté, tableau ci-dessus.

Deux corrections au protocole, faites en l'exécutant:

1. Le bras 4 ne peut pas vivre dans la suite de tests. À la latence mesurée de 0,300 s, 250 lignes
   en séquentiel coûtent 76 secondes.
2. `rows:` ne porte aucun plafond d'exactitude. La version précédente de ce plan en prévoyait un à
   25, ce qui aurait empêché les bras 2 et 3 de mesurer un lot de 40. La courbe mesurée est le
   garde-fou, pas une constante devinée.

Décision de nommage: les questions s'appellent `row0`, `row1` sur le fil, en normalcase, parce que
`row_0` accroche `Naming/VariableNumber` et que la seule alternative était de suppimer le cop ou de
modifier un fichier de test préexistant qui n'appartient pas à ce chantier.

### 2026-09-21, phase B

Écrit: `judge_rails/bin/arm0_latency`, `judge_rails_demo/lib/tasks/judge_bench.rake`,
`wiki/raw/transcripts/seed-judgments-baseline-2026-09-21.md` (sha256
`0b358b56125d79dfef0b42c351d63c5c603c99066263b78f287fe643457a5839`). `Judge::Batch.judge` étendu pour
accepter un Hash de questions, ce que le bras 3 exigeait. 206 tests verts, zéro offense.

Corrigé au passage: `config/initializers/judge.rb` de la démo ne lisait que `JEV_API_KEY`, alors que
`Judge::Configuration` accepte `TYPESAFE_API_KEY` en repli depuis toujours. La démo accepte les deux
maintenant.

Dépense réelle de la campagne: environ 1 000 requêtes et ~1,40 million de tokens d'entrée, soit
**~0,06 $** au tarif emprunté de 0,042 $/M. Le budget projeté était de 0,03 $ pour 430 requêtes; le
diagnostic supplémentaire au lot de 2 a doublé le volume.

Aucune écriture en base. `db/seed_judgments.rb` est intact, et le batché ne l'a jamais touché.

### 2026-09-21, phase C révisée

Le batching par sujet n'est pas câblé et ne le sera pas. Ce qui a été câblé à la place:

- `lib/judge/pool.rb`, nouveau. `Judge::Pool.map(items, concurrency:)`, ordre d'entrée préservé,
  concurrence 1 exécutée en ligne sans thread, première erreur relancée après l'arrêt de tous les
  workers. `Judge::Batch` s'appuie dessus, donc le code de threads n'existe qu'une fois.
- `lib/judge/rails/relation.rb`. `judge_filter`, `judge_map` et `judge_sort` prennent `concurrency:` et
  déploient sur le pool. Les `state` sont construits sur le thread appelant avant l'éventail, donc
  aucun worker ne touche une connexion ActiveRecord.
- Défaut: `concurrency:` explicite, sinon `Judge.config.concurrency`, sinon 8.

219 tests verts contre 172 au départ, zéro offense, Rails 7.2, 8.0 et 8.1 verts.

### 2026-09-23, étiquettes et bras 7 bis, 8, 9

Écrit: `db/ticket_labels.json` (deux annotateurs modèles, consensus), `lib/tasks/judge_eval.rake`
(`judge:eval:offline`, `named_values`, `criteria`, `rate`). Dans la gem, `Question::Choice` et
`Question::Noul` acceptent des entrées objet ou tableau; une entrée chaîne garde son digest, vérifié
sur les trois digests du référentiel. 263 tests verts sur Rails 7.2, 8.0 et 8.1, zéro offense. Démo:
42 tests verts, zéro offense.

Corrigé en relisant: le README de la gem montrait `question.digest # => "9e08ebfeb6e0e0fa"` pour un
choice. C'est le digest de la question urgency de la démo; la valeur réelle est `1c3be3cf24579b81`.

Pré-enregistré avant toute requête, exécuté ensuite. La clé est lue dans l'environnement du shell
à chaque commande, jamais écrite dans le projet.

### 2026-09-23, la démo passe aux critères structurés

Décidé par le propriétaire après le bras 8. `app/models/ticket.rb` déclare urgency et intent avec les
critères du bras 8, mot pour mot. Les bancs suivent sans modification, puisqu'ils lisent les
définitions du modèle: `judge_bench.rake` (bras 1 à 7) et `judge_eval.rake`. Les deux bancs de la gem,
`bin/arm0_latency` et `bin/bench_batch`, déclarent la même forme.

**Le référentiel a changé.** `db/seed_judgments.rb` est régénéré: 250 requêtes, `jev-1.13.0` sur les
250, digests urgency `4f1911289ec33ca2` et intent `4234fcadf9f795b9`, frustration inchangée
`d3f59e90f1ce9b41`. Contre le rejeu structuré du bras 8: 246/250, 250/250 et 243/250, dans le bruit
du bras 1. L'ancien référentiel est snapshoté dans
`wiki/raw/transcripts/seed-judgments-plain-2026-09-23.md`. Tout bras rejoué à partir d'ici se lit
contre le référentiel structuré, pas contre celui des chiffres ci-dessus.

Nouveau référentiel contre le consensus: urgency 88,4 % (Brier 0,090), intent 89,6 % (0,162),
frustration 62,3 %. Bandes sûres: urgency 99,2 % sur 133, intent 93,9 % sur 196. Aucune température
ne franchit encore 10 % (urgency -6,7 %, frustration -9,5 %).

`db:seed` sur une base vide restaure 250 jugements, 0 périmé. Démo: 42 tests verts, zéro offense.

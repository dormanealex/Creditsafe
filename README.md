# Surveillance Creditsafe des débiteurs professionnels

Programme Harbour `creditsafe.prg` qui utilise l'API Creditsafe Connect v1 (Global Monitoring).

| Commande | Rôle |
|---|---|
| `creditsafe` | ouvre le **menu** (toutes les fonctions ci-dessous, plus le bilan, les réglages et le journal) |
| `creditsafe TEST` | teste les identifiants et liste les portefeuilles du compte |
| `creditsafe SURVEIL` | met en surveillance les débiteurs de `DebSiren.dbf` (par SIREN, ou par nom + adresse si le SIREN manque) |
| `creditsafe ALERTES` | récupère les alertes dans `CsAlertes.dbf` |

Un 2ᵉ argument facultatif indique un autre fichier de paramètres : `creditsafe SURVEIL d:\autre.ini`.

**Tâches planifiées** : indiquez toujours la fonction (`creditsafe ALERTES`, `creditsafe SURVEIL`). Sans argument,
le programme ouvre le menu et attend qu'on appuie sur une touche.

## Menu

`creditsafe` sans argument (ou `creditsafe MENU [fichier.ini]`) affiche l'environnement (SANDBOX/LIVE), le mode
(simulation ou réel) et le nombre maximum de débiteurs, puis propose :

| Choix | Fonction |
|---|---|
| 1 | Tester la connexion Creditsafe (comme `creditsafe TEST`) |
| 2 | Mettre en surveillance les débiteurs (comme `creditsafe SURVEIL`). En mode réel, une confirmation est demandée |
| 3 | Récupérer les alertes (comme `creditsafe ALERTES`) |
| 4 | Bilan du fichier de suivi : nombre de débiteurs par statut (dernier traitement de chacun), en réel et en simulation |
| 5 | **Débiteurs à vérifier** : liste des `A_VERIFIER` (dernier traitement de chaque débiteur), avec la société proposée, son SIREN et sa note. Clic sur une ligne : détail (débiteur, société proposée, 2ᵉ société trouvée) et bouton **Copier le SIREN** |
| 6 | Passer en mode réel ou en simulation, **pour la session seulement** (confirmation pour passer en réel) |
| 7 | Nombre maximum de débiteurs à traiter, **pour la session seulement** |
| 8 | Modifier les paramètres dans le Bloc-notes, puis les recharger |
| 9 | Consulter le journal dans le Bloc-notes |
| 0 | Quitter (ou Échap) |

Le menu s'ouvre dans une **fenêtre Windows** (GTWVT, fourni avec Harbour) et se pilote **à la souris** :

* un clic sur un choix le lance (le survol le met en surbrillance) ;
* les questions et les fins de traitement affichent des **boutons cliquables** (Oui / Non, Retour au menu…) ;
* pendant un traitement, le bouton **Arrêter** (ou Échap) arrête proprement après le débiteur en cours ;
* la croix de la fenêtre fait de même, puis ferme le programme ;
* agrandir la fenêtre agrandit les caractères.

Lancé par double-clic, le programme ferme la console vide ouverte par Windows. Les lancements avec argument
(`SURVEIL`, `ALERTES`, `TEST`, donc les tâches planifiées) restent en console, sans fenêtre.

Au clavier, on choisit avec les flèches et Entrée, ou en tapant le chiffre. Les choix 6 et 7 ne modifient pas le fichier `.ini` :
ils sont signalés « modifié pour cette session » et sont perdus à la sortie, ou quand on recharge les paramètres (choix 8).

## Compilation (Windows)

```
hbmk2 creditsafe.hbp
```

Le programme utilise `MSXML2.ServerXMLHTTP.6.0` via `hbwin` : rien d'autre à installer.

## Paramétrage : `creditsafe.ini`

Tout est modifiable sans recompiler : le dossier (`\source\creditsafe`), le fichier débiteurs (`DebSiren.dbf`),
les noms des champs (SIREN, CA, CODERELA, NOM, ADRESSE, CP, VILLE), un filtre facultatif, l'environnement (SANDBOX/LIVE), le préfixe
des portefeuilles, etc. Les identifiants peuvent être mis dans les variables d'environnement
`CREDITSAFE_USER` / `CREDITSAFE_PASSWORD` plutôt que dans le fichier.

`SIMULATION=1` est le réglage par défaut : le programme cherche les sociétés mais ne crée rien chez Creditsafe.

## Fichiers DBF et index

* Tous les DBF sont ouverts avec le RDD **SIXCDX** (index `.cdx` compatibles SIx Driver / Comix).
* **Codepage des DBF : FR850** (`[GENERAL] CODEPAGE_DBF=FR850`). Harbour convertit automatiquement les données
  vers le codepage du programme (`CODEPAGE=FRWIN`).
* `DebSiren.dbf` est ouvert en partagé, en lecture seule. Son `.cdx` de production est ouvert s'il existe,
  mais la lecture se fait dans l'ordre physique.
* `CsSuivi.dbf` et `CsAlertes.dbf` sont créés avec un index de production `.cdx`. Les tags manquants sont
  recréés automatiquement, ce qui demande que le fichier ne soit pas ouvert par un autre programme à ce moment-là :

| Fichier | Tag | Clé |
|---|---|---|
| CsSuivi.cdx | CLE | `SERIE+SIREN_ORI` |
| | SIREN | `SIREN` |
| | CSID | `CS_ID` |
| | PORTF | `PORTF_NOM+SIREN` |
| CsAlertes.cdx | NOTIF | `NOTIF_ID` |
| | SIREN | `SIREN+DTOS(D_EVT)` |
| | DATE | `DTOS(D_EVT)` |
| | CSID | `CS_ID` |

## Fonctionnement de `SURVEIL`

1. Authentification : `POST /authenticate`, puis jeton `Bearer`, renouvelé automatiquement en cas de 401.
2. Pour chaque débiteur de `DebSiren.dbf` qui a un SIREN ou un SIRET (ou, sans SIREN, un nom et un code postal
   ou une ville : voir plus bas) :
   * **série** = 2 premières lettres de `CA`, sinon de `CODERELA`, sinon `SERIE_PAR_DEFAUT` ;
   * **portefeuille** = `PREFIXE_NOM` + série (ex. `DEBITEURS-AB`), créé s'il n'existe pas
     (`POST /monitoring/portfolios`), avec facultativement les e-mails d'alerte et la copie des règles
     d'un portefeuille modèle ;
   * contrôle du SIREN (le SIRET est ramené à 9 chiffres, puis clé de Luhn) ;
   * recherche : `GET /companies?countries=FR&regNo=<SIREN>`. Le siège est choisi en priorité, sinon une société active ;
   * ajout : `POST /monitoring/portfolios/{id}/companies` avec `personalReference` = CA (ou CODERELA)
     et `freeText` = nom du débiteur.
3. Chaque traitement est tracé dans **`CsSuivi.dbf`** :

| Champ | Contenu |
|---|---|
| DATE_TRT, HEURE, MODE | date, heure, REEL ou SIMUL |
| SERIE, CA, CODERELA, NOM_DEB, DEB_RECNO | débiteur d'origine |
| ADR_DEB, CP_DEB, VILLE_DEB | adresse du débiteur (utilisée pour la recherche par nom) |
| METHODE, SCORE | `SIREN` ou `NOM` ; note de la recherche par nom (sur 100) |
| SIREN_ORI / SIREN | valeur du fichier (`N:…` = clé nom + adresse) / SIREN normalisé ou trouvé |
| CS_ID, SAFENO, CS_REGNO | identifiant Creditsafe (connectId), safe number, n° d'immatriculation |
| CS_NOM, CS_ADRESSE, CS_CP, CS_VILLE, CS_STATUT, CS_TYPE, NB_RESULT | société trouvée |
| PORTF_NOM, PORTF_ID | portefeuille |
| STATUT | `AJOUTE`, `DEJA`, `INTROUVABLE`, `INVALIDE`, `ERREUR`, `SIMULE`, `A_VERIFIER` |
| HTTP, MESSAGE | code retour et message de l'API |

Le programme peut être relancé sans risque. Les couples série + SIREN déjà `AJOUTE`, `DEJA` ou `INVALIDE` (en mode REEL)
sont ignorés. Les `INTROUVABLE` et `ERREUR` sont retentés.

Un `CsSuivi.dbf` créé par une version précédente reçoit automatiquement les nouveaux champs : l'ancien fichier est
gardé sous `CsSuivi_av.dbf` et ses enregistrements sont recopiés (le fichier doit être libre à ce moment-là).

## Interrompre un traitement en cours

`SURVEIL` et `ALERTES` peuvent être arrêtés proprement en cours de route :

* **touche Échap** dans la fenêtre du programme ;
* ou **création du fichier d'arrêt** `creditsafe.stop` dans le dossier des fichiers (`[GENERAL] FICHIER_ARRET`).
  C'est le moyen à utiliser quand le programme tourne en tâche planifiée, sans fenêtre. Par exemple :
  `type nul > \source\creditsafe\creditsafe.stop`.

Le débiteur en cours (ou la page d'alertes en cours) est terminé. Le programme s'arrête ensuite normalement :
fichiers fermés, bilan écrit dans le log, fichier d'arrêt supprimé. Un fichier d'arrêt resté d'une fois précédente
est supprimé au démarrage. Pour reprendre, il suffit de relancer : en mode REEL, les débiteurs déjà traités
sont sautés. Éviter Ctrl+C, Alt+C ou la fermeture de la fenêtre, qui coupent le programme sans fermer les fichiers.

## Débiteurs sans SIREN : recherche par nom et adresse

Avec `[RECHERCHE] PAR_NOM=1`, un débiteur sans SIREN est recherché par son nom (`[CHAMPS] NOM`) et son adresse
(`[CHAMPS] ADRESSE`, `CP`, `VILLE`). Plusieurs champs peuvent être concaténés, par exemple `ADRESSE=ADR1+ADR2`.
Pour le nom, `NOM=RS|NOM` prend le premier champ non vide : la raison sociale, sinon le nom.

1. Il faut un nom et au moins un code postal ou une ville. Sinon le débiteur est ignoré, sauf avec `NOM_SEUL=1`
   (déconseillé : on obtient trop d'homonymes dans toute la France).
2. Recherche : `GET /companies?countries=FR&name=<nom>&postCode=<cp>`, puis `&city=<ville>` si rien n'est trouvé.
   Le nom est envoyé sans accents et sans forme juridique (SARL, SAS, ETS…).
3. Chaque société trouvée reçoit une **note sur 100** :
   nom 60 (mots communs, nom contenu dans l'autre, fautes de frappe, nom commercial) + code postal 25
   (même département : 10) + ville 5 + rue et numéro 10, avec −5 si la société n'est pas active.
4. Décision :

| Résultat | Statut | Effet |
|---|---|---|
| note ≥ `SCORE_AUTO` (80) **et** au moins `ECART_MIN` (10) points devant une autre société (autre SIREN) | `AJOUTE` / `SIMULE` | le SIREN trouvé est relu (choix du siège), puis la société est mise en surveillance |
| note ≥ `SCORE_MIN` (55) | `A_VERIFIER` | rien n'est ajouté ; la proposition (CS_NOM, SIREN, CS_ID, adresse) et la 2ᵉ société sont dans `CsSuivi.dbf` |
| sinon | `INTROUVABLE` | la meilleure société est quand même citée dans MESSAGE |

Sans code postal, la note ne peut pas atteindre 80 : un débiteur identifié par sa seule ville part donc toujours
en `A_VERIFIER`.

**Traiter un `A_VERIFIER`** : contrôler la proposition (menu, choix 5), puis reporter le SIREN dans `DebSiren.dbf`. Au passage suivant,
le débiteur est traité comme un débiteur avec SIREN. En mode REEL, les `A_VERIFIER` et `INTROUVABLE` trouvés par nom
ne sont pas relancés à chaque passage (pour ne pas consommer de recherches). Ils le sont si le nom ou l'adresse du
débiteur change, ou si la ligne est supprimée de `CsSuivi.dbf`.

Les particuliers n'ont pas de SIREN : sans `FILTRE`, ils sont eux aussi recherchés par nom. Un particulier homonyme
d'une entreprise individuelle peut alors être proposé. Il vaut donc mieux renseigner `[CHAMPS] FILTRE`
(ex. `TYPEDEB=="P"`) pour ne garder que les professionnels.

## Récupérer les alertes

Trois possibilités, à combiner si besoin :

1. **Par e-mail** : renseigner `[PORTEFEUILLE] EMAILS=` avant la création des portefeuilles. Creditsafe envoie alors
   les alertes à ces adresses. On peut aussi le régler pour chaque portefeuille sur le site Creditsafe.
2. **Sur le site Creditsafe**, rubrique *Monitoring / Surveillance* : il y a un portefeuille par série.
3. **Par l'API, automatiquement** : `creditsafe ALERTES` (à planifier chaque nuit avec le Planificateur de tâches Windows).
   * Pour chaque portefeuille `DEBITEURS-xx` :
     `GET /monitoring/portfolios/{id}/notificationEvents?startDate=…&endDate=…&isProcessed=false&page=…&pageSize=100`
   * Les alertes sont écrites dans **`CsAlertes.dbf`** : NOTIF_ID, date, société, règle (RULECODE, LIBELLE),
     ancienne et nouvelle valeur, rattachées au **SIREN, à la série, au CA et au CODERELA** grâce à `CsSuivi.dbf`.
     Le programme ne crée pas de doublons (clé NOTIF_ID).
   * Avec `MARQUER_TRAITEES=1`, chaque alerte importée est marquée comme traitée chez Creditsafe
     (`PATCH …/notificationEvents/{id}` `{"isProcessed": true}`).

Les **règles d'alerte** (changement de score, de limite de crédit, procédure collective, radiation, changement
d'adresse, de dirigeant…) se choisissent par portefeuille et par pays (`/monitoring/portfolios/{id}/eventRules/FR`).
Le plus simple est de régler un portefeuille modèle sur le site, puis d'indiquer son id dans
`PORTEFEUILLE_MODELE_REGLES` : ses règles sont copiées vers chaque nouveau portefeuille.

## À vérifier dans la sandbox avant de passer en LIVE

La documentation `doc.creditsafe.com` n'a pas pu être consultée pendant l'écriture du programme. Les points suivants
sont donc à vérifier avec `SIMULATION=0`, `ENVIRONNEMENT=SANDBOX` et `MAX_DEBITEURS=10` :

* le nom exact des champs de réponse (`portfolioId`, `notificationEventId`, `ruleName`…). Le programme accepte
  plusieurs variantes, mais il faut contrôler `CsSuivi.dbf` et `CsAlertes.dbf` ;
* la numérotation des pages (à partir de 0 ou de 1). Le programme ne crée pas de doublons dans les deux cas ;
* le format attendu par le `PUT` des règles d'alerte (copie depuis le modèle) ;
* le nombre de sociétés que votre contrat autorise en surveillance.

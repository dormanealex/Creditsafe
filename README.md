# Surveillance Creditsafe des débiteurs professionnels

Programme Harbour `creditsafe.prg` qui utilise l'API Creditsafe Connect v1 (Global Monitoring).

| Commande | Rôle |
|---|---|
| `creditsafe TEST` | teste les identifiants et liste les portefeuilles du compte |
| `creditsafe SURVEIL` | met en surveillance les débiteurs de `DebSiren.dbf` |
| `creditsafe ALERTES` | récupère les alertes dans `CsAlertes.dbf` |

Un 2ᵉ argument facultatif indique un autre fichier de paramètres : `creditsafe SURVEIL d:\autre.ini`.

## Compilation (Windows)

```
hbmk2 creditsafe.hbp
```

Le programme utilise `MSXML2.ServerXMLHTTP.6.0` via `hbwin` : rien d'autre à installer.

## Paramétrage : `creditsafe.ini`

Tout est modifiable sans recompiler : le dossier (`\source\creditsafe`), le fichier débiteurs (`DebSiren.dbf`),
les noms des champs (SIREN, CA, CODERELA, NOM), un filtre facultatif, l'environnement (SANDBOX/LIVE), le préfixe
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
2. Pour chaque débiteur de `DebSiren.dbf` qui a un SIREN ou un SIRET :
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
| SIREN_ORI / SIREN | valeur du fichier / SIREN normalisé |
| CS_ID, SAFENO, CS_REGNO | identifiant Creditsafe (connectId), safe number, n° d'immatriculation |
| CS_NOM, CS_ADRESSE, CS_CP, CS_VILLE, CS_STATUT, CS_TYPE, NB_RESULT | société trouvée |
| PORTF_NOM, PORTF_ID | portefeuille |
| STATUT | `AJOUTE`, `DEJA`, `INTROUVABLE`, `INVALIDE`, `ERREUR`, `SIMULE` |
| HTTP, MESSAGE | code retour et message de l'API |

Le programme peut être relancé sans risque. Les couples série + SIREN déjà `AJOUTE`, `DEJA` ou `INVALIDE` (en mode REEL)
sont ignorés. Les `INTROUVABLE` et `ERREUR` sont retentés.

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

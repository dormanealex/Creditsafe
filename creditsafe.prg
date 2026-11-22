/*
 * creditsafe.prg
 * Mise en surveillance automatique des debiteurs professionnels sur Creditsafe
 * (API Connect v1 - Global Monitoring) et recuperation des alertes.
 *
 * Utilisation :
 *    creditsafe SURVEIL  [fichier.ini]   -> met les debiteurs en surveillance
 *                                           (par SIREN, ou par nom + adresse si pas de SIREN)
 *    creditsafe ALERTES  [fichier.ini]   -> recupere les alertes (notification events)
 *    creditsafe TEST     [fichier.ini]   -> teste l'authentification et liste les portefeuilles
 *
 * Par defaut le fichier de parametres est creditsafe.ini (a cote de l'executable).
 *
 * Compilation (Windows) :  hbmk2 creditsafe.hbp
 */

#include "fileio.ch"
#include "dbstruct.ch"
#include "inkey.ch"

REQUEST HB_CODEPAGE_FRWIN
REQUEST HB_CODEPAGE_FR850
REQUEST HB_CODEPAGE_FRISO
REQUEST SIXCDX

#define CRLF  Chr( 13 ) + Chr( 10 )

STATIC s_hIni      := NIL
STATIC s_cIniFile  := ""
STATIC s_cBaseUrl  := ""
STATIC s_cToken    := ""
STATIC s_nLog      := -1
STATIC s_lSimul    := .F.

/* -------------------------------------------------------------------------- */

PROCEDURE Main( cMode, cIni )

   hb_default( @cMode, "SURVEIL" )
   hb_default( @cIni, hb_FNameExtSet( hb_ProgName(), ".ini" ) )
   cMode := Upper( AllTrim( cMode ) )

   SET DATE FRENCH
   SET CENTURY ON
   SET DELETED ON
   SET EXCLUSIVE OFF
   SET AUTOPEN ON
   rddSetDefault( "SIXCDX" )

   IF ! ChargeConfig( cIni )
      RETURN
   ENDIF

   hb_cdpSelect( Cfg( "GENERAL", "CODEPAGE", "FRWIN" ) )
   s_lSimul := Cfg( "GENERAL", "SIMULATION", "0" ) == "1"
   IF Upper( Cfg( "API", "ENVIRONNEMENT", "SANDBOX" ) ) == "LIVE"
      s_cBaseUrl := Cfg( "API", "URL_LIVE", "https://connect.creditsafe.com/v1" )
   ELSE
      s_cBaseUrl := Cfg( "API", "URL_SANDBOX", "https://connect.sandbox.creditsafe.com/v1" )
   ENDIF
   IF Right( s_cBaseUrl, 1 ) == "/"
      s_cBaseUrl := hb_StrShrink( s_cBaseUrl, 1 )
   ENDIF

   OuvreLog()
   CsLog( "===== Debut " + cMode + " - API " + s_cBaseUrl + iif( s_lSimul, " - MODE SIMULATION", "" ) + " =====" )

   DO CASE
   CASE cMode == "SURVEIL"
      MiseEnSurveillance()
   CASE cMode == "ALERTES"
      RecupereAlertes()
   CASE cMode == "TEST"
      TestConnexion()
   OTHERWISE
      CsLog( "Mode inconnu : " + cMode + "  (SURVEIL, ALERTES ou TEST)" )
   ENDCASE

   CsLog( "===== Fin " + cMode + " =====" )
   IF s_nLog != -1
      FClose( s_nLog )
   ENDIF

   RETURN

/* ==========================================================================
 *  1) MISE EN SURVEILLANCE
 * ========================================================================== */

STATIC PROCEDURE MiseEnSurveillance()

   LOCAL cFicDeb   := CheminFichier( Cfg( "GENERAL", "FICHIER_DEBITEURS", "DebSiren.dbf" ) )
   LOCAL cFicSuivi := CheminFichier( Cfg( "GENERAL", "FICHIER_SUIVI", "CsSuivi.dbf" ) )
   LOCAL cChSiren  := Cfg( "CHAMPS", "SIREN", "SIREN" )
   LOCAL cChCA     := Cfg( "CHAMPS", "CA", "CA" )
   LOCAL cChRela   := Cfg( "CHAMPS", "CODERELA", "CODERELA" )
   LOCAL cChNom    := Cfg( "CHAMPS", "NOM", "NOM" )
   LOCAL cChLimite := Cfg( "CHAMPS", "LIMITE", "" )
   LOCAL nPosLim   := 0
   LOCAL cFiltre   := Cfg( "CHAMPS", "FILTRE", "" )
   LOCAL lLuhn     := Cfg( "CHAMPS", "CONTROLE_LUHN", "1" ) == "1"
   LOCAL nMax      := Val( Cfg( "GENERAL", "MAX_DEBITEURS", "0" ) )
   LOCAL nPause    := Val( Cfg( "API", "PAUSE_MS", "250" ) ) / 1000
   LOCAL cPrefixe  := Cfg( "PORTEFEUILLE", "PREFIXE_NOM", "DEBITEURS-" )
   LOCAL cSerieDef := Cfg( "PORTEFEUILLE", "SERIE_PAR_DEFAUT", "ZZ" )
   LOCAL bFiltre, hVu := { => }, hPort, hStat := { => }
   LOCAL lParNom   := Cfg( "RECHERCHE", "PAR_NOM", "0" ) == "1"
   LOCAL lNomSeul  := Cfg( "RECHERCHE", "NOM_SEUL", "0" ) == "1"
   LOCAL aPosAdr, aPosCP, aPosVille
   LOCAL nPosSiren, nPosCA, nPosRela, aPosNom
   LOCAL cCA, cRela, cNom, xSiren, cSirenOri, cSiren, cSerie, cCle, cPortNom, cPortId
   LOCAL cAdr, cCP, cVille, lNom, lTrouve
   LOCAL hRes, nTraites := 0, k, xFiltre

   IF ! hb_FileExists( cFicDeb )
      CsLog( "ERREUR : fichier debiteurs introuvable : " + cFicDeb )
      RETURN
   ENDIF
   IF ! OuvreSuivi( cFicSuivi )
      RETURN
   ENDIF

   BEGIN SEQUENCE WITH {| e | Break( e ) }
      /* ouverture partagee, lecture seule, codepage des DBF ; index CDX de production ouvert si present */
      dbUseArea( .T., "SIXCDX", cFicDeb, "DEB", .T., .T., CdpDbf() )
      DEB->( ordSetFocus( 0 ) )     /* lecture dans l'ordre physique */
   RECOVER
      CsLog( "ERREUR : impossible d'ouvrir " + cFicDeb )
      SUIVI->( dbCloseArea() )
      RETURN
   END SEQUENCE

   nPosSiren := DEB->( FieldPos( cChSiren ) )
   nPosCA    := DEB->( FieldPos( cChCA ) )
   nPosRela  := DEB->( FieldPos( cChRela ) )
   /* NOM=RS|NOM : premier champ non vide (raison sociale, sinon nom) */
   aPosNom   := PosChamps( StrTran( cChNom, "|", "+" ), cFicDeb )
   IF ! Empty( cChLimite )
      nPosLim := DEB->( FieldPos( cChLimite ) )
   ENDIF
   IF nPosSiren == 0
      IF ! lParNom
         CsLog( "ERREUR : champ " + cChSiren + " absent de " + cFicDeb + " (voir [CHAMPS] SIREN=)" )
         DEB->( dbCloseArea() )
         SUIVI->( dbCloseArea() )
         RETURN
      ENDIF
      CsLog( "ATTENTION : champ " + cChSiren + " absent de " + cFicDeb + " : recherche par nom et adresse uniquement" )
   ENDIF
   /* champs d'adresse pour la recherche par nom (plusieurs champs possibles : ADR1+ADR2) */
   aPosAdr   := PosChamps( Cfg( "CHAMPS", "ADRESSE", "" ), cFicDeb )
   aPosCP    := PosChamps( Cfg( "CHAMPS", "CP", "" ), cFicDeb )
   aPosVille := PosChamps( Cfg( "CHAMPS", "VILLE", "" ), cFicDeb )
   IF lParNom
      CsLog( "Recherche par nom et adresse active pour les debiteurs sans SIREN" + ;
             iif( Empty( aPosCP ) .AND. Empty( aPosVille ) .AND. ! lNomSeul, ;
                  " - ATTENTION : aucun champ CP ni VILLE, aucune recherche ne sera faite", "" ) )
   ENDIF
   IF nPosCA == 0 .AND. nPosRela == 0
      CsLog( "ATTENTION : ni " + cChCA + " ni " + cChRela + " presents : serie par defaut " + cSerieDef )
   ENDIF
   IF ! Empty( cFiltre )
      bFiltre := hb_macroBlock( cFiltre )
      CsLog( "Filtre debiteurs : " + cFiltre )
   ENDIF

   /* en simulation on interroge quand meme l'API (lecture seule) mais on ne cree rien */
   IF ! Authentifier()
      DEB->( dbCloseArea() )
      SUIVI->( dbCloseArea() )
      RETURN
   ENDIF
   hPort := ListePortefeuilles()

   SELECT DEB
   DEB->( dbGoTop() )
   PrepareArret()
   DO WHILE ! DEB->( Eof() )

      /* Echap ou fichier d'arret : on s'arrete proprement entre deux debiteurs */
      IF DemandeArret()
         EXIT
      ENDIF

      IF bFiltre != NIL
         /* LOOP / EXIT interdits dans un BEGIN SEQUENCE : on passe par une variable */
         xFiltre := NIL
         BEGIN SEQUENCE WITH {| e | Break( e ) }
            xFiltre := Eval( bFiltre )
         RECOVER
            xFiltre := NIL
         END SEQUENCE
         IF ! HB_ISLOGICAL( xFiltre )
            CsLog( "ERREUR : expression FILTRE invalide : " + cFiltre )
            EXIT
         ENDIF
         IF ! xFiltre
            DEB->( dbSkip() )
            LOOP
         ENDIF
      ENDIF

      cCA   := iif( nPosCA   > 0, AllTrim( ToS( DEB->( FieldGet( nPosCA ) ) ) ), "" )
      cRela := iif( nPosRela > 0, AllTrim( ToS( DEB->( FieldGet( nPosRela ) ) ) ), "" )
      cNom  := PremierChamp( aPosNom )
      xSiren := DEB->( FieldGet( nPosSiren ) )

      /* Serie = 2 premieres lettres de CA, sinon de CODERELA */
      DO CASE
      CASE ! Empty( cCA )
         cSerie := Upper( PadR( cCA, 2 ) )
      CASE ! Empty( cRela )
         cSerie := Upper( PadR( cRela, 2 ) )
      OTHERWISE
         cSerie := Upper( PadR( cSerieDef, 2 ) )
      ENDCASE

      IF nPosSiren > 0
         cSirenOri := iif( HB_ISNUMERIC( xSiren ), iif( xSiren == 0, "", iif( xSiren < 1000000000, StrZero( xSiren, 9 ), StrZero( xSiren, 14 ) ) ), AllTrim( ToS( xSiren ) ) )
      ELSE
         cSirenOri := ""
      ENDIF
      cSiren := NormaliseSiren( cSirenOri )
      cAdr   := ValeurChamps( aPosAdr )
      cCP    := ValeurChamps( aPosCP )
      cVille := ValeurChamps( aPosVille )
      lNom   := .F.

      IF Empty( cSirenOri )
         /* pas de SIREN : recherche par nom + adresse si activee, sinon debiteur ignore sans trace */
         IF ! lParNom .OR. Empty( cNom ) .OR. ;
            ( ! lNomSeul .AND. Empty( Chiffres( cCP ) ) .AND. Empty( cVille ) )
            DEB->( dbSkip() )
            LOOP
         ENDIF
         lNom   := .T.
         cSiren := ""
         /* cle de rapprochement stable : nom + CP + ville (une correction d'adresse relance la recherche) */
         cSirenOri := "N:" + Left( hb_MD5( Upper( cNom ) + "|" + Chiffres( cCP ) + "|" + Upper( cVille ) ), 18 )
      ENDIF
      cCle := cSerie + "|" + cSirenOri

      IF hb_HHasKey( hVu, cCle ) .OR. DejaTraite( cSerie, cSirenOri, lNom )
         DEB->( dbSkip() )
         LOOP
      ENDIF
      hVu[ cCle ] := .T.

      hRes := { "SERIE" => cSerie, "CA" => cCA, "CODERELA" => cRela, "NOM_DEB" => cNom, ;
                "LIMITE" => iif( nPosLim > 0, DEB->( FieldGet( nPosLim ) ), NIL ), ;
                "SIREN_ORI" => cSirenOri, "SIREN" => cSiren, "DEB_RECNO" => DEB->( RecNo() ), ;
                "METHODE" => iif( lNom, "NOM", "SIREN" ), ;
                "ADR_DEB" => cAdr, "CP_DEB" => cCP, "VILLE_DEB" => cVille, ;
                "STATUT" => "", "HTTP" => 0, "MESSAGE" => "" }

      IF ! lNom .AND. ( Empty( cSiren ) .OR. ( lLuhn .AND. ! SirenValide( cSiren ) ) )
         hRes[ "STATUT" ]  := "INVALIDE"
         hRes[ "MESSAGE" ] := "SIREN/SIRET incorrect"
         EcritSuivi( hRes )
         Compte( hStat, "INVALIDE" )
         DEB->( dbSkip() )
         LOOP
      ENDIF

      /* --- portefeuille de la serie (cree si necessaire) --- */
      cPortNom := cPrefixe + cSerie
      hRes[ "PORTF_NOM" ] := cPortNom
      IF hb_HHasKey( hPort, Upper( cPortNom ) )
         cPortId := hPort[ Upper( cPortNom ) ]
      ELSE
         cPortId := CreePortefeuille( cPortNom, cSerie )
         /* memorise meme en cas d'echec ("") : un seul essai de creation par passage */
         hPort[ Upper( cPortNom ) ] := cPortId
      ENDIF
      IF Empty( cPortId )
         hRes[ "STATUT" ]  := "ERREUR"
         hRes[ "MESSAGE" ] := "Creation du portefeuille " + cPortNom + " impossible"
         EcritSuivi( hRes )
         Compte( hStat, "ERREUR" )
         DEB->( dbSkip() )
         LOOP
      ENDIF
      hRes[ "PORTF_ID" ] := cPortId

      /* --- recherche de la societe par SIREN, ou par nom + adresse --- */
      IF lNom
         lTrouve := RechercheParNom( cNom, cAdr, cCP, cVille, hRes )
      ELSE
         lTrouve := RechercheSociete( cSiren, hRes )
      ENDIF
      IF lTrouve
         /* --- ajout au portefeuille --- */
         AjouteSociete( cPortId, hRes )
      ENDIF

      EcritSuivi( hRes )
      Compte( hStat, hRes[ "STATUT" ] )
      CsLog( PadR( cSerie, 3 ) + PadR( hRes[ "SIREN" ], 9 ) + iif( lNom, "* ", "  " ) + PadR( hRes[ "STATUT" ], 10 ) + " " + ;
           Left( hb_HGetDef( hRes, "CS_NOM", cNom ), 40 ) + "  -> " + cPortNom + ;
           iif( Empty( hRes[ "MESSAGE" ] ), "", "  (" + hRes[ "MESSAGE" ] + ")" ) )

      nTraites++
      IF nMax > 0 .AND. nTraites >= nMax
         CsLog( "Limite MAX_DEBITEURS atteinte (" + hb_ntos( nMax ) + ")" )
         EXIT
      ENDIF
      IF nPause > 0
         hb_idleSleep( nPause )
      ENDIF
      DEB->( dbSkip() )
   ENDDO

   DEB->( dbCloseArea() )
   SUIVI->( dbCommit() )
   SUIVI->( dbCloseArea() )

   CsLog( "Bilan :" )
   FOR EACH k IN hb_HKeys( hStat )
      CsLog( "   " + PadR( k, 12 ) + Str( hStat[ k ], 7 ) )
   NEXT

   RETURN

/* Recherche la societe dans Creditsafe a partir du SIREN */
STATIC FUNCTION RechercheSociete( cSiren, hRes )

   LOCAL nStatus := 0, cResp := "", hJson, aComp, hC, hBest := NIL, k

   IF ! HttpJson( "GET", "/companies?countries=FR&regNo=" + cSiren + "&pageSize=20", NIL, @nStatus, @cResp, @hJson )
      hRes[ "STATUT" ]  := iif( nStatus == 404, "INTROUVABLE", "ERREUR" )
      hRes[ "HTTP" ]    := nStatus
      hRes[ "MESSAGE" ] := MessageErreur( cResp )
      RETURN .F.
   ENDIF

   aComp := JGet( hJson, "companies" )
   IF ! HB_ISARRAY( aComp ) .OR. Empty( aComp )
      hRes[ "STATUT" ]  := "INTROUVABLE"
      hRes[ "HTTP" ]    := nStatus
      hRes[ "MESSAGE" ] := "Aucune societe pour ce SIREN"
      RETURN .F.
   ENDIF
   hRes[ "NB_RESULT" ] := Len( aComp )

   /* 1) siege social du bon SIREN  2) societe active du bon SIREN  3) 1er du bon SIREN  4) 1er resultat */
   FOR EACH hC IN aComp
      IF Left( Chiffres( ToS( JGet( hC, "regNo" ) ) ), 9 ) == cSiren .AND. "HEAD" $ Upper( ToS( JGet( hC, "officeType" ) ) )
         hBest := hC
         EXIT
      ENDIF
   NEXT
   IF hBest == NIL
      FOR EACH hC IN aComp
         IF Left( Chiffres( ToS( JGet( hC, "regNo" ) ) ), 9 ) == cSiren .AND. Upper( ToS( JGet( hC, "status" ) ) ) == "ACTIVE"
            hBest := hC
            EXIT
         ENDIF
      NEXT
   ENDIF
   IF hBest == NIL
      FOR EACH hC IN aComp
         IF Left( Chiffres( ToS( JGet( hC, "regNo" ) ) ), 9 ) == cSiren
            hBest := hC
            EXIT
         ENDIF
      NEXT
   ENDIF
   IF hBest == NIL
      hBest := aComp[ 1 ]
      hRes[ "MESSAGE" ] := "SIREN Creditsafe different : " + ToS( JGet( hBest, "regNo" ) )
   ENDIF

   RemplitSociete( hRes, hBest )
   k := hRes[ "CS_ID" ]

   IF Empty( k )
      hRes[ "STATUT" ]  := "INTROUVABLE"
      hRes[ "MESSAGE" ] := "Reponse sans identifiant Creditsafe"
      RETURN .F.
   ENDIF

   RETURN .T.

/* Copie dans hRes les informations d'une societe renvoyee par /companies */
STATIC PROCEDURE RemplitSociete( hRes, hC )

   hRes[ "CS_ID" ]      := ToS( JGet( hC, "id" ) )
   hRes[ "SAFENO" ]     := ToS( JGet( hC, "safeNo" ) )
   hRes[ "CS_NOM" ]     := ToS( JGet( hC, "name" ) )
   hRes[ "CS_REGNO" ]   := ToS( JGet( hC, "regNo" ) )
   hRes[ "CS_ADRESSE" ] := ToS( JGet( hC, "address", "simpleValue" ) )
   hRes[ "CS_CP" ]      := ToS( JGet( hC, "address", "postCode" ) )
   hRes[ "CS_VILLE" ]   := ToS( JGet( hC, "address", "city" ) )
   hRes[ "CS_STATUT" ]  := ToS( JGet( hC, "status" ) )
   hRes[ "CS_TYPE" ]    := ToS( JGet( hC, "officeType" ) )

   RETURN

/* ==========================================================================
 *  RECHERCHE PAR NOM + ADRESSE (debiteurs sans SIREN)
 *
 *  1) GET /companies?countries=FR&name=<nom>&postCode=<cp>   (sinon &city=<ville>)
 *  2) chaque resultat recoit une note sur 100 :
 *        nom 60 + code postal 25 (departement 10) + ville 5 + rue/numero 10, -5 si societe inactive
 *  3) note >= SCORE_AUTO et nettement devant le 2e SIREN (ECART_MIN) -> societe retenue :
 *        on relit son SIREN par RechercheSociete (choix du siege), puis ajout au portefeuille
 *     note >= SCORE_MIN -> A_VERIFIER (proposition ecrite dans le suivi, rien n'est ajoute)
 *     sinon             -> INTROUVABLE
 * ========================================================================== */
STATIC FUNCTION RechercheParNom( cNom, cAdr, cCP, cVille, hRes )

   LOCAL nAuto    := Val( Cfg( "RECHERCHE", "SCORE_AUTO", "80" ) )
   LOCAL nMin     := Val( Cfg( "RECHERCHE", "SCORE_MIN", "55" ) )
   LOCAL nEcart   := Val( Cfg( "RECHERCHE", "ECART_MIN", "10" ) )
   LOCAL lNomSeul := Cfg( "RECHERCHE", "NOM_SEUL", "0" ) == "1"
   LOCAL nTaille  := Val( Cfg( "RECHERCHE", "NB_CANDIDATS", "20" ) )
   LOCAL cNomRech := NomPourRecherche( cNom )
   LOCAL aEssais := {}, cCrit, aComp := {}, nStatus := 0, cResp := "", lErreur := .F.
   LOCAL aNotes := {}, hC, aN, aBest, a2 := NIL, cSirTrouve, cMsg

   cCP := Chiffres( cCP )
   IF Len( cCP ) == 4
      cCP := "0" + cCP
   ENDIF
   IF Len( cCP ) != 5
      cCP := ""
   ENDIF
   IF nTaille < 1
      nTaille := 20
   ENDIF

   IF Empty( cNomRech )
      hRes[ "STATUT" ]  := "INTROUVABLE"
      hRes[ "MESSAGE" ] := "Nom du debiteur inexploitable pour la recherche"
      RETURN .F.
   ENDIF

   IF ! Empty( cCP )
      AAdd( aEssais, "&postCode=" + cCP )
   ENDIF
   IF ! Empty( cVille )
      AAdd( aEssais, "&city=" + UrlEncode( cVille ) )
   ENDIF
   IF lNomSeul .OR. Empty( aEssais )
      AAdd( aEssais, "" )
   ENDIF

   FOR EACH cCrit IN aEssais
      aComp := ChercheSocietes( "name=" + UrlEncode( cNomRech ) + cCrit, nTaille, @nStatus, @cResp, @lErreur )
      IF lErreur .OR. ! Empty( aComp )
         EXIT
      ENDIF
   NEXT
   hRes[ "HTTP" ] := nStatus

   IF lErreur
      hRes[ "STATUT" ]  := "ERREUR"
      hRes[ "MESSAGE" ] := "Recherche par nom : " + MessageErreur( cResp )
      RETURN .F.
   ENDIF
   IF Empty( aComp )
      hRes[ "STATUT" ]  := "INTROUVABLE"
      hRes[ "MESSAGE" ] := "Aucune societe pour ce nom et cette adresse"
      RETURN .F.
   ENDIF
   hRes[ "NB_RESULT" ] := Len( aComp )

   /* note de chaque candidat : { note, societe, SIREN } */
   FOR EACH hC IN aComp
      AAdd( aNotes, { NoteCandidat( cNom, cAdr, cCP, cVille, hC ), hC, Left( Chiffres( ToS( JGet( hC, "regNo" ) ) ), 9 ) } )
   NEXT
   ASort( aNotes,,, {| x, y | x[ 1 ] > y[ 1 ] } )
   aBest := aNotes[ 1 ]
   /* meilleur candidat d'une AUTRE societe (les etablissements d'un meme SIREN ne sont pas concurrents) */
   FOR EACH aN IN aNotes
      IF aN:__enumIndex() > 1 .AND. ( Empty( aBest[ 3 ] ) .OR. ! aN[ 3 ] == aBest[ 3 ] )
         a2 := aN
         EXIT
      ENDIF
   NEXT
   hRes[ "SCORE" ] := aBest[ 1 ]

   cMsg := "Nom/adresse note " + hb_ntos( aBest[ 1 ] ) + " : " + Candidat( aBest )
   IF a2 != NIL
      cMsg += " | 2e note " + hb_ntos( a2[ 1 ] ) + " : " + Candidat( a2 )
   ENDIF

   DO CASE
   CASE aBest[ 1 ] >= nAuto .AND. ( a2 == NIL .OR. aBest[ 1 ] - a2[ 1 ] >= nEcart )
      cSirTrouve := aBest[ 3 ]
      IF Len( cSirTrouve ) == 9
         /* on repart du SIREN trouve : choix du siege social comme pour un debiteur avec SIREN */
         hRes[ "SIREN" ] := cSirTrouve
         IF ! RechercheSociete( cSirTrouve, hRes )
            IF ! hRes[ "STATUT" ] == "INTROUVABLE"
               hRes[ "MESSAGE" ] := Left( hRes[ "MESSAGE" ] + " / " + cMsg, 200 )
               RETURN .F.
            ENDIF
            /* SIREN non relu : on garde la societe trouvee par le nom */
            RemplitSociete( hRes, aBest[ 2 ] )
            hRes[ "NB_RESULT" ] := Len( aComp )
            hRes[ "STATUT" ]    := ""
            hRes[ "HTTP" ]      := 200
         ENDIF
      ELSE
         RemplitSociete( hRes, aBest[ 2 ] )
      ENDIF
      hRes[ "MESSAGE" ] := cMsg
      IF Empty( hRes[ "CS_ID" ] )
         hRes[ "STATUT" ]  := "INTROUVABLE"
         hRes[ "MESSAGE" ] := "Reponse sans identifiant Creditsafe / " + cMsg
         RETURN .F.
      ENDIF
      RETURN .T.

   CASE aBest[ 1 ] >= nMin
      /* proposition a confirmer : ecrite dans le suivi, rien n'est ajoute a la surveillance */
      RemplitSociete( hRes, aBest[ 2 ] )
      hRes[ "SIREN" ]   := aBest[ 3 ]
      hRes[ "STATUT" ]  := "A_VERIFIER"
      hRes[ "MESSAGE" ] := cMsg + iif( aBest[ 1 ] >= nAuto, " (ecart insuffisant)", "" )

   OTHERWISE
      hRes[ "STATUT" ]  := "INTROUVABLE"
      hRes[ "MESSAGE" ] := "Aucun candidat suffisant. Meilleur : " + cMsg
   ENDCASE

   RETURN .F.

/* GET /companies (France) ; renvoie le tableau des societes. lErreur = vraie erreur (pas un simple "aucun resultat") */
STATIC FUNCTION ChercheSocietes( cCriteres, nTaille, nStatus, cResp, lErreur )

   LOCAL hJson, aComp

   lErreur := .F.
   IF ! HttpJson( "GET", "/companies?countries=FR&" + cCriteres + "&pageSize=" + hb_ntos( nTaille ), NIL, @nStatus, @cResp, @hJson )
      lErreur := nStatus != 404
      RETURN {}
   ENDIF
   aComp := JGet( hJson, "companies" )

   RETURN iif( HB_ISARRAY( aComp ), aComp, {} )

/* Libelle court d'un candidat pour le message du suivi */
STATIC FUNCTION Candidat( aN )

   RETURN AllTrim( ToS( JGet( aN[ 2 ], "name" ) ) ) + " (" + iif( Empty( aN[ 3 ] ), "sans SIREN", aN[ 3 ] ) + ") " + ;
          AllTrim( ToS( JGet( aN[ 2 ], "address", "postCode" ) ) ) + " " + AllTrim( ToS( JGet( aN[ 2 ], "address", "city" ) ) )

/* Note sur 100 d'une societe Creditsafe par rapport au debiteur */
STATIC FUNCTION NoteCandidat( cNom, cAdr, cCP, cVille, hC )

   LOCAL nNote, nSim, x, cCPc, cVilleN, cVilleC, aRue, aAdrC, nCommun := 0, cT

   /* nom : raison sociale, ou nom commercial s'il est plus proche */
   nSim := SimNom( cNom, ToS( JGet( hC, "name" ) ) )
   x := JGet( hC, "tradingNames" )
   IF HB_ISARRAY( x )
      AEval( x, {| t | nSim := Max( nSim, SimNom( cNom, iif( HB_ISHASH( t ), ToS( JGet( t, "name" ) ), ToS( t ) ) ) ) } )
   ENDIF
   nNote := nSim * 60

   /* code postal */
   cCPc := Chiffres( ToS( JGet( hC, "address", "postCode" ) ) )
   IF ! Empty( cCP ) .AND. Len( cCPc ) == 5
      DO CASE
      CASE cCPc == cCP
         nNote += 25
      CASE Left( cCPc, 2 ) == Left( cCP, 2 )
         nNote += 10
      ENDCASE
   ENDIF

   /* ville */
   cVilleN := NormTexte( cVille )
   cVilleC := NormTexte( ToS( JGet( hC, "address", "city" ) ) )
   IF ! Empty( cVilleN ) .AND. ! Empty( cVilleC ) .AND. ;
      ( cVilleN == cVilleC .OR. cVilleN $ cVilleC .OR. cVilleC $ cVilleN )
      nNote += 5
   ENDIF

   /* rue et numero : part des mots de l'adresse du debiteur retrouves dans l'adresse Creditsafe */
   aRue  := Mots( NormTexte( cAdr ), MotsVidesRue() )
   aAdrC := Mots( NormTexte( ToS( JGet( hC, "address", "simpleValue" ) ) + " " + ToS( JGet( hC, "address", "street" ) ) + ;
                  " " + ToS( JGet( hC, "address", "houseNo" ) ) ), MotsVidesRue() )
   IF ! Empty( aRue ) .AND. ! Empty( aAdrC )
      FOR EACH cT IN aRue
         IF AScan( aAdrC, {| c | c == cT } ) > 0
            nCommun++
         ENDIF
      NEXT
      nNote += 10 * nCommun / Len( aRue )
   ENDIF

   /* societe radiee / inactive : legerement penalisee */
   x := Upper( ToS( JGet( hC, "status" ) ) )
   IF ! Empty( x ) .AND. ! x == "ACTIVE"
      nNote -= 5
   ENDIF

   RETURN Max( 0, Min( 100, Round( nNote, 0 ) ) )

/* Similarite (0 a 1) entre deux raisons sociales, formes juridiques et mots vides retires */
STATIC FUNCTION SimNom( cA, cB )

   LOCAL aA := Mots( NormTexte( cA ), MotsVidesNom() )
   LOCAL aB := Mots( NormTexte( cB ), MotsVidesNom() )
   LOCAL cJA, cJB, nCommun := 0, cT, nSim

   IF Empty( aA ) .OR. Empty( aB )
      RETURN 0
   ENDIF
   cJA := ""
   AEval( aA, {| c | cJA += c } )
   cJB := ""
   AEval( aB, {| c | cJB += c } )
   IF cJA == cJB
      RETURN 1
   ENDIF

   FOR EACH cT IN aA
      IF AScan( aB, {| c | c == cT } ) > 0
         nCommun++
      ENDIF
   NEXT
   /* mots communs (Dice) */
   nSim := 2 * nCommun / ( Len( aA ) + Len( aB ) )
   /* un nom entierement contenu dans l'autre ("DUPONT" / "DUPONT ET FILS") */
   IF nCommun == Min( Len( aA ), Len( aB ) )
      nSim := Max( nSim, 0.8 )
   ENDIF
   /* fautes de frappe : bigrammes de caracteres */
   nSim := Max( nSim, DiceBigrammes( cJA, cJB ) )

   RETURN nSim

STATIC FUNCTION DiceBigrammes( cA, cB )

   LOCAL hA := { => }, i, nCommun := 0, cBi, nA := Len( cA ) - 1, nB := Len( cB ) - 1

   IF nA < 1 .OR. nB < 1
      RETURN 0
   ENDIF
   FOR i := 1 TO nA
      cBi := SubStr( cA, i, 2 )
      hA[ cBi ] := hb_HGetDef( hA, cBi, 0 ) + 1
   NEXT
   FOR i := 1 TO nB
      cBi := SubStr( cB, i, 2 )
      IF hb_HGetDef( hA, cBi, 0 ) > 0
         hA[ cBi ]--
         nCommun++
      ENDIF
   NEXT

   RETURN 2 * nCommun / ( nA + nB )

/* Nom envoye a Creditsafe : majuscules sans accents, forme juridique retiree */
STATIC FUNCTION NomPourRecherche( cNom )

   LOCAL aM := Mots( NormTexte( cNom ), MotsVidesNom() ), c := ""

   AEval( aM, {| x | c += iif( Empty( c ), "", " " ) + x } )
   IF Empty( c )
      c := NormTexte( cNom )
   ENDIF

   RETURN c

/* Majuscules, sans accents, seulement lettres / chiffres / espaces simples (codepage du programme -> FRWIN) */
STATIC FUNCTION NormTexte( c )

   /* equivalents ASCII des caracteres 192 a 223 de Windows-1252 (les minuscules 224-255 sont passees en majuscules) */
   LOCAL cTable := "AAAAAAACEEEEIIIIDNOOOOO OUUUUY S"
   LOCAL cRes := "", i, n, ch

   c := Upper( hb_Translate( ToS( c ), NIL, "FRWIN" ) )
   FOR i := 1 TO hb_BLen( c )
      n := hb_BPeek( c, i )
      DO CASE
      CASE ( n >= 48 .AND. n <= 57 ) .OR. ( n >= 65 .AND. n <= 90 )
         ch := Chr( n )
      CASE n >= 224 .AND. n < 255
         ch := SubStr( cTable, n - 223, 1 )
      CASE n >= 192
         ch := SubStr( cTable, n - 191, 1 )
      CASE n == 255 .OR. n == 159     /* Y trema */
         ch := "Y"
      CASE n == 140 .OR. n == 156     /* OE */
         ch := "OE"
      OTHERWISE
         ch := " "
      ENDCASE
      cRes += ch
   NEXT
   DO WHILE "  " $ cRes
      cRes := StrTran( cRes, "  ", " " )
   ENDDO

   RETURN AllTrim( cRes )

/* Mots d'un texte normalise, hors mots vides et lettres isolees */
STATIC FUNCTION Mots( c, hVides )

   LOCAL aRes := {}, cM

   FOR EACH cM IN hb_ATokens( c, " " )
      IF Len( cM ) > 1 .AND. ! hb_HHasKey( hVides, cM ) .AND. AScan( aRes, {| x | x == cM } ) == 0
         AAdd( aRes, cM )
      ENDIF
   NEXT

   RETURN aRes

STATIC FUNCTION MotsVidesNom()

   STATIC s_h := NIL
   LOCAL c

   IF s_h == NIL
      s_h := { => }
      FOR EACH c IN hb_ATokens( "SARL SAS SASU SA EURL SCI SNC SCP SCM SCS SCA SELARL SELAS SELAFA SELURL EARL GAEC GIE " + ;
                                "SCOP SCEA SEM SPL EI EIRL ME STE SOCIETE STES ETS ETABLISSEMENTS ETABLISSEMENT " + ;
                                "CIE COMPAGNIE ENTREPRISE ENTREPRISES ET LA LE LES DE DU DES AU AUX EN SUR PAR POUR " + ;
                                "UNIPERSONNELLE RESPONSABILITE LIMITEE ANONYME SIMPLIFIEE ACTIONS CIVILE IMMOBILIERE", " " )
         s_h[ c ] := .T.
      NEXT
   ENDIF

   RETURN s_h

STATIC FUNCTION MotsVidesRue()

   STATIC s_h := NIL
   LOCAL c

   IF s_h == NIL
      s_h := { => }
      FOR EACH c IN hb_ATokens( "RUE AVENUE AV AVE BOULEVARD BD BLD CHEMIN CHE CH ROUTE RTE PLACE PL ALLEE ALL IMPASSE IMP " + ;
                                "QUAI COURS CRS SQUARE SQ PASSAGE RESIDENCE RES LIEU DIT LD ZONE ZA ZI ZAC PARC BP CS " + ;
                                "CEDEX BIS TER DE DU DES LA LE LES ET AU AUX SAINT ST FRANCE", " " )
         s_h[ c ] := .T.
      NEXT
   ENDIF

   RETURN s_h

/* Encodage URL (UTF-8, RFC 3986) */
STATIC FUNCTION UrlEncode( c )

   LOCAL cU := hb_StrToUTF8( AllTrim( ToS( c ) ) ), cRes := "", i, n

   FOR i := 1 TO hb_BLen( cU )
      n := hb_BPeek( cU, i )
      IF ( n >= 48 .AND. n <= 57 ) .OR. ( n >= 65 .AND. n <= 90 ) .OR. ( n >= 97 .AND. n <= 122 ) .OR. ;
         n == 45 .OR. n == 46 .OR. n == 95 .OR. n == 126
         cRes += Chr( n )
      ELSE
         cRes += "%" + hb_NumToHex( n, 2 )
      ENDIF
   NEXT

   RETURN cRes

/* Ajoute la societe (connectId) au portefeuille */
STATIC PROCEDURE AjouteSociete( cPortId, hRes )

   LOCAL nStatus := 0, cResp := "", hJson, hBody, cMsg

   IF s_lSimul
      hRes[ "STATUT" ] := "SIMULE"
      RETURN
   ENDIF

   hBody := { "id" => hRes[ "CS_ID" ], ;
              "personalReference" => Left( iif( Empty( hRes[ "CA" ] ), hRes[ "CODERELA" ], hRes[ "CA" ] ), 50 ), ;
              "freeText" => Left( hRes[ "NOM_DEB" ], 100 ), ;
              "personalLimit" => LimitePerso( hRes[ "LIMITE" ] ) }

   HttpSchema( "POST", "/monitoring/portfolios/" + cPortId + "/companies", hBody, @nStatus, @cResp, @hJson )
   hRes[ "HTTP" ] := nStatus

   DO CASE
   CASE nStatus >= 200 .AND. nStatus < 300
      hRes[ "STATUT" ] := "AJOUTE"
   OTHERWISE
      cMsg := MessageErreur( cResp )
      IF nStatus == 409 .OR. "ALREADY" $ Upper( cMsg ) .OR. "EXIST" $ Upper( cMsg )
         hRes[ "STATUT" ] := "DEJA"
      ELSE
         hRes[ "STATUT" ] := "ERREUR"
      ENDIF
      hRes[ "MESSAGE" ] := cMsg
   ENDCASE

   RETURN

/* Cree un portefeuille et renvoie son identifiant */
STATIC FUNCTION CreePortefeuille( cNom, cSerie )

   LOCAL nStatus := 0, cResp := "", hJson, hBody, cId, aMails := {}, cMail, hP
   LOCAL cModele := Cfg( "PORTEFEUILLE", "PORTEFEUILLE_MODELE_REGLES", "" )

   IF s_lSimul
      CsLog( "[SIMULATION] creation du portefeuille " + cNom )
      RETURN "SIMUL-" + cSerie
   ENDIF

   FOR EACH cMail IN hb_ATokens( Cfg( "PORTEFEUILLE", "EMAILS", "" ), ";" )
      IF ! Empty( cMail )
         AAdd( aMails, AllTrim( cMail ) )
      ENDIF
   NEXT

   hBody := { "name" => cNom }
   IF ! Empty( aMails )
      hBody[ "emails" ] := aMails
   ENDIF

   IF ! HttpSchema( "POST", "/monitoring/portfolios", hBody, @nStatus, @cResp, @hJson )
      CsLog( "ERREUR creation portefeuille " + cNom + " : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
      IF nStatus == 409
         /* existe deja : on retrouve son identifiant dans le suivi */
         cId := PortefeuilleSuivi( cNom )
         IF ! Empty( cId )
            CsLog( "   portefeuille " + cNom + " existant, id " + cId + " (repris du fichier de suivi)" )
         ENDIF
         RETURN cId
      ENDIF
      RETURN ""
   ENDIF

   cId := ToS( JFind( hJson, "portfolioId" ) )
   IF Empty( cId )
      cId := ToS( JFind( hJson, "id" ) )
   ENDIF
   IF Empty( cId )
      /* on relit la liste pour retrouver l'identifiant */
      hP := ListePortefeuilles()
      cId := hb_HGetDef( hP, Upper( cNom ), "" )
   ENDIF
   CsLog( "Portefeuille cree : " + cNom + " (id " + cId + ")" )

   IF ! Empty( cId ) .AND. ! Empty( cModele )
      CopieRegles( cModele, cId )
   ENDIF

   RETURN cId

/* Copie les regles d'evenements (alertes) d'un portefeuille modele */
STATIC PROCEDURE CopieRegles( cModele, cId )

   LOCAL cPays := Cfg( "PORTEFEUILLE", "PAYS_REGLES", "FR" )
   LOCAL nStatus := 0, cResp := "", hJson, xRegles, nSt2 := 0, cResp2 := ""

   IF ! HttpJson( "GET", "/monitoring/portfolios/" + cModele + "/eventRules/" + cPays, NIL, @nStatus, @cResp, @hJson )
      CsLog( "ATTENTION : lecture des regles du portefeuille modele " + cModele + " impossible (HTTP " + hb_ntos( nStatus ) + ")" )
      RETURN
   ENDIF
   xRegles := iif( HB_ISARRAY( hJson ), hJson, JGet( hJson, "data" ) )
   IF ! HB_ISARRAY( xRegles )
      xRegles := hJson
   ENDIF
   HttpJson( "PUT", "/monitoring/portfolios/" + cId + "/eventRules/" + cPays, xRegles, @nSt2, @cResp2 )
   CsLog( "Copie des regles " + cPays + " depuis " + cModele + " -> " + cId + " : HTTP " + hb_ntos( nSt2 ) + ;
        iif( nSt2 >= 200 .AND. nSt2 < 300, "", " " + MessageErreur( cResp2 ) ) )

   RETURN

/* Renvoie un hash  NOM_PORTEFEUILLE (majuscules) => id */
STATIC FUNCTION ListePortefeuilles()

   LOCAL hPort := { => }, nPage := 0, nSize := 100, nStatus := 0, cResp := "", hJson, aP, hP, nNew
   LOCAL cNom, cId, cPremiere := "", lPage1Essayee := .F.

   DO WHILE nPage < 100
      IF ! HttpJson( "GET", "/monitoring/portfolios?page=" + hb_ntos( nPage ) + "&pageSize=" + hb_ntos( nSize ), NIL, @nStatus, @cResp, @hJson )
         CsLog( "ERREUR lecture des portefeuilles : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
         EXIT
      ENDIF
      IF Empty( cPremiere )
         cPremiere := cResp
      ENDIF
      /* tableau d'objets contenant "portfolioId", ou qu'il soit dans la reponse */
      aP := JFindTableau( hJson, "portfolioId" )
      IF Empty( aP )
         aP := JFindTableau( hJson, "id" )
      ENDIF
      IF Empty( aP )
         /* pagination a partir de 1 ? */
         IF nPage == 0 .AND. ! lPage1Essayee
            lPage1Essayee := .T.
            nPage := 1
            LOOP
         ENDIF
         EXIT
      ENDIF
      nNew := 0
      FOR EACH hP IN aP
         cNom := Upper( AllTrim( ToS( JGet( hP, "name" ) ) ) )
         cId  := ToS( JGet( hP, "portfolioId" ) )
         IF Empty( cId )
            cId := ToS( JGet( hP, "id" ) )
         ENDIF
         IF ! Empty( cNom ) .AND. ! hb_HHasKey( hPort, cNom )
            hPort[ cNom ] := cId
            nNew++
         ENDIF
      NEXT
      IF Len( aP ) < nSize .OR. nNew == 0
         EXIT
      ENDIF
      nPage++
   ENDDO
   CsLog( hb_ntos( Len( hPort ) ) + " portefeuille(s) existant(s) sur le compte" )
   IF Empty( hPort ) .AND. ! Empty( cPremiere )
      /* diagnostic : debut de la reponse brute */
      CsLog( "   reponse /monitoring/portfolios : " + Left( StrTran( StrTran( cPremiere, Chr( 13 ), " " ), Chr( 10 ), " " ), 400 ) )
   ENDIF

   RETURN hPort

/* Portefeuille deja connu dans le fichier de suivi (PORTF_NOM -> PORTF_ID) */
STATIC FUNCTION PortefeuilleSuivi( cNom )

   LOCAL cId := ""

   IF Select( "SUIVI" ) == 0
      RETURN ""
   ENDIF
   SUIVI->( ordSetFocus( "PORTF" ) )
   SUIVI->( dbSeek( PadR( cNom, 50 ) ) )
   DO WHILE ! SUIVI->( Eof() ) .AND. Upper( AllTrim( SUIVI->PORTF_NOM ) ) == Upper( cNom )
      IF ! Empty( SUIVI->PORTF_ID ) .AND. ! Left( SUIVI->PORTF_ID, 5 ) == "SIMUL"
         cId := AllTrim( SUIVI->PORTF_ID )
         EXIT
      ENDIF
      SUIVI->( dbSkip() )
   ENDDO

   RETURN cId

/* ==========================================================================
 *  2) RECUPERATION DES ALERTES
 * ========================================================================== */

STATIC PROCEDURE RecupereAlertes()

   LOCAL cFicAl    := CheminFichier( Cfg( "GENERAL", "FICHIER_ALERTES", "CsAlertes.dbf" ) )
   LOCAL cFicSuivi := CheminFichier( Cfg( "GENERAL", "FICHIER_SUIVI", "CsSuivi.dbf" ) )
   LOCAL cPrefixe  := Upper( Cfg( "PORTEFEUILLE", "PREFIXE_NOM", "DEBITEURS-" ) )
   LOCAL nJours    := Val( Cfg( "ALERTES", "JOURS", "30" ) )
   LOCAL lMarquer  := Cfg( "ALERTES", "MARQUER_TRAITEES", "0" ) == "1"
   LOCAL lNonTrt   := Cfg( "ALERTES", "SEULEMENT_NON_TRAITEES", "1" ) == "1"
   LOCAL nSize     := 100
   LOCAL hPort, hDeja := { => }, lSuivi := .F., cNom, cId, nPage, nStatus, cResp, hJson
   LOCAL aEv, hEv, cNotif, nNew, nTotal := 0, cUrl, hInfo, cDate, nSt2, cR2, lArret := .F.

   IF ! OuvreAlertes( cFicAl )
      RETURN
   ENDIF
   ALERT->( ordSetFocus( "NOTIF" ) )

   /* correspondance identifiant Creditsafe -> debiteur (fichier de suivi, tag CSID) */
   IF hb_FileExists( cFicSuivi )
      lSuivi := OuvreSuivi( cFicSuivi )
   ENDIF

   IF ! Authentifier()
      ALERT->( dbCloseArea() )
      IF lSuivi
         SUIVI->( dbCloseArea() )
      ENDIF
      RETURN
   ENDIF
   hPort := ListePortefeuilles()

   cDate := Transform( DToS( Date() - nJours ), "@R 9999-99-99" )
   CsLog( "Recherche des alertes depuis le " + cDate )
   PrepareArret()

   FOR EACH cNom IN hb_HKeys( hPort )
      IF lArret
         EXIT
      ENDIF
      IF ! Empty( cPrefixe ) .AND. ! Left( cNom, Len( cPrefixe ) ) == cPrefixe
         LOOP
      ENDIF
      cId := hPort[ cNom ]
      nPage := 0
      DO WHILE nPage < 500
         /* Echap ou fichier d'arret : on s'arrete entre deux pages (les alertes deja lues sont enregistrees) */
         IF DemandeArret()
            lArret := .T.
            EXIT
         ENDIF
         cUrl := "/monitoring/portfolios/" + cId + "/notificationEvents?startDate=" + cDate + ;
                 "&endDate=" + Transform( DToS( Date() + 1 ), "@R 9999-99-99" ) + ;
                 "&page=" + hb_ntos( nPage ) + "&pageSize=" + hb_ntos( nSize ) + ;
                 iif( lNonTrt, "&isProcessed=false", "" )
         nStatus := 0
         cResp   := ""
         hJson   := NIL
         IF ! HttpJson( "GET", cUrl, NIL, @nStatus, @cResp, @hJson )
            CsLog( "ERREUR alertes portefeuille " + cNom + " : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
            EXIT
         ENDIF
         aEv := iif( HB_ISARRAY( hJson ), hJson, JGet( hJson, "data" ) )
         IF ! HB_ISARRAY( aEv )
            aEv := JGet( hJson, "notificationEvents" )
         ENDIF
         IF ! HB_ISARRAY( aEv ) .OR. Empty( aEv )
            EXIT
         ENDIF
         nNew := 0
         FOR EACH hEv IN aEv
            cNotif := ToS( JGet( hEv, "notificationEventId" ) )
            IF Empty( cNotif ) .OR. hb_HHasKey( hDeja, cNotif ) .OR. ALERT->( dbSeek( PadR( cNotif, 40 ) ) )
               LOOP
            ENDIF
            hDeja[ cNotif ] := .T.
            nNew++
            hInfo := InfoDebiteur( ToS( JGet( hEv, "company", "id" ) ) )

            ALERT->( dbAppend() )
            ALERT->NOTIF_ID   := cNotif
            ALERT->EVENT_ID   := ToS( JGet( hEv, "eventId" ) )
            ALERT->DATE_EVT   := Left( ToS( JGet( hEv, "eventDate" ) ), 25 )
            ALERT->D_EVT      := hb_SToD( StrTran( Left( ToS( JGet( hEv, "eventDate" ) ), 10 ), "-", "" ) )
            ALERT->PORTF_ID   := cId
            ALERT->PORTF_NOM  := cNom
            ALERT->CS_ID      := ToS( JGet( hEv, "company", "id" ) )
            ALERT->SAFENO     := ToS( JGet( hEv, "company", "safeNumber" ) )
            ALERT->CS_NOM     := ToS( JGet( hEv, "company", "name" ) )
            ALERT->SIREN      := hb_HGetDef( hInfo, "SIREN", "" )
            ALERT->SERIE      := hb_HGetDef( hInfo, "SERIE", "" )
            ALERT->CA         := hb_HGetDef( hInfo, "CA", "" )
            ALERT->CODERELA   := hb_HGetDef( hInfo, "CODERELA", "" )
            ALERT->RULECODE   := ToS( JGet( hEv, "ruleCode" ) )
            ALERT->LIBELLE    := PremierNonVide( { JGet( hEv, "ruleName" ), JGet( hEv, "ruleDescription" ), JGet( hEv, "eventDescription" ), JGet( hEv, "localEventCode" ) } )
            ALERT->ANC_VAL    := ToS( JGet( hEv, "oldValue" ) )
            ALERT->NOUV_VAL   := ToS( JGet( hEv, "newValue" ) )
            ALERT->DATE_RECUP := Date()
            ALERT->TRAITEE    := .F.
            ALERT->( dbCommit() )
            nTotal++

            IF lMarquer
               nSt2 := 0
               cR2  := ""
               HttpJson( "PATCH", "/monitoring/portfolios/" + cId + "/notificationEvents/" + cNotif, ;
                         { "isProcessed" => .T. }, @nSt2, @cR2 )
               ALERT->TRAITEE := nSt2 >= 200 .AND. nSt2 < 300
               ALERT->( dbCommit() )
            ENDIF
            ALERT->( dbUnlock() )
         NEXT
         IF Len( aEv ) < nSize .OR. nNew == 0
            EXIT
         ENDIF
         nPage++
      ENDDO
   NEXT

   ALERT->( dbCommit() )
   ALERT->( dbCloseArea() )
   IF lSuivi
      SUIVI->( dbCloseArea() )
   ENDIF
   CsLog( hb_ntos( nTotal ) + " nouvelle(s) alerte(s) enregistree(s) dans " + cFicAl )

   RETURN

/* ==========================================================================
 *  3) TEST
 * ========================================================================== */

STATIC PROCEDURE TestConnexion()

   LOCAL hPort, k

   IF Authentifier()
      hPort := ListePortefeuilles()
      FOR EACH k IN hb_HKeys( hPort )
         CsLog( "   " + PadR( hPort[ k ], 12 ) + k )
      NEXT
   ENDIF

   RETURN

/* ==========================================================================
 *  HTTP / JSON
 * ========================================================================== */

STATIC FUNCTION Authentifier()

   LOCAL cUser := GetEnv( "CREDITSAFE_USER" ), cPass := GetEnv( "CREDITSAFE_PASSWORD" )
   LOCAL nStatus := 0, cResp := "", hJson

   IF Empty( cUser )
      cUser := Cfg( "API", "UTILISATEUR", "" )
   ENDIF
   IF Empty( cPass )
      cPass := Cfg( "API", "MOT_DE_PASSE", "" )
   ENDIF
   IF Empty( cUser ) .OR. Empty( cPass )
      CsLog( "ERREUR : identifiants Creditsafe absents ([API] UTILISATEUR / MOT_DE_PASSE ou variables CREDITSAFE_USER / CREDITSAFE_PASSWORD)" )
      RETURN .F.
   ENDIF

   s_cToken := ""
   IF HttpJson( "POST", "/authenticate", { "username" => cUser, "password" => cPass }, @nStatus, @cResp, @hJson, .T. )
      s_cToken := ToS( JGet( hJson, "token" ) )
   ENDIF
   IF Empty( s_cToken )
      CsLog( "ERREUR authentification Creditsafe : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
      RETURN .F.
   ENDIF
   CsLog( "Authentification Creditsafe OK" )

   RETURN .T.

/* Appel HTTP + decodage JSON. Renvoie .T. si statut 2xx */
STATIC FUNCTION HttpJson( cMethod, cPath, xBody, nStatus, cResp, hJson, lAuth )

   LOCAL oHttp, cUrl := s_cBaseUrl + cPath, nEssai := 0, cBody, oErr
   LOCAL nTimeout := Val( Cfg( "API", "TIMEOUT_S", "60" ) ) * 1000

   hb_default( @lAuth, .F. )
   cBody := iif( xBody == NIL, NIL, hb_jsonEncode( xBody ) )

   DO WHILE .T.
      nEssai++
      nStatus := 0
      cResp   := ""
      hJson   := NIL
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         oHttp := win_oleCreateObject( "MSXML2.ServerXMLHTTP.6.0" )
         oHttp:setTimeouts( 15000, 15000, nTimeout, nTimeout )
         oHttp:Open( cMethod, cUrl, .F. )
         oHttp:setRequestHeader( "Accept", "application/json" )
         IF cBody != NIL
            oHttp:setRequestHeader( "Content-Type", "application/json; charset=utf-8" )
         ENDIF
         IF ! lAuth .AND. ! Empty( s_cToken )
            oHttp:setRequestHeader( "Authorization", "Bearer " + s_cToken )
         ENDIF
         IF cBody == NIL
            oHttp:Send()
         ELSE
            oHttp:Send( cBody )
         ENDIF
         nStatus := oHttp:Status
         cResp   := oHttp:ResponseText
      RECOVER USING oErr
         nStatus := -1
         cResp   := "Erreur reseau : " + iif( HB_ISOBJECT( oErr ), ToS( oErr:description ) + " " + ToS( oErr:operation ), "" )
      END SEQUENCE
      oHttp := NIL

      /* jeton expire -> on se reauthentifie une fois */
      IF nStatus == 401 .AND. ! lAuth .AND. nEssai == 1
         IF Authentifier()
            LOOP
         ENDIF
      ENDIF
      /* trop de requetes / erreur serveur / reseau -> on reessaie */
      IF ( nStatus == 429 .OR. nStatus >= 500 .OR. nStatus == -1 ) .AND. nEssai <= 3
         CsLog( "   HTTP " + hb_ntos( nStatus ) + " sur " + cMethod + " " + cPath + " - nouvel essai dans " + hb_ntos( nEssai * 5 ) + " s" )
         hb_idleSleep( nEssai * 5 )
         LOOP
      ENDIF
      EXIT
   ENDDO

   IF ! Empty( cResp )
      BEGIN SEQUENCE WITH {| e | Break( e ) }
         hJson := hb_jsonDecode( cResp )
      RECOVER
         hJson := NIL
      END SEQUENCE
   ENDIF

   RETURN nStatus >= 200 .AND. nStatus < 300

/* Comme HttpJson, mais si l'API repond 400 "properties which are not allowed by the schema: [...]"
   on retire ces proprietes du corps et on renvoie la requete (3 essais maximum). */
STATIC FUNCTION HttpSchema( cMethod, cPath, hBody, nStatus, cResp, hJson )

   LOCAL lOk, nEssai, nPos, cListe, cProp, lRetire

   FOR nEssai := 1 TO 3
      lOk := HttpJson( cMethod, cPath, hBody, @nStatus, @cResp, @hJson )
      IF lOk .OR. nStatus != 400 .OR. ! HB_ISHASH( hBody )
         EXIT
      ENDIF
      /* propriete obligatoire manquante -> ajoutee vide */
      nPos := At( "MISSING REQUIRED PROPERTIES", Upper( cResp ) )
      IF nPos > 0
         cListe := SubStr( cResp, nPos )
         cListe := SubStr( cListe, At( "[", cListe ) + 1 )
         cListe := Left( cListe, At( "]", cListe ) - 1 )
         lRetire := .F.
         FOR EACH cProp IN hb_ATokens( StrTran( StrTran( cListe, '\"', "" ), '"', "" ), "," )
            cProp := AllTrim( cProp )
            IF ! Empty( cProp ) .AND. ! hb_HHasKey( hBody, cProp )
               hBody[ cProp ] := ""
               CsLog( "   champ obligatoire '" + cProp + "' ajoute (vide) sur " + cPath )
               lRetire := .T.
            ENDIF
         NEXT
         IF lRetire
            LOOP
         ENDIF
         EXIT
      ENDIF
      /* personalLimit attendu en nombre -> conversion */
      IF "INSTANCE TYPE" $ Upper( cResp ) .AND. hb_HHasKey( hBody, "personalLimit" ) .AND. HB_ISSTRING( hBody[ "personalLimit" ] )
         hBody[ "personalLimit" ] := Val( hBody[ "personalLimit" ] )
         CsLog( "   personalLimit envoye en numerique sur " + cPath )
         LOOP
      ENDIF
      nPos := At( "NOT ALLOWED BY THE SCHEMA", Upper( cResp ) )
      IF nPos == 0
         EXIT
      ENDIF
      cListe := SubStr( cResp, nPos )
      cListe := SubStr( cListe, At( "[", cListe ) + 1 )
      cListe := Left( cListe, At( "]", cListe ) - 1 )
      lRetire := .F.
      FOR EACH cProp IN hb_ATokens( StrTran( StrTran( cListe, '\"', "" ), '"', "" ), "," )
         cProp := AllTrim( cProp )
         IF ! Empty( cProp ) .AND. hb_HHasKey( hBody, cProp )
            hb_HDel( hBody, cProp )
            CsLog( "   champ '" + cProp + "' refuse par l'API sur " + cPath + " : retire" )
            lRetire := .T.
         ENDIF
      NEXT
      IF ! lRetire
         EXIT
      ENDIF
   NEXT

   RETURN lOk

/* personalLimit (obligatoire pour l'API) : champ [CHAMPS] LIMITE du debiteur,
   sinon [PORTEFEUILLE] LIMITE_PERSONNELLE, sinon chaine vide */
STATIC FUNCTION LimitePerso( xLimite )

   LOCAL cVal

   IF HB_ISNUMERIC( xLimite ) .AND. xLimite > 0
      RETURN hb_ntos( Int( xLimite ) )
   ENDIF
   IF HB_ISSTRING( xLimite ) .AND. ! Empty( Chiffres( xLimite ) )
      RETURN Chiffres( xLimite )
   ENDIF
   cVal := Chiffres( Cfg( "PORTEFEUILLE", "LIMITE_PERSONNELLE", "" ) )

   RETURN cVal

STATIC FUNCTION MessageErreur( cResp )

   LOCAL h, c := ""

   IF Empty( cResp )
      RETURN ""
   ENDIF
   BEGIN SEQUENCE WITH {| e | Break( e ) }
      h := hb_jsonDecode( cResp )
   RECOVER
      h := NIL
   END SEQUENCE
   IF HB_ISHASH( h )
      c := AllTrim( ToS( JGet( h, "message" ) ) + " " + ToS( JGet( h, "details" ) ) + " " + ToS( JGet( h, "error" ) ) )
   ENDIF
   IF Empty( c )
      c := cResp
   ENDIF

   RETURN Left( StrTran( StrTran( c, Chr( 13 ), " " ), Chr( 10 ), " " ), 200 )

/* Acces a un element JSON :  JGet( h, "address", "city" ) - insensible a la casse */
STATIC FUNCTION JGet( x, ... )

   LOCAL aK := hb_AParams(), i

   FOR i := 2 TO Len( aK )
      DO CASE
      CASE HB_ISHASH( x )
         x := HGetCI( x, aK[ i ] )
      CASE HB_ISARRAY( x ) .AND. HB_ISNUMERIC( aK[ i ] ) .AND. aK[ i ] >= 1 .AND. aK[ i ] <= Len( x )
         x := x[ aK[ i ] ]
      OTHERWISE
         RETURN NIL
      ENDCASE
   NEXT

   RETURN x

/* Recherche recursive du premier tableau d'objets dont le 1er element contient cKey */
STATIC FUNCTION JFindTableau( x, cKey )

   LOCAL v, r

   IF HB_ISARRAY( x )
      IF ! Empty( x ) .AND. HB_ISHASH( x[ 1 ] ) .AND. HGetCI( x[ 1 ], cKey ) != NIL
         RETURN x
      ENDIF
      FOR EACH v IN x
         r := JFindTableau( v, cKey )
         IF ! Empty( r )
            RETURN r
         ENDIF
      NEXT
   ELSEIF HB_ISHASH( x )
      FOR EACH v IN x
         r := JFindTableau( v, cKey )
         IF ! Empty( r )
            RETURN r
         ENDIF
      NEXT
   ENDIF

   RETURN {}

/* Recherche recursive d'une cle a n'importe quel niveau */
STATIC FUNCTION JFind( x, cKey )

   LOCAL v, r

   IF HB_ISHASH( x )
      r := HGetCI( x, cKey )
      IF r != NIL
         RETURN r
      ENDIF
      FOR EACH v IN x
         r := JFind( v, cKey )
         IF r != NIL
            RETURN r
         ENDIF
      NEXT
   ELSEIF HB_ISARRAY( x )
      FOR EACH v IN x
         r := JFind( v, cKey )
         IF r != NIL
            RETURN r
         ENDIF
      NEXT
   ENDIF

   RETURN NIL

STATIC FUNCTION HGetCI( h, cKey )

   LOCAL k

   IF ! HB_ISSTRING( cKey )
      RETURN NIL
   ENDIF
   IF hb_HHasKey( h, cKey )
      RETURN h[ cKey ]
   ENDIF
   FOR EACH k IN hb_HKeys( h )
      IF HB_ISSTRING( k ) .AND. Lower( k ) == Lower( cKey )
         RETURN h[ k ]
      ENDIF
   NEXT

   RETURN NIL

/* ==========================================================================
 *  FICHIERS DBF
 * ========================================================================== */

STATIC FUNCTION OuvreSuivi( cFic )

   LOCAL aStruct := { ;
      { "DATE_TRT",   "D",   8, 0 }, ;
      { "HEURE",      "C",   8, 0 }, ;
      { "MODE",       "C",   6, 0 }, ;
      { "SERIE",      "C",   2, 0 }, ;
      { "CA",         "C",  20, 0 }, ;
      { "CODERELA",   "C",  20, 0 }, ;
      { "NOM_DEB",    "C",  60, 0 }, ;
      { "DEB_RECNO",  "N",  10, 0 }, ;
      { "ADR_DEB",    "C",  80, 0 }, ;
      { "CP_DEB",     "C",  10, 0 }, ;
      { "VILLE_DEB",  "C",  50, 0 }, ;
      { "METHODE",    "C",   5, 0 }, ;
      { "SCORE",      "N",   3, 0 }, ;
      { "SIREN_ORI",  "C",  20, 0 }, ;
      { "SIREN",      "C",   9, 0 }, ;
      { "CS_ID",      "C",  30, 0 }, ;
      { "SAFENO",     "C",  20, 0 }, ;
      { "CS_REGNO",   "C",  20, 0 }, ;
      { "CS_NOM",     "C",  80, 0 }, ;
      { "CS_ADRESSE", "C", 120, 0 }, ;
      { "CS_CP",      "C",  10, 0 }, ;
      { "CS_VILLE",   "C",  50, 0 }, ;
      { "CS_STATUT",  "C",  30, 0 }, ;
      { "CS_TYPE",    "C",  30, 0 }, ;
      { "NB_RESULT",  "N",   3, 0 }, ;
      { "PORTF_NOM",  "C",  50, 0 }, ;
      { "PORTF_ID",   "C",  20, 0 }, ;
      { "STATUT",     "C",  12, 0 }, ;
      { "HTTP",       "N",   4, 0 }, ;
      { "MESSAGE",    "C", 200, 0 } }

   RETURN OuvreOuCree( cFic, aStruct, "SUIVI", { ;
      { "CLE",   "SERIE+SIREN_ORI" }, ;
      { "SIREN", "SIREN" }, ;
      { "CSID",  "CS_ID" }, ;
      { "PORTF", "PORTF_NOM+SIREN" } } )

STATIC FUNCTION OuvreAlertes( cFic )

   LOCAL aStruct := { ;
      { "NOTIF_ID",   "C",  40, 0 }, ;
      { "EVENT_ID",   "C",  20, 0 }, ;
      { "DATE_EVT",   "C",  25, 0 }, ;
      { "D_EVT",      "D",   8, 0 }, ;
      { "PORTF_ID",   "C",  20, 0 }, ;
      { "PORTF_NOM",  "C",  50, 0 }, ;
      { "CS_ID",      "C",  30, 0 }, ;
      { "SAFENO",     "C",  20, 0 }, ;
      { "CS_NOM",     "C",  80, 0 }, ;
      { "SIREN",      "C",   9, 0 }, ;
      { "SERIE",      "C",   2, 0 }, ;
      { "CA",         "C",  20, 0 }, ;
      { "CODERELA",   "C",  20, 0 }, ;
      { "RULECODE",   "C",  10, 0 }, ;
      { "LIBELLE",    "C", 100, 0 }, ;
      { "ANC_VAL",    "C", 100, 0 }, ;
      { "NOUV_VAL",   "C", 100, 0 }, ;
      { "DATE_RECUP", "D",   8, 0 }, ;
      { "TRAITEE",    "L",   1, 0 } }

   RETURN OuvreOuCree( cFic, aStruct, "ALERT", { ;
      { "NOTIF", "NOTIF_ID" }, ;
      { "SIREN", "SIREN+DTOS(D_EVT)" }, ;
      { "DATE",  "DTOS(D_EVT)" }, ;
      { "CSID",  "CS_ID" } } )

/* Ouvre (ou cree) un DBF en SIXCDX / codepage DBF, avec son index CDX de production.
   Les tags manquants sont crees (ouverture exclusive le temps de la creation). */
STATIC FUNCTION OuvreOuCree( cFic, aStruct, cAlias, aTags )

   LOCAL lOk := .T., cCdp := CdpDbf(), aManque := {}, aT, oErr

   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF ! hb_FileExists( cFic )
         dbCreate( cFic, aStruct, "SIXCDX", NIL, NIL, NIL, cCdp )   /* NIL : cree sans ouvrir */
         CsLog( "Fichier cree : " + cFic + " (SIXCDX, " + cCdp + ")" )
      ENDIF
      dbUseArea( .T., "SIXCDX", cFic, cAlias, .T., .F., cCdp )
      /* fichier d'une version precedente : champs manquants -> structure mise a jour */
      IF AScan( aStruct, {| a | ( cAlias )->( FieldPos( a[ DBS_NAME ] ) ) == 0 } ) > 0
         ( cAlias )->( dbCloseArea() )
         MetAJourStructure( cFic, aStruct, cCdp )
         dbUseArea( .T., "SIXCDX", cFic, cAlias, .T., .F., cCdp )
      ENDIF
      FOR EACH aT IN aTags
         IF ( cAlias )->( ordNumber( aT[ 1 ] ) ) == 0
            AAdd( aManque, aT )
         ENDIF
      NEXT
      IF ! Empty( aManque )
         ( cAlias )->( dbCloseArea() )
         dbUseArea( .T., "SIXCDX", cFic, cAlias, .F., .F., cCdp )
         FOR EACH aT IN aManque
            ( cAlias )->( ordCreate( NIL, aT[ 1 ], aT[ 2 ], hb_macroBlock( aT[ 2 ] ) ) )
            CsLog( "Index cree : " + hb_FNameExtSet( cFic, ".cdx" ) + " tag " + aT[ 1 ] + " = " + aT[ 2 ] )
         NEXT
         ( cAlias )->( dbCloseArea() )
         dbUseArea( .T., "SIXCDX", cFic, cAlias, .T., .F., cCdp )
      ENDIF
      ( cAlias )->( ordSetFocus( 0 ) )
   RECOVER USING oErr
      CsLog( "ERREUR : impossible d'ouvrir/creer/indexer " + cFic + ;
             iif( Empty( aManque ), "", " (creation d'index : le fichier doit etre libre)" ) + ;
             " - " + iif( HB_ISOBJECT( oErr ), ToS( oErr:description ) + " " + ToS( oErr:operation ) + " " + ToS( oErr:filename ), ToS( oErr ) ) )
      IF Select( cAlias ) > 0
         ( cAlias )->( dbCloseArea() )
      ENDIF
      lOk := .F.
   END SEQUENCE

   RETURN lOk

/* Ajoute les champs manquants : le fichier est renomme en <nom>_av.dbf (+ .cdx),
   recree avec la nouvelle structure, puis les enregistrements sont recopies champ par champ.
   Le fichier doit etre libre (ouverture exclusive). Les index sont recrees ensuite par OuvreOuCree. */
STATIC PROCEDURE MetAJourStructure( cFic, aStruct, cCdp )

   LOCAL cAv    := hb_FNameMerge( hb_FNameDir( cFic ), hb_FNameName( cFic ) + "_av", hb_FNameExt( cFic ) )
   LOCAL cCdx   := hb_FNameExtSet( cFic, ".cdx" )
   LOCAL cCdxAv := hb_FNameExtSet( cAv, ".cdx" )
   LOCAL i, nPos, nNb := 0

   /* verifie que personne n'utilise le fichier */
   dbUseArea( .T., "SIXCDX", cFic, "MAJ_OLD", .F., .F., cCdp )
   MAJ_OLD->( dbCloseArea() )

   FErase( cAv )
   FErase( cCdxAv )
   IF FRename( cFic, cAv ) != 0
      Break( "renommage impossible" )
   ENDIF
   IF hb_FileExists( cCdx ) .AND. FRename( cCdx, cCdxAv ) != 0
      FRename( cAv, cFic )
      Break( "renommage de l'index impossible" )
   ENDIF

   dbCreate( cFic, aStruct, "SIXCDX", NIL, NIL, NIL, cCdp )   /* NIL : cree sans ouvrir */
   dbUseArea( .T., "SIXCDX", cFic, "MAJ_NEW", .F., .F., cCdp )
   dbUseArea( .T., "SIXCDX", cAv, "MAJ_OLD", .F., .F., cCdp )
   MAJ_OLD->( ordSetFocus( 0 ) )
   MAJ_OLD->( dbGoTop() )
   DO WHILE ! MAJ_OLD->( Eof() )
      MAJ_NEW->( dbAppend() )
      FOR i := 1 TO MAJ_NEW->( FCount() )
         nPos := MAJ_OLD->( FieldPos( MAJ_NEW->( FieldName( i ) ) ) )
         IF nPos > 0
            MAJ_NEW->( FieldPut( i, MAJ_OLD->( FieldGet( nPos ) ) ) )
         ENDIF
      NEXT
      nNb++
      MAJ_OLD->( dbSkip() )
   ENDDO
   MAJ_NEW->( dbCommit() )
   MAJ_NEW->( dbCloseArea() )
   MAJ_OLD->( dbCloseArea() )
   CsLog( "Structure mise a jour : " + cFic + " (" + hb_ntos( nNb ) + " enregistrements recopies, ancienne version : " + cAv + ")" )

   RETURN

STATIC FUNCTION CdpDbf()
   RETURN Upper( Cfg( "GENERAL", "CODEPAGE_DBF", "FR850" ) )

/* .T. si la serie + SIREN a deja ete traitee avec succes (mode REEL).
   Recherche par nom : les INTROUVABLE et A_VERIFIER ne sont pas relances
   (corriger le nom / l'adresse, renseigner le SIREN, ou supprimer la ligne du suivi pour relancer). */
STATIC FUNCTION DejaTraite( cSerie, cSirenOri, lNom )

   LOCAL cCle := PadR( cSerie, 2 ) + PadR( cSirenOri, 20 ), lDeja := .F.
   LOCAL aFinis := iif( lNom, { "AJOUTE", "DEJA", "INVALIDE", "INTROUVABLE", "A_VERIFIER" }, { "AJOUTE", "DEJA", "INVALIDE" } )

   SUIVI->( ordSetFocus( "CLE" ) )
   SUIVI->( dbSeek( cCle ) )
   DO WHILE ! SUIVI->( Eof() ) .AND. SUIVI->SERIE + SUIVI->SIREN_ORI == cCle
      IF AllTrim( SUIVI->MODE ) == "REEL" .AND. ;
         AScan( aFinis, AllTrim( SUIVI->STATUT ) ) > 0
         lDeja := .T.
         EXIT
      ENDIF
      SUIVI->( dbSkip() )
   ENDDO

   RETURN lDeja

/* Debiteur correspondant a un identifiant Creditsafe (tag CSID du suivi) */
STATIC FUNCTION InfoDebiteur( cCsId )

   IF Select( "SUIVI" ) == 0 .OR. Empty( cCsId )
      RETURN { => }
   ENDIF
   SUIVI->( ordSetFocus( "CSID" ) )
   IF SUIVI->( dbSeek( PadR( cCsId, 30 ) ) )
      RETURN { "SIREN" => SUIVI->SIREN, "SERIE" => SUIVI->SERIE, ;
               "CA" => SUIVI->CA, "CODERELA" => SUIVI->CODERELA }
   ENDIF

   RETURN { => }

STATIC PROCEDURE EcritSuivi( hRes )

   LOCAL k, nPos, xVal

   SUIVI->( dbAppend() )
   SUIVI->DATE_TRT := Date()
   SUIVI->HEURE    := Time()
   SUIVI->MODE     := iif( s_lSimul, "SIMUL", "REEL" )
   FOR EACH k IN hb_HKeys( hRes )
      nPos := SUIVI->( FieldPos( k ) )
      IF nPos > 0
         xVal := hRes[ k ]
         IF SUIVI->( dbFieldInfo( DBS_TYPE, nPos ) ) == "C"
            xVal := ToS( xVal )
         ENDIF
         SUIVI->( FieldPut( nPos, xVal ) )
      ENDIF
   NEXT
   SUIVI->( dbCommit() )
   SUIVI->( dbUnlock() )

   RETURN

/* ==========================================================================
 *  OUTILS
 * ========================================================================== */

STATIC FUNCTION ChargeConfig( cIni )

   s_cIniFile := cIni
   IF ! hb_FileExists( cIni )
      hb_MemoWrit( cIni, IniParDefaut() )
      OutStd( "Fichier de parametres cree : " + cIni + hb_eol() + ;
              "Completez-le (identifiants Creditsafe, champs) puis relancez." + hb_eol() )
      RETURN .F.
   ENDIF
   s_hIni := hb_iniRead( cIni, .F. )
   IF ! HB_ISHASH( s_hIni )
      OutStd( "Fichier de parametres illisible : " + cIni + hb_eol() )
      RETURN .F.
   ENDIF

   RETURN .T.

/* Lecture d'un parametre (section / cle insensibles a la casse) */
STATIC FUNCTION Cfg( cSection, cCle, cDefaut )

   LOCAL hSec := HGetCI( s_hIni, cSection ), x

   IF HB_ISHASH( hSec )
      x := HGetCI( hSec, cCle )
      IF HB_ISSTRING( x ) .AND. ! Empty( x )
         RETURN AllTrim( x )
      ENDIF
   ENDIF

   RETURN cDefaut

/* Nom de fichier : si pas de chemin, on le place dans [GENERAL] DOSSIER */
STATIC FUNCTION CheminFichier( cFic )

   LOCAL cDossier := Cfg( "GENERAL", "DOSSIER", "" )

   IF Empty( cDossier ) .OR. hb_ps() $ cFic .OR. "/" $ cFic .OR. ":" $ cFic
      RETURN cFic
   ENDIF

   RETURN hb_DirSepAdd( cDossier ) + cFic

/* ==========================================================================
 *  INTERRUPTION
 *  - touche Echap dans la fenetre du programme
 *  - ou creation du fichier [GENERAL] FICHIER_ARRET (creditsafe.stop), utile en tache planifiee
 *  Le traitement en cours (debiteur ou page d'alertes) est termine, puis le programme
 *  s'arrete normalement : fichiers fermes, bilan ecrit dans le log.
 * ========================================================================== */
STATIC FUNCTION FichierArret()
   RETURN CheminFichier( Cfg( "GENERAL", "FICHIER_ARRET", "creditsafe.stop" ) )

/* Au demarrage : supprime un fichier d'arret oublie et vide le tampon clavier */
STATIC PROCEDURE PrepareArret()

   LOCAL cFic := FichierArret()

   IF hb_FileExists( cFic )
      FErase( cFic )
      CsLog( "Ancien fichier d'arret supprime : " + cFic )
   ENDIF
   CLEAR TYPEAHEAD
   CsLog( "Pour interrompre : touche Echap, ou creer le fichier " + cFic )

   RETURN

STATIC FUNCTION DemandeArret()

   LOCAL nTouche, cFic := FichierArret()

   DO WHILE ( nTouche := Inkey() ) != 0
      IF nTouche == K_ESC
         CsLog( "*** Interruption demandee (touche Echap) ***" )
         RETURN .T.
      ENDIF
   ENDDO
   IF hb_FileExists( cFic )
      FErase( cFic )
      CsLog( "*** Interruption demandee (fichier " + cFic + ") ***" )
      RETURN .T.
   ENDIF

   RETURN .F.

/* Positions des champs "ADR1+ADR2" (ou "ADR1,ADR2") dans l'alias DEB */
STATIC FUNCTION PosChamps( cListe, cFic )

   LOCAL aPos := {}, cCh, nPos

   FOR EACH cCh IN hb_ATokens( StrTran( cListe, ",", "+" ), "+" )
      cCh := AllTrim( cCh )
      IF ! Empty( cCh )
         nPos := DEB->( FieldPos( cCh ) )
         IF nPos > 0
            AAdd( aPos, nPos )
         ELSE
            CsLog( "ATTENTION : champ " + cCh + " absent de " + cFic + " (voir [CHAMPS])" )
         ENDIF
      ENDIF
   NEXT

   RETURN aPos

/* Valeurs des champs (positions) du debiteur courant, separees par un espace */
STATIC FUNCTION ValeurChamps( aPos )

   LOCAL cRes := "", nPos, c

   FOR EACH nPos IN aPos
      c := AllTrim( ToS( DEB->( FieldGet( nPos ) ) ) )
      IF ! Empty( c )
         cRes += iif( Empty( cRes ), "", " " ) + c
      ENDIF
   NEXT

   RETURN cRes

/* Valeur du premier champ non vide parmi les positions donnees */
STATIC FUNCTION PremierChamp( aPos )

   LOCAL nPos, c

   FOR EACH nPos IN aPos
      c := AllTrim( ToS( DEB->( FieldGet( nPos ) ) ) )
      IF ! Empty( c )
         RETURN c
      ENDIF
   NEXT

   RETURN ""

STATIC FUNCTION NormaliseSiren( c )

   c := Chiffres( c )
   DO CASE
   CASE Len( c ) == 14            /* SIRET -> SIREN */
      RETURN Left( c, 9 )
   CASE Len( c ) == 9
      RETURN c
   CASE Len( c ) == 8             /* zero de tete perdu */
      RETURN "0" + c
   ENDCASE

   RETURN ""

/* Cle de Luhn du SIREN */
STATIC FUNCTION SirenValide( c )

   LOCAL i, n, nSomme := 0

   IF Len( c ) != 9 .OR. c == "000000000"
      RETURN .F.
   ENDIF
   FOR i := 1 TO 9
      n := Val( SubStr( c, i, 1 ) )
      IF i % 2 == 0
         n *= 2
         IF n > 9
            n -= 9
         ENDIF
      ENDIF
      nSomme += n
   NEXT

   RETURN nSomme % 10 == 0

STATIC FUNCTION Chiffres( c )

   LOCAL cRes := "", ch

   FOR EACH ch IN c
      IF ch >= "0" .AND. ch <= "9"
         cRes += ch
      ENDIF
   NEXT

   RETURN cRes

STATIC FUNCTION ToS( x )

   DO CASE
   CASE HB_ISSTRING( x )
      RETURN x
   CASE HB_ISNUMERIC( x )
      RETURN hb_ntos( x )
   CASE HB_ISLOGICAL( x )
      RETURN iif( x, "true", "false" )
   CASE HB_ISDATE( x )
      RETURN DToC( x )
   CASE HB_ISHASH( x ) .OR. HB_ISARRAY( x )
      RETURN hb_jsonEncode( x )
   ENDCASE

   RETURN ""

STATIC FUNCTION PremierNonVide( aVal )

   LOCAL x

   FOR EACH x IN aVal
      IF ! Empty( ToS( x ) )
         RETURN ToS( x )
      ENDIF
   NEXT

   RETURN ""

STATIC PROCEDURE Compte( hStat, cCle )

   hStat[ cCle ] := hb_HGetDef( hStat, cCle, 0 ) + 1

   RETURN

STATIC PROCEDURE OuvreLog()

   LOCAL cFic := CheminFichier( Cfg( "GENERAL", "FICHIER_LOG", "creditsafe.log" ) )

   IF hb_FileExists( cFic )
      s_nLog := FOpen( cFic, FO_READWRITE + FO_SHARED )
      IF s_nLog != -1
         FSeek( s_nLog, 0, FS_END )
      ENDIF
   ELSE
      s_nLog := FCreate( cFic )
   ENDIF

   RETURN

STATIC PROCEDURE CsLog( cMsg )

   LOCAL cLigne := DToC( Date() ) + " " + Time() + "  " + cMsg

   OutStd( cLigne + hb_eol() )
   IF s_nLog != -1
      FWrite( s_nLog, cLigne + CRLF )
   ENDIF

   RETURN

STATIC FUNCTION IniParDefaut()

   RETURN ;
      "; Parametres de creditsafe.exe" + CRLF + ;
      "[GENERAL]" + CRLF + ;
      "DOSSIER=\source\creditsafe" + CRLF + ;
      "FICHIER_DEBITEURS=DebSiren.dbf" + CRLF + ;
      "FICHIER_SUIVI=CsSuivi.dbf" + CRLF + ;
      "FICHIER_ALERTES=CsAlertes.dbf" + CRLF + ;
      "FICHIER_LOG=creditsafe.log" + CRLF + ;
      "FICHIER_ARRET=creditsafe.stop" + CRLF + ;
      "CODEPAGE=FRWIN" + CRLF + ;
      "CODEPAGE_DBF=FR850" + CRLF + ;
      "SIMULATION=1" + CRLF + ;
      "MAX_DEBITEURS=0" + CRLF + CRLF + ;
      "[CHAMPS]" + CRLF + ;
      "SIREN=SIREN" + CRLF + ;
      "CA=CA" + CRLF + ;
      "CODERELA=CODERELA" + CRLF + ;
      "NOM=NOM" + CRLF + ;
      "ADRESSE=ADRESSE" + CRLF + ;
      "CP=CP" + CRLF + ;
      "VILLE=VILLE" + CRLF + ;
      "LIMITE=" + CRLF + ;
      "FILTRE=" + CRLF + ;
      "CONTROLE_LUHN=1" + CRLF + CRLF + ;
      "[RECHERCHE]" + CRLF + ;
      "PAR_NOM=1" + CRLF + ;
      "NOM_SEUL=0" + CRLF + ;
      "SCORE_AUTO=80" + CRLF + ;
      "SCORE_MIN=55" + CRLF + ;
      "ECART_MIN=10" + CRLF + ;
      "NB_CANDIDATS=20" + CRLF + CRLF + ;
      "[API]" + CRLF + ;
      "ENVIRONNEMENT=SANDBOX" + CRLF + ;
      "URL_LIVE=https://connect.creditsafe.com/v1" + CRLF + ;
      "URL_SANDBOX=https://connect.sandbox.creditsafe.com/v1" + CRLF + ;
      "UTILISATEUR=" + CRLF + ;
      "MOT_DE_PASSE=" + CRLF + ;
      "PAUSE_MS=250" + CRLF + ;
      "TIMEOUT_S=60" + CRLF + CRLF + ;
      "[PORTEFEUILLE]" + CRLF + ;
      "PREFIXE_NOM=DEBITEURS-" + CRLF + ;
      "SERIE_PAR_DEFAUT=ZZ" + CRLF + ;
      "LIMITE_PERSONNELLE=" + CRLF + ;
      "EMAILS=" + CRLF + ;
      "PORTEFEUILLE_MODELE_REGLES=" + CRLF + ;
      "PAYS_REGLES=FR" + CRLF + CRLF + ;
      "[ALERTES]" + CRLF + ;
      "JOURS=30" + CRLF + ;
      "SEULEMENT_NON_TRAITEES=1" + CRLF + ;
      "MARQUER_TRAITEES=0" + CRLF

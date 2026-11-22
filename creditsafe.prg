/*
 * creditsafe.prg
 * Mise en surveillance automatique des debiteurs professionnels sur Creditsafe
 * (API Connect v1 - Global Monitoring) et recuperation des alertes.
 *
 * Utilisation :
 *    creditsafe SURVEIL  [fichier.ini]   -> met les debiteurs en surveillance
 *    creditsafe ALERTES  [fichier.ini]   -> recupere les alertes (notification events)
 *    creditsafe TEST     [fichier.ini]   -> teste l'authentification et liste les portefeuilles
 *
 * Par defaut le fichier de parametres est creditsafe.ini (a cote de l'executable).
 *
 * Compilation (Windows) :  hbmk2 creditsafe.hbp
 */

#include "fileio.ch"
#include "dbstruct.ch"

REQUEST HB_CODEPAGE_FRWIN
REQUEST HB_CODEPAGE_FR850
REQUEST HB_CODEPAGE_FRISO
REQUEST DBFNTX

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
   rddSetDefault( "DBFNTX" )

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
   Log( "===== Debut " + cMode + " - API " + s_cBaseUrl + iif( s_lSimul, " - MODE SIMULATION", "" ) + " =====" )

   DO CASE
   CASE cMode == "SURVEIL"
      MiseEnSurveillance()
   CASE cMode == "ALERTES"
      RecupereAlertes()
   CASE cMode == "TEST"
      TestConnexion()
   OTHERWISE
      Log( "Mode inconnu : " + cMode + "  (SURVEIL, ALERTES ou TEST)" )
   ENDCASE

   Log( "===== Fin " + cMode + " =====" )
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
   LOCAL cFiltre   := Cfg( "CHAMPS", "FILTRE", "" )
   LOCAL lLuhn     := Cfg( "CHAMPS", "CONTROLE_LUHN", "1" ) == "1"
   LOCAL nMax      := Val( Cfg( "GENERAL", "MAX_DEBITEURS", "0" ) )
   LOCAL nPause    := Val( Cfg( "API", "PAUSE_MS", "250" ) ) / 1000
   LOCAL cPrefixe  := Cfg( "PORTEFEUILLE", "PREFIXE_NOM", "DEBITEURS-" )
   LOCAL cSerieDef := Cfg( "PORTEFEUILLE", "SERIE_PAR_DEFAUT", "ZZ" )
   LOCAL bFiltre, hDeja, hVu := { => }, hPort, hStat := { => }
   LOCAL nPosSiren, nPosCA, nPosRela, nPosNom
   LOCAL cCA, cRela, cNom, xSiren, cSirenOri, cSiren, cSerie, cCle, cPortNom, cPortId
   LOCAL hRes, nTraites := 0, k

   IF ! hb_FileExists( cFicDeb )
      Log( "ERREUR : fichier debiteurs introuvable : " + cFicDeb )
      RETURN
   ENDIF
   IF ! OuvreSuivi( cFicSuivi )
      RETURN
   ENDIF

   /* deja en surveillance lors d'un passage precedent -> on ne refait pas */
   hDeja := { => }
   SUIVI->( dbGoTop() )
   DO WHILE ! SUIVI->( Eof() )
      IF AllTrim( SUIVI->STATUT ) $ "AJOUTE|DEJA|INVALIDE" .AND. AllTrim( SUIVI->MODE ) == "REEL"
         hDeja[ SUIVI->SERIE + "|" + AllTrim( SUIVI->SIREN_ORI ) ] := .T.
      ENDIF
      SUIVI->( dbSkip() )
   ENDDO

   BEGIN SEQUENCE WITH {| e | Break( e ) }
      dbUseArea( .T., NIL, cFicDeb, "DEB", .T., .T. )
   RECOVER
      Log( "ERREUR : impossible d'ouvrir " + cFicDeb )
      SUIVI->( dbCloseArea() )
      RETURN
   END SEQUENCE

   nPosSiren := DEB->( FieldPos( cChSiren ) )
   nPosCA    := DEB->( FieldPos( cChCA ) )
   nPosRela  := DEB->( FieldPos( cChRela ) )
   nPosNom   := DEB->( FieldPos( cChNom ) )
   IF nPosSiren == 0
      Log( "ERREUR : champ " + cChSiren + " absent de " + cFicDeb + " (voir [CHAMPS] SIREN=)" )
      DEB->( dbCloseArea() )
      SUIVI->( dbCloseArea() )
      RETURN
   ENDIF
   IF nPosCA == 0 .AND. nPosRela == 0
      Log( "ATTENTION : ni " + cChCA + " ni " + cChRela + " presents : serie par defaut " + cSerieDef )
   ENDIF
   IF ! Empty( cFiltre )
      bFiltre := hb_macroBlock( cFiltre )
      Log( "Filtre debiteurs : " + cFiltre )
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
   DO WHILE ! DEB->( Eof() )

      IF bFiltre != NIL
         BEGIN SEQUENCE WITH {| e | Break( e ) }
            IF ! Eval( bFiltre )
               DEB->( dbSkip() )
               LOOP
            ENDIF
         RECOVER
            Log( "ERREUR : expression FILTRE invalide : " + cFiltre )
            EXIT
         END SEQUENCE
      ENDIF

      cCA   := iif( nPosCA   > 0, AllTrim( ToS( DEB->( FieldGet( nPosCA ) ) ) ), "" )
      cRela := iif( nPosRela > 0, AllTrim( ToS( DEB->( FieldGet( nPosRela ) ) ) ), "" )
      cNom  := iif( nPosNom  > 0, AllTrim( ToS( DEB->( FieldGet( nPosNom ) ) ) ), "" )
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

      cSirenOri := iif( HB_ISNUMERIC( xSiren ), iif( xSiren < 1000000000, StrZero( xSiren, 9 ), StrZero( xSiren, 14 ) ), AllTrim( ToS( xSiren ) ) )
      cSiren    := NormaliseSiren( cSirenOri )
      cCle      := cSerie + "|" + cSirenOri

      /* pas de SIREN -> pas un professionnel identifiable, on ignore sans tracer */
      IF Empty( cSirenOri )
         DEB->( dbSkip() )
         LOOP
      ENDIF
      IF hb_HHasKey( hDeja, cCle ) .OR. hb_HHasKey( hVu, cCle )
         DEB->( dbSkip() )
         LOOP
      ENDIF
      hVu[ cCle ] := .T.

      hRes := { "SERIE" => cSerie, "CA" => cCA, "CODERELA" => cRela, "NOM_DEB" => cNom, ;
                "SIREN_ORI" => cSirenOri, "SIREN" => cSiren, "DEB_RECNO" => DEB->( RecNo() ), ;
                "STATUT" => "", "HTTP" => 0, "MESSAGE" => "" }

      IF Empty( cSiren ) .OR. ( lLuhn .AND. ! SirenValide( cSiren ) )
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
         IF Empty( cPortId )
            hRes[ "STATUT" ]  := "ERREUR"
            hRes[ "MESSAGE" ] := "Creation du portefeuille " + cPortNom + " impossible"
            EcritSuivi( hRes )
            Compte( hStat, "ERREUR" )
            DEB->( dbSkip() )
            LOOP
         ENDIF
         hPort[ Upper( cPortNom ) ] := cPortId
      ENDIF
      hRes[ "PORTF_ID" ] := cPortId

      /* --- recherche de la societe par SIREN --- */
      IF RechercheSociete( cSiren, hRes )
         /* --- ajout au portefeuille --- */
         AjouteSociete( cPortId, hRes )
      ENDIF

      EcritSuivi( hRes )
      Compte( hStat, hRes[ "STATUT" ] )
      Log( PadR( cSerie, 3 ) + cSiren + "  " + PadR( hRes[ "STATUT" ], 10 ) + " " + ;
           Left( hb_HGetDef( hRes, "CS_NOM", cNom ), 40 ) + "  -> " + cPortNom + ;
           iif( Empty( hRes[ "MESSAGE" ] ), "", "  (" + hRes[ "MESSAGE" ] + ")" ) )

      nTraites++
      IF nMax > 0 .AND. nTraites >= nMax
         Log( "Limite MAX_DEBITEURS atteinte (" + hb_ntos( nMax ) + ")" )
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

   Log( "Bilan :" )
   FOR EACH k IN hb_HKeys( hStat )
      Log( "   " + PadR( k, 12 ) + Str( hStat[ k ], 7 ) )
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

   hRes[ "CS_ID" ]      := ToS( JGet( hBest, "id" ) )
   hRes[ "SAFENO" ]     := ToS( JGet( hBest, "safeNo" ) )
   hRes[ "CS_NOM" ]     := ToS( JGet( hBest, "name" ) )
   hRes[ "CS_REGNO" ]   := ToS( JGet( hBest, "regNo" ) )
   hRes[ "CS_ADRESSE" ] := ToS( JGet( hBest, "address", "simpleValue" ) )
   hRes[ "CS_CP" ]      := ToS( JGet( hBest, "address", "postCode" ) )
   hRes[ "CS_VILLE" ]   := ToS( JGet( hBest, "address", "city" ) )
   hRes[ "CS_STATUT" ]  := ToS( JGet( hBest, "status" ) )
   hRes[ "CS_TYPE" ]    := ToS( JGet( hBest, "officeType" ) )
   k := hRes[ "CS_ID" ]

   IF Empty( k )
      hRes[ "STATUT" ]  := "INTROUVABLE"
      hRes[ "MESSAGE" ] := "Reponse sans identifiant Creditsafe"
      RETURN .F.
   ENDIF

   RETURN .T.

/* Ajoute la societe (connectId) au portefeuille */
STATIC PROCEDURE AjouteSociete( cPortId, hRes )

   LOCAL nStatus := 0, cResp := "", hJson, hBody, cMsg

   IF s_lSimul
      hRes[ "STATUT" ] := "SIMULE"
      RETURN
   ENDIF

   hBody := { "id" => hRes[ "CS_ID" ], ;
              "personalReference" => Left( iif( Empty( hRes[ "CA" ] ), hRes[ "CODERELA" ], hRes[ "CA" ] ), 50 ), ;
              "freeText" => Left( hRes[ "NOM_DEB" ], 100 ) }

   HttpJson( "POST", "/monitoring/portfolios/" + cPortId + "/companies", hBody, @nStatus, @cResp, @hJson )
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
      Log( "[SIMULATION] creation du portefeuille " + cNom )
      RETURN "SIMUL-" + cSerie
   ENDIF

   FOR EACH cMail IN hb_ATokens( Cfg( "PORTEFEUILLE", "EMAILS", "" ), ";" )
      IF ! Empty( cMail )
         AAdd( aMails, AllTrim( cMail ) )
      ENDIF
   NEXT

   hBody := { "name" => cNom, ;
              "information" => "Debiteurs serie " + cSerie + " - cree automatiquement le " + DToC( Date() ) }
   IF ! Empty( aMails )
      hBody[ "emails" ] := aMails
   ENDIF

   IF ! HttpJson( "POST", "/monitoring/portfolios", hBody, @nStatus, @cResp, @hJson )
      Log( "ERREUR creation portefeuille " + cNom + " : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
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
   Log( "Portefeuille cree : " + cNom + " (id " + cId + ")" )

   IF ! Empty( cId ) .AND. ! Empty( cModele )
      CopieRegles( cModele, cId )
   ENDIF

   RETURN cId

/* Copie les regles d'evenements (alertes) d'un portefeuille modele */
STATIC PROCEDURE CopieRegles( cModele, cId )

   LOCAL cPays := Cfg( "PORTEFEUILLE", "PAYS_REGLES", "FR" )
   LOCAL nStatus := 0, cResp := "", hJson, xRegles, nSt2 := 0, cResp2 := ""

   IF ! HttpJson( "GET", "/monitoring/portfolios/" + cModele + "/eventRules/" + cPays, NIL, @nStatus, @cResp, @hJson )
      Log( "ATTENTION : lecture des regles du portefeuille modele " + cModele + " impossible (HTTP " + hb_ntos( nStatus ) + ")" )
      RETURN
   ENDIF
   xRegles := iif( HB_ISARRAY( hJson ), hJson, JGet( hJson, "data" ) )
   IF ! HB_ISARRAY( xRegles )
      xRegles := hJson
   ENDIF
   HttpJson( "PUT", "/monitoring/portfolios/" + cId + "/eventRules/" + cPays, xRegles, @nSt2, @cResp2 )
   Log( "Copie des regles " + cPays + " depuis " + cModele + " -> " + cId + " : HTTP " + hb_ntos( nSt2 ) + ;
        iif( nSt2 >= 200 .AND. nSt2 < 300, "", " " + MessageErreur( cResp2 ) ) )

   RETURN

/* Renvoie un hash  NOM_PORTEFEUILLE (majuscules) => id */
STATIC FUNCTION ListePortefeuilles()

   LOCAL hPort := { => }, nPage := 0, nSize := 100, nStatus := 0, cResp := "", hJson, aP, hP, nNew

   DO WHILE nPage < 100
      IF ! HttpJson( "GET", "/monitoring/portfolios?page=" + hb_ntos( nPage ) + "&pageSize=" + hb_ntos( nSize ), NIL, @nStatus, @cResp, @hJson )
         Log( "ERREUR lecture des portefeuilles : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
         EXIT
      ENDIF
      aP := iif( HB_ISARRAY( hJson ), hJson, JGet( hJson, "portfolios" ) )
      IF ! HB_ISARRAY( aP )
         aP := JGet( hJson, "data" )
      ENDIF
      IF ! HB_ISARRAY( aP ) .OR. Empty( aP )
         EXIT
      ENDIF
      nNew := 0
      FOR EACH hP IN aP
         IF ! hb_HHasKey( hPort, Upper( AllTrim( ToS( JGet( hP, "name" ) ) ) ) )
            hPort[ Upper( AllTrim( ToS( JGet( hP, "name" ) ) ) ) ] := ToS( JGet( hP, "portfolioId" ) )
            nNew++
         ENDIF
      NEXT
      IF Len( aP ) < nSize .OR. nNew == 0
         EXIT
      ENDIF
      nPage++
   ENDDO
   Log( hb_ntos( Len( hPort ) ) + " portefeuille(s) existant(s) sur le compte" )

   RETURN hPort

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
   LOCAL hPort, hDeja := { => }, hSoc := { => }, cNom, cId, nPage, nStatus, cResp, hJson
   LOCAL aEv, hEv, cNotif, nNew, nTotal := 0, cUrl, hInfo, cDate, nSt2, cR2

   IF ! OuvreAlertes( cFicAl )
      RETURN
   ENDIF
   ALERT->( dbGoTop() )
   DO WHILE ! ALERT->( Eof() )
      hDeja[ AllTrim( ALERT->NOTIF_ID ) ] := .T.
      ALERT->( dbSkip() )
   ENDDO

   /* correspondance identifiant Creditsafe -> debiteur (depuis le fichier de suivi) */
   IF hb_FileExists( cFicSuivi ) .AND. OuvreSuivi( cFicSuivi )
      SUIVI->( dbGoTop() )
      DO WHILE ! SUIVI->( Eof() )
         IF ! Empty( SUIVI->CS_ID ) .AND. ! hb_HHasKey( hSoc, AllTrim( SUIVI->CS_ID ) )
            hSoc[ AllTrim( SUIVI->CS_ID ) ] := { "SIREN" => SUIVI->SIREN, "SERIE" => SUIVI->SERIE, ;
                                                 "CA" => SUIVI->CA, "CODERELA" => SUIVI->CODERELA }
         ENDIF
         SUIVI->( dbSkip() )
      ENDDO
      SUIVI->( dbCloseArea() )
   ENDIF

   IF ! Authentifier()
      ALERT->( dbCloseArea() )
      RETURN
   ENDIF
   hPort := ListePortefeuilles()

   cDate := Transform( DToS( Date() - nJours ), "@R 9999-99-99" )
   Log( "Recherche des alertes depuis le " + cDate )

   FOR EACH cNom IN hb_HKeys( hPort )
      IF ! Empty( cPrefixe ) .AND. ! Left( cNom, Len( cPrefixe ) ) == cPrefixe
         LOOP
      ENDIF
      cId := hPort[ cNom ]
      nPage := 0
      DO WHILE nPage < 500
         cUrl := "/monitoring/portfolios/" + cId + "/notificationEvents?startDate=" + cDate + ;
                 "&endDate=" + Transform( DToS( Date() + 1 ), "@R 9999-99-99" ) + ;
                 "&page=" + hb_ntos( nPage ) + "&pageSize=" + hb_ntos( nSize ) + ;
                 iif( lNonTrt, "&isProcessed=false", "" )
         nStatus := 0
         cResp   := ""
         hJson   := NIL
         IF ! HttpJson( "GET", cUrl, NIL, @nStatus, @cResp, @hJson )
            Log( "ERREUR alertes portefeuille " + cNom + " : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
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
            IF Empty( cNotif ) .OR. hb_HHasKey( hDeja, cNotif )
               LOOP
            ENDIF
            hDeja[ cNotif ] := .T.
            nNew++
            hInfo := hb_HGetDef( hSoc, ToS( JGet( hEv, "company", "id" ) ), { => } )

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
            ENDIF
         NEXT
         IF Len( aEv ) < nSize .OR. nNew == 0
            EXIT
         ENDIF
         nPage++
      ENDDO
   NEXT

   ALERT->( dbCommit() )
   ALERT->( dbCloseArea() )
   Log( hb_ntos( nTotal ) + " nouvelle(s) alerte(s) enregistree(s) dans " + cFicAl )

   RETURN

/* ==========================================================================
 *  3) TEST
 * ========================================================================== */

STATIC PROCEDURE TestConnexion()

   LOCAL hPort, k

   IF Authentifier()
      hPort := ListePortefeuilles()
      FOR EACH k IN hb_HKeys( hPort )
         Log( "   " + PadR( hPort[ k ], 12 ) + k )
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
      Log( "ERREUR : identifiants Creditsafe absents ([API] UTILISATEUR / MOT_DE_PASSE ou variables CREDITSAFE_USER / CREDITSAFE_PASSWORD)" )
      RETURN .F.
   ENDIF

   s_cToken := ""
   IF HttpJson( "POST", "/authenticate", { "username" => cUser, "password" => cPass }, @nStatus, @cResp, @hJson, .T. )
      s_cToken := ToS( JGet( hJson, "token" ) )
   ENDIF
   IF Empty( s_cToken )
      Log( "ERREUR authentification Creditsafe : HTTP " + hb_ntos( nStatus ) + " " + MessageErreur( cResp ) )
      RETURN .F.
   ENDIF
   Log( "Authentification Creditsafe OK" )

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
         Log( "   HTTP " + hb_ntos( nStatus ) + " sur " + cMethod + " " + cPath + " - nouvel essai dans " + hb_ntos( nEssai * 5 ) + " s" )
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

   RETURN OuvreOuCree( cFic, aStruct, "SUIVI" )

STATIC FUNCTION OuvreAlertes( cFic )

   LOCAL aStruct := { ;
      { "NOTIF_ID",   "C",  20, 0 }, ;
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

   RETURN OuvreOuCree( cFic, aStruct, "ALERT" )

STATIC FUNCTION OuvreOuCree( cFic, aStruct, cAlias )

   LOCAL lOk := .T.

   BEGIN SEQUENCE WITH {| e | Break( e ) }
      IF ! hb_FileExists( cFic )
         dbCreate( cFic, aStruct )
         Log( "Fichier cree : " + cFic )
      ENDIF
      dbUseArea( .T., NIL, cFic, cAlias, .T., .F. )
   RECOVER
      Log( "ERREUR : impossible d'ouvrir/creer " + cFic )
      lOk := .F.
   END SEQUENCE

   RETURN lOk

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

STATIC PROCEDURE Log( cMsg )

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
      "CODEPAGE=FRWIN" + CRLF + ;
      "SIMULATION=1" + CRLF + ;
      "MAX_DEBITEURS=0" + CRLF + CRLF + ;
      "[CHAMPS]" + CRLF + ;
      "SIREN=SIREN" + CRLF + ;
      "CA=CA" + CRLF + ;
      "CODERELA=CODERELA" + CRLF + ;
      "NOM=NOM" + CRLF + ;
      "FILTRE=" + CRLF + ;
      "CONTROLE_LUHN=1" + CRLF + CRLF + ;
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
      "EMAILS=" + CRLF + ;
      "PORTEFEUILLE_MODELE_REGLES=" + CRLF + ;
      "PAYS_REGLES=FR" + CRLF + CRLF + ;
      "[ALERTES]" + CRLF + ;
      "JOURS=30" + CRLF + ;
      "SEULEMENT_NON_TRAITEES=1" + CRLF + ;
      "MARQUER_TRAITEES=0" + CRLF

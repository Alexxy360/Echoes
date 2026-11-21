# HTTP operatora zgłoszonych zdjęć — CK-05d.2c

CK-05d.2c.1 rozszerza kontrakt o [zamykanie niepewnych prób](ZAMYKANIE_NIEPEWNYCH_DECYZJI_MODERATORA.md). Wcześniejsze liczby i dowody2c poniżej są historyczne; kolejny panel iOS zdjęć2d ma używać terminalnego retire od początku.

Aktualizacja CK-05d.2d.1: [natywny transport i walidacja ramki](NATYWNY_TRANSPORT_OPERATORA_ZDJEC.md) odebrane lokalnie; późniejszy2d.2a dodaje [osobny journal](DZIENNIK_OPERATORA_ZGLOSZONYCH_ZDJEC.md). Host/panel/Runtime pozostają niepodłączone. Poniższy odbiór2c jest historyczny.

Stan: lokalnie zaimplementowane i odebrane edge/Authority/Runtime. AVATAR_REPORT_REVIEW_ENABLED=0 i AVATAR_REPORT_REVIEWER_IDS_JSON=[] w konfiguracji; brak wdrożenia lub nadania roli. [Koordynator i cały proces](OPERATOR_ZGLOSZEN_ZDJEC.md).

## Zakres i uprawnienia

Osobne POST /v1/moderation/avatar-reports/queue, inspect, decide, recover i retire (CK-05d.2c.1). Nie współdzielą typów z przyjmowaniem zgłoszenia zdjęcia, moderacją wiadomości albo approved/rejected uploadu. Nowa flaga wymaga COMMUNITY/PUBLIC_RECORDS/ACCOUNT_DELETION i zaufanych hostów pobierania. Jest niezależna od READ, uploadu, intake oraz pozostałych list moderatorów. Lista do16 kont pochodzi wyłącznie z konfiguracji serwera; domyślnie pusta. Zwykły bearer użytkownika nie nadaje tej roli, pole owner/operator w JSON jest odrzucane.

Authority weryfikuje sesję i rolę przed body/checkpoint/provider, ponownie po limitach/IO i końcowym checkpoint. Runtime i edge przypinają listę moderatorów oraz hostów do aktywnej konfiguracji; zmiana/wygaśnięcie odcina stary przebieg. Tylko prawdziwe request.cf/IP wylicza budżet na edge, a stały prywatny Authority dostaje zamknięte nagłówki. Pełna integracja2c nie uruchamia usług lub nowych sekretów.

Request ma zamknięte JSON512B/128fragmentów/3s, natywny bearer, brak Origin/range/kompresji lub prywatnych nagłówków zdjęcia. Global/IP heavy oraz reviewer30/min i inspect10/min są zużywane przed parsowaniem w Authority. Warstwa edge musi wcześniej ograniczyć i sprawdzić własne512B; to nie kryptograficzny dowód fizycznego IP/GPS klienta. GPS nie jest częścią tego API operatora. Koordynator ma8s, Authority12s, edge15s; deadline sprawdza wall i monotonic floors, także częściowe cofnięcie po wcześniejszym odczycie.

## Kontrakt

| Operacja | Wejście | Sukces |
| --- | --- | --- |
| queue | after:string lub null | JSON schemaVersion1, do20 pozycji reportID/createdAt/expiresAt i marker postępu |
| inspect | reportID | prywatna ramka metadata+JPEG lub metadata bez zdjęcia |
| decide | inspectionID,decisionID,verdict dismiss/hide_photo | JSON dokładnej decyzji/contentHash/revision, bez powodu lub obrazu |
| recover | reportID,decisionID,verdict,contentHash | JSON confirmed/not-applied/superseded/retired, wyłącznie odczyt |
| retire | reportID,decisionID,verdict,contentHash | JSON retired/confirmed/superseded; jawna bariera przyszłego wykonania własnej próby, bez cofania skutków |

JSON ma protocolVersion1, no-store/nosniff; limity odpowiedzi queue8192B, decide/recover/błąd2048B. Zamknięte kody i statusy obejmują input400, scope403, stale409, quota429 i unavailable/response503. Nieznany wynik nie oznacza cofnięcia mutacji i nie daje automatycznego nowego decisionID. Te same dane decyzji mogą odtworzyć wynik, a readonly recovery działa po wygaśnięciu inspekcji, w terminie raportu.

## Jedna binarna inspekcja

Content-Type: application/vnd.echoes.avatar-report-inspection.v1. Body składa się z4B unsigned big-endian długości metadata,1–12288B UTF-8 JSON oraz dokładnie manifest.byteCount JPEG do256000B. Łącznie do268292B. Metadata zawiera protocolVersion/schemaVersion1, inspectionID/inspectionExpiresAt, contentHash/reportID, createdAt/expiresAt, poufny reason i photo. Photo to null albo ownerID/versionID/publicationGeneration i pełny manifest obrazu. Przy null nie wolno dołączyć żadnego ogona danych.

Powód ma NFC/trim/do500UTF16, bez niedozwolonych znaków lub lone surrogates; daty są bezpiecznymi całkowitymi ms, raport ma pierwotne30dni, receipt do90s i nie przekracza terminu raportu. Metadata ma ścisły inwentarz kluczy. Owner/version manifestu odpowiadają photo, variant=image, pozytywne wymiary do512 i długość do256000. Pełna długość, SHA i struktura/wymiary JPEG są sprawdzane przy serializacji i na edge. To nie zastępuje bezpiecznego dekodera RGB i faktycznego wyświetlenia w przyszłym iOS2d.

Wymagane są dokładny Content-Length, `Cache-Control: private, no-store` i nosniff; bez kompresji/range/przekierowań. Powód nie trafia do nagłówka, obraz nie jest base64 i nie ma URL/receipt dostawcy, reporterID, GPS lub dodatkowego profilu. Błędy inspekcji to mały osobny JSON. Cała ramka przechodzi kontrolę przed udostępnieniem czegokolwiek odbiorcy. Edge ponownie serializuje tylko dozwolone pola/nagłówki.

Encoder konsumuje kopię obrazu koordynatora i czyści ją również po odmowie; czyści też własne przejściowe buforowanie. Transport ma własną kopię Response. Nie obiecujemy wyzerowania wszystkich kopii RAM/systemowych ani cofnięcia już odebranych pikseli. Stan receipt nie przechowuje zdjęcia lub powodu.

## Odpływ i usuwanie

Admission pozostaje zajęte aż do rzeczywistego zakończenia metody/bufora i pierwszego stream cancel, również gdy deadline zwrócił już błąd wywołującemu. Niepotwierdzony lub błędny cancel zamyka gate do odtworzenia instancji; stara odpowiedź nie zwalnia nowszej rezerwacji. Maintenance uwzględnia zajęty koordynator. Przy samym tym trybie właściciel zachowuje withdrawal/status, nie dostaje upload/publish/moderator. Erasure/retencja2a i bariery2b pozostają obowiązkowe.

## Wyniki i granice

15 nowych funkcji (14 HTTP/framing i1 rzeczywisty lokalny workerd), finalne909/909 na Node22.23.5 i909/909 na24.22.1; syntax199MJS obu i2JSON. Testy obejmują format i truncation, UTF8/protocol/extra keys/hash/length/manifest, null bez ogona, wyczyszczenie odrzuconej kopii, role/limity przed body, chunk budget, niepełną ramkę z faktycznym oczekiwaniem na cancel, partial clock rollback, ACK po revocation i domyślnie wyłączone trasy. Negatywna kopia bez warunku byteCount oblewa1test/1asercję; oryginał zachowany.

Rzeczywisty lokalny workerd wykonuje edge → prywatny Authority → konkretny Runtime → DO SQLite/podpisany klient → ramkę/JPEG → decyzję/replay oraz readonly recovery po odtworzeniu Runtime i expiry. Zegar fixture dopasowano do realnych alarmów i wydano świeże syntetyczne sesje. Apple/CDN/SIWA/konta oraz platformowe IP są modelowane; outbound poza loopback jest zablokowany. To ta sama baza/proces, nie restart/power-loss/PITR lub hosted Free/CPU/capacity albo zwykłe A/B. [Dokładne wyniki i SHA](evidence/avatar-report-review-http-local-tests.json).

W chwili historycznego odbioru2c nie było jeszcze natywnego transportu/journala/hosta/panelu tego procesu. Późniejszy2d.1 dodaje transport; journal/host/panel pozostają2d.2/3. W historycznym2c iOS/Core/deps/CI były niezmienione i niepowtarzane. Bez nowych uprawnień/kluczy/sekretów/usług/opłat/SDK telefonu/Apple/Cloudflare/Production/Firebase/TestFlight. Konfiguracja domyślnie wyłączona, zastany project.pbxproj zachowany; pełna migracja trwa.

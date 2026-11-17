# CK-04e.3j.3b — zamknięte HTTP i Runtime moderacji zdjęć

Wewnętrzny [podgląd i trwała decyzja 3a](OPERATOR_MODERACJI_ZDJEC.md) są połączone z rzeczywistymi funkcjami edge, prywatnej Authority i Runtime. To lokalnie sprawdzona implementacja, nie aktywacja usługi lub nadanie roli na prawdziwym koncie. Domyślna konfiguracja nadal ma GATEWAY_ENABLED=0, AVATAR_REVIEW_ENABLED=0 i AVATAR_REVIEWER_IDS_JSON=[]; nie zmieniono zdalnych bindings, sekretów, planu lub danych.

## Kontrakt

Wszystkie trasy wymagają HTTPS, POST, natywnego żądania bez Origin i zweryfikowanego gateway bearer80. Nie przyjmują cookies, operatorID, roli, downloadURL, CloudKit receipt lub rewizji decyzji z klienta.

| Trasa | Zamknięte JSON body | Sukces |
| --- | --- | --- |
| /v1/moderation/avatar/queue | {} | protocolVersion=1, schemaVersion=1, items do20 |
| /v1/moderation/avatar/inspect | accountID, requestID | JPEG200, dokładny manifest i X-Echoes-Avatar-Review |
| /v1/moderation/avatar/decide | inspectionID, decisionID, verdict=approved/rejected | protocolVersion/schemaVersion, inspectionID, accountID, requestID, decisionID, revision, verdict |

Queue item zawiera tylko accountID/requestID/versionID/generation/reviewRevision. Jedno konto ma najwyżej jedną pozycję. Decyzja jest skorelowana z inspectionID/decisionID/verdict wejścia, a właściciel/wersja/oczekiwana rewizja wynikają z trwałego potwierdzenia. Niższy prepareReview nie dostał publicznej trasy. /v1/community/avatar/review nadal nie istnieje.

Wejście ma do512B, JSON UTF8, Content-Length zgodny z rzeczywistym rozmiarem, bez kompresji, najwyżej128 niepustych chunks i deadline body3s. Nagłówki wyjściowego manifestu/potwierdzenia i owner-upload intent nie mogą być użyte jako nagłówki wejścia. Nieznane pola, źle sformatowany token i niezgodne media są odrzucane przed czytaniem body, gdy można je ustalić z nagłówków.

Sukces JSON ma zamknięte klucze: kolejka do8192B, decyzja do2048B. Podgląd nie ma trybu204/offline: tylko image/JPEG do256000B/512px. Potwierdzenie do1024 ASCII, dokładne pola i ID, generacja oraz termin w przyszłości najwyżej90s. Authority koreluje owner/request z wejściem. Edge nie czyta body klienta przed autoryzacją w Authority; sprawdza kształt potwierdzenia i manifest, a natywny klient również będzie musiał porównać je ze swoim konkretnym wyborem. Obie granice buforują ograniczoną kopię JPEG i sprawdzają długość/SHA przed oddaniem danych. Chronione kopie mają private/no-store i nosniff, bez Set-Cookie lub nagłówków dostawcy.

Błędy mają wyłącznie protocolVersion/error. AVATAR_REVIEW_INPUT400, SCOPE403, STALE/PENDING409, RATE/CAPACITY429 oraz RESPONSE/UNAVAILABLE503. Wspólne błędy gateway zachowują swoje jawne statusy, m.in. INVALID_SESSION401, BODY_TOO_LARGE413 i UNSUPPORTED_MEDIA_TYPE415. Edge wymaga zgodnej pary code/status, zamkniętych kluczy i ograniczonego JSON; nie przekazuje nieznanego kodu, prywatnych pól lub nagłówków. Retry-After jest ograniczony, Allow=POST występuje tylko przy405.

## Rola, konfiguracja i limity

Rola moderatora jest ustawieniem bramki, nie rolą Apple Developer lub tożsamością serwisową CloudKit. Wymagana osobna tożsamość serwisowa CloudKit nadal pozostaje do przygotowania i rzeczywistego odbioru.

AVATAR_REVIEWER_IDS_JSON jest serwerową listą najwyżej16 unikalnych UUID kont gateway, do2048 znaków; nie e-mailami lub Apple subject. Lista jest kanonicznie sortowana. Włączenie przeglądu wymaga niepustej listy, COMMUNITY/PUBLIC_RECORDS/ACCOUNT_DELETION oraz dokładnych hostów pobierania. Nie wymaga włączenia uploadu, peer read lub fabryki kodeka, bo moderator musi móc obsłużyć istniejące treści po zatrzymaniu intake. Błędna konfiguracja nie przechodzi walidacji aktywacji.

Runtime wiąże instancję z konkretnymi hostami i listą operatorów. Sprawdza aktualną konfigurację po await i przed odpowiedzią; zmiana listy/hostów lub wyłączenie odcina wynik starej instancji. Dla każdego żądania sesja ustala accountID, a serwerowy predykat sprawdza listę i aktywność konta. Promise zamiast synchronicznego wyniku roli/identity/flag jest odmową, nie truthy zgodą. Role i konto są sprawdzane ponownie po limicie trwałym, odczycie body, harmonogramie, checkpoint i zakończeniu koordynatora. Zwykła sesja lub zawieszony moderator nie mogą czytać kolejki lub podglądu.

Edge używa wyłącznie platformowego CF-Connecting-IP z prawidłowym request.cf. Identyfikator budżetu jest HMAC ze stałego kontekstu serwera, nie JSON lub X-Forwarded-For. Trafia do jednej prywatnej Authority. Klient nie wybiera DO, operatora lub namespace; fałszywe nagłówki uprawnień/budżetu nie są przekazywane.

Authority rezerwuje jedno niezakończone żądanie moderacji. Globalne/IP limity heavy z GatewayLimits są przed nagłówkami/body; per zweryfikowany moderator30 żądań/min i10 inspect/min są przed body/checkpoint/dostawcą. Wewnętrzna rezerwacja3a również limituje10 nowych podglądów/min, w tym błędnych. Te ograniczenia nie znoszą wspólnych budżetów gateway (m.in.12 heavy/min na IP i300 heavy/dzień całego kontrolowanego targetu), więc praktyczna przepustowość może być niższa. To ograniczony target testowy, nie dowód wystarczającej skali produkcyjnej.

Authority ma 12s całego żądania, wewnętrzny podgląd8s, edge15s. Jedno admission na handler/izolat edge pozostaje zajęte po cancel/timeout do rzeczywistego powrotu ignorującej zależności. Nie ma automatycznych ponowień lub pętli poll. Ciało wejściowe i nieprzekazane odpowiedzi są anulowane, bufory aplikacyjne czyszczone; nie jest to gwarancja fizycznego wyzerowania wszystkich kopii RAM lub cofnięcia utrwalonej decyzji.

## Wycofanie i sprzątanie

Po autoryzacji i walidacji wejścia trasa planuje istniejący alarm GatewayMaintenance przed checkpoint/operacją. Potwierdzenia wygasają logicznie po90s i są sprzątane lokalnie także po wyłączeniu przeglądu. Nadal oddzielnie trzeba dokończyć retencję/orphans assetów.

Status/clear właściciela pozostają dostępne przez withdrawalOnly także wtedy, gdy aktywna jest tylko moderacja, a upload i peer read są wyłączone. Nie wymaga to kodeka ani prawa publikacji. Clear unieważnia już otwarty podgląd i późniejszą decyzję moderatora. Lokalny test Runtime/edge sprawdza ten konkretny przypadek.

Nowa decyzja moderacji zmienia rewizję i odcina poprzednie ready. W natywnym etapie trzeba również odebrać ponowne zatwierdzenie dawnej publikacji: po udanej publikacji dawny pending journal autora jest usunięty, a obecny canPublish wymaga takiej operacji. Odtworzenie świadomej publikacji bez nowego JPEG pozostaje jawnie otwartym scenariuszem przed odbiorem; nie wolno zastąpić go automatyczną publikacją.

## Dowody i dalszy odbiór

501/501 na Node22 i Node24, 23 nowe funkcje testów (22 HTTP i jedna domyślnego wyłączenia rzeczywistego entry), plus rozszerzony istniejący test workerd. Syntax112 MJS obu runtime i cztery JSON/config. Pełne wyniki i SHA: [dowody](evidence/avatar-review-http-local-tests.json).

Sprawdzono kontrolę roli przed body, utratę roli/tożsamości po trwałym admission i ostatnim checkpoint, limity IP/konta, ścisłe nagłówki/body, cancel/timeout z ignorującą zależnością, nieznane pola/Promise w finalizerach, binarną korelację owner/request/expiry/variant/SHA, zamknięte error code/status, cofnięcie przy samym review oraz zmianę konfiguracji po odpowiedzi Authority. Dwie negatywne kopie bez roli przed body i bez quota faktycznie oblewają wybrane testy; właściwe SHA pozostają niezmienione.

Prawdziwy lokalny workerd/DO/SQLite/Wasm wykonał upload, queue, inspect, odmowę decyzji bez potwierdzenia, approved i dokładny replay, status autora nadal bez publikacji, potem clear/status. Są to konkretne funkcje edge/Authority/Runtime z rzeczywistymi Request/Response i lokalnym SQL. Binding prywatnej Authority, request.cf, Apple, konta i pliki dostawcy są modelami; nie jest to zdalny Cloudflare/CloudKit ani pomiar Free CPU/RSS/cold-start/subrequests/transferu. Podpisy S2S są niezależnie sprawdzane na efemerycznych kluczach testowych. Oddzielnie rzeczywisty community entry odmawia nowych tras bez aktywacji/sekretów.

Pierwsze7 HTTP i wcześniejsze51 odczytu/uploadu przeszły od razu; rozszerzone22 też. Pierwszy workerd wykrył brak alarm() w testowej klasie DO, wymagany przez nowe schedule. Dodano rzeczywisty lokalny handler cleanup i świeżą syntetyczną sesję zgodną z zegarem platformy, by alarm nie był planowany w przeszłości. Dwie lokalne diagnostyki na syntetycznych danych przywróciły pliki i sprawdziły SHA; stos błędu nie jest częścią końcowego API. Końcowe dwa workerd i pełne501 obu Node przechodzą bez rozluźniania zabezpieczeń produkcyjnych.

Następny3c: natywny transport/host/ekran operatora, poprawny decode i rzeczywisty podgląd przed udostępnieniem przycisków, świadome decyzje i ten sam ID przy niepewnym wyniku, expiry/foreground/konto oraz scenariusz autora po ponownym zatwierdzeniu. Dalej: prawdziwe uprawnienia/schema/hosty/SIWA/odrębna tożsamość serwisowa/hosted Free/dwa zwykłe konta, import i FileProtection/locked-device, ostrzeżenia SwiftUI, zgłoszenia/kontakt/retencja i reszta migracji. Zwykłe wejście nadal Firebase, pełny cel aktywny. W tym podetapie nie zmieniono Swift/Core/UI/projektu/lockfile/deps/CI, nie ponawiano niezmienionych buildów/audytu lub wygasłych testów SDK, nie aktywowano zdalnych usług/sekretów/opłat/Production/Firebase/TestFlight. Zastany project.pbxproj zachowany.

## Natywny kontrakt3c.1

Postęp CK-04e.3j.3c.1 (17 listopada 2026): natywny zamknięty queue/inspect/decide i osobny ephemeral URLSession, domyślnie wyłączone. Korelacja całego wyboru, SHA/JPEG i ImageIO poza UI aktorem; receipt związany z origin/bearer, absolutny i monotoniczny limit90s od rozpoczęcia pobierania. Jeden request, brak cookies/cache/redirect lub retry/nowego ID, JSON8192/2048B i JPEG256000B; scope403 nie wylogowuje. 26 nowych testów (18 kontraktu+8 URLSession), pełne442 zdefiniowane/440 zaliczonych+2 sprzętowe skipy na Macu/iOS, Debug/Release/strict format5. Siedem odpowiedzi konkretnego lokalnego edge/Authority/Runtime/SQL/Wasm z modelami Apple/kont przechodzi Swift; kontrola negatywna bez reviewRevision oblewa1 test/1 asercję. Brak nowych aktywacji/uprawnień/usług/opłat/SDK/Production/Firebase/TestFlight. Host, trwały zapis decyzji i ekran pozostają do wdrożenia; kolejny3c.2, następnie świadome ponowne opublikowanie autora bez journala. Ostrzeżenia istniejących preview/edytora MainActor/Sendable i runtime ramek SwiftUI pozostają do naprawy/odbioru przed TestFlight. [Kontrakt i granice](NATYWNA_MODERACJA_HTTP.md), [dowody](evidence/avatar-review-native-local-tests.json).

## Odczyt wyniku3c.2a

Dodano osobny odczyt recover: stan bieżącej dokładnej decyzji można sprawdzić po expiry receipt i nowej sesji tego samego uprawnionego konta. Nie odnawia to podglądu i nie wykonuje decyzji. superseded nie jest potwierdzeniem historycznego sukcesu lub porażki. Trwały host/UI nadal kolejne; pełna semantyka i dowody: [odzyskiwanie](ODZYSKIWANIE_DECYZJI_MODERACJI.md).

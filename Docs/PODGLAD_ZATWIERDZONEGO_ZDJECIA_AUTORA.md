# CK-04e.3j.3c.4c.1 — chroniony podgląd zatwierdzonego zdjęcia autora

Aktualizacja CK-05c.4c: wspólne pobieranie zdjęć oczekuje teraz na zakończenie pierwszego cancel oraz rzeczywistej pracy klienta CloudKit, również dla późnego fetch. Niepotwierdzone sprzątanie zamyka dany scope; pełny kontrakt i granice w [odpływie IO zdjęć](ODPLYW_IO_ZDJEC_PROFILOWYCH.md).

Serwer ma osobny odczyt pełnego, zatwierdzonego pliku na potrzeby świadomej publikacji po utracie dawnego upload journala. Działa także przy ready=0, bez publicznego wskaźnika zdjęcia. Odczyt nie publikuje pliku, nie wyraża zgody autora i nie zmienia decyzji moderacji.

## Zamknięty kontrakt

`POST /v1/community/avatar/preview` przyjmuje JSON do 512 B, dokładnie: requestID, versionID, generation i reviewRevision. Wymaga natywnego bearer. Konto pochodzi wyłącznie z bieżącej sesji; ownerID/accountID, GPS, URL, hash cache, wariant, receipt oraz consentVersion są zabronione. Przyznaje dostęp tylko do własnego bieżącego zatwierdzonego wyboru. Nie wymaga roli moderatora ani obecności w promieniu 3 km. Inne konto nie może odczytać pliku przez podanie identyfikatorów autora.

Sukces to wyłącznie 200 z kompletnym JPEG do 256000 B / 512 px, `Cache-Control: private, no-store`, `X-Content-Type-Options: nosniff`, dokładną Content-Length i istniejącym zamkniętym X-Echoes-Avatar-Manifest dla wariantu image. Nowy X-Echoes-Avatar-Selection zawiera dokładnie schemaVersion=1 oraz te same cztery pola wyboru. Nie ma 204, ścieżki offline, URL dostawcy, cookies ani publicznego cache. Obie granice sprawdzają korelację wyboru/manifestu; Authority dodatkowo sprawdza konto z sesji. Edge przesyła wyłącznie wybrane nagłówki i przejmuje ograniczone ciało, zanim zamknie sygnał żądania.

Selection jest korelacją odpowiedzi z żądaniem, nie tokenem uprawnienia, receipt moderatora ani dowodem obejrzenia zdjęcia przez człowieka. Kolejny etap iOS musi sprawdzić tę korelację, faktycznie wyświetlić aktualny obraz, ograniczyć jego czas/lifecycle/scope i uzyskać osobne potwierdzenie autora. Sam ten endpoint nie otwiera publikacji w interfejsie.

## Autoryzacja, integralność i wyścigi

Polityka używa istniejących barier bieżącej intencji, generacji i zatwierdzenia oraz settled registry, staged record tag i descriptor hash. Porównuje pełny wybór; nowa ocena nie zastępuje starej rewizji w żądaniu. Pending/rejected, clear, inny request/version/generation/revision lub wycofane konto odmawiają odczytu.

Czytnik ponownie sprawdza sesję/konto, aktywację, wybór, zatwierdzenie i oba commitments po await, podczas pobierania oraz w jednorazowym finalizerze. HTTP wykonuje jeszcze synchroniczny recheck po przejęciu pełnego JPEG. Zmiana decyzji podczas tego ostatniego buforowania również odcina wynik. Po wydaniu odpowiedzi nie istnieje możliwość zdalnego wymazania pobranych pikseli — klient nadal musi przestrzegać własnych barier.

Plik pochodzi wyłącznie z dokładnych hostów wdrożenia, pod zweryfikowanym URL HTTPS. Żądanie dostawcy pomija credentials, ma ręczne redirect i tylko Accept/Cache-Control. Wspólny ograniczony downloader sprawdza status, encoding, długość i strumień; czytnik porównuje SHA-256, nagłówek JPEG i wymiary z zatwierdzonym manifestem. Nie loguje pliku, URL lub bearer. Bufory robocze są czyszczone; nie jest to obietnica fizycznego wymazania wszystkich kopii RAM/platformy.

## Limity i aktywacja

Osobna `AVATAR_OWNER_PREVIEW_ENABLED` domyślnie wynosi 0; wrangler.community.jsonc zachowuje 0. Włączenie wymaga poprawnych zależności Development/community/public records/account deletion oraz dokładnej niepustej listy hostów pobierania. Zmiana flagi/hostów lub wygaśnięcie konfiguracji w trakcie pracy odcina odpowiedź. Upload, zwykły odczyt i moderator mogą pozostać wyłączone. Status/clear nadal działają także przy samym włączonym podglądzie, aby zachować możliwość wycofania.

Authority przed czytaniem body/checkpoint/provider zużywa istniejący globalny/IP heavy budget oraz trwały wspólny account/image budget (12 odczytów/min, w tym 4 pełne obrazy/min). Podgląd nie dostaje dodatkowych czterech obrazów poza zwykłym odczytem. Edge najpierw sprawdza i ogranicza własne wejście do 512 B; wadliwe wejście odrzucone na edge nie dociera do licznika Authority. Nie jest to gwarancja ochrony całego konta Cloudflare przed dowolnym ruchem lub kosztami spoza tego przepływu.

Body ma 3 s i do 128 niepustych chunks; czytnik 8 s, Authority 12 s, edge 15 s. Każdy z trzech poziomów zachowuje jeden zajęty slot, także po timeout/cancel do faktycznego końca ignorującej zależności. Nie uruchamia pętli retry. Błędy edge są zamkniętym JSON do 2048 B, z poprawnym związkiem code/status i bez prywatnych nagłówków.

## Dowody i pozostała praca

[Raport testów](evidence/avatar-owner-preview-local-tests.json) zawiera końcowe wyniki i SHA. Dziewiętnaście nowych funkcji testowych obejmuje własny approved/ready=0, odmowę innemu kontu, pełny wybór i zamknięte wejście, flagi, media/bearer, współdzielony trwały limit, wyścigi decyzji/clear/sesji/flag, ostatni recheck po buforowaniu, uszkodzony plik/URL, korelację odpowiedzi, retained admission czytnika/Authority/edge, pending/rejected, clock rollback, commitments, wadliwe strumienie i ścisłe błędy.

Dodatkowy test uruchamia rzeczywisty lokalny workerd/SQLite/Wasm/S2S signatures z modelami Apple i kont. Po zatwierdzeniu wyłącza upload i moderatora, pobiera własny pełny JPEG przez edge → Authority → Runtime, weryfikuje wybór/SHA i potwierdza brak publikacji oraz działające clear. Wspólne konto tego scenariusza jest tożsamością syntetyczną; test nie zastępuje dwóch rzeczywistych zwykłych kont. W odizolowanej kopii usunięcie końcowej bariery zatwierdzenia powoduje oczekiwaną porażkę testu wyścigu, przy zachowanych SHA oryginałów.

Ten etap obejmuje serwer. Następny CK-04e.3j.3c.4c.2: natywne API/transport i efemeryczny podgląd dokładnego zatwierdzonego wyboru, a następnie integracja rzeczywiście wyświetlonego obrazu i osobnego potwierdzenia w edytorze. Publikacja bez upload journala nadal jest zamknięta w UI. Kod iOS/Core, zależności i CI pozostały niezmienione; nie powtarzano ich wcześniejszych testów. Nie wykonano zdalnego wdrożenia, aktywacji, zmian schematu/ról/sekretów/usług/opłat, SDK telefonu, Production, Firebase ani TestFlight.

Kontynuacja CK-04e.3j.3c.4c.2 dodała [natywny klient/transport oraz efemeryczny zweryfikowany wynik](NATYWNY_PODGLAD_ZDJECIA_AUTORA.md). Nadal wymagany jest host/aktualny obraz, faktyczne wyświetlenie i osobna zgoda w edytorze; blokada publikacji bez upload journala w UI pozostaje aktywna.

Nadal wymagane są m.in. realne role/schemat/hosty/SIWA/service identity/hosted Free, dwa zwykłe konta, fizyczny Keychain/FileProtection/locked-device i PhotosPicker/iCloud Photos, zgłoszenia/kontakt/retencja oraz pozostała migracja. Wcześniejsze ostrzeżenia ramek UI pozostają otwarte; zwykłe wejście nadal używa Firebase. To nie jest odbiór gotowości TestFlight.

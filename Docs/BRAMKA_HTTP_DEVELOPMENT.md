# Bramka HTTP Development — CK-02i

Stan: 14 listopada 2026. Połączono lokalnie rzeczywistą implementację verifiera/OAuth, sesji, odnowienia, zlecenia usuwania, limitów i harmonogramu. **Nie wdrożono nowej usługi ani namespace, nie utworzono sekretów i nie podłączono iOS.** Zwykła aplikacja nadal używa Firebase. Nowy target nie obsługuje jeszcze mapy/czatu/profili i nie jest gotową wersją TestFlight.

## Kontrakt dla klienta iOS

Ścieżki są zamknięte, bez query string, arbitralnego URL, typu rekordu, nazw metod lub ról. Wszystkie poza health używają POST, JSON UTF-8 i HTTPS. Każda odpowiedź JSON ma protocolVersion=1; logout zwraca puste 204. Cache-Control: no-store, bez cookies i CORS. Błędy mają stały kod, a nie treść wyjątku lub odpowiedź Apple.

| Ścieżka | JSON body | Uwierzytelnienie / wynik |
| --- | --- | --- |
| GET /health | brak | Tylko status procesu; nie potwierdza Apple, CloudKit ani gotowości wydania. |
| /v1/auth/challenge | purpose: login albo account_deletion | Zaufany budżet wyznacza edge; wynik challengeID, nonce, expiresAt. Telefon przekazuje Apple SHA-256 nonce. |
| /v1/auth/login | challengeID, identityToken, authorizationCode | Świeży dowód Apple; wynik accountID, sessionToken/expiresAt, renewalToken/renewalExpiresAt. |
| /v1/auth/renew | {} | Authorization: Bearer renewalToken; atomowa rotacja obu tokenów. |
| /v1/auth/session | {} | Bearer sessionToken; własne accountID/expiresAt. |
| /v1/auth/logout | {} | Bearer renewalToken; idempotentne usunięcie tej sesji, także po wygaśnięciu krótkiego dostępu. |
| /v1/auth/logout-all | {} | Bearer sessionToken; generacja unieważnia także odnowienia innych urządzeń. |
| /v1/account/deletion | deletionID, challengeID, identityToken, opcjonalne expectedAccountID | Bearer statusToken. Świeże, osobne wyzwanie usuwania; 202 ze statusem. Retry istniejącego zadania może wysłać samo deletionID. |
| /v1/account/deletion/status | deletionID | Bearer statusToken; wyłącznie stan własnego zadania. |
| /v1/account/deletion/private-cleanup | deletionID | Bearer statusToken; zgłoszenie urządzenia, bez deklaracji serwerowego dowodu skasowania private CloudKit. |

Limity body: 16 KiB dla login/renew/zlecenia usunięcia, 256 bajtów dla pozostałych tras, odczyt do 3 s. Nieznane pola są odrzucane. Tokeny pozostają nieprzezroczystymi sekretami klienta; nie należy odtwarzać ich formatu w UI. StatusToken/renewalToken nie dają zwykłego dostępu do profilu. Żaden sekret nie należy do URL lub logów.

Istotne statusy: 400 nieprawidłowe wejście, 401 nieważna sesja/tożsamość lub ponowna autoryzacja, 403 blokada/usuwanie, 409 zajęte odnowienie albo limit sesji, 429 limit żądań, 503 niedostępna konfiguracja/usługa/pojemność. Retry-After dotyczy oczekiwania, nie upoważnia do powtarzania nieznanego wyniku jednorazowego kodu lub rotacji. Klient nadal wymaga single-flight, atomowego Keychain i własnej obsługi zmiany konta.

## Granica zaufania i routing

`forwardGatewayRequest` odczytuje CF-Connecting-IP tylko z wejścia platformy Cloudflare z obecnym kontekstem request.cf. Nie używa X-Forwarded-For, JSON ani nagłówka X-Echoes przesłanego przez klienta. IP jest kanonizowany (IPv4 /32, IPv6 /64, IPv4-mapped jako IPv4), a następnie zamieniany w HMAC ze zmianą przestrzeni dnia UTC. Do SQLite trafia skrót, bez adresu IP.

Połączenia zza NAT współdzielą limit; ten identyfikator nie jest osobą ani urządzeniem. Stałe okna pozwalają na serie na granicach. Zaufanie do CF-Connecting-IP dotyczy tego wdrożenia: inne Workery tego samego operatora/strefy muszą być zaufane, ponieważ same-zone subrequest może zmieniać x-real-ip. Nie przenosić tej reguły do dowolnego reverse proxy. [Nagłówki Cloudflare](https://developers.cloudflare.com/fundamentals/reference/http-headers/).

Edge kopiuje tylko potrzebne nagłówki i sam dodaje budżet. Wszystkie konta trafiają do jednego prywatnego CommunityAuthority o stałej nazwie. Odrzucany jest inny objectID/host/brak budżetu; nie można rozdzielić konta lub limitów na obiekty wybierane przez JSON. Nie ma publicznego RPC operatora. Ten singleton upraszcza spójność w prototypie; jego pojemność i opóźnienia wymagają pomiaru, a skalowanie nie polega na losowym shardowaniu wyzwań.

## Składanie komponentów i aktywacja

`createGatewayRuntime` tworzy prawdziwe klasy AppleOAuthClient, verifier/JWKS, AuthenticationState, vault i RenewalProofs oraz koordynatory. Nie ma domyślnego sukcesu exchange lub erasure. Klucze vault, renewal i budżetu muszą mieć różny materiał. Opcjonalny fetch transport jest zaufaną zależnością testów/serwera, nigdy opcją HTTP; zachowuje też sygnał timeout źródła JWKS.

Nowy plik `gateway/wrangler.community.jsonc` proponuje osobny target echoes-community-development i klasę SQLite CommunityAuthority. Domyślnie GATEWAY_ENABLED=0, ACCOUNT_DELETION_ENABLED=0, brak URL preview/workers.dev i logowania. Nie jest dowodem istnienia takiej usługi. Aktywacja jest ograniczona do jawnego Development/kontenera i ścisłego terminu UTC do 7 dni. Termin/wyłączenie zatrzymuje nowe operacje oraz nowe wywołania Apple; rozpoczęte operacje mogą kończyć się w swoich timeoutach. To konfiguracja kontrolowanej próby, nie polityka stałej dostępności produkcyjnej.

Włączenie ACCOUNT_DELETION_ENABLED bez prawdziwego adaptera kasowania blokuje inicjalizację. Obecny entry point nie podłącza takiego adaptera, więc usuwania nie da się włączyć samą flagą. Auth-only nadaje się do osobno zatwierdzonej próby deweloperskiej właściciela, **nie do wydania kont społecznościowych bez działającego usuwania**.

Przed aktywacją potrzebne są osobne sekrety (nazwy, bez wartości w repo):

| Nazwa | Znaczenie |
| --- | --- |
| APPLE_SIGNIN_PRIVATE_KEY / APPLE_SIGNIN_KEY_ID | Dedykowany klucz Sign in with Apple dla App ID; nie klucz S2S CloudKit. Nie tworzono go w tym etapie. |
| REFRESH_KEYS_JSON / REFRESH_ACTIVE_KEY_ID | Wersjonowane klucze AES-256-GCM vault. |
| RENEWAL_KEYS_JSON / RENEWAL_ACTIVE_KEY_ID | Osobne wersjonowane klucze integralności renewal. |
| REQUEST_BUDGET_KEY | Oddzielny HMAC budżetu sieciowego. |

Klucz Sign in with Apple nie jest oznaczany przez ten kod jako „Development-only” w Apple. To usługa/konfiguracja jest Development; przyszła zgoda na przekazanie klucza musi uwzględniać rzeczywiste prawa walidacji/odwołania dla App ID. Nowe zasoby, uprawnienia i transfer sekretów nadal wymagają konkretnego przygotowanego zakresu. Dotychczasowy Worker diagnostyczny pozostaje oddzielny i nie zmienił kodu.

## Limity i alarm

Własny prototyp dopuszcza 2000 wejść do authority/dobę UTC, w tym 300 operacji login/renew/zlecenia usunięcia. Na skrót sieci: 120/min ogółem, 12/min cięższych tras. Nadal obowiązuje limit 5 wyzwań/stałe 5 min z magazynu auth. Są to parametry kontrolowanej próby, nie deklaracja pojemności wydania. Liczniki są trwałe i atomowe; sync kończy się przed dalszą operacją. Dzienny licznik ogranicza też wzrost tabel okien; usuwanie wygasłych wpisów jest indeksowane i nie robi COUNT całej tabeli na każde nowe IP.

Limity aplikacji **nie rezerwują** limitów konta Cloudflare i nie zatrzymują naliczania wszystkich odrzuconych wywołań platformy. Inne usługi dzielą budżet, a SQL/delete/setAlarm także zużywają zasoby. Free odmawia dalszych operacji po wyczerpaniu; kod nie przełącza na Paid. Osobno trzeba zmierzyć liczbę wierszy/czas/ruch — sama liczba 2000 nie jest gwarancją zmieszczenia SQL lub odporności na DoS.

Zwykły Workers Free ma 10 ms CPU; dokumentacja DO opisuje domyślnie 30 s CPU, dlatego cięższa logika jest w authority. Free SQLite ma dodatkowo limit 1 GB na obiekt i 5 GB na konto. Cennik podaje 100 tys. zapisanych wierszy na dobę, wliczając delete i setAlarm. [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [DO limits](https://developers.cloudflare.com/durable-objects/platform/limits/), [DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/). To aktualne podstawy projektu, nie wynik pomiaru naszego kodu.

Alarm jest planowany przed przyjęciem mutacji. Każde wywołanie zapisuje następny termin na początku, wykonuje ograniczone lokalne sprzątanie i najwyżej jeden krok usuwania. Trwały kursor obraca zadania, więc oczekiwanie jednego właściciela nie zatrzymuje wszystkich ani nie ogranicza kolejki do pierwszych 10. Osobne kwalifikowanie do 100 zadań po terminie odwołania usuwa sekrety niezależnie od tego kursora. Po wyłączeniu lub usunięciu kluczy można nadal wykonywać lokalne cleanup/reconciliation, bez połączenia z Apple. Alarm kończy się, gdy brak danych czasowych/receipts i wykonywalnych zadań; nie budzi bez końca pustego obiektu. Gdy pozostało tylko oczekiwanie na urządzenie lub niedostępnego dostawcę bez lokalnych terminów, kolejne żądanie albo bootstrap konfiguracji ponownie planuje pracę. Sam health nie budzi authority. [Semantyka alarmów, w tym at-least-once](https://developers.cloudflare.com/durable-objects/api/alarms/).

## Weryfikacja i następny odbiór

**163/163 testów Node 22.23.5**, w tym 24 nowe: 13 HTTP/runtime i 11 limitów/alarmu. Testy wykorzystują realne koordynatory/verifier/SQLite i jawnie podstawiony transport Apple, platformę edge oraz API alarmu. Obejmują cały protokół do odnowienia/logout/usuwania, odrzucanie wejść, podmienione nagłówki, spójny objectID, expiry/klucze, limity/reopen, równe wybieranie zadań i sprzątanie bez sekretów. [Raport](evidence/gateway-http-local-tests.json).

To nie jest próba workerd/Cloudflare: import cloudflare:workers, prawdziwy request.cf, uruchamianie alarmów i CPU/wiersze wymagają osobnego testu Development. Nie wykonano prawdziwego logowania/revoke, kasowania CloudKit ani zmian iOS. Dalej: natywny klient i Keychain, rzeczywisty adapter danych, konfiguracja Sign in with Apple i kontrolowany test po osobnej zgodzie, role/A-B oraz pomiar obciążenia. Mapa/czat/moderacja i pełne odłączenie Firebase pozostają w planie.

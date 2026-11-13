# Prototyp diagnostyczny Workers — CK-01g

Stan: 13 listopada 2026. Kod diagnostyki i SQLite wdrożono w Workers Free. HTTP i zabezpieczenia wejścia przeszły, ale pierwszy test CloudKit z hostingu nie przeszedł przez nieobsługiwany redirect:error. Poprawkę manual sprawdzono w 27 testach lokalnych; pełny odbiór S2S/CPU nadal oczekuje. Próba jest wyłączona i nie ma sekretów w aktywnej konfiguracji. To techniczna próba jednego syntetycznego rekordu, a nie logowanie ani backend użytkowników Echoes.

## Zakres

- `GET /health`: zwraca status procesu i tryb development-diagnostic. Nie sprawdza CloudKit, konta Apple ani gotowości migracji.
- `POST /probe`: wymaga sekretu Bearer, aktywacji ograniczonej czasowo i dokładnego pustego obiektu `{}`. Klient nie wybiera rekordu, zapytania, celu sieciowego ani konta.
- Pozostałe ścieżki/query/method są odrzucane. Odpowiedzi mają no-store; brak CORS udostępniającego dane innym stronom.
- Jedna aktywacja ma jeden PROBE_RUN_ID. Durable Object SQLite rezerwuje przebieg przed żądaniem CloudKit i zachowuje UUID oraz nonce do ewentualnego uzgodnienia po awarii. Ten magazyn zawiera wyłącznie diagnostykę, nie zastępuje bazy aplikacji.
- S2S nadal używa wyłącznie iCloud.mpvEcho.Echo/development/public i EchoesGatewayProbeV1. Pola testowe oraz ograniczona rola są opisane w [raporcie CloudKit](CLOUDKIT_WERYFIKACJA.md).

## Konfiguracja domyślna

`gateway/wrangler.jsonc` ma PROBE_ENABLED=0, puste RUN_ID/termin, workers_dev=false i preview_urls=false. Nie zawiera klucza, tokenu, account ID ani skryptu uruchamiającego deploy. Włączenie ścieżki wymaga kompletnej konfiguracji po osobnym uzgodnieniu testu.

Wymagane wartości przy kontrolowanej aktywacji:

| Pole | Znaczenie |
| --- | --- |
| CLOUDKIT_CONTAINER | Tylko iCloud.mpvEcho.Echo. |
| CLOUDKIT_ENVIRONMENT | Tylko development. |
| CLOUDKIT_KEY_ID | Identyfikator zatwierdzonego klucza Development. |
| CLOUDKIT_PRIVATE_KEY | Sekret usługi, PKCS#8 P-256. Przekazany po zgodzie w CK-01j, następnie usunięty z aktywnej konfiguracji. |
| PROBE_BEARER_TOKEN | Osobny losowy sekret: 32 bajty, base64url bez paddingu (43 znaki). Token techniczny, nie sesja użytkownika. |
| PROBE_RUN_ID | Nowy UUID operatora dla jednego zatwierdzonego przebiegu. |
| PROBE_EXPIRES_AT | Termin ISO8601, najwyżej 2 godziny od bieżącej chwili. Po terminie odmowa. |
| DEVELOPMENT_PROBE | Binding klasy DevelopmentProbe z nową klasą SQLite w migracji v1. Bez KV-backed DO wymagającego planu Paid. |

Nie umieszczać rzeczywistych sekretów w vars, repozytorium, logach, komendach powłoki ani czacie. Sam wcześniejszy klucz Apple i potwierdzenie Free nie oznaczają zgody na przekazanie go nowemu odbiorcy — Cloudflare.

## Pojedyncze wykonanie i awarie

Rezerwacja ma unikalny klucz w SQLite. Równoległe żądanie otrzymuje 202 running-or-unknown zamiast drugiego zapisu. Zakończony przebieg zwraca zapisany raport (200 albo 502); także nieudana próba nie uruchamia kolejnego zapisu. Stan przeżywa odtworzenie instancji.

Przed wywołaniem CloudKit oraz przed odpowiedzią po zapisie raportu Worker wywołuje storage.sync(). Cloudflare dokumentuje też automatyczne output gates zatrzymujące zewnętrzne wiadomości do utrwalenia zapisów. [SQLite storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/), [zasady input/output gates](https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/).

Awaria procesu pomiędzy operacjami sieciowymi może pozostawić rekord testowy. Rezerwacja zachowuje jego UUID i nonce, a system nie ponawia automatycznie nieznanego zapisu. Operator musi uzgodnić taki stan przed kolejną aktywacją. Nie czyścić rezerwacji działającego endpointu — usunięcie rezerwacji mogłoby pozwolić na powtórzenie. Nie obiecujemy transakcji obejmującej równocześnie SQLite i CloudKit.

## Weryfikacja

`node --test gateway/test/*.test.mjs`: **25 testów lokalnych przeszło** na Node 22.23.5. W tym 12 wcześniejszych testów podpisu/próby, 1 trwałego kontekstu bez wycieku nonce, 6 kontroli HTTP i 6 rezerwacji SQLite. Sprawdzono brak wywołania bazy bez tokenu, datę aktywacji, nieprawidłowe wejście, brak dowolnego rekordu/URL, równoległość, ponowienie, odtworzenie z pliku SQLite, znacznik awarii, błąd sprzątania i oczekiwanie na utrwalenie przed operacją zewnętrzną.

Testy używają wbudowanego SQLite Node oraz adaptera interfejsu sql.exec. Nie wykonują fetch do Apple/Cloudflare i nie czytają rzeczywistego klucza. Sprawdzenie składni plików MJS przeszło. Nie uruchomiono jeszcze klasy w workerd/Miniflare ani na hostingu i nie zmierzono 10 ms CPU.

Próba pobrania metadanych Miniflare z registry.npmjs.org zakończyła się ECONNRESET; niezależny curl również zakończył się błędem połączenia TLS. Nie wyłączano kontroli certyfikatów ani nie instalowano pakietów z nieoficjalnego źródła. Zależności runtime modułu pozostają zerowe. Weryfikacja runtime Workers pozostaje przed przekazaniem sekretu i testem sieciowym.

## CK-01h — pusta usługa Cloudflare i zgoda na zdalny kod

W panelu utworzono `echoes-development-probe` na koncie Workers Free. Aktualny plan ponownie odczytano 13 listopada: Free / Current plan / $0. Adres: https://echoes-development-probe.2rnd2bt6rd.workers.dev/ . Jest tam wyłącznie domyślny Hello World dostawcy, bez sekretów i bindings; nie jest to prototyp Echoes ani backend aplikacji. [Zapis stanu](evidence/cloudflare-development-worker-bootstrap.json).

Środowisko w panelu Cloudflare ma domyślną etykietę Production. Nie oznacza to przełączenia kontenera CloudKit: usługa nie ma żadnego połączenia z CloudKit, a przygotowany podpisujący kod dopuszcza tylko Development.

Automatyczna kontrola odrzuciła utworzenie pierwszego pliku cloudkit-request.mjs w zdalnym edytorze jako trwałą zmianę wdrożonej usługi bez jednoznacznej zgody. Plik nie powstał, nie publikowano żadnego kodu Echoes, nie obchodzono blokady. Przygotowano do zatwierdzenia modyfikację/publikację istniejącego Workera, klasę SQLite dla pojedynczej próby, konfigurację/token i ewentualne przekazanie zatwierdzonego klucza Development jako sekretu wyłącznie tej usługi.

To nowy odbiorca klucza: wcześniejsza zgoda dotyczyła pozostawienia go lokalnie. Dopóki nie ma konkretnego potwierdzenia, prywatny klucz pozostaje wyłącznie na Macu. Samo Hello World potwierdza utworzenie usługi, nie akceptację modułów Node, działanie DO, dostęp CloudKit ani pomiar CPU prototypu.

## CK-01j — 2026-11-13 — wdrożenie diagnostyki i poprawka zgodności Workers

Po wyjaśnieniu roli Cloudflare właściciel jednoznacznie zatwierdził kod, SQLite, klucz Development jako sekret oraz jedną próbę. Osobno zatwierdził tymczasowy token wdrożenia ograniczony do tej jednej usługi. W panelu potwierdzono Individual Workers Editor / echoes-development-probe, bez uprawnień do innych usług; ustawiono okno około 2 h. Nie zmieniono planu Workers Free, CloudKit Production ani danych użytkowników.

Kod opublikowano w Dashboard, a klasę DevelopmentProbe utworzono przez oficjalne API z new_sqlite_classes / v1. Pierwszy upload API odrzucił błędną nazwę części multipart (No such module: worker.js); poprawienie filename=worker.js pozwoliło wdrożyć klasę SQLite. Metadane zwróciły startup_time_ms=4 — to czas startu, nie pomiar CPU żądania. Runtime HTTP potwierdził 200 /health, 503 dla wyłączonej próby, 405 dla metody i 404 dla obcej trasy. Po aktywacji bez klucza Apple potwierdzono 401 bez tokenu, 400 dla obcego wejścia i 503 diagnostic-disabled z Durable Object. Żaden z tych preflightów nie wykonuje operacji CloudKit. [Raport wyłączonego HTTP](evidence/workers-disabled-http.json), [preflight runtime](evidence/workers-runtime-preflight.json).

Następnie przesłano klucz wyłącznie do sekretu CLOUDKIT_PRIVATE_KEY tej usługi i wykonano jeden POST /probe. Wynik: HTTP 502, TRANSPORT_FAILED przy create i cleanup. Trwała rezerwacja zachowała RUN_ID i kontekst; nie skasowano jej ani nie ponowiono zapisu pod nowym UUID. [Raport próby](evidence/workers-cloudkit-probe-failed.json). Lokalny podpisany lookup tego dokładnego UUID zwrócił NOT_FOUND: rekord nie pozostał w Development. [Potwierdzenie nieobecności](evidence/workers-cloudkit-probe-absence.json). To nie jest sukces testu Cloudflare → CloudKit.

Przyczyna: użyty redirect:error jest zgodny z Node, ale Workers rzuca TypeError przy konstruowaniu Request, zanim wyśle żądanie. Poprawka ustawia manual; istniejący odczyt odpowiedzi odrzuca 3xx bez podążania za Location. [Oficjalna dokumentacja Request](https://developers.cloudflare.com/workers/runtime-apis/request/). Dodano regresję z dwoma rzeczywistymi serwerami loopback: cel przekierowania nie otrzymuje żadnego żądania ani podpisanych nagłówków, create nie jest ponawiane.

Dodano też bramkowany tym samym tokenem, UUID i terminem PROBE_LOCAL_CHECK_ONLY: samo skonstruowanie podpisanego żądania wewnątrz DO, bez fetch, SQLite i eksportu podpisu/klucza/treści wyjątku. To pomoc do odbioru runtime przed następnym zapisem. Pierwsze wdrożenie tego trybu po wznowieniu pracy odrzuciło 401, ponieważ poprzedni token zdążył wygasnąć; nie przedłużano go automatycznie.

Poprzednia aktywacja wygasła. Po wznowieniu pracy ustawiono także jawne PROBE_ENABLED=0 i usunięto CLOUDKIT_PRIVATE_KEY oraz PROBE_BEARER_TOKEN z aktywnej wersji. Wygasły token API usunięto w panelu, a lokalne tymczasowe kopie sekretów usunięto z /private/tmp. Oryginalny klucz Apple pozostaje w chronionym Application Support. Usunięcie bindingów aktywnej wersji nie jest deklaracją wyczyszczenia historii wersji dostawcy ani unieważnienia S2S w Apple; tego klucza Apple nie odwołano. Rezerwacja SQLite pozostaje jako dowód wykonania, nie jest czyszczona do ponowienia.

Weryfikacja poprawki: 27 testów Node 22 przeszło, składnia wygenerowanego pliku poprawna. Test loopback początkowo zablokował sandbox (listen EPERM), a po dopuszczeniu lokalnych portów przeszedł cały zestaw. Nie instalowano zależności i nie wyłączano TLS. Npm pozostaje niedostępny z tej sieci; wdrożenie używało panelu/oficjalnego API. Pełny test S2S po poprawce, pomiar CPU i A/B nadal wymagają odbioru; nie zmieniono aplikacji iOS ani adaptera Firebase.

Poprawiony pakiet opublikowano przez Dashboard jako aktywną wersję `476028fa`, przy PROBE_ENABLED=0 i bez obydwu sekretów. Publikacja kodu nie jest dowodem ukończenia próby S2S po poprawce.

# Prototyp diagnostyczny Workers — CK-01g

Stan: 13 listopada 2026. Kod jest przygotowany i sprawdzony lokalnie. Nie został wdrożony do Cloudflare, nie przekazano klucza i nie uruchomiono opłat. To techniczna próba jednego syntetycznego rekordu, a nie logowanie ani backend użytkowników Echoes.

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
| CLOUDKIT_PRIVATE_KEY | Sekret usługi, PKCS#8 P-256. Jeszcze nieprzekazany hostingowi. |
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

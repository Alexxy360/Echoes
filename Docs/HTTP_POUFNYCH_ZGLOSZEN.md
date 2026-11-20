# HTTP i Runtime poufnych zgłoszeń — CK-05c.3

Aktualizacja CK-05d.2c.1: dodatkowe POST `/v1/moderation/reports/retire` ma te same cztery pola co recover i te same role/limity/deadline. Tylko retired/confirmed/superseded są terminalnym wynikiem retire; recover dodatkowo odczytuje retired, zachowując readonly. `not-applied` nie daje obietnicy niewykonania. [Aktualny kontrakt](ZAMYKANIE_NIEPEWNYCH_DECYZJI_MODERATORA.md); liczby poprzedniego etapu poniżej są historyczne.

19 listopada 2026. **Trasy są podłączone do lokalnego kodu edge/Authority/Runtime i sprawdzone w rzeczywistym lokalnym workerd.** Konfiguracja wdrożeniowa ma REPORT_REVIEW_ENABLED=0 i REPORT_REVIEWER_IDS_JSON=[]; żadnej roli moderatora ani usługi nie aktywowano. Późniejszy [CK-05c.3a](ODPLYW_IO_KLIENTA_CLOUDKIT.md) domyka błędy anulowania wspólnego klienta CloudKit. [Wyniki HTTP](evidence/report-review-http-local-tests.json), [decyzje i recovery](DECYZJE_ZGLOSZEN_I_ODZYSKIWANIE.md).

## Kontrakt

Wspólny prefiks `/v1/moderation/reports/`. Wyłącznie HTTPS POST, JSON, natywny Bearer sesji gateway; brak Origin/query/CORS, kompresji, Range lub żądań warunkowych. Dane wejściowe do512B, do128fragmentów, fatal UTF8 i3s. Dodatkowe pola są odrzucane; autor/operator/rola nie pochodzą z body lub niestandardowych nagłówków.

| Trasa | Dokładne pola body | Wynik |
| --- | --- | --- |
| queue | after: null albo poprzedni marker reportID | schemaVersion=1, do20metadanych reportID/createdAt/expiresAt i after |
| inspect | reportID | Powód zgłoszenia, opcjonalna dostępna wiadomość oraz inspectionID/inspectionExpiresAt/contentHash |
| decide | inspectionID, decisionID, verdict | Dokładny wynik decyzji i niezmienna revision |
| recover | reportID, decisionID, verdict, contentHash | confirmed/not-applied/superseded i revision tylko dla confirmed |

Wszystkie odpowiedzi mają protocolVersion=1, no-store, no-cache i nosniff. Nie ujawniają identyfikatora zgłaszającego, GPS ani dodatkowych pól profilu; tekst jest dostępny tylko w inspect. Dopuszczalne verdict: dismiss/hide_message. Rozstrzygnięcia i ich trwałość zachowują kontrakt CK-05c.2. Inspekcja nie jest dowodem obejrzenia treści przez człowieka; świadoma decyzja w panelu pozostaje wymagana.

Odpowiedzi są walidowane w Authority i ponownie w edge: ścisłe pola/typy, ograniczone i kanoniczne teksty, kolejność/unikatowość strony i postęp markera, świeże terminy oraz dokładne ID żądanej inspekcji/decyzji/recovery. Edge nie przepuszcza dodatkowych pól lub nagłówków. Limity rzeczywistych bajtów: queue8192, inspect12288, decide/recover2048, błąd2048. Do128fragmentów i poprawny Content-Length, fatal UTF8. Nieznany error/status, przekierowanie, publiczny cache lub niezgodny materiał zamykają odpowiedź.

Kody: REPORT_REVIEW_INPUT=400, SCOPE=403, STALE=409, CAPACITY=429, RESPONSE/UNAVAILABLE=503; pozostałe błędy przechodzą tylko przez zamknięte mapowanie wspólnego gateway. SCOPE nie daje klientowi podstawy do automatycznego usunięcia zwykłej sesji: może oznaczać brak roli. Nie drukujemy surowych błędów, odpowiedzi lub treści zgłoszeń.

## Osobne prawa i limity

REPORT_REVIEW_ENABLED musi być dokładnie1 i wymaga aktywnych COMMUNITY/PUBLIC_RECORDS/ACCOUNT_DELETION oraz ważnej konfiguracji Development. Lista REPORT_REVIEWER_IDS_JSON zawiera maks16unikatowych UUID kont Echoes, jest domyślnie pusta i nie dziedziczy moderatorów zdjęć. To nie identyfikatory CloudKit Users ani samo konto właściciela Apple. Nie ustawiamy jej na podstawie domysłu; rzeczywiste konta i uruchomienie wymagają konkretnego przygotowanego zakresu.

Authority rozwiązuje sesję i sprawdza osobną rolę przed body, checkpoint i IO; powtarza kontrolę po await i przed końcową odpowiedzią. Runtime odcina przygotowane odpowiedzi również po zmianie listy, flagi lub konfiguracji. Edge sprawdza ten sam niezmieniony zakres po odczycie body odpowiedzi. Publiczny endpoint nie nadaje żadnej roli. Wyłączona konfiguracja nie uruchamia odczytu poufnych danych.

Attemptowane body liczą się do osobnego trwałego limitu30żądań/min/konto i10inspekcji/min/konto. Liczniki mają oddzielny hash/kind od moderacji zdjęć; nie przełączamy jednego limitu w drugi. Pozostają wspólne limity Development:2000żądań/dobę,300ciężkich/dobę oraz12ciężkich/min/transport. To niskie pułapy kontrolowanego targetu, nie ocena pojemności gotowej aplikacji lub Free.

## Deadline i utrzymanie zasobów

Jedno żądanie na instancję handlera i jedno na isolate edge. Cały deadline Authority do12s, edge15s; rdzeń decyzji zachowuje własne8s. Zegar ścienny/monotoniczny, sygnał anulowania i limity fragmentów działają także dla strumienia zajmującego mikro-zadania. Edge najpierw sprawdza małe body, następnie przekazuje kanoniczny JSON z rzeczywistym Content-Length i wyłącznie dozwolonymi nagłówkami oraz serwerowym hashem budżetu platformowego IP.

Slot pozostaje zajęty do faktycznego zakończenia fetch/read/cancel i pracy rdzenia, również po timeout. `CommunityReportReview.waitForPendingOperations` obejmuje pracę zakończoną dopiero po drain klienta; gotowy finalizer ma osobny stan occupied. Nieudane anulowanie lub niemożność potwierdzenia własności strumienia zamyka gate do restartu instancji. Późna Response jest anulowana z zachowaniem slotu. Lokalny alarm pomija pracę zewnętrznych providerów, gdy serwis zgłoszeń jest zajęty; nadal wykonuje lokalną retencję.

## Dowody i pozostała praca

16nowych funkcji:15HTTP/Runtime/granic strumieni i1workerd. Pełne **742/742 Node22.23.5 i742/742 Node24.22.1**. Działają exact queue→inspect→decide→recover, odmowa zwykłego konta i osobna konfiguracja, ścisły body/result/headers, limity, zmiana roli po końcowym checkpoint lub podczas body edge, niewspółpracujące IO, zachowanie slotu do drain i trwałe zamknięcie po błędzie cancel.

Lokalny workerd z rzeczywistym Durable Object/SQLite, podpisami i publicznym kodem edge/Authority/Runtime potwierdził decyzję hidden, zniknięcie z kolejki, tę samą revision po utworzeniu nowego Runtime, odmowę zwykłej sesji, disabled po wyłączeniu flagi, brak treści/tokenów w SQL i prywatne nagłówki. Sieć zewnętrzna harnessu była odcięta. Provider Apple, platformowe cf/IP i tożsamości są jawnie syntetyczne. Nowy Runtime w tym samym DO nie jest eviction/PITR ani próbą hostowanego Cloudflare.

Nie było prawdziwego SIWA/operatora, uprawnień zwykłych kont A/B, kontaktu z Apple/Cloudflare, nowych kluczy lub przekazania sekretów, wdrożenia, opłat, SDK telefonu, Production/Firebase/TestFlight. iOS/Swift/UI i zależności/CI niezmienione, ich testów lub kompilacji nie ponawiano. Następne: typowany natywny kontrakt, chroniony panel i trwały decision intent/recovery, potem realny odbiór sesji/ról/hostingu oraz cały pozostały plan migracji.

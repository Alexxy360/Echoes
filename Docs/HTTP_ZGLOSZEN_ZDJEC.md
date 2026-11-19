# Zgłoszenia zdjęć — chroniony intake i HTTP (CK-05d.1b)

Stan: implementacja i odbiór lokalny. Domyślna flaga `AVATAR_REPORT_ENABLED=0`. Nie wdrożono tego etapu na hostingu ani nowego typu w Apple. Dalsze kroki obejmuje [plan zgłoszeń](ZGLOSZENIA_ZDJEC_PLAN.md).

## Kontrakt

Wspólne warunki: HTTPS, POST, bez query i Origin, kanoniczna sesja `Authorization: Bearer …`, `Content-Type: application/json` (opcjonalnie charset=utf-8). Backend uwierzytelnia zwykłe aktywne konto; listy moderatorów zdjęć i wiadomości nie nadają praw do tworzenia zgłoszeń. Własne zdjęcie nie może być zgłoszone. Serwer nie przyjmuje accountID zgłaszającego, roli, generacji publikacji ani skrótu obrazu z JSON.

| Trasa | Dokładne pola JSON | Warunki dodatkowe |
| --- | --- | --- |
| `/v1/community/avatar/report` | requestID UUID, ownerID UUID, versionID UUID, reason, coordinate {latitude,longitude} | Aktywny odczyt zdjęć; dokładna bieżąca publikacja, aktywna obecność właściciela, zasięg 3 km, brak blokad w obu kierunkach. |
| `/v1/community/avatar/report/recover` | requestID UUID | Wyłącznie istniejąca własna próba; odczyt zdjęcia, GPS i ponowny dostęp do osoby nie są potrzebne. |

Powód jest przycinany i normalizowany NFC, ma 1–500 jednostek UTF-16; samotne surrogaty są odrzucane. Serwer nie zapisuje współrzędnych w raporcie ani jego lokalnym journalu intencji. Zasięg jest liczony od podanej pozycji do aktywnej przybliżonej obecności — nie dowodzi fizycznej pozycji urządzenia. To ta sama granica zaufania pozycji co w chronionym odczycie zdjęcia.

Odpowiedź sukcesu ma wyłącznie protocolVersion=1, schemaVersion=1, requestID, reportID i outcome. reportID pochodzi z konta sesji i requestID. Submit może zwrócić `accepted`; recovery może zwrócić `accepted` lub `unconfirmed`. Nie ma powodu, wskazania osoby, skrótu obrazu, pikseli ani URL dostawcy w odpowiedzi. Zawsze no-store/nosniff, bez CORS. Edge weryfikuje wersję/protokół, zamknięte pola, powiązanie requestID, namespace raportu oraz status/kod błędu; Authority dodatkowo wylicza dokładny reportID z konta sesji.

`accepted` potwierdza zapis zgłoszenia, nie decyzję moderatora i nie usunięcie zdjęcia. `unconfirmed` nie dowodzi, że dawne CREATE nigdy nie dotrze. Recovery nie ponawia CREATE/REPLACE treści; może utrwalić potwierdzenie znanej intencji/rejestru i checkpoint. Nie generuje nowego requestID. Błąd po wysłaniu submit oznacza nieznany wynik dla klienta, również gdy w odpowiedzi jest 404/401/503 po późniejszej zmianie stanu. Klient zachowuje pierwotny requestID i wykonuje jawne recovery; nie tworzy automatycznie nowego zgłoszenia.

## Sprawdzenie dokładnej wersji

Coordinator odczytuje zaufaną publikację, weryfikuje dokładny wskaźnik CloudKit i obecność przez chroniony read lease, a następnie dokładny rekord avatar z tagiem, metadanymi i zobowiązaniami obu ASSET. Nie pobiera JPEG/CDN. Wylicza avatarID, versionID, publicationGeneration i imageSHA256 po stronie serwera; do zapisu dodaje jedynie zwalidowany reason. Każde IO i końcowy ACK ponownie sprawdzają konto, aktywację, publikację, obecność, zasięg i obie blokady. Zmiana wycofuje zgodę na zaakceptowany ACK; rozpoczęty wcześniej zapis może już istnieć i pozostaje do recovery.

Intencja w CommunityState jest dokładnie związana z requestID i hash treści. Jest dołączona do istniejącego erasure właściciela i wspólnego limitu zgłoszeń. Finalizer jest jednorazowy; stary nie zwalnia miejsca zajętego przez nową operację. Submit i recovery kontrolują aktualną czytelność/tag/hash raportu także po ostatnim checkpoint. Retencja i create-only pozostają takie jak w CK-05d.1a: 30 dni od pierwszego createdAt, bez przedłużania przez retry.

## Granice zasobów i konfiguracja

- Zamknięte JSON: maksymalnie 4096 rzeczywistych bajtów, 128 niepustych fragmentów, fatal UTF-8, zgodność Content-Length; body ma własny limit do 3 sekund. Range, warunkowe nagłówki i nagłówki zamiaru/manifestu/wyboru/recenzji zdjęcia są odrzucone. Odpowiedź ma maksymalnie 2048 B.
- Authority pobiera istniejący trwały budżet globalny/IP przed body, następnie budżet uwierzytelnionego konta przed parsowaniem. Osobny namespace: 6 prób/min łącznie, w tym 3 submit/min. Odrzucona próba także może zużyć budżet łączny; klient musi respektować backoff.
- Zapis zdjęciowy i zgłoszenie wiadomości dzielą trwały odstęp 10 sekund. Identyczna intencja jest idempotentna; inny reason pod tym samym requestID daje konflikt. Brak migracji tabel: użyto istniejących community_intents_v1, report_at i gateway_windows_v1.
- Pozostają limity Development: 2000 żądań/dzień i 300 ciężkich operacji/dzień globalnie, 120 żądań/min i 12 ciężkich/min na budżet platformowego IP. To celowo niski budżet testowy, nie potwierdzona wydajność aplikacji społecznościowej ani gwarancja kosztu.
- Core ma limit do 8 sekund, Authority do 12, Edge do 15. Rzeczywiste timery działają przy zamrożonym zegarze aplikacji; cofnięcie czasu odmawia. Jeden zatrzymany slot na instancję core/Authority oraz jeden na Edge isolate. Timeout/anulowanie nie zwalnia go przed rzeczywistym końcem fetch/read/cancel. Niepotwierdzony drain zamyka instancję do odtworzenia; nie ma automatycznego resetu ani retry zapisu.
- Edge używa wyłącznie platformowego CF-Connecting-IP i metadanych colo, podpisuje budżet i odtwarza allowlist nagłówków. Żaden X-Operator/X-Forwarded-For/budżet użytkownika nie jest przekazywany jako uprawnienie.
- Aktywacja wymaga istniejących GATEWAY/PUBLIC_RECORDS/COMMUNITY i ACCOUNT_DELETION. Submit dodatkowo AVATAR_READ i zweryfikowanych hostów. Recovery działa z AVATAR_READ=0, bez hostów, uploadu i ról moderatorów. W tym trybie właściciel zachowuje status/clear, lecz nie uzyskuje publikacji, uploadu ani moderacji.

Kody domeny: AVATAR_REPORT_INPUT (400), SCOPE (401), NOT_FOUND (404), CONFLICT (409), LIMIT (429), RESPONSE/UNAVAILABLE (503), zawsze z pełnym prefiksem. Błędy wspólnych limitów/aktywacji zachowują ustalone kody bramki. Odpowiedzi nie zawierają surowych błędów dostawcy ani kodów panelu moderatora.

## Dowody i ograniczenia

[Zapis weryfikacji](evidence/avatar-report-intake-local-tests.json) obejmuje cały zestaw gateway, testy negatywne i rzeczywisty lokalny workerd/DO/SQLite. Provider Apple, konta i platformowe metadata są jawnie modelowane; test workerd ma zablokowany zewnętrzny outbound. Odtworzenie Runtime korzysta z tej samej lokalnej instancji procesu/bazy; nie jest dowodem przetrwania utraty zasilania lub restartu procesu. Nowe opóźnione cancel sprawdzono w Node Web Streams, nie na hostingu.

Native DTO/journal/formularz i osobny operator zgłoszeń zdjęć pozostają do wykonania. Nie importowano schematu, nie zmieniono praw/kluczy/sekretów/usług, nie uruchomiono opłat ani Production, Firebase i TestFlight. Zwykłe A/B, SIWA, rzeczywiste query/ASSET/CDN/retencja, Free i urządzenia nadal wymagają odbioru. Kontakt do wsparcia właściciel poda później.

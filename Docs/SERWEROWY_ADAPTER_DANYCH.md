# Serwerowy adapter rekordów społecznościowych — CK-04a

Stan: 15 listopada 2026. Zaimplementowano rzeczywisty transport CloudKit Web Services Development/public, rejestr zapisów w prywatnym SQLite i repozytorium pięciu typów. Po jawnym włączeniu w konfiguracji runtime podłącza ten adapter do istniejącego procesu usuwania. Domyślne `PUBLIC_RECORDS_ENABLED=0`, `GATEWAY_ENABLED=0` i `ACCOUNT_DELETION_ENABLED=0` pozostają wyłączone. Nie utworzono usługi, typów/indeksów/ról ani sekretów w chmurze. Zwykły klient iOS nadal korzysta z Firebase; serwerowe HTTP mapy/czatu i własnego profilu dodano w CK-04c, nadal bez aktywacji i natywnego adaptera.

Aktualizacja CK-04b: dodano [punkt kontrolny i obsługę cofnięcia rejestru](PUNKT_KONTROLNY_REJESTRU.md), także dla auth/HTTP i procesora. W CK-04b 234/234 Node 22/24; poniższy CK-04a zachowuje swój zakres historyczny. Nadal brak aktywacji i rzeczywistego odbioru usług.

## Własność i format

`CloudKitPublicRepository.write` ustala accountID przez istniejącą autoryzację access tokenu. Klient nie wybiera właściciela, typu CloudKit, dowolnego pola, terminu lub ścieżki podpisywania. Zamknięty kontrakt obejmuje:

| Rodzaj | Typ CloudKit | Zawartość i klucz |
| --- | --- | --- |
| profile | EchoesPublicProfileV1 | Pseudonim, singleton konta. Bez automatycznego przypisania starego Firebase. |
| presence | EchoesPresenceV1 | Pseudonim, przybliżona pozycja, muzyka/generacja. Serwerowy termin 10 min; sprawdzenie wieku pomiaru. |
| message | EchoesLocalMessageV1 | Pseudonim, treść, przybliżona pozycja i serwerowe czasy 2 h. UUID żądania jest kluczem idempotencji. |
| block | EchoesBlockV1 | Docelowy UUID i stan preferencji. Klucz logiczny musi odpowiadać celowi. |
| report | EchoesReportV1 | Nazwa rekordu wiadomości i powód. Osobny UUID żądania. |

Nazwy `community-v1-<kind>-<digest>` i ownerKey powstają na serwerze. Wspólny format ma schemaVersion, erased, hash operacji/treści i serwerowe czasy. Pozycja jest zaokrąglana do 3 miejsc dziesiętnych przed zapisem; nie jest dowodem fizycznego pobytu. Pola latitude/longitude zawsze mają typ DOUBLE, również przy zerze. Schemat odrzuca obce pola i nie obsługuje jeszcze CKAsset. Czas wygaśnięcia oznacza termin widoczności; fizyczne sprzątanie wygasłych treści nadal wymaga osobnego wykonawcy.

Domyślna publiczna baza CloudKit ma być dostępna wyłącznie przez usługę. Dla wszystkich pięciu typów wymagane jest odebranie praw `_world`, `_icloud` i `_creator` oraz nadanie osobnej tożsamości serwisowej potrzebnych praw. Zwłaszcza zgłoszenia i blokady nie mogą być publicznie czytelne. Te role nie są wdrożone ani odebrane na dwóch zwykłych kontach. S2S nie omija ACL.

## Trwałość i wersje

`PublicRecordRegistry` działa w tym samym authority/SQLite co konto i zadania. Zapisuje dokładny identyfikator rekordu, konto, typ, skrót klucza logicznego, skrót payloadu, requestID, generację i tagi. Nie przechowuje treści, nazwy ani GPS. Surowy UUID celu blokowania nie jest zapisywany jako klucz SQL. Rezerwacja i liczniki powstają w transakcji, a `storage.sync()` poprzedza wyjście do CloudKit. Przed dispatch i po odpowiedzi ponownie sprawdzane są sesja/generacja oraz stan rejestru.

Operacje używają wyłącznie create i replace z recordChangeTag. Nie ma forceUpdate/forceReplace/forceDelete. Profile, obecność i blokady mają warunkowe aktualizacje; wiadomości/zgłoszenia są tutaj niemodyfikowalne. Identyczne jawne ponowienie nieznanego wyniku zachowuje payload i czasy. EXISTS/CONFLICT może doprowadzić do odczytu dokładnego rekordu i uznania wyłącznie tego samego mutationKey/payloadu. Inny requestID nie zastępuje pending. Sam transport nie robi retry ani pętli.

Kontrolowany target ogranicza rejestr, włącznie z zachowanymi barierami, do 1000 wpisów na konto i 10000 łącznie. Trwałe liczniki nie skanują całego rejestru przy każdym zapisie; inicjalny bounded COUNT/GROUP BY służy migracji liczników. Błąd insert cofa liczniki i rezerwację. To limity prototypu Development, nie deklaracja pojemności wydania lub liczby użytkowników. Ich zwalnianie i retencja nadal są do zaprojektowania.

## Usuwanie i spóźnione zapisy

Puste query nie jest dowodem braku danych: [Apple opisuje asynchroniczną aktualizację indeksów](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/QueryingRecords.html). Adapter bierze dokładne własne ID z rejestru. Sprawdza aktywne zadanie, właściciela, lease i blokadę konta; utrwala stan erasing przed siecią. Nowe rezerwacje zablokowanego konta są odrzucane.

Partia obejmuje najwyżej 25 rekordów i maksymalnie jeden lookup oraz jeden modify, bez zapytań indeksowych. Dla brakującego jeszcze CREATE powstaje bariera pod tym samym ID. Istniejący rekord jest zastępowany warunkowo minimalnymi polami schemaVersion/ownerKey/erased/deletionKey, z usunięciem całej treści i nieznanych pól. Jeśli stary zapis wygra wyścig, erasure dostaje konflikt i wymaga kolejnego kroku. Jeśli wygra bariera, stary create/replace nie odtworzy treści. Bariera jest ponownie zastępowana także po utracie odpowiedzi: sam metadata-only lookup nie dowodzi nieobecności dodatkowych pól.

Pełna odpowiedź modyfikacji jest sprawdzana per nazwa/typ/właściciel/tag/pola. Częściowy sukces potwierdza tylko własne sprawdzone rekordy i nie daje false completed. Po udanej barierze rejestr usuwa requestID, payloadHash, expectedTag i klucz logiczny oraz zeruje wcześniejsze czasy aktywności i generację; pozostaje minimalna identyfikacja bariery. Barier nie kasuje się fizycznie w tym etapie. Istniejący job runner zachowuje osobny settling pass, private ACK i odwołanie Apple.

## Transport i konfiguracja

`CloudKitPublicClient` podpisuje tylko stały kontener Development/public i dozwolone ID/typy. Wysyła JSON bez redirectów, ogranicza odpowiedź do 512 KiB i 8 s dla całego fetch/body także przy dostawcy ignorującym AbortSignal. Anulowanie nadrzędne kończy oczekiwanie; błędne/duplikowane/obce wyniki i UTF-8 są odrzucane. Błąd ma stały tekst/kod, bez upstream reason, URL lub cause. Publiczne klucze SIWA i CloudKit są porównywane kryptograficznie, więc zmiana formatowania PEM nie pozwala użyć tej samej pary.

Aktywacja wymaga PUBLIC_RECORDS_ENABLED=1, włączonego usuwania, istniejącego okna Development oraz osobnych CLOUDKIT_KEY_ID/CLOUDKIT_PRIVATE_KEY. Nie ma wartości domyślnych lub fallback do testowego cleanera. Istniejące testy auth mogą nadal jawnie wstrzykiwać model przy wyłączonym public storage; entry point usługi tego nie robi. Nowe uprawnienia/sekrety/usługa wymagają przygotowanego zakresu i zgody; ten etap ich nie uruchamia.

## Wyniki i otwarte wymagania

217/217 testów na Node 22.23.5 i 24.22.1, w tym 21 nowych (20 transportu/rejestru/repozytorium i 1 kompozycji runtime/HTTP). P-256 jest generowane w pamięci i niezależnie sprawdzane verify(). SQLite jest rzeczywiste lokalnie, CloudKit/Apple są jawnymi modelami. Testy obejmują nieznane create/replace, późne odpowiedzi po barierze, różne konta, wszystkie typy, 52 rekordy, częściowy błąd, dodatkowe pola, lease, limity 1000/10000, rollback, deadline/cancel i rozdział kluczy. Node 22 pobrano tymczasowo z nodejs.org i sprawdzono SHA-256; nie instalowano systemowo. Składnia 49 MJS i konfiguracja JSON poprawne. [Raport i hashe](evidence/public-records-local-tests.json).

CK-04b dodaje zdalny checkpoint/epokę i outbox wymagane przed potwierdzaniem completed. Odbiór dotyczy lokalnych modeli i spójnych snapshotów SQLite, nie rzeczywistego PITR. Przed aktywacją nadal trzeba przygotować i odebrać bootstrap, inwentarz nowej przestrzeni i procedurę operatora oraz potwierdzić brak wcześniejszych niezarejestrowanych rekordów.

Nadal wymagane są retencja barier/rejestru, workflow operatora, HTTP funkcji społecznościowych wraz z limitami, blokadami/zakresem 3 km/moderacją, iOS CommunityClient, publiczne zdjęcia/CKAsset, schemat/indeksy/role, rzeczywisty Workers CPU/SQL i A/B. Prymityw zapisu preferencji/zgłoszeń sam nie egzekwuje blokad odpowiedzi ani uprawnień do zgłaszanej wiadomości; zrobi to koordynator. Nie zaliczono pełnej migracji lub TestFlight. Swift/UI i projekt aplikacji pozostały identyczne z poprzednim checkpointem; nie powtarzano ich testów.

Podstawy protokołu: [lookup](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/LookupRecords.html), [create/replace i tagi](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html), [kody błędów](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ErrorCodes.html).

Aktualizacja CK-04c: [funkcje i zamknięte HTTP](FUNKCJE_SPOLECZNOSCIOWE_GATEWAY.md), 256/256 Node 22/24. Odczyty exact-ID po regionalnych kandydatach, writeLatest tylko dla presence/block z aktualnym zamiarem, inactive slot bez treści i zachowanie około 500 m. Prywatna projekcja zasad jest czyszczona przez procesor właściciela. Pole LOCATION i indeksy wymagają rzeczywistego odbioru; domyślne flagi 0.

# Punkt kontrolny rejestru i odtworzenie SQLite — CK-04b

Stan: 15 listopada 2026. Dodano zdalny punkt kontrolny z trwałym outboxem, sprawdzany przed zapisem/usuwaniem rekordów oraz w natywnym HTTP auth/usuwania. Domyślne flagi nadal mają wartość 0. Nie utworzono rekordów, typów, ról, usług ani sekretów w chmurze. Zwykły klient iOS nadal Firebase.

## Dlaczego sama liczba rekordów nie wystarcza

Przywrócenie starszej kopii SQLite może zgubić informację o rekordach istniejących w CloudKit. Ponowne dopisanie innego rekordu może dać ten sam licznik. Cofnięcie wylogowania może również odtworzyć ważną lokalnie sesję bez zmiany liczby rekordów. Kontrola musi rozróżniać historię potwierdzeń, zanim powstanie nowa rezerwacja lub odpowiedź nadająca dostęp.

Cloudflare opisuje [PITR jako przywrócenie całej bazy podczas restartu instancji](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/#onnextsessionrestorebookmark). Ten protokół chroni spójne transakcyjne kopie i utratę rejestru. Nie jest deklaracją integralności dowolnego ręcznie przepisanego SQL ani odtworzenia brakujących danych przez automat.

## Dwa powiązane magazyny

| Miejsce | Zawartość |
| --- | --- |
| SQLite public_registry_checkpoint_v1 | Losowa epoka registryID, początkowy anchor, ostatnie potwierdzone pola/tag i najwyżej jeden pending wraz z oczekiwanym tagiem rodzica. |
| CloudKit EchoesRegistryCheckpointV1 / community-registry-checkpoint-v1 | schemaVersion=1, registryID, anchorID, parentAnchorID i registeredCount. Bez nazw, GPS, treści, tokenów Apple lub danych konkretnego użytkownika. |

`PublicRegistryCheckpoint` serializuje wyłącznie pracę punktu kontrolnego. Nowy losowy anchor jest zapisywany w SQLite i synchronizowany przed warunkowym replace CloudKit. Dzięki temu przywrócona kopia może uznać zdalny wynik wyłącznie wtedy, gdy zawiera dokładne potwierdzenie lub jego wcześniejszy, utrwalony outbox. Sama zgodność licznika nie wystarcza.

Utrata odpowiedzi nie tworzy nowej historii bez sprawdzenia. Jeśli zdalny rekord odpowiada pending, następuje lokalne potwierdzenie bez ponownego zapisu. Jeśli nadal odpowiada rodzicowi, jawne advance może ponowić dokładnie ten sam pending z tym samym tagiem. Konflikt pozwala na jeden odczyt sprawdzający ten sam wynik; inna gałąź blokuje operację. Po rozstrzygnięciu starszego pending advance tworzy nowy anchor, obejmujący bieżącą pracę. Kolejka nie dziedziczy błędu poprzedniej próby.

Każde porównanie obejmuje wszystkie pola i tag. Brak rekordu, inna epoka, nieznany anchor, niespójny pending lub nieprawidłowe pola kończą się błędem. Nie ma forceReplace, automatycznego resetu do 0, przestawienia zdalnego punktu na starszą kopię ani domyślnego false remaining. Stare odpowiedzi nie nadpisują nowszego lokalnego potwierdzenia. Rejestr przy otwarciu sprawdza zgodność ograniczonych liczników z rekordami; istniejące wpisy bez epoki wymagają osobnego zbadania zamiast automatycznej adopcji.

## Gdzie obowiązuje kontrola

- Repozytorium sprawdza punkt przed reserve, utrwala go po rezerwacji przed dispatch i po zapisie przed zwróceniem wyniku. Po dodatkowym await ponownie sprawdza sesję i aktualny request.
- Usuwanie sprawdza punkt przed wyborem partii, po erasing przed CloudKit oraz po potwierdzeniu barier przed receipt. Pusty lokalny zbiór nie omija kontroli odtworzenia.
- HTTP sprawdza punkt po limitach/body, przed dispatch, i zapisuje go przed odpowiedzią, także po błędzie operacji. Shallow health pozostaje wyłącznie liveness. Wyczerpany limit nie generuje kolejnych wywołań CloudKit.
- Runtime utrwala punkt przed żądaniem do Apple i wokół kroku procesora usuwania. Aktywne maintenance utrwala wynik; lokalna retencja po wyłączeniu/utracie konfiguracji nadal działa bez klucza i nie uruchamia dostawców.
- Authority z utworzoną lokalną epoką nie może uruchomić auth-only bez tej kontroli. Handler bez checkpoint utworzony przez tę wersję w tym samym magazynie zostaje wyłączony; po dispatch ponownie sprawdzana jest aktywacja.

Usunięcie danych, revoke lub rotacja mogą wykonać się lokalnie przed nieznanym wynikiem punktu kontrolnego. Taki przypadek nie zwraca potwierdzonego sukcesu. Kolejna próba musi rozstrzygnąć dokładny outbox lub zgłosić potrzebę odzyskania stanu. Zabezpieczenie celowo zatrzymuje dostęp po cofnięciu potwierdzonego wylogowania.

## Pierwsza inicjalizacja i odzyskanie awarii

Runtime nigdy nie tworzy brakującego rekordu kontrolnego. `prepareBootstrap()` przygotowuje lokalną epokę wyłącznie przy pustym rejestrze bez potwierdzenia/pending. Oddzielne, niewystawione w HTTP `createCheckpointForBootstrap()` potrafi jedynie create początkowego rekordu; istniejącego nie zastąpi. Późniejsze verify może przyjąć tylko dokładnie przygotowany początek. Są to narzędzia dla zaufanej inicjalizacji, nie nowa zgoda na operacje w Apple.

Przed rzeczywistą inicjalizacją trzeba potwierdzić nową przestrzeń i inwentarz, przygotować konkretny rekord/epokę oraz role i uzyskać zgodę na tę operację. Typ kontrolny wymaga praw wyłącznie tożsamości serwisowej, bez `_world`, `_icloud` i `_creator`, tak jak chronione typy społecznościowe. Nie opublikowano schematu. Przypadek starych wpisów bez punktu lub potwierdzonej innej gałęzi wymaga odzyskania odpowiedniej kopii i przeglądu operatora; nie należy naprawiać go przez ręczne nadpisanie punktu lub utworzenie nowej epoki nad istniejącymi danymi.

## Dowody i pozostały odbiór

234/234 testy na Node 22.23.5 i 24.22.1; 17 nowych (12 checkpoint i 5 HTTP/runtime). Obejmują brak rekordu, utratę bootstrap/advance response, failure zapisu i sync, restart, dwie gałęzie przy tym samym liczniku, pełną utratę epoki, blokadę false erasure, obie kolejności spóźnionej odpowiedzi oraz cofnięcie logout-all, wyłączenie auth-only, limit przed siecią i brak Apple dispatch. Snapshoty przywracają własne syntetyczne tabele w rzeczywistym lokalnym SQLite; nie jest to test Cloudflare PITR. CloudKit/Apple są modelami. Składnia 52 MJS i konfiguracja JSON poprawne.

Kontrola negatywna w oddzielnej kopii /tmp, po wyłączeniu jednego porównania potwierdzonego zdalnego anchor/tag, faktycznie wykryła nieprawidłową trzecią rezerwację po cofnięciu (3 zamiast 2). Źródła właściwe niezmienione; ich pełna regresja jest zielona. [Raport i hashe](evidence/registry-checkpoint-local-tests.json).

Prawdziwe SDK/role/PITR/Workers i zwykłe konta A/B niezaliczone. Dodatkowe odczyty i modyfikacje punktu zwiększają opóźnienia i liczbę operacji; CPU/SQL/transfer w Workers Free trzeba zmierzyć przed aktywacją. Retencja barier i metadanych, inwentarz/operacyjne odzyskanie, koordynator funkcji/HTTP, adapter iOS, profile/zdjęcia i pełna regresja produktu pozostają wymagane. Nie powtarzano kompilacji iOS, bo źródła Swift/projekt są identyczne. Bez zmian Production, płatnych usług, danych użytkowników lub Firebase.

Podstawa warunkowego zapisu: [Apple — create/replace i recordChangeTag](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html).

Aktualizacja CK-04c: koordynator funkcji i zamknięte HTTP są już [zaimplementowane lokalnie](FUNKCJE_SPOLECZNOSCIOWE_GATEWAY.md). Finalizer odpowiedzi ponawia lokalne kontrole po ostatnim advance, a czyszczenie projekcji także otrzymuje punkt kontrolny przed receipt procesora. Realny bootstrap/PITR/role, natywny adapter, retencja i odbiór kosztów pozostają otwarte.
